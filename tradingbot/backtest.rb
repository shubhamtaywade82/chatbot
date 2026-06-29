require "securerandom"
require "json"
require_relative "config"
require_relative "storage"
require_relative "../lib/chatbot/smc_engines"

module TradingBot
  module Backtest
    BINANCE_API = "https://api.binance.com"

    def self.run(config)
      bt_config = config.dup
      id = SecureRandom.uuid
      storage = Storage.new
      storage.create_backtest(id, config.to_h)

      puts "=" * 60
      puts "Backtest #{id[0..7]}"
      puts "Symbols: #{config.symbols.join(", ")}"
      puts "Period: #{config.start_date} → #{config.end_date}"
      puts "Initial Balance: $#{config.initial_balance}"
      puts "=" * 60

      all_trades = []
      total_pnl = 0.0
      peak_balance = config.initial_balance
      balance = config.initial_balance
      wins = 0
      losses = 0
      equity_curve = [balance]

      backtest_config = config.to_h

      config.symbols.each do |symbol|
        puts "\n--- Backtesting #{symbol} ---"
        candles_1h = fetch_historical(symbol, "1h", config.start_date, config.end_date)
        next unless candles_1h && candles_1h.size > 100

        candles_15m = fetch_historical(symbol, "15m", config.start_date, config.end_date)

        trades = run_symbol(symbol, candles_1h, candles_15m, config, storage, id)
        all_trades.concat(trades)

        trades.each do |t|
          balance += t[:pnl]
          peak_balance = balance if balance > peak_balance
        end
        equity_curve << balance

        win_count = trades.count { |t| t[:pnl] > 0 }
        loss_count = trades.count { |t| t[:pnl] <= 0 }
        wins += win_count
        losses += loss_count

        sym_pnl = trades.sum { |t| t[:pnl] }
        puts "  #{symbol}: #{trades.size} trades, PnL: $#{sym_pnl.round(2)}, Win: #{win_count}, Loss: #{loss_count}"
      end

      metrics = compute_metrics(all_trades, equity_curve, config.initial_balance)
      puts "\n" + "=" * 60
      puts "RESULTS"
      puts "=" * 60
      puts "Total Trades: #{metrics[:total_trades]}"
      puts "Win Rate: #{metrics[:win_rate]}%"
      puts "Profit Factor: #{metrics[:profit_factor]}"
      puts "Total PnL: $#{metrics[:total_pnl]}"
      puts "Max Drawdown: #{metrics[:max_drawdown]}%"
      puts "Sharpe Ratio: #{metrics[:sharpe_ratio]}"
      puts "Avg Win: $#{metrics[:avg_win]}"
      puts "Avg Loss: $#{metrics[:avg_loss]}"
      puts "Avg R:R: #{metrics[:avg_rr]}"

      storage.finish_backtest(id, metrics)
      metrics.merge(backtest_id: id)
    end

    def self.optimize(config, param_grid)
      best_result = nil
      best_params = nil

      param_grid.each do |params|
        trial_config = config.dup
        params.each { |k, v| trial_config.send("#{k}=", v) rescue nil }

        puts "\n#{'=' * 40}"
        puts "Trial: #{params}"
        result = run(trial_config)
        pf = result[:profit_factor] || 0
        total = result[:total_pnl] || 0

        if best_result.nil? || total > best_result[:total_pnl]
          best_result = result
          best_params = params
        end
      end

      puts "\n#{'=' * 60}"
      puts "BEST PARAMETERS"
      puts best_params.inspect
      puts "Best PnL: $#{best_result[:total_pnl]} | Win Rate: #{best_result[:win_rate]}%"
      best_result.merge(best_params: best_params)
    end

    private

    def self.run_symbol(symbol, candles_1h, candles_15m, config, storage, backtest_id)
      trades = []
      position = nil

      lookback = 100
      (lookback...candles_1h.size).each do |i|
        slice_1h = candles_1h[(i - lookback + 1)..i]
        slice_15m = candles_15m ? candles_15m[(i * 4 - lookback + 1)..(i * 4)]&.last(lookback) : slice_1h

        next if slice_1h.size < 50

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

        if position.nil?
          setup = detect_setup(slice_1h, ms, displacements, obs, sweeps, pd, current_price, atr_val, config)
          next unless setup

          sl_pct = ((current_price - setup[:stop_loss]).abs / current_price * 100)
          next if sl_pct > config.max_risk_per_trade_pct

          position = {
            symbol: symbol, direction: setup[:direction],
            entry_price: current_price, stop_loss: setup[:stop_loss],
            take_profit: setup[:take_profit], quantity: setup[:quantity],
            entry_index: i, entry_time: Time.at(slice_1h.last[:time]).utc.strftime("%Y-%m-%d %H:%M"),
            rr: setup[:rr]
          }
        else
          tp = position[:take_profit]
          sl = position[:stop_loss]
          if position[:direction] == "LONG"
            if current_price >= tp
              pnl = (tp - position[:entry_price]) * position[:quantity]
              pnl -= (pnl.abs * config.taker_fee)
              pnl -= (position[:entry_price] * position[:quantity] * config.taker_fee)
              position[:pnl] = pnl.round(2)
              position[:exit_price] = tp
              position[:exit_time] = Time.at(slice_1h.last[:time]).utc.strftime("%Y-%m-%d %H:%M")
              position[:exit_reason] = "take_profit"
              trades << position
              log_backtest_trade(storage, position, backtest_id)
              position = nil
            elsif current_price <= sl
              pnl = (sl - position[:entry_price]) * position[:quantity]
              pnl -= (pnl.abs * config.taker_fee)
              pnl -= (position[:entry_price] * position[:quantity] * config.taker_fee)
              position[:pnl] = pnl.round(2)
              position[:exit_price] = sl
              position[:exit_time] = Time.at(slice_1h.last[:time]).utc.strftime("%Y-%m-%d %H:%M")
              position[:exit_reason] = "stop_loss"
              trades << position
              log_backtest_trade(storage, position, backtest_id)
              position = nil
            end
          else
            if current_price <= tp
              pnl = (position[:entry_price] - tp) * position[:quantity]
              pnl -= (pnl.abs * config.taker_fee)
              pnl -= (position[:entry_price] * position[:quantity] * config.taker_fee)
              position[:pnl] = pnl.round(2)
              position[:exit_price] = tp
              position[:exit_time] = Time.at(slice_1h.last[:time]).utc.strftime("%Y-%m-%d %H:%M")
              position[:exit_reason] = "take_profit"
              trades << position
              log_backtest_trade(storage, position, backtest_id)
              position = nil
            elsif current_price >= sl
              pnl = (position[:entry_price] - sl) * position[:quantity]
              pnl -= (pnl.abs * config.taker_fee)
              pnl -= (position[:entry_price] * position[:quantity] * config.taker_fee)
              position[:pnl] = pnl.round(2)
              position[:exit_price] = sl
              position[:exit_time] = Time.at(slice_1h.last[:time]).utc.strftime("%Y-%m-%d %H:%M")
              position[:exit_reason] = "stop_loss"
              trades << position
              log_backtest_trade(storage, position, backtest_id)
              position = nil
            end
          end
        end

        max_hold = 48
        if position && (i - position[:entry_index]) >= max_hold
          exit_price = slice_1h.last[:close]
          pnl = position[:direction] == "LONG" ?
            (exit_price - position[:entry_price]) * position[:quantity] :
            (position[:entry_price] - exit_price) * position[:quantity]
          pnl -= (pnl.abs * config.taker_fee) + (position[:entry_price] * position[:quantity] * config.taker_fee)
          position[:pnl] = pnl.round(2)
          position[:exit_price] = exit_price
          position[:exit_reason] = "time_exit"
          trades << position
          log_backtest_trade(storage, position, backtest_id)
          position = nil
        end
      end

      trades
    end

    def self.detect_setup(candles, ms, displacements, obs, sweeps, pd, price, atr, config)
      active_obs = obs.select { |ob| !ob[:invalidated] }
      recent_sweeps = sweeps.select { |s| s[:sweep_index] >= candles.size - 10 }
      recent_bos = ms[:bos_events].select { |e| e[:index] >= candles.size - 10 }
      recent_choch = ms[:choch_events].select { |e| e[:index] >= candles.size - 20 }

      in_discount = PDArray.discount?(price, pd)
      trend = ms[:trend]
      candidates = []

      # Strategy 1: BOS Retest
      recent_bos.each do |bos|
        s = bos_retest_setup(bos, price, atr, ms, config)
        candidates << s if s
      end

      # Strategy 2: CHoCH Reversal
      recent_choch.each do |choch|
        s = choch_setup(choch, price, atr, ms, config)
        candidates << s if s
      end

      # Strategy 3: Sweep + Trend
      recent_sweeps.each do |sweep|
        s = sweep_setup(sweep, price, atr, ms, pd, in_discount, config)
        candidates << s if s
      end

      # Strategy 4: OB Bounce
      active_obs.each do |ob|
        s = ob_setup(ob, price, atr, ms, pd, in_discount, config)
        candidates << s if s
      end

      # Strategy 5: Displacement follow
      recent_disp = displacements.select { |d| d[:index] >= candles.size - 5 }
      recent_disp.each do |disp|
        s = displacement_setup(disp, price, atr, ms, config)
        candidates << s if s
      end

      # Pick best by R:R (minimum 2.0)
      candidates.select { |c| c[:rr] >= config.min_rr_ratio }
                .max_by { |c| c[:rr] }
    end

    def self.bos_retest_setup(bos, price, atr, ms, config)
      is_bullish = bos[:type].to_s.include?("bullish")
      is_bearish = bos[:type].to_s.include?("bearish")
      return nil unless is_bullish || is_bearish

      if is_bullish
        direction = "LONG"
        sl = [price - atr * 2.0, ms[:protected_low] || price - atr * 3].min
        tp = price + (price - sl) * 2.5
      else
        direction = "SHORT"
        sl = [price + atr * 2.0, ms[:protected_high] || price + atr * 3].max
        tp = price - (sl - price) * 2.5
      end

      rr = ((tp - price).abs / (price - sl).abs).round(2)
      return nil if rr < config.min_rr_ratio

      { direction: direction, stop_loss: sl.round(4), take_profit: tp.round(4),
        quantity: calc_quantity(price, sl, config), rr: rr }
    end

    def self.choch_setup(choch, price, atr, ms, config)
      is_bullish = choch[:choch_type].to_s.include?("bullish")
      is_bearish = choch[:choch_type].to_s.include?("bearish")
      return nil unless is_bullish || is_bearish

      if is_bullish
        direction = "LONG"
        sl = [price - atr * 2.0, ms[:protected_low] || price - atr * 3].min
        tp = price + (price - sl) * 3.0
      else
        direction = "SHORT"
        sl = [price + atr * 2.0, ms[:protected_high] || price + atr * 3].max
        tp = price - (sl - price) * 3.0
      end

      rr = ((tp - price).abs / (price - sl).abs).round(2)
      return nil if rr < config.min_rr_ratio

      { direction: direction, stop_loss: sl.round(4), take_profit: tp.round(4),
        quantity: calc_quantity(price, sl, config), rr: rr }
    end

    def self.sweep_setup(sweep, price, atr, ms, pd, in_discount, config)
      is_ssl = sweep[:type].to_s.include?("SSL") || sweep[:type].to_s.include?("sell")
      is_bsl = sweep[:type].to_s.include?("BSL") || sweep[:type].to_s.include?("buy")

      if is_ssl && (ms[:trend] != :bearish || in_discount)
        direction = "LONG"
        sl = [price - atr * 1.5, ms[:protected_low] || price - atr * 2].min
        tp = price + (price - sl) * 2.5
      elsif is_bsl && (ms[:trend] != :bullish || !in_discount)
        direction = "SHORT"
        sl = [price + atr * 1.5, ms[:protected_high] || price + atr * 2].max
        tp = price - (sl - price) * 2.5
      else
        return nil
      end

      rr = ((tp - price).abs / (price - sl).abs).round(2)
      return nil if rr < config.min_rr_ratio

      { direction: direction, stop_loss: sl.round(4), take_profit: tp.round(4),
        quantity: calc_quantity(price, sl, config), rr: rr }
    end

    def self.ob_setup(ob, price, atr, ms, pd, in_discount, config)
      zone_min, zone_max = ob[:zone].minmax
      proximity = ((price - zone_min).abs / (zone_max - zone_min + 0.01))
      return nil unless proximity < 0.3

      if ob[:direction] == :bullish
        direction = "LONG"
        sl = [zone_min - atr * 0.5, ms[:protected_low] || zone_min - atr].min
        tp = price + (price - sl) * 2.5
      elsif ob[:direction] == :bearish
        direction = "SHORT"
        sl = [zone_max + atr * 0.5, ms[:protected_high] || zone_max + atr].max
        tp = price - (sl - price) * 2.5
      else
        return nil
      end

      rr = ((tp - price).abs / (price - sl).abs).round(2)
      return nil if rr < config.min_rr_ratio

      { direction: direction, stop_loss: sl.round(4), take_profit: tp.round(4),
        quantity: calc_quantity(price, sl, config), rr: rr }
    end

    def self.displacement_setup(disp, price, atr, ms, config)
      if disp[:direction] == :bullish
        direction = "LONG"
        sl = [price - atr * 2.0, ms[:protected_low] || price - atr * 3].min
        tp = price + (price - sl) * 2.0
      elsif disp[:direction] == :bearish
        direction = "SHORT"
        sl = [price + atr * 2.0, ms[:protected_high] || price + atr * 3].max
        tp = price - (sl - price) * 2.0
      else
        return nil
      end

      rr = ((tp - price).abs / (price - sl).abs).round(2)
      return nil if rr < config.min_rr_ratio

      { direction: direction, stop_loss: sl.round(4), take_profit: tp.round(4),
        quantity: calc_quantity(price, sl, config), rr: rr }
    end

    def self.calc_quantity(price, sl, config)
      risk_per_trade = config.initial_balance * (config.max_risk_per_trade_pct / 100.0)
      risk_per_unit = (price - sl).abs
      return 0.01 if risk_per_unit <= 0
      [[(risk_per_trade / risk_per_unit).round(4), 0.01].max, 1000].min
    end

    def self.log_backtest_trade(storage, trade, backtest_id)
      storage.log_backtest_trade(trade, backtest_id)
    end

    def self.compute_metrics(trades, equity_curve, initial_balance)
      return default_metrics if trades.empty?

      total_pnl = trades.sum { |t| t[:pnl] }
      wins = trades.select { |t| t[:pnl] > 0 }
      losses = trades.select { |t| t[:pnl] <= 0 }
      win_rate = trades.size > 0 ? (wins.size.to_f / trades.size * 100).round(2) : 0

      gross_profit = wins.sum { |t| t[:pnl] }
      gross_loss = losses.sum { |t| t[:pnl].abs }
      profit_factor = gross_loss > 0 ? (gross_profit / gross_loss).round(2) : gross_profit > 0 ? 99.99 : 0

      max_dd = 0
      peak = initial_balance
      equity_curve.each do |bal|
        peak = bal if bal > peak
        dd = ((peak - bal) / peak * 100).round(2)
        max_dd = dd if dd > max_dd
      end

      returns = []
      equity_curve.each_cons(2) { |a, b| returns << (b - a) / a }
      avg_return = returns.size > 0 ? returns.sum / returns.size : 0
      std_return = returns.size > 1 ? Math.sqrt(returns.map { |r| (r - avg_return) ** 2 }.sum / (returns.size - 1)) : 1
      sharpe = std_return > 0 ? ((avg_return / std_return) * Math.sqrt(365)).round(2) : 0

      avg_win = wins.size > 0 ? (wins.sum { |t| t[:pnl] } / wins.size).round(2) : 0
      avg_loss = losses.size > 0 ? (losses.sum { |t| t[:pnl] } / losses.size).round(2) : 0
      avg_rr = losses.size > 0 ? (avg_win / avg_loss.abs).round(2) : 0

      { total_trades: trades.size, win_rate: win_rate, profit_factor: profit_factor,
        total_pnl: total_pnl.round(2), max_drawdown: max_dd, sharpe_ratio: sharpe,
        avg_win: avg_win, avg_loss: avg_loss, avg_rr: avg_rr }
    end

    def self.default_metrics
      { total_trades: 0, win_rate: 0, profit_factor: 0, total_pnl: 0,
        max_drawdown: 0, sharpe_ratio: 0, avg_win: 0, avg_loss: 0, avg_rr: 0 }
    end

    def self.fetch_historical(symbol, interval, start_date, end_date)
      all_candles = []
      start_ts = Time.parse(start_date).to_i * 1000
      end_ts = Time.parse(end_date).to_i * 1000
      limit = 1000

      current_start = start_ts
      while current_start < end_ts
        url = "#{BINANCE_API}/api/v3/klines?symbol=#{symbol}&interval=#{interval}&limit=#{limit}&startTime=#{current_start.to_i}"
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
    rescue => e
      warn "Historical fetch error: #{e.message}"
      nil
    end
  end
end
