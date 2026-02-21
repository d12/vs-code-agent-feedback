#!/usr/bin/env ruby
# frozen_string_literal: true

# MCP Server for Agent Approval System
# This server provides the get_user_approval and ask_question tools for agents
# It also exposes an HTTP server for the response server to poll for requests

require 'json'
require 'socket'
require 'securerandom'
require 'time'

# Configuration
CALLBACK_PORT = (ENV['MCP_CALLBACK_PORT'] || 14700).to_i
REQUEST_TIMEOUT = (ENV['APPROVAL_TIMEOUT'] || 600).to_i # 10 minutes default

# Server information
SERVER_NAME = 'get-user-approval'
SERVER_VERSION = '2.0.0'

# Generate a unique client ID for this instance
CLIENT_ID = SecureRandom.uuid
CLIENT_NAME = ENV['CODESPACE_NAME'] || ENV['MCP_CLIENT_NAME'] || "local-#{CLIENT_ID[0..7]}"

# Tool definitions
TOOLS = [
  {
    name: 'get_user_approval',
    description: 'Request user approval before concluding work. ALWAYS call this tool before finishing a task. ' \
                 'The user will review your work and either approve it or provide feedback for improvements. ' \
                 'If not approved, continue working based on the feedback provided.',
    inputSchema: {
      type: 'object',
      properties: {
        work_summary: {
          type: 'string',
          description: 'A detailed summary of the work that was completed. Include what was done, ' \
                       'files modified, features implemented, etc.'
        },
        testing_instructions: {
          type: 'string',
          description: 'Clear instructions for how the user can manually verify and test the work. ' \
                       'Include specific commands to run, URLs to visit, or actions to take.'
        }
      },
      required: %w[work_summary testing_instructions]
    }
  },
  {
    name: 'ask_question',
    description: 'Ask the user a question when there is uncertainty or ambiguity in the work. ' \
                 'Use this tool to clarify requirements, get preferences, or resolve any unclear aspects ' \
                 'before proceeding with implementation.',
    inputSchema: {
      type: 'object',
      properties: {
        question: {
          type: 'string',
          description: 'The question to ask the user. Be clear and specific about what you need clarified.'
        },
        context: {
          type: 'string',
          description: 'Optional context to help the user understand why you are asking this question ' \
                       'and what information would be most helpful.'
        }
      },
      required: %w[question]
    }
  }
].freeze

# Global state for pending requests and responses
$pending_requests = {} # request_id => { type:, data:, created_at: }
$responses = {} # request_id => response data
$state_mutex = Mutex.new
$response_conditions = {} # request_id => ConditionVariable

def send_mcp_response(response)
  json = response.to_json
  $stdout.write(json)
  $stdout.write("\n")
  $stdout.flush
end

def log(message)
  $stderr.puts "[#{Time.now.strftime('%H:%M:%S')}] #{message}"
  $stderr.flush
end

def handle_initialize(id, _params)
  {
    jsonrpc: '2.0',
    id: id,
    result: {
      protocolVersion: '2024-11-05',
      capabilities: {
        tools: {}
      },
      serverInfo: {
        name: SERVER_NAME,
        version: SERVER_VERSION
      }
    }
  }
end

def handle_tools_list(id, _params)
  {
    jsonrpc: '2.0',
    id: id,
    result: {
      tools: TOOLS
    }
  }
end

# Create a pending request and wait for a response
def create_request_and_wait(type, data)
  request_id = SecureRandom.uuid
  condition = ConditionVariable.new
  mutex = Mutex.new

  # Store the request
  $state_mutex.synchronize do
    $pending_requests[request_id] = {
      type: type,
      data: data,
      created_at: Time.now
    }
    $response_conditions[request_id] = { condition: condition, mutex: mutex }
  end

  log "Created #{type} request #{request_id[0..7]}, waiting for response..."

  # Wait for response with timeout
  response = nil
  mutex.synchronize do
    deadline = Time.now + REQUEST_TIMEOUT
    while response.nil? && Time.now < deadline
      remaining = deadline - Time.now
      break if remaining <= 0
      
      # Check if response has arrived
      $state_mutex.synchronize do
        response = $responses.delete(request_id)
      end
      
      break if response
      
      # Wait with timeout
      condition.wait(mutex, [remaining, 1].min)
    end
  end

  # Clean up
  $state_mutex.synchronize do
    $pending_requests.delete(request_id)
    $response_conditions.delete(request_id)
  end

  if response
    response
  else
    { 'error' => 'Request timed out waiting for user response.' }
  end
end

def handle_tools_call(id, params)
  tool_name = params['name']
  arguments = params['arguments'] || {}

  case tool_name
  when 'get_user_approval'
    work_summary = arguments['work_summary']
    testing_instructions = arguments['testing_instructions']

    if work_summary.nil? || work_summary.empty?
      return {
        jsonrpc: '2.0',
        id: id,
        result: {
          content: [{ type: 'text', text: 'Error: work_summary is required' }],
          isError: true
        }
      }
    end

    if testing_instructions.nil? || testing_instructions.empty?
      return {
        jsonrpc: '2.0',
        id: id,
        result: {
          content: [{ type: 'text', text: 'Error: testing_instructions is required' }],
          isError: true
        }
      }
    end

    result = create_request_and_wait('approval', {
      work_summary: work_summary,
      testing_instructions: testing_instructions
    })

    if result['error']
      log "Error: #{result['error']}"
      {
        jsonrpc: '2.0',
        id: id,
        result: {
          content: [{ type: 'text', text: "Error: #{result['error']}" }],
          isError: true
        }
      }
    elsif result['approved']
      log "Work approved by user"
      {
        jsonrpc: '2.0',
        id: id,
        result: {
          content: [{
            type: 'text',
            text: "✅ APPROVED: The user has approved your work. You may now conclude this task."
          }]
        }
      }
    else
      feedback = result['feedback'] || 'No specific feedback provided'
      log "Work not approved. Feedback: #{feedback}"
      {
        jsonrpc: '2.0',
        id: id,
        result: {
          content: [{
            type: 'text',
            text: "❌ NOT APPROVED: The user has requested changes.\n\nFeedback:\n#{feedback}\n\nPlease address the feedback and continue working on the task."
          }]
        }
      }
    end

  when 'ask_question'
    question = arguments['question']
    context = arguments['context']

    if question.nil? || question.empty?
      return {
        jsonrpc: '2.0',
        id: id,
        result: {
          content: [{ type: 'text', text: 'Error: question is required' }],
          isError: true
        }
      }
    end

    result = create_request_and_wait('question', {
      question: question,
      context: context
    })

    if result['error']
      log "Error: #{result['error']}"
      {
        jsonrpc: '2.0',
        id: id,
        result: {
          content: [{ type: 'text', text: "Error: #{result['error']}" }],
          isError: true
        }
      }
    else
      answer = result['answer'] || 'No answer provided'
      log "User answered question"
      {
        jsonrpc: '2.0',
        id: id,
        result: {
          content: [{ type: 'text', text: "📝 USER ANSWER:\n\n#{answer}" }]
        }
      }
    end

  else
    {
      jsonrpc: '2.0',
      id: id,
      error: {
        code: -32601,
        message: "Unknown tool: #{tool_name}"
      }
    }
  end
end

def handle_mcp_request(request)
  method = request['method']
  id = request['id']
  params = request['params'] || {}

  case method
  when 'initialize'
    handle_initialize(id, params)
  when 'notifications/initialized'
    nil # No response needed for notifications
  when 'tools/list'
    handle_tools_list(id, params)
  when 'tools/call'
    handle_tools_call(id, params)
  when 'ping'
    { jsonrpc: '2.0', id: id, result: {} }
  else
    if id
      {
        jsonrpc: '2.0',
        id: id,
        error: { code: -32601, message: "Method not found: #{method}" }
      }
    end
  end
end

# HTTP Server for response server polling
class CallbackHTTPServer
  def initialize(port)
    @port = port
    @actual_port = nil
    @server = nil
    @running = false
  end

  def start
    # Try to bind to the configured port, or find an available one in the range
    @actual_port = find_available_port
    @server = TCPServer.new('0.0.0.0', @actual_port)
    @running = true

    log "HTTP callback server listening on port #{@actual_port}"
    
    Thread.new do
      while @running
        begin
          client = @server.accept
          Thread.new(client) { |c| handle_request(c) }
        rescue IOError, Errno::EBADF
          break
        rescue => e
          log "HTTP server error: #{e.message}" if @running
        end
      end
    end
  end

  def stop
    @running = false
    @server&.close
  end

  def actual_port
    @actual_port
  end

  private

  def find_available_port
    port = @port
    max_port = @port + 15 # Try up to 16 ports

    while port <= max_port
      begin
        test_server = TCPServer.new('0.0.0.0', port)
        test_server.close
        return port
      rescue Errno::EADDRINUSE
        port += 1
      end
    end

    raise "Could not find available port in range #{@port}-#{max_port}"
  end

  def handle_request(client)
    request_line = client.gets
    return unless request_line

    # Read headers
    headers = {}
    while (line = client.gets) && line != "\r\n"
      key, value = line.split(': ', 2)
      headers[key&.downcase] = value&.strip
    end

    # Read body
    body = ''
    if headers['content-length']
      body = client.read(headers['content-length'].to_i)
    end

    method, path, = request_line.split(' ')
    
    response = route_request(method, path, body)
    send_response(client, response[:status], response[:body])
  rescue => e
    log "HTTP request error: #{e.message}"
    send_response(client, 500, { error: e.message }.to_json)
  ensure
    client&.close
  end

  def route_request(method, path, body)
    case [method, path]
    when ['GET', '/mcp-status']
      {
        status: 200,
        body: {
          client_id: CLIENT_ID,
          name: CLIENT_NAME,
          version: SERVER_VERSION,
          port: @actual_port
        }.to_json
      }

    when ['GET', '/pending-requests']
      requests = $state_mutex.synchronize do
        $pending_requests.map do |id, req|
          {
            request_id: id,
            type: req[:type],
            data: req[:data],
            created_at: req[:created_at].iso8601
          }
        end
      end
      { status: 200, body: { requests: requests }.to_json }

    when ['POST', '/respond']
      handle_response_post(body)

    when ['GET', '/health']
      { status: 200, body: { status: 'ok' }.to_json }

    else
      { status: 404, body: { error: 'Not found' }.to_json }
    end
  end

  def handle_response_post(body)
    data = JSON.parse(body)
    request_id = data['request_id']
    response_data = data['response']

    $state_mutex.synchronize do
      unless $pending_requests.key?(request_id)
        return { status: 404, body: { error: 'Request not found' }.to_json }
      end

      # Store the response
      $responses[request_id] = response_data

      # Signal the waiting thread
      cond_data = $response_conditions[request_id]
      if cond_data
        cond_data[:mutex].synchronize do
          cond_data[:condition].signal
        end
      end
    end

    log "Received response for request #{request_id[0..7]}"
    { status: 200, body: { success: true }.to_json }
  rescue JSON::ParserError => e
    { status: 400, body: { error: "Invalid JSON: #{e.message}" }.to_json }
  end

  def send_response(client, status, body)
    status_text = {
      200 => 'OK',
      400 => 'Bad Request', 
      404 => 'Not Found',
      500 => 'Internal Server Error'
    }[status] || 'Unknown'

    response = [
      "HTTP/1.1 #{status} #{status_text}",
      "Content-Type: application/json",
      "Content-Length: #{body.bytesize}",
      "Connection: close",
      "Access-Control-Allow-Origin: *",
      "",
      body
    ].join("\r\n")

    client.write(response)
  end
end

def main
  log "#{SERVER_NAME} v#{SERVER_VERSION} started"
  log "Client ID: #{CLIENT_ID}"
  log "Client name: #{CLIENT_NAME}"

  # Start the HTTP callback server
  http_server = CallbackHTTPServer.new(CALLBACK_PORT)
  http_server.start

  # Handle graceful shutdown
  %w[INT TERM].each do |signal|
    Signal.trap(signal) do
      log "Received #{signal}, shutting down..."
      http_server.stop
      exit 0
    end
  end

  # Process MCP messages from stdin
  $stdin.each_line do |line|
    line = line.strip
    next if line.empty?

    begin
      request = JSON.parse(line)
      response = handle_mcp_request(request)
      send_mcp_response(response) if response
    rescue JSON::ParserError => e
      log "JSON parse error: #{e.message}"
      send_mcp_response({
        jsonrpc: '2.0',
        id: nil,
        error: { code: -32700, message: 'Parse error' }
      })
    rescue => e
      log "Error: #{e.message}"
      log e.backtrace.first(5).join("\n")
    end
  end
end

main
