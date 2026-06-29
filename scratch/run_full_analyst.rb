# frozen_string_literal: true

require "bundler/setup"
require "json"
require_relative "../tradingbot/config"
require_relative "../tradingbot/engine"
require_relative "../tradingbot/analyst"

config_path = File.join(__dir__, "..", "tradingbot", "config.yml")
bot_config = TradingBot::Config.load(config_path)
bot_config.verbose = true

engine = TradingBot::Engine.new(bot_config)
multi_tf = engine.send(:multi_tf_analysis, "ETHUSDT")

analyst = TradingBot::Analyst.new(bot_config)

# Temporarily override options in the analyst client call to test num_predict: 1024
puts "Running analyst.analyze with num_predict: 1024..."
start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
client = analyst.instance_variable_get(:@client)
market_context = analyst.send(:build_context, "ETHUSDT", [{ event_type: :liquidity_sweep, timeframe: "1h", price: 1573.92, description: "BS sweep of $1582.29" }], multi_tf, 0)

response = client.chat(
  model: bot_config.model,
  messages: [
    { role: "system", content: TradingBot::Analyst::SYSTEM_PROMPT },
    { role: "user", content: market_context }
  ],
  options: { temperature: 0.2, num_predict: 1024 }
)
duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).to_i

puts "================== RESULT =================="
response_text = response.respond_to?(:message) ? response.message.content : response.to_s
parsed = analyst.send(:parse_response, response_text, [{ event_type: :liquidity_sweep, timeframe: "1h", price: 1573.92, description: "BS sweep of $1582.29" }])

puts "Parsed Action: #{parsed[:action]}"
puts "Parsed Reason: #{parsed[:reason]}"
puts "Raw Response: '#{response_text}'"
puts "Duration: #{duration_ms}ms"

# Inspect the raw message data to see the thinking process
data = response.message.instance_variable_get(:@data)
puts "Thinking Process length: #{data["thinking"]&.length || 0} chars"
puts "Thinking Process preview: #{data["thinking"]&.slice(0, 200)}..."
