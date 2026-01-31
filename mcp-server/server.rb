#!/usr/bin/env ruby
# frozen_string_literal: true

# MCP Server for Agent Approval System
# This server provides the get_user_approval tool for agents to request user approval

require 'json'
require 'net/http'
require 'uri'

# Configuration
RESPONSE_SERVER_HOST = ENV['APPROVAL_SERVER_HOST'] || '127.0.0.1'
RESPONSE_SERVER_PORT = (ENV['APPROVAL_SERVER_PORT'] || 9876).to_i
REQUEST_TIMEOUT = (ENV['APPROVAL_TIMEOUT'] || 600).to_i # 10 minutes default

# Server information
SERVER_NAME = 'get-user-approval'
SERVER_VERSION = '1.0.0'

# Tool definition
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

def send_response(response)
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

def request_user_approval(work_summary, testing_instructions)
  uri = URI("http://#{RESPONSE_SERVER_HOST}:#{RESPONSE_SERVER_PORT}/approval-request")

  http = Net::HTTP.new(uri.host, uri.port)
  http.read_timeout = REQUEST_TIMEOUT
  http.open_timeout = 10

  request = Net::HTTP::Post.new(uri.path)
  request['Content-Type'] = 'application/json'
  request.body = {
    work_summary: work_summary,
    testing_instructions: testing_instructions
  }.to_json

  log "Sending approval request to response server..."
  response = http.request(request)

  if response.code == '200'
    JSON.parse(response.body)
  else
    { 'error' => "Response server returned #{response.code}: #{response.body}" }
  end
rescue Errno::ECONNREFUSED
  { 'error' => 'Could not connect to response server. Make sure the response server is running.' }
rescue Net::ReadTimeout
  { 'error' => 'Request timed out waiting for user response.' }
rescue => e
  { 'error' => "Error communicating with response server: #{e.message}" }
end

def request_user_question(question, context)
  uri = URI("http://#{RESPONSE_SERVER_HOST}:#{RESPONSE_SERVER_PORT}/question")

  http = Net::HTTP.new(uri.host, uri.port)
  http.read_timeout = REQUEST_TIMEOUT
  http.open_timeout = 10

  request = Net::HTTP::Post.new(uri.path)
  request['Content-Type'] = 'application/json'
  request.body = {
    question: question,
    context: context
  }.to_json

  log "Sending question to response server..."
  response = http.request(request)

  if response.code == '200'
    JSON.parse(response.body)
  else
    { 'error' => "Response server returned #{response.code}: #{response.body}" }
  end
rescue Errno::ECONNREFUSED
  { 'error' => 'Could not connect to response server. Make sure the response server is running.' }
rescue Net::ReadTimeout
  { 'error' => 'Request timed out waiting for user response.' }
rescue => e
  { 'error' => "Error communicating with response server: #{e.message}" }
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
          content: [
            {
              type: 'text',
              text: 'Error: work_summary is required'
            }
          ],
          isError: true
        }
      }
    end

    if testing_instructions.nil? || testing_instructions.empty?
      return {
        jsonrpc: '2.0',
        id: id,
        result: {
          content: [
            {
              type: 'text',
              text: 'Error: testing_instructions is required'
            }
          ],
          isError: true
        }
      }
    end

    # Request approval from the response server
    result = request_user_approval(work_summary, testing_instructions)

    if result['error']
      log "Error: #{result['error']}"
      {
        jsonrpc: '2.0',
        id: id,
        result: {
          content: [
            {
              type: 'text',
              text: "Error: #{result['error']}"
            }
          ],
          isError: true
        }
      }
    elsif result['approved']
      log "Work approved by user"
      {
        jsonrpc: '2.0',
        id: id,
        result: {
          content: [
            {
              type: 'text',
              text: "✅ APPROVED: The user has approved your work. You may now conclude this task."
            }
          ]
        }
      }
    else
      feedback = result['feedback'] || 'No specific feedback provided'
      log "Work not approved. Feedback: #{feedback}"
      {
        jsonrpc: '2.0',
        id: id,
        result: {
          content: [
            {
              type: 'text',
              text: "❌ NOT APPROVED: The user has requested changes.\n\nFeedback:\n#{feedback}\n\nPlease address the feedback and continue working on the task."
            }
          ]
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
          content: [
            {
              type: 'text',
              text: 'Error: question is required'
            }
          ],
          isError: true
        }
      }
    end

    # Send question to the response server
    result = request_user_question(question, context)

    if result['error']
      log "Error: #{result['error']}"
      {
        jsonrpc: '2.0',
        id: id,
        result: {
          content: [
            {
              type: 'text',
              text: "Error: #{result['error']}"
            }
          ],
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
          content: [
            {
              type: 'text',
              text: "📝 USER ANSWER:\n\n#{answer}"
            }
          ]
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

def handle_request(request)
  method = request['method']
  id = request['id']
  params = request['params'] || {}

  case method
  when 'initialize'
    handle_initialize(id, params)
  when 'notifications/initialized'
    # This is a notification, no response needed
    nil
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
        error: {
          code: -32601,
          message: "Method not found: #{method}"
        }
      }
    end
  end
end

def main
  log "#{SERVER_NAME} v#{SERVER_VERSION} started"
  log "Response server: #{RESPONSE_SERVER_HOST}:#{RESPONSE_SERVER_PORT}"

  $stdin.each_line do |line|
    line = line.strip
    next if line.empty?

    begin
      request = JSON.parse(line)
      response = handle_request(request)
      send_response(response) if response
    rescue JSON::ParserError => e
      log "JSON parse error: #{e.message}"
      send_response({
        jsonrpc: '2.0',
        id: nil,
        error: {
          code: -32700,
          message: 'Parse error'
        }
      })
    rescue => e
      log "Error: #{e.message}"
      log e.backtrace.first(5).join("\n")
    end
  end
end

main
