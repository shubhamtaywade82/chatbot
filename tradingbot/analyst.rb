require "ollama_agent"

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
      - LONG: Sweep of buy-side liquidity (BSL) OR order block retest + bullish BOS/CHoCH on higher TF + price in discount zone
      - SHORT: Sweep of sell-side liquidity (SSL) OR order block retest + bearish BOS/CHoCH on higher TF + price in premium zone
      - Minimum R:R ratio: 2.0
      - Entry at order block zone or after sweep reclaim
      - Stop loss beyond the sweep level or OB zone
    PROMPT

    def initialize(config)
      @config = config
      ENV["OLLAMA_BASE_URL"] = config.base_url
      ENV["OLLAMA_AGENT_SKILLS"] = "0"
      ENV["OLLAMA_AGENT_EXTERNAL_SKILLS"] = "0"
      ENV.delete("OLLAMA_AGENT_THINK")

      @runner = OllamaAgent::Runner.build(
        model: config.model,
        system_prompt: SYSTEM_PROMPT,
        stream: false,
        read_only: true,
        skills_enabled: false,
        think: nil,
        http_timeout: 120
      )
    end

    def analyze(symbol:, events:, multi_tf_data:, open_trades_count:)
      market_context = build_context(symbol, events, multi_tf_data, open_trades_count)
      response = @runner.run(market_context)
      response_text = response.is_a?(Hash) ? (response[:content] || response["content"] || response.to_s) : response.to_s
      parse_response(response_text, events)
    rescue => e
      warn "Analyst error: #{e.message}" if @config.verbose?
      { action: "wait", reason: "Analysis error: #{e.message}" }
    end

    private

    def build_context(symbol, events, multi_tf_data, open_trades_count)
      context = "=== MARKET ANALYSIS REQUEST ===\n"
      context += "Symbol: #{symbol}\n"
      context += "Open Trades: #{open_trades_count}/#{@config.max_open_trades}\n"
      context += "Mode: #{@config.mode}\n\n"

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
