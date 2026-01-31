#!/usr/bin/env ruby
# frozen_string_literal: true

# Response Server for Agent Approval System
# This server runs in a terminal and allows users to approve/reject agent work

require 'socket'
require 'json'
require 'timeout'

# Load local libraries
require_relative 'lib/terminal'
require_relative 'lib/notifier'

class ResponseServer
  DEFAULT_PORT = 9876
  
  def initialize(port: DEFAULT_PORT)
    @port = port
    @notifier = Notifier.default
    @running = false
  end

  def start
    @running = true
    @server = TCPServer.new('127.0.0.1', @port)
    
    display_banner
    puts Terminal.success("✓ Server listening on port #{@port}")
    puts Terminal.dim("  Waiting for agent approval requests...")
    puts Terminal.divider
    puts

    # Handle graceful shutdown
    setup_signal_handlers

    while @running
      begin
        client = @server.accept
        handle_client(client)
      rescue IOError, Errno::EBADF
        # Server was closed, exit gracefully
        break
      rescue => e
        puts Terminal.error("Error accepting connection: #{e.message}")
      end
    end
  end

  def stop
    @running = false
    @server&.close
  end

  private

  def setup_signal_handlers
    %w[INT TERM].each do |signal|
      Signal.trap(signal) do
        puts "\n"
        puts Terminal.warning("Received #{signal}, shutting down...")
        stop
      end
    end
  end

  def display_banner
    banner = <<~BANNER
    
      ╔═══════════════════════════════════════════════════════════╗
      ║                                                           ║
      ║   🤖  Agent Approval Response Server  🤖                  ║
      ║                                                           ║
      ╚═══════════════════════════════════════════════════════════╝
    
    BANNER
    puts Terminal.colorize(banner, :bright_cyan, :bold)
  end

  def handle_client(client)
    request_line = client.gets
    return unless request_line

    # Read headers
    headers = {}
    while (line = client.gets) && line != "\r\n"
      key, value = line.split(': ', 2)
      headers[key.downcase] = value&.strip
    end

    # Read body if content-length specified
    body = ''
    if headers['content-length']
      body = client.read(headers['content-length'].to_i)
    end

    # Parse HTTP request
    method, path, = request_line.split(' ')

    response = if method == 'POST' && path == '/approval-request'
                 handle_approval_request(body)
               elsif method == 'POST' && path == '/question'
                 handle_question_request(body)
               elsif method == 'GET' && path == '/health'
                 { status: 200, body: { status: 'ok' }.to_json }
               else
                 { status: 404, body: { error: 'Not found' }.to_json }
               end

    send_response(client, response[:status], response[:body])
  rescue => e
    puts Terminal.error("Error handling client: #{e.message}")
    puts Terminal.dim(e.backtrace.first(5).join("\n"))
    send_response(client, 500, { error: e.message }.to_json)
  ensure
    client&.close
  end

  def handle_approval_request(body)
    data = JSON.parse(body)
    work_summary = data['work_summary'] || 'No summary provided'
    testing_instructions = data['testing_instructions'] || 'No testing instructions provided'

    # Send notification
    @notifier.notify(
      title: '🤖 Agent Needs Approval',
      message: 'An agent is waiting for your approval. Check the terminal.'
    )

    # Display the request
    display_approval_request(work_summary, testing_instructions)

    # Get user response
    response = get_user_response

    puts Terminal.divider
    puts

    {
      status: 200,
      body: response.to_json
    }
  rescue JSON::ParserError => e
    { status: 400, body: { error: "Invalid JSON: #{e.message}" }.to_json }
  end

  def handle_question_request(body)
    data = JSON.parse(body)
    question = data['question'] || 'No question provided'
    context = data['context']

    # Send notification
    @notifier.notify(
      title: '❓ Agent Has a Question',
      message: 'An agent is waiting for your answer. Check the terminal.'
    )

    # Display the question
    display_question(question, context)

    # Get user response
    response = get_question_response

    puts Terminal.divider
    puts

    {
      status: 200,
      body: response.to_json
    }
  rescue JSON::ParserError => e
    { status: 400, body: { error: "Invalid JSON: #{e.message}" }.to_json }
  end

  def display_approval_request(work_summary, testing_instructions)
    puts "\n"
    puts Terminal.colorize('🔔 NEW APPROVAL REQUEST', :bright_yellow, :bold)
    puts Terminal.dim("  Received at #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}")
    puts
    
    puts Terminal.box('📋 WORK SUMMARY', work_summary, color: :blue)
    puts
    puts Terminal.box('🧪 TESTING INSTRUCTIONS', testing_instructions, color: :magenta)
    puts
  end

  def display_question(question, context)
    puts "\n"
    puts Terminal.colorize('❓ AGENT QUESTION', :bright_cyan, :bold)
    puts Terminal.dim("  Received at #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}")
    puts
    
    puts Terminal.box('🤔 QUESTION', question, color: :cyan)
    if context && !context.empty?
      puts
      puts Terminal.box('📋 CONTEXT', context, color: :blue)
    end
    puts
  end

  def get_question_response
    # Flush any buffered input (e.g., extra newlines from previous submission)
    flush_stdin
    
    puts Terminal.colorize('─' * 60, :dim)
    puts
    puts Terminal.colorize('  Please provide your answer:', :bold)
    puts Terminal.dim('  (Enter your answer, then press Enter twice to submit)')
    puts
    
    answer = get_multiline_input
    
    puts
    puts Terminal.success('✓ Answer sent to agent')
    
    { answer: answer }
  end

  def get_user_response
    # Flush any buffered input (e.g., extra newlines from previous submission)
    flush_stdin
    
    puts Terminal.colorize('─' * 60, :dim)
    puts
    puts Terminal.colorize('  What would you like to do?', :bold)
    puts
    puts Terminal.colorize('    [y/yes]', :green, :bold) + Terminal.dim(' - Approve the work (agent will complete)')
    puts Terminal.colorize('    [n/no] ', :red, :bold) + Terminal.dim(' - Reject and provide feedback')
    puts
    
    loop do
      Terminal.prompt('Your decision')
      input = $stdin.gets&.strip&.downcase

      case input
      when 'y', 'yes'
        puts
        puts Terminal.success('✓ Work approved!')
        return { approved: true, feedback: nil }
      when 'n', 'no'
        puts
        puts Terminal.warning('Please provide feedback for the agent:')
        puts Terminal.dim('(Enter your feedback, then press Enter twice to submit)')
        puts
        
        feedback = get_multiline_input
        
        puts
        puts Terminal.info("✓ Feedback sent to agent")
        return { approved: false, feedback: feedback }
      else
        puts Terminal.error("Invalid input. Please enter 'y' or 'n'")
      end
    end
  end

  def get_multiline_input
    lines = []
    empty_line_count = 0
    
    Terminal.prompt('Feedback')
    
    while empty_line_count < 1
      line = $stdin.gets
      break unless line
      
      line = line.chomp
      if line.empty?
        empty_line_count += 1
      else
        empty_line_count = 0
        lines << line
      end
    end
    
    lines.join("\n")
  end

  # Flush any buffered input from stdin (non-blocking)
  def flush_stdin
    require 'io/wait'
    while $stdin.ready?
      $stdin.read_nonblock(1024)
    end
  rescue IO::WaitReadable, EOFError
    # No data available, that's fine
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
      "",
      body
    ].join("\r\n")

    client.write(response)
  end
end

# Main entry point
if __FILE__ == $PROGRAM_NAME
  port = (ARGV[0] || ENV['APPROVAL_SERVER_PORT'] || ResponseServer::DEFAULT_PORT).to_i
  
  server = ResponseServer.new(port: port)
  server.start
end
