# frozen_string_literal: true

require 'shellwords'

# Modular notification system - easily extensible for SMS, email, etc.
module Notifier
  class Base
    def notify(title:, message:, url: nil)
      raise NotImplementedError, "Subclasses must implement #notify"
    end
  end

  # macOS notification using terminal-notifier (preferred) or osascript fallback
  class MacOS < Base
    def notify(title:, message:, url: nil)
      # Escape quotes for shell
      escaped_title = title.gsub('"', '\\"').gsub("'", "'\\''")
      escaped_message = message.gsub('"', '\\"').gsub("'", "'\\''")
      
      # Try terminal-notifier first (supports click actions)
      if command_exists?('terminal-notifier')
        # Use -execute to run AppleScript that finds and focuses the correct Chrome tab
        # This handles: multiple Chrome windows, user browsing other tabs, etc.
        focus_script = build_chrome_focus_script(url)
        
        args = [
          'terminal-notifier',
          '-title', title,
          '-message', message,
          '-sound', 'default',
          '-execute', focus_script
        ]
        
        system(*args)
      else
        # Fallback to osascript (no click action support)
        system(
          'osascript', '-e',
          "display notification \"#{escaped_message}\" with title \"#{escaped_title}\" sound name \"default\""
        )
      end
    end
    
    private
    
    def command_exists?(cmd)
      system("which #{cmd} > /dev/null 2>&1")
    end
    
    # Build an AppleScript command that finds and focuses the Chrome tab with our URL
    def build_chrome_focus_script(url)
      return 'open -a "Google Chrome"' unless url
      
      # Extract the host:port to match (handles both http and https, with or without path)
      # For localhost:18463, we want to match any tab containing that
      match_pattern = url.sub(%r{^https?://}, '').sub(%r{/.*$}, '')
      
      # AppleScript to find the tab and focus it
      # Each line becomes a separate -e argument to osascript
      lines = [
        'tell application "Google Chrome"',
        'activate',
        'set found to false',
        'set windowCount to count of windows',
        'repeat with windowIndex from 1 to windowCount',
        'set w to window windowIndex',
        'set tabCount to count of tabs of w',
        'repeat with tabIndex from 1 to tabCount',
        'set t to tab tabIndex of w',
        "if URL of t contains \"#{match_pattern}\" then",
        'set active tab index of w to tabIndex',
        'set index of w to 1',
        'set found to true',
        'exit repeat',
        'end if',
        'end repeat',
        'if found then exit repeat',
        'end repeat',
        'if not found then',
        "open location \"#{url}\"",
        'end if',
        'end tell'
      ]
      
      # Build osascript command with multiple -e flags
      args = lines.flat_map { |line| ['-e', line] }
      (['osascript'] + args).shelljoin
    end
  end

  # Linux notification using notify-send
  class Linux < Base
    def notify(title:, message:, url: nil)
      # notify-send doesn't support click actions easily
      # Some desktop environments support actions though
      system('notify-send', '--urgency=critical', title, message)
      
      # If URL provided, try xdg-open in background (optional)
      if url
        Thread.new do
          # Try to focus existing browser window
          system('wmctrl', '-a', 'localhost:18463', err: '/dev/null') rescue nil
        end
      end
    end
  end

  # Placeholder for future SMS notifications
  class SMS < Base
    def initialize(phone_number:, api_key:)
      @phone_number = phone_number
      @api_key = api_key
    end

    def notify(title:, message:, url: nil)
      # TODO: Implement SMS notification (e.g., Twilio)
      warn "SMS notifications not yet implemented"
    end
  end

  # Placeholder for future email notifications
  class Email < Base
    def initialize(email_address:, smtp_config:)
      @email_address = email_address
      @smtp_config = smtp_config
    end

    def notify(title:, message:, url: nil)
      # TODO: Implement email notification
      warn "Email notifications not yet implemented"
    end
  end
  
  # Null notifier - does nothing (for web-only mode)
  class Null < Base
    def notify(title:, message:, url: nil)
      # No-op
    end
  end

  # Factory method to get the appropriate notifier
  def self.default
    case RUBY_PLATFORM
    when /darwin/
      MacOS.new
    when /linux/
      Linux.new
    else
      warn "Unknown platform: #{RUBY_PLATFORM}, notifications may not work"
      MacOS.new
    end
  end
  
  def self.null
    Null.new
  end
end
