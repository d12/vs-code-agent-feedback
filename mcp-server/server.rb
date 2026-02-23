#!/usr/bin/env ruby
# frozen_string_literal: true

# MCP Server for Agent Approval System
# This server provides the get_user_approval and ask_question tools for agents
# It also exposes an HTTP server for the response server to poll for requests

require 'json'
require 'socket'
require 'securerandom'
require 'time'
require 'uri'

# Configuration
CALLBACK_PORT = (ENV['MCP_CALLBACK_PORT'] || 14700).to_i
REQUEST_TIMEOUT = (ENV['APPROVAL_TIMEOUT'] || 60 * 30).to_i # 30 minutes default

# Server information
SERVER_NAME = 'get-user-approval'
SERVER_VERSION = '2.0.0'

# Get git repo name for better client identification
def get_git_repo_name(workspace_dir)
  return nil unless workspace_dir && !workspace_dir.empty?

  begin
    # Get the remote URL first (most reliable for repo name)
    remote_url = `git -C "#{workspace_dir}" config --get remote.origin.url 2>/dev/null`.strip
    if remote_url && !remote_url.empty?
      # Extract repo name from URL (handles both HTTPS and SSH formats)
      # Examples:
      # https://github.com/user/repo.git -> user/repo
      # git@github.com:user/repo.git -> user/repo
      if remote_url =~ %r{[/:]([^/]+?)/([^/]+?)(?:\.git)?$}
        return "#{$1}/#{$2}".sub(/\.git$/, '')
      end
    end

    # Fallback: get the root directory name
    root_dir = `git -C "#{workspace_dir}" rev-parse --show-toplevel 2>/dev/null`.strip
    if root_dir && !root_dir.empty?
      return File.basename(root_dir)
    end
  rescue => e
    # Git not available or not in a git repo
  end
  nil
end

# Get the current git diff for the workspace
def get_git_diff(workspace_dir)
  return nil unless workspace_dir && !workspace_dir.empty?

  begin
    # Check if we're in a git repo
    git_root = `git -C "#{workspace_dir}" rev-parse --show-toplevel 2>/dev/null`.strip
    return nil if git_root.empty?

    # Get diff of staged and unstaged changes
    # --no-color ensures clean output
    diff = `git -C "#{git_root}" diff HEAD --no-color 2>/dev/null`.strip

    # If no changes against HEAD, try just unstaged changes
    if diff.empty?
      diff = `git -C "#{git_root}" diff --no-color 2>/dev/null`.strip
    end

    # Include untracked files with full content (like GitHub PR view)
    untracked = `git -C "#{git_root}" ls-files --others --exclude-standard 2>/dev/null`.strip
    unless untracked.empty?
      untracked_files = untracked.split("\n")
      untracked_diffs = untracked_files.map do |file|
        file_path = File.join(git_root, file)
        next nil unless File.exist?(file_path) && File.file?(file_path)

        # Skip binary files
        begin
          content = File.read(file_path, encoding: 'UTF-8')
          # Check if file appears to be binary
          if content.include?("\x00") || !content.valid_encoding?
            next "diff --git a/#{file} b/#{file}\nnew file mode 100644\nBinary file"
          end

          lines = content.split("\n", -1)
          line_count = lines.length

          # Format like a git diff for a new file
          header = "diff --git a/#{file} b/#{file}\n"
          header += "new file mode 100644\n"
          header += "--- /dev/null\n"
          header += "+++ b/#{file}\n"
          header += "@@ -0,0 +1,#{line_count} @@\n"

          # Add all lines as additions
          diff_content = lines.map { |line| "+#{line}" }.join("\n")

          header + diff_content
        rescue => e
          "diff --git a/#{file} b/#{file}\nnew file mode 100644\n# Error reading file: #{e.message}"
        end
      end.compact

      if untracked_diffs.any?
        diff = diff.empty? ? untracked_diffs.join("\n\n") : diff + "\n\n" + untracked_diffs.join("\n\n")
      end
    end

    return nil if diff.empty?
    diff
  rescue => e
    log "Error getting git diff: #{e.message}"
    nil
  end
end

# Workspace directory can be passed via:
# 1. First argument (from VS Code ${workspaceFolder})
# 2. Environment variable MCP_WORKSPACE_DIR (preferred - set via env in mcp.json)
# 3. MCP roots/list request (automatic, after initialization)
# 4. Falls back to current directory
def resolve_workspace_dir
  # Check argument first
  if ARGV[0] && !ARGV[0].empty? && !ARGV[0].start_with?('${')
    return ARGV[0]
  end

  # Check environment variable (VS Code sets this via env config)
  env_workspace = ENV['MCP_WORKSPACE_DIR']
  if env_workspace && !env_workspace.empty? && !env_workspace.start_with?('${')
    return env_workspace
  end

  # Fallback to current directory
  Dir.pwd
end

# Mutable client state (can be updated after roots/list response)
module ClientState
  class << self
    attr_accessor :workspace_dir, :client_name, :pending_requests

    def initialize!
      @workspace_dir = resolve_workspace_dir
      @client_name = compute_client_name(@workspace_dir)
      @pending_requests = {} # For tracking outgoing requests (like roots/list)
      @request_id_counter = 0
    end

    def next_request_id
      @request_id_counter += 1
      "server-#{@request_id_counter}"
    end

    def compute_client_name(workspace)
      git_name = get_git_repo_name(workspace)
      git_name || ENV['CODESPACE_NAME'] || ENV['MCP_CLIENT_NAME'] || "local-#{CLIENT_ID[0..7]}"
    end

    def update_from_roots(roots)
      return if roots.nil? || roots.empty?

      # Use the first root's URI
      root = roots.first
      uri = root['uri'] || root[:uri]
      return unless uri

      # Convert file:// URI to path
      if uri.start_with?('file://')
        path = URI.decode_www_form_component(uri.sub('file://', ''))
        @workspace_dir = path
        new_name = compute_client_name(path)
        if new_name != @client_name
          @client_name = new_name
          log "Updated client name from roots: #{@client_name}"
        end
      end
    end
  end
end

# Generate a unique client ID for this instance
CLIENT_ID = SecureRandom.uuid

# Initialize client state
ClientState.initialize!

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

def handle_initialize(id, params)
  # Log initialize params to see what VS Code sends
  log "Initialize params: #{params.inspect}"
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

    # Collect git diff from the workspace
    git_diff = get_git_diff(ClientState.workspace_dir)

    result = create_request_and_wait('approval', {
      work_summary: work_summary,
      testing_instructions: testing_instructions,
      git_diff: git_diff
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

  # Check if this is a response to one of our requests (like roots/list)
  if request.key?('result') || request.key?('error')
    handle_client_response(request)
    return nil
  end

  case method
  when 'initialize'
    handle_initialize(id, params)
  when 'notifications/initialized'
    # After initialization, request roots to get workspace folder
    request_roots_list
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

# Send a request to the client to list roots (workspace folders)
def request_roots_list
  request_id = ClientState.next_request_id
  ClientState.pending_requests[request_id] = 'roots/list'

  request = {
    jsonrpc: '2.0',
    id: request_id,
    method: 'roots/list'
  }
  send_mcp_response(request)
end

# Handle responses from the client (for requests we sent)
def handle_client_response(response)
  request_id = response['id']
  pending_method = ClientState.pending_requests.delete(request_id)

  return unless pending_method

  if response['error']
    log "Client returned error for #{pending_method}: #{response['error']['message']}"
    return
  end

  case pending_method
  when 'roots/list'
    roots = response.dig('result', 'roots')
    ClientState.update_from_roots(roots)
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
          name: ClientState.client_name,
          version: SERVER_VERSION,
          port: @actual_port,
          timeout_seconds: REQUEST_TIMEOUT
        }.to_json
      }

    when ['GET', '/pending-requests']
      requests = $state_mutex.synchronize do
        $pending_requests.map do |id, req|
          expires_at = req[:created_at] + REQUEST_TIMEOUT
          {
            request_id: id,
            type: req[:type],
            data: req[:data],
            created_at: req[:created_at].iso8601,
            expires_at: expires_at.iso8601,
            timeout_seconds: REQUEST_TIMEOUT
          }
        end
      end
      { status: 200, body: { requests: requests, timeout_seconds: REQUEST_TIMEOUT }.to_json }

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
  log "Initial workspace: #{ClientState.workspace_dir}"
  log "Initial client name: #{ClientState.client_name}"

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
