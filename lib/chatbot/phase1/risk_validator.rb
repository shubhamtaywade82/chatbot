# frozen_string_literal: true

module Chatbot
  module Phase1
    class RiskValidator
      DEFAULT_MAX_RISK_PCT = 2.0 # 2% of equity
      STALENESS_THRESHOLD_SEC = 300 # 5 minutes

      # Validates a trade intent against deterministic risk rules.
      # Returns a Hash indicating approval, validation details, and risk checks status.
      #
      # @param intent [Hash] the trade intent from model/tool loop
      # @param equity [Float] the current equity/balance
      # @param max_risk_pct [Float] max risk percentage of equity per trade
      # @param current_time [Time] optional time anchor to verify staleness
      def self.validate(intent, equity:, max_risk_pct: DEFAULT_MAX_RISK_PCT, current_time: Time.now)
        symbol = intent[:symbol] || intent["symbol"]
        action = intent[:action] || intent["action"]
        entry = (intent[:entry_price] || intent["entry_price"]).to_f
        sl = (intent[:stop_loss] || intent["stop_loss"]).to_f
        tp = (intent[:take_profit] || intent["take_profit"]).to_f
        risk_pct = (intent[:risk_percent] || intent["risk_percent"] || max_risk_pct).to_f
        
        # Hard check for allowed symbol universe
        allowed_symbols = %w[ETHUSDT SOLUSDT XRPUSDT]
        unless allowed_symbols.include?(symbol&.upcase)
          return rejected_checks(schema_valid: false, reason: "Symbol not in allowed universe: #{symbol}")
        end

        unless %w[BUY SELL].include?(action&.upcase)
          return {
            approved: false,
            action: "HOLD",
            reason: "Invalid action or no trade signal",
            risk_checks: { schema_valid: true, rr_valid: false, stop_valid: false, risk_within_limit: false, approved: false }
          }
        end

        # Market data completeness and staleness checks
        candles = intent[:candles] || intent["candles"]
        if candles.nil? || candles.empty?
          return rejected_checks(schema_valid: true, reason: "Market data incomplete: no candles provided")
        end

        last_candle_time = candles.last[:close_time] || candles.last[:time]
        if last_candle_time.nil? || (current_time.to_i - last_candle_time.to_i).abs > STALENESS_THRESHOLD_SEC
          return rejected_checks(schema_valid: true, reason: "Market data is stale or incomplete")
        end

        # Core logic rules
        is_long = action.upcase == "BUY"
        stop_valid = false
        rr_valid = false

        if is_long
          stop_valid = sl < entry && tp > entry
          risk_amt = entry - sl
          reward_amt = tp - entry
        else
          stop_valid = sl > entry && tp < entry
          risk_amt = sl - entry
          reward_amt = entry - tp
        end

        if stop_valid && risk_amt > 0
          rr = reward_amt / risk_amt
          rr_valid = rr >= 1.5
        end

        # Risk amount verification
        # position_size = (equity * (risk_pct / 100.0)) / risk_amt
        # Total risk at stop loss = position_size * risk_amt = equity * (risk_pct / 100.0)
        # So we check if the requested risk percent is within the limits, and entry/sl exists
        risk_within_limit = risk_pct <= max_risk_pct && risk_pct > 0

        approved = stop_valid && rr_valid && risk_within_limit

        {
          approved: approved,
          action: approved ? action.upcase : "HOLD",
          reason: approved ? "Risk checks passed" : "Risk check failed: stop_valid=#{stop_valid}, rr_valid=#{rr_valid}, risk_within_limit=#{risk_within_limit}",
          risk_checks: {
            schema_valid: true,
            rr_valid: rr_valid,
            stop_valid: stop_valid,
            risk_within_limit: risk_within_limit,
            approved: approved
          }
        }
      end

      private

      def self.rejected_checks(schema_valid:, reason:)
        {
          approved: false,
          action: "HOLD",
          reason: reason,
          risk_checks: {
            schema_valid: schema_valid,
            rr_valid: false,
            stop_valid: false,
            risk_within_limit: false,
            approved: false
          }
        }
      end
    end
  end
end
