# frozen_string_literal: true

require "bundler/setup"
require "json"
require "sqlite3"
require_relative "../tradingbot/config"
require_relative "../tradingbot/analyst"

config_path = File.join(__dir__, "..", "tradingbot", "config.yml")
bot_config = TradingBot::Config.load(config_path)

db = SQLite3::Database.new("tradingbot/trading_bot.db")
db.results_as_hash = true

row = db.get_first_row("SELECT * FROM llm_responses ORDER BY created_at DESC LIMIT 1")
puts "Created At: #{row['created_at']}"
puts "Symbol: #{row['symbol']}"
puts "Parsed Action: #{row['parsed_action']}"
puts "Response: #{row['response']}"
puts "Prompt: #{row['prompt']}"
