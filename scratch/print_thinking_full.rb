# frozen_string_literal: true

require "bundler/setup"
require "json"
require_relative "../tradingbot/config"
require_relative "../tradingbot/engine"
require_relative "../tradingbot/analyst"

config_path = File.join(__dir__, "..", "tradingbot", "config.yml")
bot_config = TradingBot::Config.load(config_path)

engine = TradingBot::Engine.new(bot_config)
multi_tf = engine.send(:multi_tf_analysis, "ETHUSDT")

analyst = TradingBot::Analyst.new(bot_config)
client = analyst.instance_variable_get(:@client)
market_context = analyst.send(:build_context, "ETHUSDT", [{ event_type: :liquidity_sweep, timeframe: "1h", price: 1573.92, description: "BS sweep of $1582.29" }], multi_tf, 0)

puts "Sending request with think: false..."
response = client.chat(
  model: bot_config.model,
  messages: [
    { role: "system", content: TradingBot::Analyst::SYSTEM_PROMPT },
    { role: "user", content: market_context }
  ],
  think: false,
  options: { temperature: 0.2, num_predict: 256 }
)

data = response.message.instance_variable_get(:@data)
puts "================== THINKING PROCESS =================="
puts data["thinking"].inspect
puts "================== CONTENT =================="
puts response.message.content
puts "============================================="
