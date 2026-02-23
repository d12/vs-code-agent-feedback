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
  POLL_INTERVAL = 2 # seconds between each full port range scan
  STALE_CLIENT_TIMEOUT = 15 # seconds - client is considered stale if not seen
  NOTIFICATION_INTERVAL = 5 * 60 # 5 minutes
  TIMEOUT_BUFFER = 10 # seconds before timeout to send auto-response

  # Notification modes: :server, :web, :both
  attr_reader :notification_mode

  def initialize(port: DEFAULT_PORT, notification_mode: :server)
    @port = port
    @notification_mode = notification_mode
    @notifier = notification_mode == :web ? Notifier.null : Notifier.default
    @running = false
    @clients = {} # client_id => { url:, name:, last_seen:, timeout_seconds: }
    @pending_requests = {} # request_id => { client_id:, type:, data:, created_at:, expires_at:, last_notified_at: }
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
    puts "  Notification mode: #{@notification_mode}"
    puts "-" * 60
    puts

    # Handle graceful shutdown
    setup_signal_handlers

    # Start the client discovery thread
    @discovery_thread = Thread.new { discovery_loop }

    # Start the timeout and notification checker thread
    @timeout_thread = Thread.new { timeout_and_notification_loop }

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
    @timeout_thread&.kill
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

  # Timeout and notification checker loop
  def timeout_and_notification_loop
    while @running
      now = Time.now
      requests_to_timeout = []
      requests_to_notify = []

      @requests_mutex.synchronize do
        @pending_requests.each do |request_id, req|
          next if @responses.key?(request_id) # Already responded

          # Check for timeout (respond just before it expires)
          if req[:expires_at] && now >= (req[:expires_at] - TIMEOUT_BUFFER)
            requests_to_timeout << request_id
            next
          end

          # Check if we need to send a reminder notification
          if req[:last_notified_at] && (now - req[:last_notified_at]) >= NOTIFICATION_INTERVAL
            requests_to_notify << request_id
          end
        end
      end

      # Handle timeouts (auto-respond with "ask again" message)
      requests_to_timeout.each do |request_id|
        handle_timeout(request_id)
      end

      # Send reminder notifications
      requests_to_notify.each do |request_id|
        send_reminder_notification(request_id)
      end

      sleep 1 # Check every second for precision
    end
  end

  def handle_timeout(request_id)
    @requests_mutex.synchronize do
      req = @pending_requests[request_id]
      return unless req

      client_id = req[:client_id]
      client_info = @clients_mutex.synchronize { @clients[client_id] }

      if client_info
        # Send auto-response asking to try again
        timeout_response = {
          'error' => 'Request timed out. The user did not respond in time. Please ask again if you still need approval or an answer.'
        }

        begin
          uri = URI("#{client_info[:url]}/respond")
          http = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = 5
          http.read_timeout = 5

          post_request = Net::HTTP::Post.new(uri.path)
          post_request['Content-Type'] = 'application/json'
          post_request.body = {
            request_id: request_id,
            response: timeout_response
          }.to_json

          http.request(post_request)
          puts "[#{Time.now.strftime('%H:%M:%S')}] Auto-responded to timed out request #{request_id[0..7]}"
        rescue => e
          puts "[Timeout] Error sending timeout response: #{e.message}" if ENV['DEBUG']
        end
      end

      # Remove from pending requests
      @pending_requests.delete(request_id)
      @responses[request_id] = { 'timed_out' => true }
    end
  end

  def send_reminder_notification(request_id)
    @requests_mutex.synchronize do
      req = @pending_requests[request_id]
      return unless req

      # Update last_notified_at so browser knows a reminder is due
      req[:last_notified_at] = Time.now
      puts "[#{Time.now.strftime('%H:%M:%S')}] Reminder due for request #{request_id[0..7]}"
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
          port: port,
          timeout_seconds: data['timeout_seconds'] || 1800
        }

        if existing.nil?
          puts "[#{Time.now.strftime('%H:%M:%S')}] New client connected: #{data['name'] || client_id} on port #{port}"
        end
      end

      # Check for pending requests from this client
      fetch_pending_requests(client_id, port)
    end
  rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout, Errno::EHOSTUNREACH
    # Port not responding - check if we had a client there and mark as potentially offline
    @clients_mutex.synchronize do
      @clients.each do |id, info|
        if info[:port] == port && (Time.now - info[:last_seen]) > 10
          # Client hasn't responded in 10 seconds, may be offline
        end
      end
    end
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
      default_timeout = data['timeout_seconds'] || 1800

      @requests_mutex.synchronize do
        requests.each do |req|
          request_id = req['request_id']
          next if @pending_requests[request_id] # Already have this request

          created_at = Time.parse(req['created_at'])
          expires_at = req['expires_at'] ? Time.parse(req['expires_at']) : (created_at + default_timeout)

          @pending_requests[request_id] = {
            client_id: client_id,
            type: req['type'],
            data: req['data'],
            created_at: created_at,
            expires_at: expires_at,
            last_notified_at: Time.now # Track when we last notified
          }

          client_name = @clients[client_id][:name]
          puts "[#{Time.now.strftime('%H:%M:%S')}] New #{req['type']} request from #{client_name}"

          # Send server-side notification if enabled
          if @notification_mode == :server || @notification_mode == :both
            notify_new_request(req['type'], req['data'], client_name)
          end
        end
      end
    end
  rescue => e
    puts "[Fetch] Error getting requests from port #{port}: #{e.message}" if ENV['DEBUG']
  end

  # Send OS-level notification for new requests
  def notify_new_request(type, data, client_name)
    title = type == 'approval' ? "Review needed: #{client_name}" : "Question from #{client_name}"
    message = if type == 'approval'
      (data['work_summary'] || '').slice(0, 150)
    else
      (data['question'] || '').slice(0, 150)
    end

    @notifier.notify(
      title: title,
      message: message,
      url: "http://localhost:#{@port}"
    )
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
      # Clean up stale clients (not seen recently)
      @clients.reject! { |_, v| Time.now - v[:last_seen] > STALE_CLIENT_TIMEOUT }

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
          created_at: req[:created_at].iso8601,
          expires_at: req[:expires_at]&.iso8601,
          last_notified_at: req[:last_notified_at]&.iso8601
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
        <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
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
            display: flex;
            align-items: center;
            gap: 12px;
            margin-bottom: 24px;
            padding: 12px 16px;
            background: var(--bg-secondary);
            border-radius: var(--radius-md);
            border: 1px solid var(--border-light);
            box-shadow: var(--shadow-sm);
            flex-wrap: wrap;
          }

          .status-bar-label {
            font-size: 0.75rem;
            text-transform: uppercase;
            letter-spacing: 0.08em;
            color: var(--text-muted);
            font-weight: 600;
          }

          .clients-list {
            display: flex;
            gap: 8px;
            flex-wrap: wrap;
            align-items: center;
          }

          .no-clients {
            color: var(--text-muted);
            font-size: 0.85rem;
            font-style: italic;
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
            max-height: 250px;
            overflow-y: auto;
            color: var(--text-primary);
            border: 1px solid var(--border-light);
          }

          /* Markdown styling */
          .markdown-body {
            white-space: normal;
          }

          .markdown-body p {
            margin-bottom: 0.75em;
          }

          .markdown-body p:last-child {
            margin-bottom: 0;
          }

          .markdown-body code {
            background: var(--bg-secondary);
            padding: 2px 6px;
            border-radius: 4px;
            font-family: 'SF Mono', Monaco, 'Courier New', monospace;
            font-size: 0.85em;
            border: 1px solid var(--border-light);
          }

          .markdown-body pre {
            background: var(--bg-secondary);
            padding: 12px;
            border-radius: var(--radius-sm);
            overflow-x: auto;
            margin: 0.75em 0;
            border: 1px solid var(--border-light);
          }

          .markdown-body pre code {
            background: none;
            padding: 0;
            border: none;
          }

          .markdown-body ul, .markdown-body ol {
            margin: 0.75em 0;
            padding-left: 1.5em;
          }

          .markdown-body li {
            margin-bottom: 0.25em;
          }

          .markdown-body h1, .markdown-body h2, .markdown-body h3,
          .markdown-body h4, .markdown-body h5, .markdown-body h6 {
            margin: 1em 0 0.5em;
            font-weight: 600;
          }

          .markdown-body h1:first-child, .markdown-body h2:first-child,
          .markdown-body h3:first-child, .markdown-body h4:first-child {
            margin-top: 0;
          }

          .markdown-body strong {
            font-weight: 600;
          }

          .markdown-body a {
            color: var(--accent-blue);
            text-decoration: none;
          }

          .markdown-body a:hover {
            text-decoration: underline;
          }

          .markdown-body blockquote {
            border-left: 3px solid var(--border-medium);
            padding-left: 1em;
            margin: 0.75em 0;
            color: var(--text-secondary);
          }

          /* Diff viewer styles */
          .diff-section {
            margin-top: 16px;
            border: 1px solid var(--border-light);
            border-radius: var(--radius-sm);
            overflow: hidden;
          }

          .diff-summary {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 12px 16px;
            background: var(--bg-secondary);
            cursor: pointer;
            font-weight: 500;
            user-select: none;
          }

          .diff-summary:hover {
            background: var(--bg-tertiary);
          }

          .diff-summary::-webkit-details-marker {
            margin-right: 8px;
          }

          .diff-stats {
            font-size: 0.85rem;
            color: var(--text-secondary);
            font-weight: normal;
          }

          .diff-content {
            max-height: 500px;
            overflow: auto;
            background: #1e1e1e;
          }

          .diff-view {
            margin: 0;
            padding: 16px;
            font-family: 'SF Mono', 'Monaco', 'Inconsolata', 'Roboto Mono', monospace;
            font-size: 12px;
            line-height: 1.5;
            white-space: pre;
            overflow-x: auto;
            color: #d4d4d4;
          }

          .diff-view span {
            display: block;
          }

          .diff-header {
            color: #569cd6;
            font-weight: bold;
            margin-top: 8px;
          }

          .diff-header:first-child {
            margin-top: 0;
          }

          .diff-file {
            color: #ce9178;
            font-weight: bold;
          }

          .diff-hunk {
            color: #c586c0;
            background: rgba(197, 134, 192, 0.1);
            margin: 8px 0 4px 0;
            padding: 2px 0;
          }

          .diff-add {
            color: #4ec9b0;
            background: rgba(78, 201, 176, 0.15);
          }

          .diff-del {
            color: #f14c4c;
            background: rgba(241, 76, 76, 0.15);
          }

          .diff-context {
            color: #d4d4d4;
          }

          .diff-comment {
            color: #6a9955;
            font-style: italic;
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

          .countdown-timer {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 6px 12px;
            border-radius: 20px;
            font-size: 0.8rem;
            font-weight: 600;
            background: var(--bg-accent);
            color: var(--text-secondary);
            border: 1px solid var(--border-light);
          }

          .countdown-timer.warning {
            background: #fef3c7;
            color: #92400e;
            border-color: #fcd34d;
          }

          .countdown-timer.critical {
            background: #fee2e2;
            color: #991b1b;
            border-color: #fca5a5;
            animation: pulse-critical 1s ease-in-out infinite;
          }

          @keyframes pulse-critical {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.7; }
          }

          .countdown-timer svg {
            width: 14px;
            height: 14px;
          }

          /* Request selection styles */
          .request-card.selected {
            outline: 3px solid var(--accent-blue);
            outline-offset: 2px;
            box-shadow: var(--shadow-lg), 0 0 0 6px rgba(59, 130, 246, 0.1);
          }

          /* Keyboard hints */
          .keyboard-hints {
            position: fixed;
            bottom: 20px;
            right: 20px;
            background: var(--bg-secondary);
            border: 1px solid var(--border-light);
            border-radius: var(--radius-md);
            padding: 12px 16px;
            font-size: 0.75rem;
            color: var(--text-muted);
            box-shadow: var(--shadow-md);
            z-index: 100;
          }

          .keyboard-hints h4 {
            font-weight: 600;
            margin-bottom: 8px;
            color: var(--text-secondary);
          }

          .keyboard-hints ul {
            list-style: none;
            margin: 0;
            padding: 0;
          }

          .keyboard-hints li {
            margin-bottom: 4px;
          }

          .keyboard-hints kbd {
            background: var(--bg-tertiary);
            padding: 2px 6px;
            border-radius: 4px;
            font-family: monospace;
            font-size: 0.7rem;
            border: 1px solid var(--border-light);
            margin-right: 6px;
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
            <span class="status-bar-label">Connected:</span>
            <div class="clients-list" id="clients-list">
              <span class="no-clients">No clients connected</span>
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

        <!-- Keyboard hints -->
        <div class="keyboard-hints" id="keyboard-hints">
          <h4>⌨️ Keyboard Shortcuts</h4>
          <ul>
            <li><kbd>J</kbd> / <kbd>↓</kbd> Next request</li>
            <li><kbd>K</kbd> / <kbd>↑</kbd> Previous request</li>
            <li><kbd>A</kbd> Approve selected</li>
            <li><kbd>R</kbd> / <kbd>Enter</kbd> Add feedback</li>
            <li><kbd>S</kbd> Send feedback</li>
            <li><kbd>D</kbd> Toggle diff</li>
            <li><kbd>Esc</kbd> Unfocus / Deselect</li>
            <li><kbd>?</kbd> Toggle hints</li>
          </ul>
        </div>

        <script>
          const API_BASE = '';
          const NOTIFICATION_MODE = '#{@notification_mode}'; // server, web, or both
          let lastRequestIds = new Set();
          let lastRequestsJson = '';
          let selectedRequestIndex = -1;
          let allRequests = [];
          let lastNotifiedAt = {}; // Track when we last sent notification for each request
          let isFirstFetch = true; // Don't notify on initial page load
          const REMINDER_INTERVAL = 5 * 60 * 1000; // 5 minutes in ms

          // Request notification permission on load
          if ('Notification' in window && Notification.permission === 'default') {
            Notification.requestPermission();
          }

          // Audio context for notification sound
          let audioContext = null;
          function playNotificationSound() {
            try {
              if (!audioContext) {
                audioContext = new (window.AudioContext || window.webkitAudioContext)();
              }
              // Resume if suspended (browser policy)
              if (audioContext.state === 'suspended') {
                audioContext.resume();
              }
              // Create a short beep sound
              const oscillator = audioContext.createOscillator();
              const gainNode = audioContext.createGain();
              oscillator.connect(gainNode);
              gainNode.connect(audioContext.destination);
              oscillator.frequency.value = 800;
              oscillator.type = 'sine';
              gainNode.gain.setValueAtTime(0.3, audioContext.currentTime);
              gainNode.gain.exponentialRampToValueAtTime(0.01, audioContext.currentTime + 0.3);
              oscillator.start(audioContext.currentTime);
              oscillator.stop(audioContext.currentTime + 0.3);
            } catch (e) {
              console.log('Could not play notification sound:', e);
            }
          }

          // Flash the tab title when there are pending requests
          let originalTitle = document.title;
          let titleFlashInterval = null;

          function startTitleFlash(count) {
            if (titleFlashInterval) return;
            let showAlert = true;
            titleFlashInterval = setInterval(() => {
              document.title = showAlert ? `(${count}) 🔔 Action Required!` : originalTitle;
              showAlert = !showAlert;
            }, 1000);
          }

          function stopTitleFlash() {
            if (titleFlashInterval) {
              clearInterval(titleFlashInterval);
              titleFlashInterval = null;
              document.title = originalTitle;
            }
          }

          function sendBrowserNotification(title, body, requestId) {
            // Only send browser notifications if mode is 'web' or 'both'
            if (NOTIFICATION_MODE === 'server') {
              console.log('Skipping browser notification (server mode)');
              return;
            }

            // Play sound immediately
            playNotificationSound();

            if ('Notification' in window && Notification.permission === 'granted') {
              console.log('Sending browser notification:', title);
              const notification = new Notification(title, {
                body: body,
                icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><text y=".9em" font-size="90">🤖</text></svg>',
                tag: requestId || 'agent-request', // Unique tag per request
                renotify: true, // Force notification even with same tag
                requireInteraction: true, // Keep notification visible until clicked
                silent: false, // Allow sound
                vibrate: [200, 100, 200] // Vibration pattern for mobile
              });
              notification.onclick = () => {
                window.focus();
                notification.close();
              };
            } else {
              console.log('Cannot send notification - permission:', Notification.permission);
            }
          }

          function formatText(text) {
            // Escape HTML and convert newlines to <br> for proper formatting
            return escapeHtml(text || '').split(String.fromCharCode(10)).join('<br>');
          }

          function renderMarkdown(text) {
            if (!text) return '';
            try {
              // Configure marked for safe rendering
              marked.setOptions({
                breaks: true,
                gfm: true
              });
              return marked.parse(text);
            } catch (e) {
              // Fallback to escaped text if marked fails
              return escapeHtml(text);
            }
          }

          function renderDiff(diff) {
            if (!diff) return '';
            const lines = diff.split(String.fromCharCode(10));
            return lines.map(line => {
              const escaped = escapeHtml(line);
              if (line.startsWith('+++') || line.startsWith('---')) {
                return `<span class="diff-file">${escaped}</span>`;
              } else if (line.startsWith('@@')) {
                return `<span class="diff-hunk">${escaped}</span>`;
              } else if (line.startsWith('+')) {
                return `<span class="diff-add">${escaped}</span>`;
              } else if (line.startsWith('-')) {
                return `<span class="diff-del">${escaped}</span>`;
              } else if (line.startsWith('diff ')) {
                return `<span class="diff-header">${escaped}</span>`;
              } else if (line.startsWith('#')) {
                return `<span class="diff-comment">${escaped}</span>`;
              }
              return `<span class="diff-context">${escaped}</span>`;
            }).join(String.fromCharCode(10));
          }

          function getDiffStats(diff) {
            if (!diff) return '';
            const lines = diff.split(String.fromCharCode(10));
            let additions = 0, deletions = 0, files = 0;
            lines.forEach(line => {
              if (line.startsWith('+') && !line.startsWith('+++')) additions++;
              else if (line.startsWith('-') && !line.startsWith('---')) deletions++;
              else if (line.startsWith('diff ')) files++;
            });
            const parts = [];
            if (files > 0) parts.push(`${files} file${files !== 1 ? 's' : ''}`);
            if (additions > 0) parts.push(`+${additions}`);
            if (deletions > 0) parts.push(`-${deletions}`);
            return parts.join(', ');
          }

          async function fetchClients() {
            try {
              const res = await fetch(API_BASE + '/api/clients');
              const data = await res.json();

              const clientsList = document.getElementById('clients-list');
              if (data.clients.length === 0) {
                clientsList.innerHTML = '<span class="no-clients">No clients connected</span>';
              } else {
                clientsList.innerHTML = data.clients.map(c =>
                  `<span class="client-badge">${escapeHtml(c.name)}</span>`
                ).join('');
              }
            } catch (e) {
              console.error('Error fetching clients:', e);
            }
          }

          async function fetchRequests() {
            try {
              const res = await fetch(API_BASE + '/api/requests');
              const data = await res.json();

              const currentIds = new Set(data.requests.map(r => r.id));
              const now = Date.now();

              // Start or stop title flashing based on pending requests
              if (data.requests.length > 0 && !document.hasFocus()) {
                startTitleFlash(data.requests.length);
              } else if (data.requests.length === 0) {
                stopTitleFlash();
              }

              // Check for new requests and send browser notifications (skip first fetch)
              if (!isFirstFetch) {
                for (const req of data.requests) {
                  // New request notification
                  if (!lastRequestIds.has(req.id)) {
                    const repoName = req.client_name || 'Unknown';
                    const title = req.type === 'approval'
                      ? `Review needed for ${repoName}`
                      : `Question from ${repoName}`;
                    const body = req.type === 'approval'
                      ? (req.data?.work_summary || '').substring(0, 150)
                      : (req.data?.question || '').substring(0, 150);
                    sendBrowserNotification(title, body, req.id);
                    lastNotifiedAt[req.id] = now;
                  }
                  // Reminder notification (every 5 minutes)
                  else if (lastNotifiedAt[req.id] && (now - lastNotifiedAt[req.id]) >= REMINDER_INTERVAL) {
                    const repoName = req.client_name || 'Unknown';
                    const remaining = req.expires_at ? Math.round((new Date(req.expires_at) - now) / 60000) : '?';
                    const title = `⏰ Still waiting: ${repoName}`;
                    const body = `${remaining} minutes remaining`;
                    sendBrowserNotification(title, body, req.id + '-reminder');
                    lastNotifiedAt[req.id] = now;
                  }
                }
              } else {
                // On first fetch, just record current IDs without notifying
                for (const req of data.requests) {
                  lastNotifiedAt[req.id] = now;
                }
                isFirstFetch = false;
              }

              // Stop title flash when window is focused
              window.addEventListener('focus', stopTitleFlash);

              lastRequestIds = currentIds;

              // Clean up old notification timestamps
              for (const id of Object.keys(lastNotifiedAt)) {
                if (!currentIds.has(id)) {
                  delete lastNotifiedAt[id];
                }
              }

              // Store all requests for keyboard navigation
              allRequests = data.requests;

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
            const countdownHtml = req.expires_at ?
              `<span class="countdown-timer" data-expires="${req.expires_at}" id="timer-${req.id}">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <circle cx="12" cy="12" r="10"></circle>
                  <polyline points="12 6 12 12 16 14"></polyline>
                </svg>
                <span class="countdown-value">--:--</span>
              </span>` : '';

            if (req.type === 'approval') {
              return `
                <div class="request-card approval" data-id="${req.id}" data-expires="${req.expires_at || ''}">
                  <div class="request-header">
                    <div class="request-type">
                      <span class="badge approval">Approval Request</span>
                      <span class="request-meta">from ${escapeHtml(req.client_name)}</span>
                    </div>
                    <div style="display: flex; align-items: center; gap: 12px;">
                      ${countdownHtml}
                    </div>
                  </div>
                  <div class="request-content">
                    <div class="content-section">
                      <h4>📋 Work Summary</h4>
                      <div class="text markdown-body">${renderMarkdown(req.data.work_summary)}</div>
                    </div>
                    <div class="content-section">
                      <h4>🧪 Testing Instructions</h4>
                      <div class="text markdown-body">${renderMarkdown(req.data.testing_instructions)}</div>
                    </div>
                    ${req.data.git_diff ? `
                    <details class="diff-section">
                      <summary class="diff-summary">
                        <span>📝 Git Diff</span>
                        <span class="diff-stats">${getDiffStats(req.data.git_diff)}</span>
                      </summary>
                      <div class="diff-content">
                        <pre class="diff-view">${renderDiff(req.data.git_diff)}</pre>
                      </div>
                    </details>
                    ` : ''}
                  </div>
                  <div class="response-section">
                    <div class="response-buttons">
                      <button class="btn btn-approve" onclick="approveRequest('${req.id}')">✓ Approve [A]</button>
                      <button class="btn btn-reject" onclick="showFeedback('${req.id}')">✗ Request Changes [R]</button>
                    </div>
                    <div class="feedback-area" id="feedback-${req.id}">
                      <textarea id="feedback-text-${req.id}" placeholder="Enter your feedback for the agent..."></textarea>
                      <button class="btn btn-submit" onclick="rejectRequest('${req.id}')">Send [S]</button>
                    </div>
                  </div>
                </div>
              `;
            } else if (req.type === 'question') {
              return `
                <div class="request-card question" data-id="${req.id}" data-expires="${req.expires_at || ''}">
                  <div class="request-header">
                    <div class="request-type">
                      <span class="badge question">Question</span>
                      <span class="request-meta">from ${escapeHtml(req.client_name)}</span>
                    </div>
                    <div style="display: flex; align-items: center; gap: 12px;">
                      ${countdownHtml}
                    </div>
                  </div>
                  <div class="request-content">
                    <div class="content-section">
                      <h4>❓ Question</h4>
                      <div class="text markdown-body">${renderMarkdown(req.data.question)}</div>
                    </div>
                    ${req.data.context ? `
                      <div class="content-section">
                        <h4>📋 Context</h4>
                        <div class="text markdown-body">${renderMarkdown(req.data.context)}</div>
                      </div>
                    ` : ''}
                  </div>
                  <div class="response-section">
                    <div class="answer-area">
                      <textarea id="answer-text-${req.id}" placeholder="Enter your answer..."></textarea>
                      <button class="btn btn-submit" onclick="answerQuestion('${req.id}')">Send Answer [S]</button>
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
            const feedbackArea = document.getElementById('feedback-' + requestId);
            feedbackArea.classList.add('visible');

            // Auto-focus the textarea
            const textarea = document.getElementById('feedback-text-' + requestId);
            if (textarea) {
              textarea.focus();
            }

            // Scroll the card into view so button is fully visible
            const card = feedbackArea.closest('.request-card');
            if (card) {
              setTimeout(() => {
                card.scrollIntoView({ behavior: 'smooth', block: 'end' });
              }, 100);
            }
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

          // Update countdown timers
          function updateCountdowns() {
            document.querySelectorAll('.countdown-timer').forEach(timer => {
              const expiresAt = timer.dataset.expires;
              if (!expiresAt) return;

              const expires = new Date(expiresAt);
              const now = new Date();
              const remainingMs = expires - now;

              const valueEl = timer.querySelector('.countdown-value');
              if (!valueEl) return;

              if (remainingMs <= 0) {
                valueEl.textContent = 'Expired';
                timer.classList.add('critical');
                timer.classList.remove('warning');
              } else {
                const totalSeconds = Math.floor(remainingMs / 1000);
                const minutes = Math.floor(totalSeconds / 60);
                const seconds = totalSeconds % 60;

                valueEl.textContent = `${minutes}:${seconds.toString().padStart(2, '0')}`;

                // Add warning/critical classes based on time remaining
                timer.classList.remove('warning', 'critical');
                if (minutes < 2) {
                  timer.classList.add('critical');
                } else if (minutes < 5) {
                  timer.classList.add('warning');
                }
              }
            });
          }

          // Selection management
          function selectRequest(index) {
            // Remove previous selection
            document.querySelectorAll('.request-card.selected').forEach(el => el.classList.remove('selected'));

            if (index < 0 || index >= allRequests.length) {
              selectedRequestIndex = -1;
              return;
            }

            selectedRequestIndex = index;
            const card = document.querySelector(`.request-card[data-id="${allRequests[index].id}"]`);
            if (card) {
              card.classList.add('selected');
              card.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
            }
          }

          function getSelectedRequest() {
            if (selectedRequestIndex >= 0 && selectedRequestIndex < allRequests.length) {
              return allRequests[selectedRequestIndex];
            }
            return null;
          }

          // Keyboard handling
          document.addEventListener('keydown', (e) => {
            const activeElement = document.activeElement;
            const isTyping = activeElement?.tagName === 'TEXTAREA' || activeElement?.tagName === 'INPUT';

            // Handle Escape - unfocus if typing, otherwise deselect
            // Important: only blur OR deselect, never both on same keypress
            if (e.key === 'Escape') {
              e.preventDefault();
              if (isTyping) {
                // Just blur the input - keep the request selected so user can hit 'S' to send
                activeElement.blur();
              } else if (selectedRequestIndex >= 0) {
                // Not typing - deselect the request
                selectRequest(-1);
                // Also hide any open feedback areas
                document.querySelectorAll('.feedback-area.visible').forEach(fa => fa.classList.remove('visible'));
              }
              return;
            }

            // Don't handle other shortcuts while typing
            if (isTyping) {
              // Ctrl/Cmd+Enter to submit from textarea
              if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
                e.preventDefault();
                const textarea = document.activeElement;
                const card = textarea.closest('.request-card');
                if (card) {
                  const requestId = card.dataset.id;
                  const isQuestion = card.classList.contains('question');
                  if (isQuestion) {
                    answerQuestion(requestId);
                  } else {
                    rejectRequest(requestId);
                  }
                }
              }
              return;
            }

            // Navigation
            if (e.key === 'j' || e.key === 'ArrowDown') {
              e.preventDefault();
              if (allRequests.length > 0) {
                selectRequest(Math.min(selectedRequestIndex + 1, allRequests.length - 1));
              }
              return;
            }

            if (e.key === 'k' || e.key === 'ArrowUp') {
              e.preventDefault();
              if (allRequests.length > 0) {
                selectRequest(Math.max(selectedRequestIndex - 1, 0));
              }
              return;
            }

            // Quick approve
            if (e.key === 'a') {
              e.preventDefault();
              const selected = getSelectedRequest();
              if (selected) {
                approveRequest(selected.id);
              }
              return;
            }

            // Show feedback / answer area
            if (e.key === 'r' || e.key === 'Enter') {
              e.preventDefault();
              const selected = getSelectedRequest();
              if (selected) {
                const card = document.querySelector(`.request-card[data-id="${selected.id}"]`);
                if (card) {
                  const isQuestion = card.classList.contains('question');
                  if (isQuestion) {
                    // Focus answer textarea
                    const textarea = card.querySelector('textarea');
                    if (textarea) textarea.focus();
                  } else {
                    // Show feedback area and focus
                    showFeedback(selected.id);
                  }
                }
              } else if (allRequests.length > 0 && e.key === 'Enter') {
                // Select first if none selected
                selectRequest(0);
              }
              return;
            }

            // Send feedback (S key)
            if (e.key === 's') {
              e.preventDefault();
              const selected = getSelectedRequest();
              if (selected) {
                const card = document.querySelector(`.request-card[data-id="${selected.id}"]`);
                if (card) {
                  const isQuestion = card.classList.contains('question');
                  if (isQuestion) {
                    answerQuestion(selected.id);
                  } else {
                    rejectRequest(selected.id);
                  }
                }
              }
              return;
            }

            // Toggle diff (D key)
            if (e.key === 'd') {
              e.preventDefault();
              const selected = getSelectedRequest();
              if (selected) {
                const card = document.querySelector(`.request-card[data-id="${selected.id}"]`);
                if (card) {
                  const details = card.querySelector('.diff-section');
                  if (details) {
                    details.open = !details.open;
                  }
                }
              }
              return;
            }

            // Toggle keyboard hints
            if (e.key === '?') {
              e.preventDefault();
              const hints = document.getElementById('keyboard-hints');
              hints.style.display = hints.style.display === 'none' ? 'block' : 'none';
              return;
            }

            // Select first request if none selected and navigating
            if (allRequests.length > 0 && selectedRequestIndex < 0) {
              if (['j', 'k', 'ArrowDown', 'ArrowUp'].includes(e.key)) {
                selectRequest(0);
              }
            }
          });

          // Poll for updates
          setInterval(fetchClients, 2000);
          setInterval(fetchRequests, 2000);
          setInterval(updateCountdowns, 1000); // Update timers every second

          // Initial fetch
          fetchClients();
          fetchRequests();
          setTimeout(updateCountdowns, 100); // Initial countdown update

          // Rapid initial client polling to catch name updates quickly
          setTimeout(fetchClients, 500);
          setTimeout(fetchClients, 1000);
          setTimeout(fetchClients, 1500);
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
  require 'optparse'

  options = {
    port: (ENV['RESPONSE_SERVER_PORT'] || ResponseServer::DEFAULT_PORT).to_i,
    notification_mode: (ENV['NOTIFICATION_MODE'] || 'server').to_sym
  }

  OptionParser.new do |opts|
    opts.banner = "Usage: #{$PROGRAM_NAME} [options]"

    opts.on('-p', '--port PORT', Integer, "Port to listen on (default: #{ResponseServer::DEFAULT_PORT})") do |p|
      options[:port] = p
    end

    opts.on('-n', '--notifications MODE', [:server, :web, :both],
            'Notification mode: server, web, or both (default: server)',
            '  server - OS notifications that focus Chrome when clicked',
            '  web    - Browser notifications only',
            '  both   - Both server and browser notifications') do |mode|
      options[:notification_mode] = mode
    end

    opts.on('-h', '--help', 'Show this help') do
      puts opts
      exit
    end
  end.parse!

  # Legacy positional argument support
  if ARGV[0] && options[:port] == ResponseServer::DEFAULT_PORT
    options[:port] = ARGV[0].to_i
  end

  server = ResponseServer.new(port: options[:port], notification_mode: options[:notification_mode])
  server.start
end
