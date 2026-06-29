# frozen_string_literal: true

require_relative "../tradingbot/config"
require_relative "../tradingbot/storage"
require_relative "../tradingbot/scanner"
require_relative "../tradingbot/analyst"
require_relative "../tradingbot/engine"

config_path = File.join(__dir__, "..", "tradingbot", "config.yml")
config = TradingBot::Config.load(config_path)
config.verbose = true

engine = TradingBot::Engine.new(config)
analyst = TradingBot::Analyst.new(config)

puts "Fetching multi_tf_data..."
multi_tf = engine.send(:multi_tf_analysis, "ETHUSDT")

puts "Running analyst.analyze..."
res = analyst.analyze(
  symbol: "ETHUSDT",
  events: [{ event_type: :liquidity_sweep, timeframe: "1h", price: 1573.92, description: "BS sweep of $1582.29" }],
  multi_tf_data: multi_tf,
  open_trades_count: 0
)

puts "Analyst result action: #{res[:action]}"
puts "Analyst raw response: #{res[:raw_response]}"
