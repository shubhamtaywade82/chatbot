# frozen_string_literal: true

module Chatbot
  module TerminalMarkdown
    # ANSI escape sequences for text styling
    RESET      = "\e[0m"
    BOLD       = "\e[1m"
    DIM        = "\e[2m"
    ITALIC     = "\e[3m"
    UNDERLINE  = "\e[4m"
    
    # Colors
    RED        = "\e[31m"
    GREEN      = "\e[32m"
    YELLOW     = "\e[33m"
    BLUE       = "\e[34m"
    MAGENTA    = "\e[35m"
    CYAN       = "\e[36m"
    GRAY       = "\e[90m"
    
    # Backgrounds
    BG_GRAY    = "\e[100m"

    def self.render_line(line)
      # 1. Blockquote / Alerts
      if line.start_with?(">")
        if line.match?(/>\s*\[!(NOTE|INFO)\]/i)
          return "#{BLUE}#{BOLD}ℹ NOTE:#{RESET} "
        elsif line.match?(/>\s*\[!(IMPORTANT|WARNING|CAUTION)\]/i)
          return "#{RED}#{BOLD}⚠ IMPORTANT:#{RESET} "
        elsif line.match?(/>\s*\[!(TIP)\]/i)
          return "#{GREEN}#{BOLD}💡 TIP:#{RESET} "
        else
          return "#{GRAY}#{line.sub(/^>\s*/, "  │ ")}#{RESET}"
        end
      end

      # 2. Headers
      if line.start_with?("#")
        header_match = line.match(/^(\#+)\s*(.*)$/)
        if header_match
          level = header_match[1].length
          content = header_match[2]
          case level
          when 1
            return "\n#{MAGENTA}#{BOLD}#{UNDERLINE}#{content}#{RESET}\n"
          when 2
            return "\n#{CYAN}#{BOLD}#{content}#{RESET}\n"
          else
            return "\n#{YELLOW}#{BOLD}#{content}#{RESET}\n"
          end
        end
      end

      # 3. Horizontal Rule
      if line.match?(/^(\-{3,}|\*{3,}|\_{3,})$/)
        return "#{GRAY}#{"─" * 60}#{RESET}"
      end

      # 4. Lists
      if line.match?(/^\s*[\-\*\+]\s+/)
        line = line.sub(/^\s*[\-\*\+]\s+/, "  #{BLUE}•#{RESET} ")
      elsif line.match?(/^\s*\d+\.\s+/)
        line = line.sub(/^\s*(\d+)\.\s+/) { |m| "  #{BLUE}#{$1}.#{RESET} " }
      end

      # 5. Tables
      if line.start_with?("|")
        # Color table borders and separators
        line = line.gsub("|", "#{BLUE}|#{RESET}")
        line = line.gsub("---", "#{BLUE}---#{RESET}")
        # Make table headers bold
        if line.match?(/[^-\s|]/) # contains actual text
          line = line.gsub(/(?<=^|\|)\s*([^|]+?)\s*(?=\||$)/) do |m|
            # If it's a header or separator line
            content = $1.strip
            if content.match?(/^[-:]+$/)
              m
            else
              " #{BOLD}#{content}#{RESET} "
            end
          end
        end
      end

      # 6. Inline formatting (bold, italic, code)
      line = render_inline(line)

      line
    end

    def self.render_inline(text)
      # Inline code: `code`
      text = text.gsub(/`([^`]+)`/) { "#{YELLOW}#{$1}#{RESET}" }

      # Bold-italic: ***text***
      text = text.gsub(/\*\*\*([^*]+)\*\*\*/) { "#{BOLD}#{ITALIC}#{$1}#{RESET}" }

      # Bold: **text**
      text = text.gsub(/\*\*([^*]+)\*\*/) { "#{BOLD}#{$1}#{RESET}" }

      # Italic: *text*
      text = text.gsub(/\*([^*]+)\*/) { "#{ITALIC}#{$1}#{RESET}" }

      text
    end
  end
end
