#!/usr/bin/env ruby
# frozen_string_literal: true

# Integration test for the new architecture
# This simulates an MCP server client and tests the response server

require 'net/http'
require 'json'
require 'socket'
require 'securerandom'

RESPONSE_SERVER_URL = "http://127.0.0.1:#{ENV['RESPONSE_SERVER_PORT'] || 18463}"
MCP_CALLBACK_PORT = 14700

puts "=" * 60
puts "Integration Test: Agent Approval System v2.0"
puts "=" * 60
puts

# Test 1: Check response server health
puts "1. Testing Response Server health..."
begin
  uri = URI("#{RESPONSE_SERVER_URL}/health")
  response = Net::HTTP.get_response(uri)
  if response.code == '200'
    puts "   ✓ Response server is healthy"
  else
    puts "   ✗ Response server returned #{response.code}"
    exit 1
  end
rescue => e
  puts "   ✗ Could not connect to response server: #{e.message}"
  puts "   Make sure to run: ruby response-server/server.rb"
  exit 1
end

# Test 2: Simulate MCP server HTTP endpoint
puts "\n2. Starting simulated MCP server on port #{MCP_CALLBACK_PORT}..."

client_id = SecureRandom.uuid
client_name = "test-client-#{client_id[0..7]}"
pending_requests = {}

begin
  server = TCPServer.new('127.0.0.1', MCP_CALLBACK_PORT)
  puts "   ✓ MCP callback server listening on port #{MCP_CALLBACK_PORT}"
rescue Errno::EADDRINUSE
  puts "   ✗ Port #{MCP_CALLBACK_PORT} is in use. Kill existing process first."
  exit 1
end

# Create a test request
request_id = SecureRandom.uuid
pending_requests[request_id] = {
  type: 'approval',
  data: {
    'work_summary' => 'Test work summary - this is a simulated approval request',
    'testing_instructions' => 'No testing needed - this is just a test'
  },
  created_at: Time.now.strftime('%Y-%m-%dT%H:%M:%S%z')
}

puts "\n3. Created test approval request (ID: #{request_id[0..7]}...)"

# Handle HTTP requests in a thread
responses_received = []
server_running = true
server_thread = Thread.new do
  while server_running
    begin
      client = server.accept_nonblock
      request_line = client.gets
      next unless request_line

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
      
      response_body = case [method, path]
      when ['GET', '/mcp-status']
        { client_id: client_id, name: client_name, version: '2.0.0', port: MCP_CALLBACK_PORT }.to_json
      when ['GET', '/pending-requests']
        reqs = pending_requests.map { |id, r| { request_id: id, type: r[:type], data: r[:data], created_at: r[:created_at] } }
        { requests: reqs }.to_json
      when ['POST', '/respond']
        data = JSON.parse(body)
        responses_received << data
        pending_requests.delete(data['request_id'])
        { success: true }.to_json
      else
        { error: 'Not found' }.to_json
      end

      http_response = [
        "HTTP/1.1 200 OK",
        "Content-Type: application/json",
        "Content-Length: #{response_body.bytesize}",
        "Connection: close",
        "",
        response_body
      ].join("\r\n")

      client.write(http_response)
      client.close
    rescue IO::WaitReadable
      IO.select([server], nil, nil, 0.1)
      retry if server_running
    rescue => e
      puts "   Error in server thread: #{e.message}" unless e.message.include?('closed')
    end
  end
end

puts "\n4. Waiting for Response Server to discover us (up to 10 seconds)..."
discovered = false
10.times do |i|
  sleep 1
  uri = URI("#{RESPONSE_SERVER_URL}/api/clients")
  response = Net::HTTP.get_response(uri)
  data = JSON.parse(response.body)
  
  if data['clients'].any? { |c| c['id'] == client_id }
    puts "   ✓ Response server discovered our client!"
    discovered = true
    break
  end
  print "   Waiting... (#{i + 1}s)\r"
end

unless discovered
  puts "\n   ✗ Response server did not discover our client"
  server.close
  exit 1
end

# Test 5: Check if request appears in Response Server
puts "\n5. Checking if our request appears in Response Server..."
uri = URI("#{RESPONSE_SERVER_URL}/api/requests")
response = Net::HTTP.get_response(uri)
data = JSON.parse(response.body)

if data['requests'].any? { |r| r['id'] == request_id }
  puts "   ✓ Request is visible in Response Server!"
else
  puts "   ✗ Request not found in Response Server"
  server.close
  exit 1
end

# Test 6: Simulate user response
puts "\n6. Simulating user approval via API..."
uri = URI("#{RESPONSE_SERVER_URL}/api/respond")
http = Net::HTTP.new(uri.host, uri.port)
request = Net::HTTP::Post.new(uri.path)
request['Content-Type'] = 'application/json'
request.body = {
  request_id: request_id,
  response: { approved: true, feedback: nil }
}.to_json

response = http.request(request)
if response.code == '200'
  puts "   ✓ Response sent successfully"
else
  puts "   ✗ Failed to send response: #{response.body}"
  server.close
  exit 1
end

# Wait a moment for response to be delivered
sleep 0.5

# Check if we received the response
if responses_received.any? { |r| r['request_id'] == request_id }
  received = responses_received.find { |r| r['request_id'] == request_id }
  puts "   ✓ MCP server received the response!"
  puts "     Approved: #{received['response']['approved']}"
else
  puts "   ✗ MCP server did not receive the response"
  server.close
  exit 1
end

# Cleanup
server_running = false
sleep 0.2
server.close
server_thread.kill

puts
puts "=" * 60
puts "All tests passed! ✓"
puts "=" * 60
puts
puts "The system is working correctly. You can now:"
puts "  1. Open http://localhost:18463 in your browser"
puts "  2. Start using the MCP server in VS Code"
puts "  3. Try the get_user_approval and ask_question tools"
puts
