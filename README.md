# Get User Approval - MCP Server

An MCP (Model Context Protocol) server that enables agents to request user approval before concluding work and ask clarifying questions. This helps ensure agent output quality by allowing human verification and clarification during task execution.

## Overview

This system consists of two components:

1. **Response Server** (`response-server/`) - A web-based server that runs on your **local machine** and provides a browser UI for responding to agent requests
2. **MCP Server** (`mcp-server/`) - The MCP server that provides the `get_user_approval` and `ask_question` tools to agents (runs in VS Code/CodeSpaces)

## How It Works

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  YOUR LOCAL MACHINE                                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │  Response Server (Web UI)                                               ││
│  │  http://localhost:18463                                                 ││
│  │  - Polls ports 14700-14715 to discover MCP clients                      ││
│  │  - Shows all pending requests in browser                                 ││
│  │  - Sends responses back to MCP servers                                   ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│         ▲                    ▲                    ▲                         │
│         │ Port 14700         │ Port 14701         │ Port 14702              │
│         │ (forwarded)        │ (forwarded)        │ (forwarded)             │
└─────────┼────────────────────┼────────────────────┼─────────────────────────┘
          │                    │                    │
┌─────────┼────────────────────┼────────────────────┼─────────────────────────┐
│ CODESPACE 1                  │ CODESPACE 2        │ CODESPACE 3             │
│  ┌──────┴──────┐      ┌──────┴──────┐      ┌──────┴──────┐                  │
│  │ MCP Server  │      │ MCP Server  │      │ MCP Server  │                  │
│  │ Port 14700  │      │ Port 14700  │      │ Port 14700  │                  │
│  │ (internal)  │      │ (internal)  │      │ (internal)  │                  │
│  └─────────────┘      └─────────────┘      └─────────────┘                  │
│         ▲                    ▲                    ▲                         │
│         │                    │                    │                         │
│  ┌──────┴──────┐      ┌──────┴──────┐      ┌──────┴──────┐                  │
│  │  AI Agent   │      │  AI Agent   │      │  AI Agent   │                  │
│  │  (VS Code)  │      │  (VS Code)  │      │  (VS Code)  │                  │
│  └─────────────┘      └─────────────┘      └─────────────┘                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key Features

- **Browser-based UI**: No more terminal-based interaction - manage all requests in a modern web interface
- **Multi-CodeSpace Support**: Run multiple VS Code instances in different CodeSpaces, all connecting to one Response Server
- **Auto-Discovery**: Response Server automatically discovers MCP clients via port polling
- **Desktop Notifications**: Get notified when agents need your attention

### How the Communication Works

1. **MCP Server starts** in each CodeSpace and exposes an HTTP endpoint on port 14700
2. **VS Code auto-forwards** port 14700 to your local machine (14700, 14701, etc. if ports are in use)
3. **Response Server polls** ports 14700-14715 on localhost to discover connected MCP clients
4. **Agent calls** `get_user_approval` or `ask_question` → request is queued in MCP Server
5. **Response Server fetches** pending requests from all connected MCP clients
6. **User responds** via web UI → Response Server POSTs response back to MCP Server
7. **Agent receives** the response and continues

## Requirements

- Ruby 3.x (no additional gems required)
- macOS (for notifications) or Linux with `notify-send`
- VS Code with MCP support
- **Optional (macOS)**: `terminal-notifier` for clickable notifications that focus Chrome

```bash
# Install terminal-notifier for best notification experience (macOS)
brew install terminal-notifier
```

## Quick Start

### 1. Start the Response Server (on your LOCAL machine)

In a dedicated terminal that will remain open:

```bash
./bin/start-response-server
```

**Notification modes:**
- `./start-response-server` - Server notifications (default, uses terminal-notifier if installed)
- `./start-response-server -n web` - Browser notifications only
- `./start-response-server -n both` - Both server and browser notifications

You should see:

```
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║   🤖  Agent Approval Response Server  🤖                  ║
║         (Web Interface Edition)                           ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝

✓ Web server listening on http://localhost:18463
  Open this URL in your browser to manage agent requests
  Polling ports 14700-14715 for MCP clients...
```

Open http://localhost:18463 in your browser.

### 2. Configure VS Code

Add the MCP server to your VS Code configuration. Run this in each environment (laptop or CodeSpaces):

```bash
./bin/install-mcp-server
```

Or manually add to your MCP server configuration:

```json
{
  "servers": {
    "getUserApproval": {
      "type": "stdio",
      "command": "ruby",
      "args": [
        "/FULL/PATH/TO/vs-code-agent-feedback/mcp-server/server.rb"
      ]
    }
  }
}
```

> **Note:** The server automatically detects your workspace folder via the MCP protocol and displays the git repository name (e.g., `owner/repo`) in the dashboard.

### 3. Configure Agent Instructions

Add the following to your agent's chat instructions (click the Cog in the agent window → "Chat instructions"):

See `sample_instructions.md` for recommended instructions.

## Tool Reference

### `get_user_approval`

Request user approval before concluding work.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `work_summary` | string | Yes | A detailed summary of the work completed |
| `testing_instructions` | string | Yes | Instructions for how to verify the work |

**Returns:**

- If approved: `"✅ APPROVED: The user has approved your work. You may now conclude this task."`
- If not approved: `"❌ NOT APPROVED: The user has requested changes.\n\nFeedback:\n{feedback}\n\nPlease address the feedback and continue working on the task."`

### `ask_question`

Ask the user a question when there is uncertainty or ambiguity in the work.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `question` | string | Yes | The question to ask the user |
| `context` | string | No | Optional context to help the user understand why you are asking |

**Returns:**

- `"📝 USER ANSWER:\n\n{answer}"`

## Configuration

### Environment Variables

#### MCP Server (runs in CodeSpace/VS Code)

| Variable | Default | Description |
|----------|---------|-------------|
| `MCP_CALLBACK_PORT` | `14700` | Port for HTTP callback endpoint |
| `MCP_CLIENT_NAME` | auto-detected | Custom name for this MCP instance |
| `CODESPACE_NAME` | auto-detected | Used to name the client (set automatically in CodeSpaces) |
| `APPROVAL_TIMEOUT` | `600` | Request timeout in seconds (10 minutes) |

#### Response Server (runs locally)

| Variable | Default | Description |
|----------|---------|-------------|
| `RESPONSE_SERVER_PORT` | `18463` | Port for web UI |

### Custom Ports

```bash
# Response server on custom port
./bin/start-response-server 9000

# Or via environment variable
RESPONSE_SERVER_PORT=9000 ./bin/start-response-server
```

## CodeSpaces Setup

### Automatic Port Forwarding

When you run the MCP server in a CodeSpace, VS Code automatically forwards port 14700 to your local machine. The Response Server running locally will automatically discover the connection.

**Port Range**: The system uses ports 14700-14715 to support up to 16 concurrent CodeSpace instances. Each MCP server binds to port 14700 internally, and VS Code assigns the next available local port.

### Step-by-Step

1. **Local Machine**: Start the Response Server
   ```bash
   ./bin/start-response-server
   ```

2. **Each CodeSpace**: Install the MCP server
   ```bash
   ./bin/install-mcp-server
   ```

3. **Each CodeSpace**: Restart VS Code or reload the MCP servers

4. **Local Machine**: Open http://localhost:18463 - you should see connected clients appear

### devcontainer.json Configuration (Optional)

Add this to your `.devcontainer/devcontainer.json` to automatically forward the MCP port:

```json
{
  "forwardPorts": [14700],
  "portsAttributes": {
    "14700": {
      "label": "MCP Agent Approval",
      "onAutoForward": "silent"
    }
  }
}
```

## Extending Notifications

The notification system is modular. Edit `response-server/lib/notifier.rb` to add new notification methods:

```ruby
# Example: Add SMS notification
class SMS < Base
  def initialize(phone_number:, api_key:)
    @phone_number = phone_number
    @api_key = api_key
  end

  def notify(title:, message:)
    # Implement SMS sending (e.g., via Twilio)
  end
end
```

Currently supported:
- **macOS**: Native notifications via `osascript`
- **Linux**: `notify-send` command

## Troubleshooting

### Response Server doesn't see any clients

1. Ensure the MCP server is running (check VS Code's MCP status)
2. Verify port 14700 is being forwarded (VS Code Ports panel)
3. Check that the port is forwarded to the 14700-14715 range locally

### Agent request times out

- Default timeout is 10 minutes
- Ensure Response Server is running and the web UI is open
- Check for any connection issues in the Response Server terminal

### No notification received

- macOS: Check System Preferences > Notifications > Script Editor
- Linux: Ensure `notify-send` is installed (`apt install libnotify-bin`)

### Port conflict

If port 14700 is already in use on your local machine, the next MCP client will use 14701, etc. The Response Server polls all ports in the range.

## File Structure

```
vs-code-agent-feedback-mcp/
├── bin/
│   ├── install-mcp-server    # Installation script
│   └── start-response-server # Startup script for response server
├── mcp-server/
│   └── server.rb             # MCP server (stdio + HTTP callback)
├── response-server/
│   ├── server.rb             # Web-based response server
│   └── lib/
│       └── notifier.rb       # Notification modules
├── sample_instructions.md    # Sample agent instructions
└── README.md                 # This file
```

## Architecture Notes

### Why Port Polling?

When using CodeSpaces, the remote environment cannot directly reach your local machine. However, VS Code's port forwarding allows your local machine to reach the CodeSpace. We leverage this by:

1. Each MCP server exposes an HTTP endpoint on port 14700
2. VS Code forwards this port to your local machine
3. The Response Server polls the port range to discover clients
4. Communication is pull-based (Response Server fetches requests, posts responses)

### Why a Port Range?

When multiple CodeSpaces are active, each forwards port 14700 internally. VS Code assigns the next available local port (14700, 14701, 14702, etc.). By polling a range of 16 ports, we support up to 16 concurrent CodeSpace instances.

## License

MIT
