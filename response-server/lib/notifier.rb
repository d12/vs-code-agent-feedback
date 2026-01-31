# frozen_string_literal: true

# Modular notification system - easily extensible for SMS, email, etc.
module Notifier
  class Base
    def notify(title:, message:)
      raise NotImplementedError, "Subclasses must implement #notify"
    end
  end

  # macOS notification using the notify shell function
  class MacOS < Base
    def notify(title:, message:)
      # Escape quotes for shell
      escaped_title = title.gsub('"', '\\"')
      escaped_message = message.gsub('"', '\\"')
      
      # Use osascript directly (same as the notify function)
      system(
        'osascript', '-e',
        "display notification \"#{escaped_message}\" with title \"#{escaped_title}\" sound name \"Default\""
      )
    end
  end

  # Linux notification using notify-send
  class Linux < Base
    def notify(title:, message:)
      system('notify-send', title, message)
    end
  end

  # Placeholder for future SMS notifications
  class SMS < Base
    def initialize(phone_number:, api_key:)
      @phone_number = phone_number
      @api_key = api_key
    end

    def notify(title:, message:)
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

    def notify(title:, message:)
      # TODO: Implement email notification
      warn "Email notifications not yet implemented"
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
end
