# frozen_string_literal: true

$LOAD_PATH.unshift File.join(__dir__, "..", "lib")
$LOAD_PATH.unshift File.join(__dir__, "..", "config")

require "bundler/setup"
require "json"
require "net/http"
require "openssl"
require "time"
require_relative "../tradingbot/config"
require_relative "../tradingbot/storage"
require_relative "../lib/chatbot/smc_engines"

module TradingBot
  class SimulatorCached
    # Runs the backtest simulation using pre-computed SMC indicator slices
    def self.run_simulation(cached_indicators, trial_params, config)
      all_trades = []
      balance = config.initial_balance
      peak_balance = balance

      # Parameters
      sl_mult = trial_params[:sl_mult]
      tp_mult = trial_params[:tp_mult]
      max_hold = trial_params[:max_hold]

      cached_indicators.each do |symbol, steps|
        position = nil

        steps.each_with_index do |step, i|
          current_price = step[:close]

          if position.nil?
            setup = detect_setup(step, sl_mult, tp_mult, config)
            next unless setup

            sl_pct = ((current_price - setup[:stop_loss]).abs / current_price * 100)
            next if sl_pct > config.max_risk_per_trade_pct

            position = {
              symbol: symbol, direction: setup[:direction],
              entry_price: current_price, stop_loss: setup[:stop_loss],
              take_profit: setup[:take_profit], quantity: setup[:quantity],
              entry_index: i, rr: setup[:rr]
            }
          else
            tp = position[:take_profit]
            sl = position[:stop_loss]
            if position[:direction] == "LONG"
              if current_price >= tp
                pnl = (tp - position[:entry_price]) * position[:quantity]
                pnl -= (pnl.abs * config.taker_fee) + (position[:entry_price] * position[:quantity] * config.taker_fee)
                position[:pnl] = pnl.round(2)
                all_trades << position
                position = nil
              elsif current_price <= sl
                pnl = (sl - position[:entry_price]) * position[:quantity]
                pnl -= (pnl.abs * config.taker_fee) + (position[:entry_price] * position[:quantity] * config.taker_fee)
                position[:pnl] = pnl.round(2)
                all_trades << position
                position = nil
              end
            else
              if current_price <= tp
                pnl = (position[:entry_price] - tp) * position[:quantity]
                pnl -= (pnl.abs * config.taker_fee) + (position[:entry_price] * position[:quantity] * config.taker_fee)
                position[:pnl] = pnl.round(2)
                all_trades << position
                position = nil
              elsif current_price >= sl
                pnl = (position[:entry_price] - sl) * position[:quantity]
                pnl -= (pnl.abs * config.taker_fee) + (position[:entry_price] * position[:quantity] * config.taker_fee)
                position[:pnl] = pnl.round(2)
                all_trades << position
                position = nil
              end
            end
          end

          if position && (i - position[:entry_index]) >= max_hold
            exit_price = current_price
            pnl = position[:direction] == "LONG" ?
              (exit_price - position[:entry_price]) * position[:quantity] :
              (position[:entry_price] - exit_price) * position[:quantity]
            pnl -= (pnl.abs * config.taker_fee) + (position[:entry_price] * position[:quantity] * config.taker_fee)
            position[:pnl] = pnl.round(2)
            all_trades << position
            position = nil
          end
        end
      end

      compute_metrics(all_trades, config.initial_balance)
    end

    def self.detect_setup(step, sl_mult, tp_mult, config)
      ms = step[:ms]
      atr = step[:atr]
      obs = step[:obs]
      sweeps = step[:sweeps]
      pd = step[:pd]
      price = step[:close]
      in_discount = step[:in_discount]

      active_obs = obs.select { |ob| !ob[:invalidated] }
      recent_sweeps = sweeps.select { |s| s[:sweep_index] >= step[:candle_count] - 10 }
      recent_bos = ms[:bos_events].select { |e| e[:index] >= step[:candle_count] - 10 }
      recent_choch = ms[:choch_events].select { |e| e[:index] >= step[:candle_count] - 20 }

      candidates = []

      # Strategy 1: BOS Retest (Trend Aligned)
      recent_bos.each do |bos|
        is_bullish = bos[:type].to_s.include?("bullish")
        is_bearish = bos[:type].to_s.include?("bearish")
        next unless is_bullish || is_bearish
        next if is_bullish && ms[:trend] != :bullish
        next if is_bearish && ms[:trend] != :bearish

        if is_bullish
          direction = "LONG"
          sl = [price - atr * sl_mult, ms[:protected_low] || price - atr * (sl_mult + 1)].min
          tp = price + (price - sl) * tp_mult
        else
          direction = "SHORT"
          sl = [price + atr * sl_mult, ms[:protected_high] || price + atr * (sl_mult + 1)].max
          tp = price - (sl - price) * tp_mult
        end

        rr = ((tp - price).abs / (price - sl).abs).round(2)
        next if rr < config.min_rr_ratio

        candidates << { direction: direction, stop_loss: sl, take_profit: tp,
                       quantity: calc_quantity(price, sl, config), rr: rr }
      end

      # Strategy 2: CHoCH Reversal
      recent_choch.each do |choch|
        is_bullish = choch[:choch_type].to_s.include?("bullish")
        is_bearish = choch[:choch_type].to_s.include?("bearish")
        next unless is_bullish || is_bearish

        if is_bullish
          direction = "LONG"
          sl = [price - atr * sl_mult, ms[:protected_low] || price - atr * (sl_mult + 1)].min
          tp = price + (price - sl) * tp_mult
        else
          direction = "SHORT"
          sl = [price + atr * sl_mult, ms[:protected_high] || price + atr * (sl_mult + 1)].max
          tp = price - (sl - price) * tp_mult
        end

        rr = ((tp - price).abs / (price - sl).abs).round(2)
        next if rr < config.min_rr_ratio

        candidates << { direction: direction, stop_loss: sl, take_profit: tp,
                       quantity: calc_quantity(price, sl, config), rr: rr }
      end

      # Strategy 3: Sweep + Trend
      recent_sweeps.each do |sweep|
        is_ssl = sweep[:type].to_s.include?("SSL") || sweep[:type].to_s.include?("sell")
        is_bsl = sweep[:type].to_s.include?("BSL") || sweep[:type].to_s.include?("buy")

        if is_ssl && (ms[:trend] != :bearish || in_discount)
          direction = "LONG"
          sl = [price - atr * (sl_mult * 0.75), ms[:protected_low] || price - atr * sl_mult].min
          tp = price + (price - sl) * tp_mult
        elsif is_bsl && (ms[:trend] != :bullish || !in_discount)
          direction = "SHORT"
          sl = [price + atr * (sl_mult * 0.75), ms[:protected_high] || price + atr * sl_mult].max
          tp = price - (sl - price) * tp_mult
        else
          next
        end

        rr = ((tp - price).abs / (price - sl).abs).round(2)
        next if rr < config.min_rr_ratio

        candidates << { direction: direction, stop_loss: sl, take_profit: tp,
                       quantity: calc_quantity(price, sl, config), rr: rr }
      end

      # Strategy 4: OB Bounce (Trend Aligned)
      active_obs.each do |ob|
        zone_min, zone_max = ob[:zone].minmax
        proximity = ((price - zone_min).abs / (zone_max - zone_min + 0.01))
        next unless proximity < 0.3
        next if ob[:direction] == :bullish && ms[:trend] != :bullish
        next if ob[:direction] == :bearish && ms[:trend] != :bearish

        if ob[:direction] == :bullish
          direction = "LONG"
          sl = [zone_min - atr * 0.5, ms[:protected_low] || zone_min - atr].min
          tp = price + (price - sl) * tp_mult
        elsif ob[:direction] == :bearish
          direction = "SHORT"
          sl = [zone_max + atr * 0.5, ms[:protected_high] || zone_max + atr].max
          tp = price - (sl - price) * tp_mult
        else
          next
        end

        rr = ((tp - price).abs / (price - sl).abs).round(2)
        next if rr < config.min_rr_ratio

        candidates << { direction: direction, stop_loss: sl, take_profit: tp,
                       quantity: calc_quantity(price, sl, config), rr: rr }
      end

      candidates.max_by { |c| c[:rr] }
    end

    def self.calc_quantity(price, sl, config)
      risk_per_trade = config.initial_balance * (config.max_risk_per_trade_pct / 100.0)
      risk_per_unit = (price - sl).abs
      return 0.01 if risk_per_unit <= 0
      [[(risk_per_trade / risk_per_unit).round(4), 0.01].max, 1000].min
    end

    def self.compute_metrics(trades, initial_balance)
      return { total_trades: 0, win_rate: 0, profit_factor: 0, total_pnl: 0 } if trades.empty?

      total_pnl = trades.sum { |t| t[:pnl] }
      wins = trades.select { |t| t[:pnl] > 0 }
      losses = trades.select { |t| t[:pnl] <= 0 }
      win_rate = (wins.size.to_f / trades.size * 100).round(2)

      gross_profit = wins.sum { |t| t[:pnl] }
      gross_loss = losses.sum { |t| t[:pnl].abs }
      profit_factor = gross_loss > 0 ? (gross_profit / gross_loss).round(2) : gross_profit > 0 ? 99.99 : 0

      { total_trades: trades.size, win_rate: win_rate, profit_factor: profit_factor, total_pnl: total_pnl.round(2) }
    end
  end

  def self.fetch_historical(symbol, interval, start_date, end_date)
    all_candles = []
    start_ts = Time.parse(start_date).to_i * 1000
    end_ts = Time.parse(end_date).to_i * 1000
    limit = 1000

    current_start = start_ts
    while current_start < end_ts
      url = "https://api.binance.com/api/v3/klines?symbol=#{symbol}&interval=#{interval}&limit=#{limit}&startTime=#{current_start.to_i}"
      resp = Net::HTTP.get_response(URI(url))
      break unless resp.is_a?(Net::HTTPOK)

      batch = JSON.parse(resp.body)
      break if batch.empty?

      candles = batch.map do |k|
        { time: k[0] / 1000, open: k[1].to_f, high: k[2].to_f,
          low: k[3].to_f, close: k[4].to_f, volume: k[5].to_f }
      end
      all_candles.concat(candles)

      last_time = batch.last[0]
      break if last_time >= end_ts
      current_start = last_time + 1
    end

    all_candles
  end
end

# Executing grid search
config = TradingBot::Config.load
symbols = config.symbols
start_date = config.start_date
end_date = config.end_date

puts "Caching historical candles for #{symbols.join(', ')}..."
candles_hash = {}
symbols.each do |symbol|
  candles_hash[symbol] = TradingBot.fetch_historical(symbol, "1h", start_date, end_date)
  puts "Cached #{candles_hash[symbol].size} candles for #{symbol}"
end

puts "\nPre-calculating technical indicators (SMC structures)..."
cached_indicators = {}
symbols.each do |symbol|
  candles = candles_hash[symbol]
  cached_indicators[symbol] = []
  lookback = 100

  (lookback...candles.size).each do |i|
    slice_1h = candles[(i - lookback + 1)..i]
    pivots = PivotDetector.detect(slice_1h, left_bars: 4, right_bars: 4)
    ms = MarketStructure.analyze(slice_1h, pivots[:highs], pivots[:lows])
    atr_val = ATR.compute(slice_1h)
    displacements = Displacement.detect(slice_1h, atr_val)
    obs = OrderBlock.detect(slice_1h, ms[:bos_events], displacements)

    eq = LiquiditySweep.find_equal_highs_lows(pivots[:highs], pivots[:lows])
    sweeps = LiquiditySweep.detect_sweeps(slice_1h, pivots[:highs], pivots[:lows],
                                           equal_highs: eq[:equal_highs],
                                           equal_lows: eq[:equal_lows])

    recent_50 = slice_1h.last(50)
    range_high = recent_50.map { |c| c[:high] }.max
    range_low  = recent_50.map { |c| c[:low] }.min
    pd = PDArray.compute(range_high, range_low)
    current_price = slice_1h.last[:close]
    in_discount = PDArray.discount?(current_price, pd)

    cached_indicators[symbol] << {
      close: current_price,
      candle_count: slice_1h.size,
      ms: ms,
      atr: atr_val,
      obs: obs,
      sweeps: sweeps,
      pd: pd,
      in_discount: in_discount
    }
  end
  puts "Finished pre-calculation for #{symbol}"
end

# Define parameters grid
sl_mult_grid = [1.0, 1.5, 2.0, 2.5]
tp_mult_grid = [2.0, 2.5, 3.0, 3.5]
max_hold_grid = [24, 48, 72]

results = []

puts "\nRunning Grid Search Optimization..."
sl_mult_grid.each do |sl|
  tp_mult_grid.each do |tp|
    max_hold_grid.each do |hold|
      params = { sl_mult: sl, tp_mult: tp, max_hold: hold }
      metrics = TradingBot::SimulatorCached.run_simulation(cached_indicators, params, config)
      results << { params: params, metrics: metrics }
    end
  end
end
puts "Done!"

# Find best configurations
best_pnl = results.max_by { |r| r[:metrics][:total_pnl] }
best_win_rate = results.select { |r| r[:metrics][:total_trades] >= 50 }.max_by { |r| r[:metrics][:win_rate] }
best_profit_factor = results.select { |r| r[:metrics][:total_trades] >= 50 }.max_by { |r| r[:metrics][:profit_factor] }

puts "\n" + "=" * 60
puts "OPTIMIZATION RESULTS"
puts "=" * 60
puts "🏆 BEST FOR MAXIMUM ROI/PnL:"
puts "Parameters: #{best_pnl[:params]}"
puts "Metrics: #{best_pnl[:metrics]}"
puts "ROI: #{(best_pnl[:metrics][:total_pnl] / config.initial_balance * 100).round(2)}%"

puts "\n🎯 BEST FOR WIN RATE (> 50 trades):"
puts "Parameters: #{best_win_rate[:params]}"
puts "Metrics: #{best_win_rate[:metrics]}"

puts "\n🛡️ BEST FOR PROFIT FACTOR (> 50 trades):"
puts "Parameters: #{best_profit_factor[:params]}"
puts "Metrics: #{best_profit_factor[:metrics]}"
puts "=" * 60
