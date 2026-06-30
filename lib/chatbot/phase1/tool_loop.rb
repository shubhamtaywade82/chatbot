# frozen_string_literal: true

require_relative "binance_adapter"
require_relative "indicator_calculator"
require_relative "risk_validator"
require_relative "paper_exchange"
require_relative "ollama_router"
require_relative "trace_logger"

module Chatbot
  module Phase1
    class ToolLoop
      attr_reader :binance, :router, :exchange, :logger

      def initialize(endpoints:, exchange_balance: 1000.0)
        @binance = BinanceAdapter.new
        @router = OllamaRouter.new(endpoints)
        @exchange = PaperExchange.new(exchange_balance)
        @logger = TraceLogger.new
      end

      # Executes one analysis and trade iteration for a symbol
      # @param symbol [String]
      # @param timeframe [String] (e.g. "1h")
      # @return [Hash] JSON response contract
      def run_iteration(symbol, timeframe = "1h")
        symbol = symbol.upcase
        unless %w[ETHUSDT SOLUSDT XRPUSDT].include?(symbol)
          raise "Invalid symbol: #{symbol}. Phase 1 only allows ETHUSDT, SOLUSDT, XRPUSDT."
        end

        # 1. Fetch Market Data (Tool Calls)
        tool_calls = [
          { name: "get_ticker", args: { symbol: symbol } },
          { name: "get_klines", args: { symbol: symbol, timeframe: timeframe } },
          { name: "get_order_book", args: { symbol: symbol } },
          { name: "get_stats_24hr", args: { symbol: symbol } }
        ]

        ticker_data = @binance.ticker(symbol)
        candles = @binance.klines(symbol, timeframe, 100)
        book = @binance.order_book(symbol, 10)
        stats = @binance.stats_24hr(symbol)

        # Handle potential API errors/missing data
        if ticker_data["error"] || candles.empty? || book[:bids].empty? || stats["error"]
          observation = "API Error or incomplete data"
          tool_observations = [{ name: "get_market_data", summary: observation }]
          risk_result = RiskValidator.validate({ symbol: symbol, action: "HOLD" }, equity: @exchange.equity)
          
          trace = @logger.log_trace(
            decision_summary: "Market data retrieval failed",
            tool_calls: tool_calls,
            tool_observations: tool_observations,
            risk_checks: risk_result[:risk_checks],
            final_intent: { symbol: symbol, action: "HOLD", entry_price: 0.0, stop_loss: 0.0, take_profit: 0.0 }
          )

          return format_contract_response(symbol, timeframe, "HOLD", 0.0, 0.0, 0.0, 0.0, 0.0, ["stale_or_incomplete_data"], trace)
        end

        # 2. Compute Indicators (Deterministic Calculation in Ruby)
        rsi = IndicatorCalculator.calculate_rsi(candles).last
        ema20 = IndicatorCalculator.calculate_ema(candles, 20).last
        ema50 = IndicatorCalculator.calculate_ema(candles, 50).last
        macd_data = IndicatorCalculator.calculate_macd(candles)
        macd = macd_data[:macd].last
        macd_signal = macd_data[:signal].last
        atr = IndicatorCalculator.calculate_atr(candles).last
        bb = IndicatorCalculator.calculate_bollinger_bands(candles)
        bb_upper = bb[:upper].last
        bb_lower = bb[:lower].last
        bb_basis = bb[:basis].last
        vol_trend = IndicatorCalculator.calculate_volume_trend(candles)

        current_price = ticker_data["price"].to_f

        # Create summarized observation for LLM
        obs_summary = "Price: #{current_price}, RSI: #{rsi&.round(2)}, " \
                      "EMA20: #{ema20&.round(2)}, EMA50: #{ema50&.round(2)}, " \
                      "MACD: #{macd&.round(4)}/Signal: #{macd_signal&.round(4)}, " \
                      "ATR: #{atr&.round(4)}, Bollinger Bands: Upper=#{bb_upper&.round(2)}/Basis=#{bb_basis&.round(2)}/Lower=#{bb_lower&.round(2)}, " \
                      "Volume Trend: #{vol_trend[:trend]} (ratio: #{vol_trend[:ratio]})"

        tool_observations = [
          { name: "get_ticker", summary: "Current price: #{current_price}" },
          { name: "get_klines", summary: "Fetched #{candles.size} candles. Indicators: #{obs_summary}" },
          { name: "get_order_book", summary: "Spread: #{(book[:asks][0][0] - book[:bids][0][0]).round(4)}, Depth Bids: #{book[:bids].size}, Asks: #{book[:asks].size}" },
          { name: "get_stats_24hr", summary: "24h Price Change: #{stats['priceChangePercent']}%" }
        ]

        # 3. Model Analysis Prompt & Fallback Routing
        system_prompt = <<~PROMPT
          You are an institutional crypto futures trading manager.
          Analyze the clean indicators provided to you. Do NOT calculate any indicators or values yourself.
          You must output a single JSON block representing your trading intent.
          
          Universe rules: Only output for symbol: #{symbol}.
          Action rules: Must be BUY, SELL, or HOLD.
          R:R rules: Set stop loss and take profit such that the Reward-to-Risk ratio is at least 1.5.
          
          Response JSON format (MUST match this exactly):
          {
            "action": "BUY" | "SELL" | "HOLD",
            "confidence": 0.0 to 1.0,
            "entry_price": <suggested entry price, typically close to current price>,
            "stop_loss": <suggested stop loss price>,
            "take_profit": <suggested take profit price>,
            "risk_percent": <percent of equity to risk, e.g. 1.0>,
            "reason_codes": ["code1", "code2"]
          }
        PROMPT

        user_prompt = <<~PROMPT
          Indicators and Market Context for #{symbol}:
          - Current Price: #{current_price}
          - RSI (14): #{rsi}
          - EMA (20): #{ema20}
          - EMA (50): #{ema50}
          - MACD Line: #{macd}, Signal Line: #{macd_signal}
          - ATR (14): #{atr}
          - Bollinger Bands (20, 2): Upper=#{bb_upper}, Basis=#{bb_basis}, Lower=#{bb_lower}
          - Volume Trend: #{vol_trend[:trend]}
          - 24h Stats: High=#{stats['highPrice']}, Low=#{stats['lowPrice']}, Change=#{stats['priceChangePercent']}%
        PROMPT

        messages = [
          { role: "system", content: system_prompt },
          { role: "user", content: user_prompt }
        ]

        # Call Router
        router_resp = @router.chat(messages, format: "json")
        llm_intent = JSON.parse(router_resp[:content]) rescue nil

        # If LLM failed to return valid JSON, force HOLD
        if llm_intent.nil?
          llm_intent = {
            "action" => "HOLD",
            "confidence" => 0.0,
            "entry_price" => current_price,
            "stop_loss" => 0.0,
            "take_profit" => 0.0,
            "risk_percent" => 0.0,
            "reason_codes" => ["llm_json_failed"]
          }
        end

        # Map to symbols
        llm_intent["symbol"] = symbol
        # Inject candles for staleness/completeness check
        llm_intent[:candles] = candles

        # 4. Pure Ruby Risk Validation
        risk_result = RiskValidator.validate(llm_intent, equity: @exchange.equity)

        decision_summary = "Model recommended #{llm_intent['action']} with confidence #{llm_intent['confidence']}. Reason: #{llm_intent['reason_codes']&.join(', ')}."
        
        final_action = risk_result[:action]
        entry_price = llm_intent["entry_price"].to_f
        stop_loss = llm_intent["stop_loss"].to_f
        take_profit = llm_intent["take_profit"].to_f
        risk_percent = llm_intent["risk_percent"].to_f
        confidence = llm_intent["confidence"].to_f
        reason_codes = llm_intent["reason_codes"] || []

        # If risk check fails or action becomes HOLD, zero out pricing parameters to avoid downstream execution bugs
        if final_action == "HOLD"
          entry_price = 0.0
          stop_loss = 0.0
          take_profit = 0.0
          risk_percent = 0.0
        end

        # 5. Paper Execution (If approved)
        position_size = 0.0
        if risk_result[:approved] && %w[BUY SELL].include?(final_action)
          trade_params = {
            symbol: symbol,
            action: final_action,
            entry_price: entry_price,
            stop_loss: stop_loss,
            take_profit: take_profit,
            risk_percent: risk_percent
          }
          exec_res = @exchange.execute_order(trade_params)
          if exec_res[:success]
            position_size = exec_res[:position][:quantity]
          else
            final_action = "HOLD"
            risk_result[:approved] = false
            risk_result[:risk_checks][:approved] = false
            decision_summary += " | Execution failed: #{exec_res[:error]}"
          end
        end

        trace = @logger.log_trace(
          decision_summary: decision_summary,
          tool_calls: tool_calls,
          tool_observations: tool_observations,
          risk_checks: risk_result[:risk_checks],
          final_intent: {
            symbol: symbol,
            action: final_action,
            entry_price: entry_price,
            stop_loss: stop_loss,
            take_profit: take_profit
          }
        )

        format_contract_response(
          symbol, timeframe, final_action, confidence, entry_price, stop_loss,
          take_profit, risk_percent, position_size, reason_codes, trace
        )
      end

      private

      def format_contract_response(symbol, timeframe, action, confidence, entry_price, stop_loss, take_profit, risk_percent, position_size, reason_codes, trace)
        {
          symbol: symbol,
          action: action,
          timeframe: timeframe,
          confidence: confidence,
          entry_type: "market",
          entry_price: entry_price,
          stop_loss: stop_loss,
          take_profit: take_profit,
          risk_percent: risk_percent,
          position_size: position_size,
          reason_codes: reason_codes,
          tool_calls: trace[:tool_calls],
          tool_observations: trace[:tool_observations],
          risk_checks: trace[:risk_checks]
        }
      end
    end
  end
end
