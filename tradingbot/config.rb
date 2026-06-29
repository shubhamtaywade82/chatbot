require "yaml"
require "ostruct"
require "optparse"

module TradingBot
  Config = Struct.new(
    :symbols, :poll_interval_sec, :timeframes, :candle_limit,
    :model, :base_url, :min_analysis_interval_sec, :max_setups_per_symbol,
    :mode, :max_risk_per_trade_pct, :max_open_trades, :default_leverage, :min_rr_ratio,
    :start_date, :end_date, :initial_balance, :maker_fee, :taker_fee, :slippage_pct,
    :log_level, :verbose,
    :binance_api_key, :binance_api_secret,
    :coindcx_api_key, :coindcx_api_secret,
    :telegram_enabled, :telegram_bot_token, :telegram_chat_id,
    keyword_init: true
  ) do
    def self.load(path = nil)
      dotenv_path = File.join(__dir__, "..", ".env")
      if File.exist?(dotenv_path)
        File.readlines(dotenv_path).each do |line|
          next if line.strip.empty? || line.start_with?("#")
          key, val = line.split("=", 2)
          next unless key && val
          ENV[key.strip] = val.strip.gsub(/\A['"]|['"]\z/, "")
        end
      end

      path ||= File.join(__dir__, "config.yml")
      raw = YAML.safe_load(File.read(path), permitted_classes: [Symbol])
      new(
        symbols: raw.dig("symbols") || [],
        poll_interval_sec: raw.dig("monitor", "poll_interval_sec") || 60,
        timeframes: raw.dig("monitor", "timeframes") || %w[15m 1h 4h],
        candle_limit: raw.dig("monitor", "candle_limit") || 200,
        model: raw.dig("analysis", "model") || "qwen3.5:4b",
        base_url: raw.dig("analysis", "base_url") || "http://localhost:11434",
        min_analysis_interval_sec: raw.dig("analysis", "min_analysis_interval_sec") || 120,
        max_setups_per_symbol: raw.dig("analysis", "max_setups_per_symbol") || 1,
        mode: raw.dig("execution", "mode") || "paper",
        max_risk_per_trade_pct: raw.dig("execution", "max_risk_per_trade_pct") || 2.0,
        max_open_trades: raw.dig("execution", "max_open_trades") || 3,
        default_leverage: raw.dig("execution", "default_leverage") || 3,
        min_rr_ratio: raw.dig("execution", "min_rr_ratio") || 2.0,
        start_date: raw.dig("backtest", "start_date") || "2025-06-01",
        end_date: raw.dig("backtest", "end_date") || "2025-12-31",
        initial_balance: raw.dig("backtest", "initial_balance") || 1000.0,
        maker_fee: raw.dig("backtest", "maker_fee") || 0.0002,
        taker_fee: raw.dig("backtest", "taker_fee") || 0.0004,
        slippage_pct: raw.dig("backtest", "slippage_pct") || 0.05,
        log_level: raw.dig("logging", "level") || "info",
        verbose: raw.dig("logging", "verbose") || false,
        binance_api_key: ENV["CHAT_BINANCE_API_KEY"],
        binance_api_secret: ENV["CHAT_BINANCE_API_SECRET"],
        coindcx_api_key: ENV["CHAT_COINDCX_API_KEY"],
        coindcx_api_secret: ENV["CHAT_COINDCX_API_SECRET"],
        telegram_enabled: raw.dig("telegram", "enabled") || false,
        telegram_bot_token: raw.dig("telegram", "bot_token"),
        telegram_chat_id: raw.dig("telegram", "chat_id")
      )
    end

    def live?
      mode == "live"
    end

    def paper?
      !live?
    end

    def verbose?
      verbose
    end
  end
end
