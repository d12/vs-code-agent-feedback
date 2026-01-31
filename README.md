# Get User Approval - MCP Server

An MCP (Model Context Protocol) server that enables agents to request user approval before concluding work and ask clarifying questions. This helps ensure agent output quality by allowing human verification and clarification during task execution.

## Overview

This system consists of two components:

1. **Response Server** (`response-server/`) - A terminal-based HTTP server where users receive and respond to approval requests and questions
2. **MCP Server** (`mcp-server/`) - The MCP server that provides the `get_user_approval` and `ask_question` tools to agents

## How It Works

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│                 │     │                 │     │                 │
│   AI Agent      │────▶│   MCP Server    │────▶│ Response Server │
│   (VS Code)     │     │   (stdio)       │     │ (HTTP/Terminal) │
│                 │◀────│                 │◀────│                 │
└─────────────────┘     └─────────────────┘     └─────────────────┘
                                                        │
                                                        ▼
                                                 ┌─────────────┐
                                                 │    User     │
                                                 │  (Terminal) │
                                                 └─────────────┘
```

**For Approvals:**
1. Agent calls `get_user_approval` tool with a work summary and testing instructions
2. MCP server forwards the request to the response server
3. Response server shows the request in the terminal and sends a notification
4. User reviews the work and either approves or provides feedback
5. Response is relayed back through the MCP server to the agent
6. If not approved, the agent continues working based on feedback

**For Questions:**
1. Agent calls `ask_question` tool with a question and optional context
2. MCP server forwards the request to the response server
3. Response server shows the question in the terminal and sends a notification
4. User provides an answer
5. Response is relayed back through the MCP server to the agent

## Requirements

- Ruby 3.x (no additional gems required)
- macOS (for notifications) or Linux with `notify-send`

## Quick Start

### 1. Start the Response Server

In a dedicated terminal that will remain open:

```bash
cd get-user-approval/response-server
ruby server.rb
```

You should see:

```
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║   🤖  Agent Approval Response Server  🤖                  ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝

✓ Server listening on port 9876
  Waiting for agent approval requests...
```

### 2. Configure VS Code

Add the MCP server to your VS Code configuration. Edit `.vscode/mcp.json` in your workspace or your user MCP configuration:

```json
{
  "servers": {
    "getUserApproval": {
      "type": "stdio",
      "command": "ruby",
      "args": [
        "/FULL/PATH/TO/get-user-approval/mcp-server/server.rb"
      ]
    }
  }
}
```

Replace `/FULL/PATH/TO/` with the actual path to the `get-user-approval` directory.

### 3. Configure Agent Instructions

Add instructions to your `.github/copilot-instructions.md` or agent prompt:

```markdown
## Completion Protocol

Before concluding ANY task, you MUST call the `get_user_approval` tool with:
- A detailed summary of the work completed
- Clear instructions for how to test/verify the work

Only conclude the task after receiving approval. If the user provides feedback,
continue working to address their concerns and request approval again.
```

### 4. Test the Setup

Run the integration test:

```bash
cd get-user-approval
ruby test_integration.rb
```

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

| Variable | Default | Description |
|----------|---------|-------------|
| `APPROVAL_SERVER_HOST` | `127.0.0.1` | Response server host |
| `APPROVAL_SERVER_PORT` | `9876` | Response server port |
| `APPROVAL_TIMEOUT` | `600` | Request timeout in seconds (10 minutes) |

### Custom Port

To use a different port:

```bash
# Response server
ruby server.rb 8080

# Or via environment variable
APPROVAL_SERVER_PORT=8080 ruby server.rb
```

Update the MCP server configuration accordingly:

```json
{
  "servers": {
    "getUserApproval": {
      "type": "stdio",
      "command": "ruby",
      "args": ["/path/to/mcp-server/server.rb"],
      "env": {
        "APPROVAL_SERVER_PORT": "8080"
      }
    }
  }
}
```

## Extending Notifications

The notification system is modular and designed for easy extension. Edit `response-server/lib/notifier.rb` to add new notification methods:

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

Planned:
- SMS (Twilio)
- Email (SMTP)
- Slack
- Discord

## Troubleshooting

### MCP server can't connect to response server

- Ensure the response server is running
- Check that both are using the same port
- Verify no firewall is blocking localhost connections

### No notification received

- macOS: Check System Preferences > Notifications > Script Editor
- Linux: Ensure `notify-send` is installed (`apt install libnotify-bin`)

### Agent not using the tool

- Verify the MCP server is configured in VS Code
- Check that the tool appears in VS Code's tool picker
- Ensure agent instructions include the completion protocol

## File Structure

```
get-user-approval/
├── mcp-server/
│   └── server.rb          # MCP server (stdio)
├── response-server/
│   ├── server.rb          # Response server (HTTP)
│   └── lib/
│       ├── notifier.rb    # Notification modules
│       └── terminal.rb    # Terminal formatting utilities
├── test_integration.rb    # Integration test script
└── README.md              # This file
```

## License

MIT
