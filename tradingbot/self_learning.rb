# frozen_string_literal: true

require "json"
require "ollama_client"

module TradingBot
  class SelfLearning
    # Scans closed trades, queries the LLM for a post-mortem, and writes to database
    def self.process_closed_trades(storage, config)
      trades = storage.unprocessed_closed_trades(limit: 5)
      return if trades.empty?

      ollama_conf = Ollama::Config.new
      ollama_conf.base_url = config.base_url
      ollama_conf.timeout = 120
      client = Ollama::Client.new(config: ollama_conf)

      trades.each do |trade|
        outcome = if trade["pnl"].to_f > 0
                    "WIN"
                  elsif trade["pnl"].to_f < 0
                    "LOSS"
                  else
                    "BREAKEVEN"
                  end

        prompt = <<~PROMPT
          You are an institutional trading mentor. Review this completed trade:
          Symbol: #{trade['symbol']}
          Direction: #{trade['direction']}
          Entry Price: $#{trade['entry_price']}
          Exit Price: $#{trade['exit_price']}
          PnL: $#{trade['pnl']}
          Exit Reason: #{trade['exit_reason']}
          Entry Reason: #{trade['entry_reason']}

          Identify what we can learn from this trade. Write a single, brief sentence summarizing the key lesson.
          - If it was a WIN, highlight what went right (e.g., strong trend alignment).
          - If it was a LOSS, diagnose the mistake to avoid next time (e.g., entered in premium zone, ignored order block rejection).
          Keep it under 15 words. Be direct. Do not write a preamble, conversational filler, or intro.
        PROMPT

        puts "  Analyzing post-mortem for trade ##{trade['id']} (#{trade['symbol']})..." if config.verbose
        
        begin
          response = client.chat(
            model: config.model,
            messages: [{ role: "user", content: prompt }],
            think: false,
            options: { temperature: 0.3, num_predict: 64 }
          )
          
          lesson = response.respond_to?(:message) ? response.message.content : response.to_s
          lesson = lesson.strip.gsub(/\A["']|["']\z/, "") # Strip quotes
          
          storage.save_lesson(
            trade_id: trade["id"],
            symbol: trade["symbol"],
            direction: trade["direction"],
            outcome: outcome,
            lesson: lesson
          )
          
          puts "  💾 Lesson saved for trade ##{trade['id']}: \"#{lesson}\"" if config.verbose
        rescue => e
          warn "  ⚠️ SelfLearning error for trade ##{trade['id']}: #{e.message}"
        end
      end
    end
  end
end
