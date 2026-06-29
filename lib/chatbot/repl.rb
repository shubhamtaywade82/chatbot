require "readline"
require "ollama_client"

module Chatbot
  class REPL
    HISTORY_FILE = File.expand_path("../../.chatbot_history", __dir__)

    def initialize(session:)
      @session = session
      @running = false
      load_history
    end

    def run
      @running = true
      puts "-" * 50

      while @running
        input = Readline.readline("You> ", false)
        break if input.nil?

        input = input.strip
        next if input.empty?

        save_to_history(input)

        handle_command(input) || chat(input)
      end
    end

    private

    def load_history
      if File.exist?(HISTORY_FILE)
        File.readlines(HISTORY_FILE).each do |line|
          line = line.chomp
          next if line.empty?
          Readline::HISTORY.push(line)
        end
      end
    end

    def save_to_history(input)
      # Append to readline in-memory history if it's different from the last entry
      if Readline::HISTORY.empty? || Readline::HISTORY.to_a.last != input
        Readline::HISTORY.push(input)
      end

      # Persist to local history file
      File.open(HISTORY_FILE, "a") { |f| f.puts(input) }
    end

    def chat(input)
      result = @session.chat(input)
      if result.is_a?(Hash) && result[:error]
        puts "  [ERROR] #{result[:error]}"
      end

      nil
    end

    def handle_command(input)
      case input
      when "/quit", "/q"
        @running = false
        puts "Goodbye!"

      when "/clear"
        puts @session.reset!

      when "/switch", "/model"
        puts "Usage: /switch <model_name> or /model <model_name>"

      when /^\/switch (.+)/, /^\/model (.+)/
        @session.switch_model($1.strip)
        puts "Switched to #{$1.strip}"

      when "/models"
        client = Ollama::Client.new
        puts client.list_model_names.join(", ")

      when "/help"
        puts "/quit /q  - Exit"
        puts "/clear    - Reset conversation"
        puts "/switch   - Switch model: /switch <name>"
        puts "/models   - List models"
        puts "/help     - This help"

      else
        return false
      end

      true
    end
  end
end
