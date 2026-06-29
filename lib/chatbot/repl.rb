# frozen_string_literal: true

require "readline"

module Chatbot
  class REPL
    COMMANDS = %w[/quit /q /clear /history /models /switch /json /tools /embed /help].freeze

    def initialize(session:)
      @session = session
      @running = false
    end

    def run
      @running = true
      banner

      while @running
        input = Readline.readline("You> ", true)
        break if input.nil?

        input = input.strip
        next if input.empty?

        handle_command(input) || chat(input)
      end
    end

    private

    def banner
      puts "🤖 Ollama ChatBot — #{@session.config.model}"
      puts "Commands: /help, /quit, /clear, /history, /switch <model>, /json <prompt>, /tools <prompt>, /embed <text>"
      puts "-" * 50
    end

    def chat(input)
      @session.reset_cancel!
      @session.renderer.prompt("Bot>")

      result = @session.chat(input, think: true)

      if result[:error]
        puts "\n[ERROR] #{result[:error]}"
      elsif result[:thinking] && !result[:thinking].empty?
        puts "\n[Reasoning: #{result[:thinking].length} chars]"
      end
    end

    def handle_command(input)
      case input
      when "/quit", "/q"
        @running = false
        puts "Goodbye!"
        true

      when "/clear"
        @session.conversation.clear!
        puts "History cleared."
        true

      when "/history"
        @session.conversation.messages.each do |m|
          puts "#{m.role}: #{m.content.to_s[0..200]}"
        end
        true

      when "/models"
        models = @session.client.list_model_names rescue []
        puts models.join(", ")
        true

      when /^\/switch (.+)/
        @session.switch_model($1.strip)
        true

      when /^\/json (.+)/
        schema = {
          "type" => "object",
          "properties" => {
            "answer" => { "type" => "string" },
            "confidence" => { "type" => "number" }
          },
          "required" => ["answer"]
        }
        result = @session.chat($1.strip, schema: schema)
        puts "\nJSON: #{result[:parsed].inspect}"
        true

      when /^\/tools (.+)/
        result = @session.chat($1.strip, tools: true)
        puts "\nResult: #{result.inspect}"
        true

      when /^\/embed (.+)/
        embedding = @session.embed($1.strip)
        puts "Embedding: #{embedding[0..4].inspect}... (#{embedding.length} dims)"
        true

      when "/help"
        puts COMMANDS.join(", ")
        true

      else
        false
      end
    end
  end
end