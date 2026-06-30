# frozen_string_literal: true

$LOAD_PATH.unshift File.join(__dir__, "..", "lib")
$LOAD_PATH.unshift File.join(__dir__, "..", "config")

require "bundler/setup"
require "json"
require "net/http"
require_relative "../tradingbot/config"
require_relative "../tradingbot/storage"
require_relative "../tradingbot/analyst"
require_relative "../tradingbot/scanner"
require_relative "../tradingbot/self_learning"

# Initialize
config = TradingBot::Config.load
storage = TradingBot::Storage.new
analyst = TradingBot::Analyst.new(config, storage)
scanner = TradingBot::Scanner.new(storage, config)

puts "============================================================"
puts "🌍 RUNNING LIVE REAL-DATA LLM ANALYSIS WITH SELF-LEARNING"
puts "============================================================"

# Process closed trades database backlog first to make sure lessons are loaded
puts "Processing any outstanding trade post-mortems..."
TradingBot::SelfLearning.process_closed_trades(storage, config)

config.symbols.each do |symbol|
  puts "\n" + "=" * 50
  puts "📊 Symbol: #{symbol}"
  puts "=" * 50

  puts "1. Fetching live multi-timeframe candles..."
  # Fetch data for scanner
  events = scanner.scan(symbol)
  
  # Fetch multi timeframe data
  multi_tf_data = []
  config.timeframes.each do |tf|
    # Fetch candles from Binance klines API
    url = "https://api.binance.com/api/v3/klines?symbol=#{symbol}&interval=#{tf}&limit=100"
    resp = Net::HTTP.get_response(URI(url))
    next unless resp.is_a?(Net::HTTPOK)
    
    batch = JSON.parse(resp.body)
    candles = batch.map do |k|
      { open: k[1].to_f, high: k[2].to_f, low: k[3].to_f, close: k[4].to_f, volume: k[5].to_f }
    end
    
    # Analyze structures
    pivots = PivotDetector.detect(candles, left_bars: 4, right_bars: 4)
    ms = MarketStructure.analyze(candles, pivots[:highs], pivots[:lows])
    atr_val = ATR.compute(candles)
    displacements = Displacement.detect(candles, atr_val)
    obs = OrderBlock.detect(candles, ms[:bos_events], displacements)
    
    eq = LiquiditySweep.find_equal_highs_lows(pivots[:highs], pivots[:lows])
    sweeps = LiquiditySweep.detect_sweeps(candles, pivots[:highs], pivots[:lows],
                                           equal_highs: eq[:equal_highs],
                                           equal_lows: eq[:equal_lows])

    recent_50 = candles.last(50)
    range_high = recent_50.map { |c| c[:high] }.max
    range_low  = recent_50.map { |c| c[:low] }.min
    pd = PDArray.compute(range_high, range_low)
    current_price = candles.last[:close]
    in_discount = PDArray.discount?(current_price, pd)

    # Format active OB descriptions
    ob_desc = obs.select { |ob| !ob[:invalidated] }.map do |ob|
      "#{ob[:direction].to_s.upcase} OB zone $#{ob[:zone].min.round(2)}-$#{ob[:zone].max.round(2)}"
    end

    # Format sweep descriptions
    sweep_desc = sweeps.last(3).map do |s|
      "[#{s[:type]}] swept $#{s[:swept_level].round(2)}"
    end

    multi_tf_data << {
      interval: tf,
      current_price: current_price,
      trend: ms[:trend],
      atr: atr_val.round(4),
      protected_high: ms[:protected_high],
      protected_low: ms[:protected_low],
      last_swing_high: ms[:last_swing_high],
      last_swing_low: ms[:last_swing_low],
      bos_events: ms[:bos_events].last(2).map { |e| e[:type] },
      order_blocks: ob_desc.last(3),
      sweeps: sweep_desc,
      discount_zone: in_discount ? "discount" : "premium",
      pd_range: pd
    }
  end

  puts "2. Running LLM Analyst decision (Self-Learning enabled)..."
  result = analyst.analyze(
    symbol: symbol,
    events: events,
    multi_tf_data: multi_tf_data,
    open_trades_count: 0
  )

  puts "\n--- Stored Lessons retrieved for #{symbol} ---"
  lessons = storage.recent_lessons(symbol: symbol, limit: 3)
  if lessons.any?
    lessons.each { |l| puts "  - [#{l['outcome']}] #{l['lesson']}" }
  else
    puts "  No lessons recorded yet."
  end

  puts "\n--- Trade Decision Result ---"
  puts JSON.pretty_generate(result.reject { |k| k == :prompt || k == :raw_response })
end
