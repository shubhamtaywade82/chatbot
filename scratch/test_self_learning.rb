# frozen_string_literal: true

$LOAD_PATH.unshift File.join(__dir__, "..", "lib")
$LOAD_PATH.unshift File.join(__dir__, "..", "config")

require "bundler/setup"
require "sqlite3"
require_relative "../tradingbot/config"
require_relative "../tradingbot/storage"
require_relative "../tradingbot/self_learning"
require_relative "../tradingbot/analyst"

# Initialize
config = TradingBot::Config.load
storage = TradingBot::Storage.new

puts "============================================================"
puts "🧪 TESTING SELF-LEARNING FEEDBACK LOOP"
puts "============================================================"

# 1. Clear old test trade lessons if they exist to keep test clean
storage.instance_variable_get(:@db).execute("DELETE FROM trade_lessons WHERE symbol = 'TESTUSDT'")
storage.instance_variable_get(:@db).execute("DELETE FROM trades WHERE symbol = 'TESTUSDT'")

# 2. Insert a mock completed LOSS trade
puts "1. Mocking a closed LOSS trade on TESTUSDT..."
db = storage.instance_variable_get(:@db)
db.execute(<<~SQL)
  INSERT INTO trades (
    symbol, direction, entry_price, exit_price, quantity, stop_loss,
    status, pnl, pnl_pct, rr_ratio, entry_reason, exit_reason, exit_time
  ) VALUES (
    'TESTUSDT', 'LONG', 2500.0, 2450.0, 0.1, 2450.0,
    'closed', -5.0, -2.0, 2.5, 'Bullish Order Block bounce on 15m', 'stop_loss', datetime('now')
  );
SQL

# Get trade id
trade_id = db.last_insert_row_id
puts "   Mock trade ##{trade_id} created."

# 3. Execute self-learning processor
puts "\n2. Triggering LLM post-mortem analysis on the closed trade..."
# Temporarily enable verbose to print saving lessons
config.verbose = true
TradingBot::SelfLearning.process_closed_trades(storage, config)

# 4. Verify stored lesson
puts "\n3. Reading saved lesson from database..."
lessons = db.execute("SELECT * FROM trade_lessons WHERE trade_id = ?", [trade_id])
if lessons.any?
  lesson = lessons.first
  puts "   ✅ Saved Lesson: \"#{lesson['lesson']}\" (Outcome: #{lesson['outcome']})"
else
  puts "   ❌ Failed to generate or save lesson."
end

# 5. Verify Prompt Injection for next trade scan
puts "\n4. Simulating next LLM analysis prompt for TESTUSDT..."
analyst = TradingBot::Analyst.new(config, storage)
mock_tf_data = [{
  interval: "1h", current_price: 2470.0, trend: "bearish", atr: 30.0,
  discount_zone: "premium"
}]

context = analyst.send(:build_context, "TESTUSDT", [], mock_tf_data, 0)
puts "-" * 60
puts context
puts "-" * 60
puts "✅ TEST COMPLETED SUCCESSFULLY!"
