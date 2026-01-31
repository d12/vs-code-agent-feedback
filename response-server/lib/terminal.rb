# frozen_string_literal: true

# Terminal formatting utilities with colors and styling
module Terminal
  # ANSI color codes
  COLORS = {
    reset: "\e[0m",
    bold: "\e[1m",
    dim: "\e[2m",
    italic: "\e[3m",
    underline: "\e[4m",
    
    # Foreground colors
    black: "\e[30m",
    red: "\e[31m",
    green: "\e[32m",
    yellow: "\e[33m",
    blue: "\e[34m",
    magenta: "\e[35m",
    cyan: "\e[36m",
    white: "\e[37m",
    
    # Bright foreground colors
    bright_black: "\e[90m",
    bright_red: "\e[91m",
    bright_green: "\e[92m",
    bright_yellow: "\e[93m",
    bright_blue: "\e[94m",
    bright_magenta: "\e[95m",
    bright_cyan: "\e[96m",
    bright_white: "\e[97m",
    
    # Background colors
    bg_black: "\e[40m",
    bg_red: "\e[41m",
    bg_green: "\e[42m",
    bg_yellow: "\e[43m",
    bg_blue: "\e[44m",
    bg_magenta: "\e[45m",
    bg_cyan: "\e[46m",
    bg_white: "\e[47m"
  }.freeze

  class << self
    def colorize(text, *styles)
      codes = styles.map { |s| COLORS[s] }.compact.join
      "#{codes}#{text}#{COLORS[:reset]}"
    end

    def bold(text)
      colorize(text, :bold)
    end

    def success(text)
      colorize(text, :green, :bold)
    end

    def error(text)
      colorize(text, :red, :bold)
    end

    def warning(text)
      colorize(text, :yellow, :bold)
    end

    def info(text)
      colorize(text, :cyan)
    end

    def dim(text)
      colorize(text, :dim)
    end

    def header(text)
      colorize(text, :bold, :bright_magenta)
    end

    def divider(char: '─', width: 60)
      colorize(char * width, :dim)
    end

    def box(title, content, color: :cyan)
      width = 60
      top = "╭#{'─' * (width - 2)}╮"
      bottom = "╰#{'─' * (width - 2)}╯"
      
      lines = []
      lines << colorize(top, color)
      lines << colorize("│ #{title.ljust(width - 4)} │", color, :bold)
      lines << colorize("├#{'─' * (width - 2)}┤", color)
      
      content.to_s.split("\n").each do |line|
        # Wrap long lines
        wrapped = word_wrap(line, width - 4)
        wrapped.each do |wrapped_line|
          lines << colorize("│ ", color) + wrapped_line.ljust(width - 4) + colorize(" │", color)
        end
      end
      
      lines << colorize(bottom, color)
      lines.join("\n")
    end

    def word_wrap(text, width)
      return [''] if text.nil? || text.empty?
      
      lines = []
      current_line = ''
      
      text.split(/\s+/).each do |word|
        if current_line.empty?
          current_line = word
        elsif (current_line.length + word.length + 1) <= width
          current_line += " #{word}"
        else
          lines << current_line
          current_line = word
        end
      end
      
      lines << current_line unless current_line.empty?
      lines.empty? ? [''] : lines
    end

    def prompt(text)
      print colorize("#{text} ", :yellow, :bold)
      print colorize("▶ ", :bright_yellow)
    end

    def clear_screen
      print "\e[2J\e[H"
    end

    def newline(count = 1)
      puts "\n" * count
    end
  end
end
