require "ollama_client"

module TradingBot
  class Analyst
    SYSTEM_PROMPT = <<~PROMPT
      You are an institutional SMC (Smart Money Concepts) trading analyst. Your ONLY job is to analyze market data and return a structured trade decision in JSON.

      RULES:
      - Only return VALID JSON. No markdown, no explanation, no preamble.
      - Use ONLY the data provided below. Never invent prices or levels.
      - If NO trade setup meets criteria, return {"action":"wait","reason":"<brief reason>"}
      - If a setup IS found, return the following JSON structure:
      {
        "action": "trade",
        "direction": "LONG" or "SHORT",
        "entry_price": <number>,
        "stop_loss": <number>,
        "take_profit_1": <number>,
        "take_profit_2": <number>,
        "take_profit_3": <number>,
        "rr_ratio": <number>,
        "confidence": <0.0-1.0>,
        "timeframe": "<entry timeframe>",
        "reason": "<concise SMC reason for the setup>",
        "event_type": "<the event that triggered this>"
      }

      SMC Setup Criteria:
      - LONG: Reversal after Sell-Side Liquidity (SSL) sweep, OR bullish Order Block retest, OR bullish BOS/CHoCH pullback.
      - SHORT: Reversal after Buy-Side Liquidity (BSL) sweep, OR bearish Order Block retest, OR bearish BOS/CHoCH pullback.
      - TREND ALIGNMENT: Setups (BOS Retest, Order Blocks, and Displacements) MUST align with the current trend (e.g., LONG only in a bullish trend, SHORT only in a bearish trend). CHoCH reversals represent the start of a new trend.
      - PREMIUM/DISCOUNT: LONG entries must be in the DISCOUNT zone (below equilibrium). SHORT entries must be in the PREMIUM zone (above equilibrium).
      - Minimum R:R ratio: 2.0
      - Stop loss placed beyond the sweep level or order block zone boundary.
    PROMPT

    def initialize(config, storage = nil)
      @config = config
      @storage = storage
      ollama_conf = Ollama::Config.new
      ollama_conf.base_url = config.base_url
      ollama_conf.timeout = 120
      @client = Ollama::Client.new(config: ollama_conf)
    end

    def analyze(symbol:, events:, multi_tf_data:, open_trades_count:)
      market_context = build_context(symbol, events, multi_tf_data, open_trades_count)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      response = @client.chat(
        model: @config.model,
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          { role: "user", content: market_context }
        ],
        think: false,
        options: { temperature: 0.2, num_predict: 256 }
      )

      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).to_i
      response_text = response.respond_to?(:message) ? response.message.content : response.to_s
      parsed = parse_response(response_text, events)
      parsed[:raw_response] = response_text
      parsed[:prompt] = market_context
      parsed[:duration_ms] = duration_ms
      parsed
    rescue => e
      warn "Analyst error: #{e.message}" if @config.verbose?
      { action: "wait", reason: "Analysis error: #{e.message}", raw_response: "Error: #{e.message}" }
    end

    private

    def build_context(symbol, events, multi_tf_data, open_trades_count)
      context = "=== MARKET ANALYSIS REQUEST ===\n"
      context += "Symbol: #{symbol}\n"
      context += "Open Trades: #{open_trades_count}/#{@config.max_open_trades}\n"
      context += "Mode: #{@config.mode}\n\n"

      context += "--- Optimized Strategy Parameters ---\n"
      context += "Stop Loss Offset: #{@config.sl_atr_multiplier} * ATR from entry, placed beyond the OB boundary/sweep level.\n"
      context += "Take Profit Target: Target at least #{@config.tp_risk_multiplier} * Risk (R:R ratio >= #{@config.tp_risk_multiplier}).\n"
      context += "Max Trade Hold Duration: #{@config.max_hold_hours} hours.\n\n"

      if @storage
        lessons = @storage.recent_lessons(symbol: symbol, limit: 5)
        if lessons.any?
          context += "--- Self-Learning: Lessons from Past Trades ---\n"
          lessons.each do |l|
            context += "- [Outcome: #{l['outcome']}] #{l['lesson']}\n"
          end
          context += "\n"
        end
      end

      if events.any?
        context += "--- Recent Events ---\n"
        events.each do |e|
          context += "[#{e[:event_type]}] #{e[:description]} on #{e[:timeframe]} at $#{e[:price]}\n"
        end
        context += "\n"
      end

      multi_tf_data.each do |tf_data|
        context += "--- #{tf_data[:interval]} Timeframe ---\n"
        context += "Price: $#{tf_data[:current_price]}\n"
        context += "Trend: #{tf_data[:trend]}\n"
        context += "ATR: $#{tf_data[:atr]}\n"
        context += "Protected High: $#{tf_data[:protected_high]}\n" if tf_data[:protected_high]
        context += "Protected Low: $#{tf_data[:protected_low]}\n" if tf_data[:protected_low]
        context += "Last Swing High: $#{tf_data[:last_swing_high]}\n" if tf_data[:last_swing_high]
        context += "Last Swing Low: $#{tf_data[:last_swing_low]}\n" if tf_data[:last_swing_low]

        if tf_data[:bos_events]&.any?
          context += "BOS Events: #{tf_data[:bos_events].join(", ")}\n"
        end
        if tf_data[:order_blocks]&.any?
          context += "Active OBs:\n"
          tf_data[:order_blocks].each { |ob| context += "  #{ob}\n" }
        end
        if tf_data[:sweeps]&.any?
          context += "Sweeps: #{tf_data[:sweeps].join(", ")}\n"
        end
        context += "Discount Zone: #{tf_data[:discount_zone]}\n"
        if tf_data[:pd_range]
          context += "PD Array: High $#{tf_data[:pd_range][:high]}, Low $#{tf_data[:pd_range][:low]}, Eq $#{tf_data[:pd_range][:equilibrium]}\n"
        end
        context += "\n"
      end

      context
    end

    def parse_response(raw, events)
      cleaned = raw.strip.gsub(/\A```(?:json)?\s*|\s*```\z/, "")
      json = JSON.parse(cleaned) rescue nil
      return { action: "wait", reason: "Failed to parse LLM response" } unless json

      action = json["action"] || "wait"
      return { action: action, reason: json["reason"] || "No setup" } unless action == "trade"

      direction = json["direction"]
      entry = json["entry_price"].to_f
      sl = json["stop_loss"].to_f
      tp1 = json["take_profit_1"].to_f
      tp2 = json["take_profit_2"].to_f
      tp3 = json["take_profit_3"].to_f
      confidence = json["confidence"].to_f
      rr = json["rr_ratio"].to_f

      return { action: "wait", reason: "Missing critical fields" } if entry <= 0 || sl <= 0

      if rr < @config.min_rr_ratio
        return { action: "wait", reason: "R:R #{rr.round(2)} < minimum #{@config.min_rr_ratio}" }
      end

      event_type = events.first ? events.first[:event_type].to_s : "periodic"
      {
        action: "trade",
        direction: direction,
        entry_price: entry,
        stop_loss: sl,
        take_profit_1: tp1,
        take_profit_2: tp2,
        take_profit_3: tp3,
        rr_ratio: rr,
        confidence: confidence,
        timeframe: json["timeframe"] || "1h",
        reason: json["reason"] || "",
        event_type: event_type
      }
    end
  end
end
