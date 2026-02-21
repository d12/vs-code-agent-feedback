#!/usr/bin/env ruby
# frozen_string_literal: true

# Response Server for Agent Approval System
# This server runs locally and provides a web-based UI for handling agent requests
# It discovers MCP servers by polling a range of ports (for CodeSpaces support)

require 'socket'
require 'json'
require 'timeout'
require 'net/http'
require 'uri'
require 'securerandom'
require 'time'

# Load local libraries
require_relative 'lib/notifier'

class ResponseServer
  DEFAULT_PORT = 18463
  MCP_PORT_RANGE = (14700..14715).freeze
  POLL_INTERVAL = 2 # seconds

  def initialize(port: DEFAULT_PORT)
    @port = port
    @notifier = Notifier.default
    @running = false
    @clients = {} # client_id => { url:, name:, last_seen: }
    @pending_requests = {} # request_id => { client_id:, type:, data:, created_at: }
    @responses = {} # request_id => response data
    @clients_mutex = Mutex.new
    @requests_mutex = Mutex.new
  end

  def start
    @running = true
    @server = TCPServer.new('0.0.0.0', @port)

    display_banner
    puts "✓ Web server listening on http://localhost:#{@port}"
    puts "  Open this URL in your browser to manage agent requests"
    puts "  Polling ports #{MCP_PORT_RANGE.first}-#{MCP_PORT_RANGE.last} for MCP clients..."
    puts "-" * 60
    puts

    # Handle graceful shutdown
    setup_signal_handlers

    # Start the client discovery thread
    @discovery_thread = Thread.new { discovery_loop }

    while @running
      begin
        client = @server.accept
        Thread.new(client) { |c| handle_client(c) }
      rescue IOError, Errno::EBADF
        break
      rescue => e
        puts "Error accepting connection: #{e.message}"
      end
    end
  end

  def stop
    @running = false
    @discovery_thread&.kill
    @server&.close
  end

  private

  def setup_signal_handlers
    %w[INT TERM].each do |signal|
      Signal.trap(signal) do
        puts "\nReceived #{signal}, shutting down..."
        stop
      end
    end
  end

  def display_banner
    banner = <<~BANNER

      ╔═══════════════════════════════════════════════════════════╗
      ║                                                           ║
      ║   🤖  Agent Approval Response Server  🤖                  ║
      ║         (Web Interface Edition)                           ║
      ║                                                           ║
      ╚═══════════════════════════════════════════════════════════╝

    BANNER
    puts banner
  end

  # Discovery loop - polls the port range for MCP clients
  def discovery_loop
    while @running
      MCP_PORT_RANGE.each do |port|
        check_port_for_client(port)
      end
      sleep POLL_INTERVAL
    end
  end

  def check_port_for_client(port)
    uri = URI("http://127.0.0.1:#{port}/mcp-status")
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 0.5
    http.read_timeout = 0.5

    request = Net::HTTP::Get.new(uri.path)
    response = http.request(request)

    if response.code == '200'
      data = JSON.parse(response.body)
      client_id = data['client_id']
      
      @clients_mutex.synchronize do
        existing = @clients[client_id]
        @clients[client_id] = {
          url: "http://127.0.0.1:#{port}",
          name: data['name'] || "CodeSpace #{client_id[0..7]}",
          last_seen: Time.now,
          port: port
        }
        
        if existing.nil?
          puts "[#{Time.now.strftime('%H:%M:%S')}] New client connected: #{data['name'] || client_id} on port #{port}"
        end
      end

      # Check for pending requests from this client
      fetch_pending_requests(client_id, port)
    end
  rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout, Errno::EHOSTUNREACH
    # Port not responding, ignore
  rescue => e
    # Unexpected error, log but continue
    puts "[Discovery] Error checking port #{port}: #{e.message}" if ENV['DEBUG']
  end

  def fetch_pending_requests(client_id, port)
    uri = URI("http://127.0.0.1:#{port}/pending-requests")
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 1
    http.read_timeout = 1

    request = Net::HTTP::Get.new(uri.path)
    response = http.request(request)

    if response.code == '200'
      data = JSON.parse(response.body)
      requests = data['requests'] || []
      
      @requests_mutex.synchronize do
        requests.each do |req|
          request_id = req['request_id']
          next if @pending_requests[request_id] # Already have this request

          @pending_requests[request_id] = {
            client_id: client_id,
            type: req['type'],
            data: req['data'],
            created_at: Time.parse(req['created_at'])
          }

          # Send notification for new request
          notify_new_request(req['type'], req['data'])
          puts "[#{Time.now.strftime('%H:%M:%S')}] New #{req['type']} request from #{@clients[client_id][:name]}"
        end
      end
    end
  rescue => e
    puts "[Fetch] Error getting requests from port #{port}: #{e.message}" if ENV['DEBUG']
  end

  def notify_new_request(type, data)
    case type
    when 'approval'
      @notifier.notify(
        title: '🤖 Agent Needs Approval',
        message: 'An agent is waiting for your approval. Check the browser.'
      )
    when 'question'
      @notifier.notify(
        title: '❓ Agent Has a Question',
        message: 'An agent is waiting for your answer. Check the browser.'
      )
    end
  end

  def handle_client(client)
    request_line = client.gets
    return unless request_line

    # Read headers
    headers = {}
    while (line = client.gets) && line != "\r\n"
      key, value = line.split(': ', 2)
      headers[key&.downcase] = value&.strip
    end

    # Read body if content-length specified
    body = ''
    if headers['content-length']
      body = client.read(headers['content-length'].to_i)
    end

    # Parse HTTP request
    method, path, = request_line.split(' ')
    path_without_query = path.split('?').first

    response = route_request(method, path_without_query, path, body, headers)
    send_response(client, response[:status], response[:body], response[:content_type] || 'application/json')
  rescue => e
    puts "Error handling client: #{e.message}"
    puts e.backtrace.first(5).join("\n") if ENV['DEBUG']
    send_response(client, 500, { error: e.message }.to_json)
  ensure
    client&.close
  end

  def route_request(method, path, full_path, body, headers)
    case [method, path]
    when ['GET', '/']
      serve_index_html
    when ['GET', '/health']
      { status: 200, body: { status: 'ok' }.to_json }
    when ['GET', '/api/clients']
      get_clients
    when ['GET', '/api/requests']
      get_requests
    when ['POST', '/api/respond']
      handle_response(body)
    when ['GET', '/api/events']
      # SSE endpoint for real-time updates
      { status: 200, body: 'SSE not implemented in simple server', content_type: 'text/plain' }
    else
      { status: 404, body: { error: 'Not found' }.to_json }
    end
  end

  def get_clients
    @clients_mutex.synchronize do
      # Clean up stale clients (not seen in 30 seconds)
      @clients.reject! { |_, v| Time.now - v[:last_seen] > 30 }
      
      clients_list = @clients.map do |id, info|
        {
          id: id,
          name: info[:name],
          port: info[:port],
          last_seen: info[:last_seen].iso8601
        }
      end
      
      { status: 200, body: { clients: clients_list }.to_json }
    end
  end

  def get_requests
    @requests_mutex.synchronize do
      # Filter out requests that have been responded to
      pending = @pending_requests.reject { |id, _| @responses.key?(id) }
      
      requests_list = pending.map do |id, req|
        client_name = @clients_mutex.synchronize { @clients[req[:client_id]]&.dig(:name) || 'Unknown' }
        {
          id: id,
          type: req[:type],
          data: req[:data],
          client_id: req[:client_id],
          client_name: client_name,
          created_at: req[:created_at].iso8601
        }
      end
      
      { status: 200, body: { requests: requests_list }.to_json }
    end
  end

  def handle_response(body)
    data = JSON.parse(body)
    request_id = data['request_id']
    response_data = data['response']

    @requests_mutex.synchronize do
      unless @pending_requests.key?(request_id)
        return { status: 404, body: { error: 'Request not found' }.to_json }
      end

      req = @pending_requests[request_id]
      client_id = req[:client_id]

      # Get client info
      client_info = @clients_mutex.synchronize { @clients[client_id] }
      unless client_info
        return { status: 400, body: { error: 'Client no longer connected' }.to_json }
      end

      # Send response to the MCP server
      uri = URI("#{client_info[:url]}/respond")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 5
      http.read_timeout = 5

      post_request = Net::HTTP::Post.new(uri.path)
      post_request['Content-Type'] = 'application/json'
      post_request.body = {
        request_id: request_id,
        response: response_data
      }.to_json

      result = http.request(post_request)

      if result.code == '200'
        # Mark as responded
        @responses[request_id] = response_data
        @pending_requests.delete(request_id)
        puts "[#{Time.now.strftime('%H:%M:%S')}] Response sent for request #{request_id[0..7]}"
        { status: 200, body: { success: true }.to_json }
      else
        { status: 500, body: { error: "Failed to send response: #{result.body}" }.to_json }
      end
    end
  rescue JSON::ParserError => e
    { status: 400, body: { error: "Invalid JSON: #{e.message}" }.to_json }
  rescue => e
    { status: 500, body: { error: e.message }.to_json }
  end

  def serve_index_html
    html = <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Agent Approval Center</title>
        <style>
          * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
          }
          
          :root {
            --bg-primary: #fafbfc;
            --bg-secondary: #ffffff;
            --bg-accent: #f0f4f8;
            --text-primary: #1a2b3c;
            --text-secondary: #5a6b7c;
            --text-muted: #8a9bac;
            --border-light: #e2e8f0;
            --border-medium: #cbd5e1;
            --accent-blue: #3b82f6;
            --accent-green: #10b981;
            --accent-amber: #f59e0b;
            --accent-rose: #f43f5e;
            --accent-purple: #8b5cf6;
            --shadow-sm: 0 1px 3px rgba(0,0,0,0.06), 0 1px 2px rgba(0,0,0,0.04);
            --shadow-md: 0 4px 6px rgba(0,0,0,0.05), 0 2px 4px rgba(0,0,0,0.03);
            --shadow-lg: 0 10px 25px rgba(0,0,0,0.08), 0 6px 10px rgba(0,0,0,0.04);
            --radius-sm: 8px;
            --radius-md: 12px;
            --radius-lg: 16px;
          }
          
          body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', sans-serif;
            background: var(--bg-primary);
            min-height: 100vh;
            color: var(--text-primary);
            line-height: 1.5;
          }
          
          /* Decorative background pattern */
          body::before {
            content: '';
            position: fixed;
            top: 0;
            left: 0;
            right: 0;
            height: 300px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 50%, #f093fb 100%);
            opacity: 0.06;
            z-index: -1;
          }
          
          .container {
            max-width: 960px;
            margin: 0 auto;
            padding: 24px;
          }
          
          header {
            text-align: center;
            margin-bottom: 32px;
            padding: 32px 24px;
            background: var(--bg-secondary);
            border-radius: var(--radius-lg);
            box-shadow: var(--shadow-md);
            border: 1px solid var(--border-light);
            position: relative;
            overflow: hidden;
          }
          
          header::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            height: 4px;
            background: linear-gradient(90deg, var(--accent-blue), var(--accent-purple), var(--accent-rose));
          }
          
          .header-icon {
            width: 64px;
            height: 64px;
            margin: 0 auto 16px;
            background: linear-gradient(135deg, #e0e7ff 0%, #fce7f3 100%);
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 28px;
          }
          
          header h1 {
            font-size: 1.75rem;
            font-weight: 700;
            margin-bottom: 8px;
            color: var(--text-primary);
          }
          
          header p {
            color: var(--text-secondary);
            font-size: 0.95rem;
          }
          
          .status-bar {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 16px;
            margin-bottom: 24px;
          }
          
          .status-card {
            background: var(--bg-secondary);
            border-radius: var(--radius-md);
            padding: 20px;
            border: 1px solid var(--border-light);
            box-shadow: var(--shadow-sm);
            transition: transform 0.2s ease, box-shadow 0.2s ease;
          }
          
          .status-card:hover {
            transform: translateY(-2px);
            box-shadow: var(--shadow-md);
          }
          
          .status-card h3 {
            font-size: 0.75rem;
            text-transform: uppercase;
            letter-spacing: 0.08em;
            color: var(--text-muted);
            margin-bottom: 8px;
            font-weight: 600;
          }
          
          .status-card .value {
            font-size: 2rem;
            font-weight: 700;
            color: var(--text-primary);
          }
          
          .clients-list {
            display: flex;
            gap: 8px;
            flex-wrap: wrap;
            margin-top: 12px;
          }
          
          .client-badge {
            background: linear-gradient(135deg, #ecfdf5 0%, #d1fae5 100%);
            color: #047857;
            padding: 6px 12px;
            border-radius: 20px;
            font-size: 0.8rem;
            font-weight: 500;
            display: inline-flex;
            align-items: center;
            gap: 8px;
            border: 1px solid #a7f3d0;
          }
          
          .client-badge::before {
            content: '';
            width: 8px;
            height: 8px;
            background: var(--accent-green);
            border-radius: 50%;
            animation: pulse 2s ease-in-out infinite;
            box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.4);
          }
          
          @keyframes pulse {
            0% { box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.4); }
            70% { box-shadow: 0 0 0 8px rgba(16, 185, 129, 0); }
            100% { box-shadow: 0 0 0 0 rgba(16, 185, 129, 0); }
          }
          
          .requests-section {
            margin-top: 8px;
          }
          
          .section-header {
            display: flex;
            align-items: center;
            gap: 12px;
            margin-bottom: 20px;
          }
          
          .section-header h2 {
            font-size: 1.25rem;
            font-weight: 600;
            color: var(--text-primary);
          }
          
          .section-badge {
            background: var(--bg-accent);
            color: var(--text-secondary);
            padding: 4px 10px;
            border-radius: 12px;
            font-size: 0.75rem;
            font-weight: 600;
          }
          
          .no-requests {
            text-align: center;
            padding: 80px 24px;
            background: var(--bg-secondary);
            border-radius: var(--radius-lg);
            border: 2px dashed var(--border-medium);
          }
          
          .no-requests .icon-container {
            width: 80px;
            height: 80px;
            margin: 0 auto 20px;
            background: linear-gradient(135deg, #e0f2fe 0%, #ede9fe 100%);
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 36px;
          }
          
          .no-requests h3 {
            font-size: 1.1rem;
            color: var(--text-primary);
            margin-bottom: 8px;
          }
          
          .no-requests p {
            color: var(--text-muted);
            font-size: 0.9rem;
          }
          
          .request-card {
            background: var(--bg-secondary);
            border-radius: var(--radius-lg);
            padding: 24px;
            margin-bottom: 16px;
            border: 1px solid var(--border-light);
            box-shadow: var(--shadow-sm);
            transition: box-shadow 0.2s ease, border-color 0.2s ease;
            position: relative;
            overflow: hidden;
          }
          
          .request-card::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            width: 4px;
            height: 100%;
          }
          
          .request-card:hover {
            box-shadow: var(--shadow-lg);
            border-color: var(--border-medium);
          }
          
          .request-card.approval::before {
            background: linear-gradient(180deg, var(--accent-amber), #fbbf24);
          }
          
          .request-card.question::before {
            background: linear-gradient(180deg, var(--accent-blue), #60a5fa);
          }
          
          .request-header {
            display: flex;
            justify-content: space-between;
            align-items: flex-start;
            margin-bottom: 20px;
            gap: 16px;
          }
          
          .request-type {
            display: flex;
            align-items: center;
            gap: 12px;
            flex-wrap: wrap;
          }
          
          .request-type .badge {
            padding: 6px 14px;
            border-radius: 20px;
            font-size: 0.75rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.03em;
          }
          
          .request-type .badge.approval {
            background: linear-gradient(135deg, #fef3c7 0%, #fde68a 100%);
            color: #92400e;
            border: 1px solid #fcd34d;
          }
          
          .request-type .badge.question {
            background: linear-gradient(135deg, #dbeafe 0%, #bfdbfe 100%);
            color: #1e40af;
            border: 1px solid #93c5fd;
          }
          
          .request-meta {
            font-size: 0.85rem;
            color: var(--text-muted);
          }
          
          .request-content {
            margin-bottom: 20px;
          }
          
          .content-section {
            margin-bottom: 20px;
          }
          
          .content-section:last-child {
            margin-bottom: 0;
          }
          
          .content-section h4 {
            font-size: 0.8rem;
            color: var(--text-secondary);
            margin-bottom: 10px;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            font-weight: 600;
          }
          
          .content-section .text {
            background: var(--bg-accent);
            padding: 16px;
            border-radius: var(--radius-sm);
            font-size: 0.9rem;
            line-height: 1.7;
            white-space: pre-wrap;
            max-height: 250px;
            overflow-y: auto;
            color: var(--text-primary);
            border: 1px solid var(--border-light);
          }
          
          .response-section {
            border-top: 1px solid var(--border-light);
            padding-top: 20px;
            margin-top: 20px;
          }
          
          .response-buttons {
            display: flex;
            gap: 12px;
            flex-wrap: wrap;
          }
          
          .btn {
            padding: 12px 24px;
            border-radius: var(--radius-sm);
            font-size: 0.9rem;
            font-weight: 600;
            cursor: pointer;
            border: none;
            transition: all 0.2s ease;
            display: inline-flex;
            align-items: center;
            gap: 8px;
          }
          
          .btn-approve {
            background: linear-gradient(135deg, #10b981 0%, #059669 100%);
            color: white;
            box-shadow: 0 2px 8px rgba(16, 185, 129, 0.3);
          }
          
          .btn-approve:hover {
            transform: translateY(-1px);
            box-shadow: 0 4px 12px rgba(16, 185, 129, 0.4);
          }
          
          .btn-reject {
            background: var(--bg-secondary);
            color: var(--accent-rose);
            border: 2px solid var(--accent-rose);
          }
          
          .btn-reject:hover {
            background: #fff1f2;
          }
          
          .btn-submit {
            background: linear-gradient(135deg, var(--accent-blue) 0%, #2563eb 100%);
            color: white;
            box-shadow: 0 2px 8px rgba(59, 130, 246, 0.3);
          }
          
          .btn-submit:hover {
            transform: translateY(-1px);
            box-shadow: 0 4px 12px rgba(59, 130, 246, 0.4);
          }
          
          .feedback-area {
            display: none;
            margin-top: 16px;
            animation: slideDown 0.2s ease;
          }
          
          @keyframes slideDown {
            from { opacity: 0; transform: translateY(-8px); }
            to { opacity: 1; transform: translateY(0); }
          }
          
          .feedback-area.visible {
            display: block;
          }
          
          .feedback-area textarea,
          .answer-area textarea {
            width: 100%;
            min-height: 120px;
            padding: 14px;
            border-radius: var(--radius-sm);
            border: 2px solid var(--border-light);
            background: var(--bg-secondary);
            color: var(--text-primary);
            font-family: inherit;
            font-size: 0.9rem;
            resize: vertical;
            margin-bottom: 12px;
            transition: border-color 0.2s ease, box-shadow 0.2s ease;
          }
          
          .feedback-area textarea:focus,
          .answer-area textarea:focus {
            outline: none;
            border-color: var(--accent-blue);
            box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.1);
          }
          
          .feedback-area textarea::placeholder,
          .answer-area textarea::placeholder {
            color: var(--text-muted);
          }
          
          footer {
            text-align: center;
            padding: 32px 24px;
            color: var(--text-muted);
            font-size: 0.8rem;
          }
          
          .loading {
            display: inline-block;
            width: 18px;
            height: 18px;
            border: 2px solid var(--border-light);
            border-top-color: var(--accent-blue);
            border-radius: 50%;
            animation: spin 0.8s linear infinite;
          }
          
          @media (max-width: 640px) {
            .container { padding: 16px; }
            header { padding: 24px 16px; }
            .request-card { padding: 20px 16px; }
            .response-buttons { flex-direction: column; }
            .btn { width: 100%; justify-content: center; }
          }
        </style>
      </head>
      <body>
        <div class="container">
          <header>
            <div class="header-icon">🤖</div>
            <h1>Agent Approval Center</h1>
            <p>Review and respond to AI agent requests from your CodeSpaces</p>
          </header>
          
          <div class="status-bar">
            <div class="status-card">
              <h3>Connected Clients</h3>
              <div class="value" id="client-count">0</div>
              <div class="clients-list" id="clients-list"></div>
            </div>
            <div class="status-card">
              <h3>Pending Requests</h3>
              <div class="value" id="request-count">0</div>
            </div>
          </div>
          
          <div class="requests-section">
            <div class="section-header">
              <h2>Pending Requests</h2>
              <span class="section-badge" id="request-badge">0 waiting</span>
            </div>
            <div id="requests-container">
              <div class="no-requests">
                <div class="icon-container">📭</div>
                <h3>No pending requests</h3>
                <p>Waiting for AI agents to request your approval...</p>
              </div>
            </div>
          </div>
          
          <footer>
            Agent Approval MCP Server &middot; Listening on port <span id="port-display">18463</span>
          </footer>
        </div>
        
        <script>
          const API_BASE = '';
          let lastRequestIds = new Set();
          let lastRequestsJson = '';
          
          async function fetchClients() {
            try {
              const res = await fetch(API_BASE + '/api/clients');
              const data = await res.json();
              
              document.getElementById('client-count').textContent = data.clients.length;
              
              const clientsList = document.getElementById('clients-list');
              clientsList.innerHTML = data.clients.map(c => 
                `<span class="client-badge">${escapeHtml(c.name)}</span>`
              ).join('');
            } catch (e) {
              console.error('Error fetching clients:', e);
            }
          }
          
          async function fetchRequests() {
            try {
              const res = await fetch(API_BASE + '/api/requests');
              const data = await res.json();
              
              document.getElementById('request-count').textContent = data.requests.length;
              document.getElementById('request-badge').textContent = 
                data.requests.length === 0 ? '0 waiting' : 
                data.requests.length === 1 ? '1 waiting' : 
                data.requests.length + ' waiting';
              
              const container = document.getElementById('requests-container');
              
              // Check if we have an active element (user is typing)
              const activeEl = document.activeElement;
              const isUserTyping = activeEl && activeEl.tagName === 'TEXTAREA';
              
              // Create a signature of current requests to detect changes
              const requestsJson = JSON.stringify(data.requests.map(r => r.id).sort());
              const hasChanged = requestsJson !== lastRequestsJson;
              
              if (data.requests.length === 0) {
                lastRequestsJson = requestsJson;
                container.innerHTML = `
                  <div class="no-requests">
                    <div class="icon-container">📭</div>
                    <h3>No pending requests</h3>
                    <p>Waiting for AI agents to request your approval...</p>
                  </div>
                `;
              } else if (hasChanged || container.querySelector('.no-requests')) {
                // Only rebuild if requests changed or we're showing the empty state
                // But first, save any user input
                const savedInputs = {};
                const savedVisibility = {};
                
                if (!isUserTyping) {
                  // Safe to rebuild
                  lastRequestsJson = requestsJson;
                  container.innerHTML = data.requests.map(r => renderRequest(r)).join('');
                } else {
                  // User is typing - save their input, rebuild, then restore
                  document.querySelectorAll('textarea').forEach(ta => {
                    if (ta.value) savedInputs[ta.id] = ta.value;
                  });
                  document.querySelectorAll('.feedback-area.visible').forEach(fa => {
                    savedVisibility[fa.id] = true;
                  });
                  
                  lastRequestsJson = requestsJson;
                  container.innerHTML = data.requests.map(r => renderRequest(r)).join('');
                  
                  // Restore inputs
                  Object.entries(savedInputs).forEach(([id, value]) => {
                    const el = document.getElementById(id);
                    if (el) el.value = value;
                  });
                  Object.entries(savedVisibility).forEach(([id, _]) => {
                    const el = document.getElementById(id);
                    if (el) el.classList.add('visible');
                  });
                }
              }
              // If nothing changed and user might be typing, don't touch the DOM
              
            } catch (e) {
              console.error('Error fetching requests:', e);
            }
          }
          
          function renderRequest(req) {
            if (req.type === 'approval') {
              return `
                <div class="request-card approval" data-id="${req.id}">
                  <div class="request-header">
                    <div class="request-type">
                      <span class="badge approval">Approval Request</span>
                      <span class="request-meta">from ${escapeHtml(req.client_name)}</span>
                    </div>
                    <span class="request-meta">${formatTime(req.created_at)}</span>
                  </div>
                  <div class="request-content">
                    <div class="content-section">
                      <h4>📋 Work Summary</h4>
                      <div class="text">${escapeHtml(req.data.work_summary)}</div>
                    </div>
                    <div class="content-section">
                      <h4>🧪 Testing Instructions</h4>
                      <div class="text">${escapeHtml(req.data.testing_instructions)}</div>
                    </div>
                  </div>
                  <div class="response-section">
                    <div class="response-buttons">
                      <button class="btn btn-approve" onclick="approveRequest('${req.id}')">✓ Approve</button>
                      <button class="btn btn-reject" onclick="showFeedback('${req.id}')">✗ Request Changes</button>
                    </div>
                    <div class="feedback-area" id="feedback-${req.id}">
                      <textarea id="feedback-text-${req.id}" placeholder="Enter your feedback for the agent..."></textarea>
                      <button class="btn btn-submit" onclick="rejectRequest('${req.id}')">Send Feedback</button>
                    </div>
                  </div>
                </div>
              `;
            } else if (req.type === 'question') {
              return `
                <div class="request-card question" data-id="${req.id}">
                  <div class="request-header">
                    <div class="request-type">
                      <span class="badge question">Question</span>
                      <span class="request-meta">from ${escapeHtml(req.client_name)}</span>
                    </div>
                    <span class="request-meta">${formatTime(req.created_at)}</span>
                  </div>
                  <div class="request-content">
                    <div class="content-section">
                      <h4>❓ Question</h4>
                      <div class="text">${escapeHtml(req.data.question)}</div>
                    </div>
                    ${req.data.context ? `
                      <div class="content-section">
                        <h4>📋 Context</h4>
                        <div class="text">${escapeHtml(req.data.context)}</div>
                      </div>
                    ` : ''}
                  </div>
                  <div class="response-section">
                    <div class="answer-area">
                      <textarea id="answer-text-${req.id}" placeholder="Enter your answer..."></textarea>
                      <button class="btn btn-submit" onclick="answerQuestion('${req.id}')">Send Answer</button>
                    </div>
                  </div>
                </div>
              `;
            }
            return '';
          }
          
          function escapeHtml(text) {
            const div = document.createElement('div');
            div.textContent = text || '';
            return div.innerHTML;
          }
          
          function formatTime(isoString) {
            const date = new Date(isoString);
            return date.toLocaleTimeString();
          }
          
          function showFeedback(requestId) {
            document.getElementById('feedback-' + requestId).classList.add('visible');
          }
          
          async function approveRequest(requestId) {
            await sendResponse(requestId, { approved: true, feedback: null });
          }
          
          async function rejectRequest(requestId) {
            const feedback = document.getElementById('feedback-text-' + requestId).value;
            if (!feedback.trim()) {
              alert('Please provide feedback');
              return;
            }
            await sendResponse(requestId, { approved: false, feedback: feedback });
          }
          
          async function answerQuestion(requestId) {
            const answer = document.getElementById('answer-text-' + requestId).value;
            if (!answer.trim()) {
              alert('Please provide an answer');
              return;
            }
            await sendResponse(requestId, { answer: answer });
          }
          
          async function sendResponse(requestId, response) {
            try {
              const res = await fetch(API_BASE + '/api/respond', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ request_id: requestId, response: response })
              });
              
              if (res.ok) {
                fetchRequests();
              } else {
                const data = await res.json();
                alert('Error: ' + (data.error || 'Unknown error'));
              }
            } catch (e) {
              alert('Error sending response: ' + e.message);
            }
          }
          
          // Poll for updates
          setInterval(fetchClients, 3000);
          setInterval(fetchRequests, 2000);
          
          // Initial fetch
          fetchClients();
          fetchRequests();
        </script>
      </body>
      </html>
    HTML

    { status: 200, body: html, content_type: 'text/html' }
  end

  def send_response(client, status, body, content_type = 'application/json')
    status_text = {
      200 => 'OK',
      400 => 'Bad Request',
      404 => 'Not Found',
      500 => 'Internal Server Error'
    }[status] || 'Unknown'

    response = [
      "HTTP/1.1 #{status} #{status_text}",
      "Content-Type: #{content_type}",
      "Content-Length: #{body.bytesize}",
      "Connection: close",
      "Access-Control-Allow-Origin: *",
      "",
      body
    ].join("\r\n")

    client.write(response)
  end
end

# Main entry point
if __FILE__ == $PROGRAM_NAME
  port = (ARGV[0] || ENV['RESPONSE_SERVER_PORT'] || ResponseServer::DEFAULT_PORT).to_i

  server = ResponseServer.new(port: port)
  server.start
end
