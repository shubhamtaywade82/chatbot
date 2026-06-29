# frozen_string_literal: true

require "bundler/setup"
require "ollama_client"
require "json"
require_relative "../tradingbot/config"
require_relative "../tradingbot/engine"

config_path = File.join(__dir__, "..", "tradingbot", "config.yml")
bot_config = TradingBot::Config.load(config_path)

engine = TradingBot::Engine.new(bot_config)
multi_tf = engine.send(:multi_tf_analysis, "ETHUSDT")

# Build the system prompt
system_prompt = <<~PROMPT
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
PROMPT

# Build the market context
analyst_class = TradingBot::Analyst.new(bot_config)
market_context = analyst_class.send(:build_context, "ETHUSDT", [{ event_type: :liquidity_sweep, timeframe: "1h", price: 1573.92, description: "BS sweep of $1582.29" }], multi_tf, 0)

config = Ollama::Config.new
config.base_url = "http://localhost:11434"
config.timeout = 120

client = Ollama::Client.new(config: config)

puts "Sending direct chat request to Ollama..."
start_time = Time.now
begin
  resp = client.chat(
    model: "qwen3.5:4b",
    messages: [
      { role: "system", content: system_prompt },
      { role: "user", content: market_context }
    ],
    options: { temperature: 0.2 }
  )
  duration = Time.now - start_time
  puts "Completed in #{duration.round(2)}s"
  puts "Response class: #{resp.class}"
  if resp.respond_to?(:message)
    puts "Message: #{resp.message.content}"
  else
    puts "Resp keys/inspect: #{resp.inspect}"
  end
rescue => e
  puts "Failed with error: #{e.class} - #{e.message}"
  puts e.backtrace.join("\n")
end
