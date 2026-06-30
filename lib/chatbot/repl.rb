require "readline"
require "ollama_client"
require_relative "phase1/tool_loop"

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
      puts "Type /help to see available commands."
      puts "Type /trade <ETHUSDT|SOLUSDT|XRPUSDT> [timeframe] to execute Phase 1 agent."
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

      when "/trade"
        puts "Usage: /trade <ETHUSDT|SOLUSDT|XRPUSDT> [timeframe]"

      when /^\/trade\s+(\S+)(?:\s+(\S+))?/
        symbol = $1.strip.upcase
        timeframe = $2 ? $2.strip : "1h"
        run_phase1_agent(symbol, timeframe)

      when "/help"
        puts "/quit /q  - Exit"
        puts "/clear    - Reset conversation"
        puts "/switch   - Switch model: /switch <name>"
        puts "/models   - List models"
        puts "/trade    - Run Phase 1 trading agent: /trade <symbol> [timeframe]"
        puts "/help     - This help"

      else
        return false
      end

      true
    end

    def run_phase1_agent(symbol, timeframe)
      unless %w[ETHUSDT SOLUSDT XRPUSDT].include?(symbol)
        puts "[ERROR] Invalid symbol: #{symbol}. Phase 1 only allows: ETHUSDT, SOLUSDT, XRPUSDT."
        return
      end

      # Configure model pool using the currently active session settings
      endpoints = [
        { url: @session.config.base_url, model: @session.config.model }
      ]

      puts "🤖 Launching Phase 1 Agent iteration for #{symbol} (#{timeframe})..."
      loop_runner = Chatbot::Phase1::ToolLoop.new(endpoints: endpoints)
      
      result = loop_runner.run_iteration(symbol, timeframe)
      
      puts "\n=== AGENT RESPONSE CONTRACT ==="
      puts JSON.pretty_generate(result)
      puts "================================"

      # Print Trace details
      if loop_runner.logger.traces.any?
        puts "\n" + loop_runner.logger.format_trace(loop_runner.logger.traces.last)
      end
    rescue => e
      puts "[ERROR] Agent execution failed: #{e.message}"
      puts e.backtrace.first(5).join("\n")
    end
  end
end
