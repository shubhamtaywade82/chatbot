# frozen_string_literal: true

# ---------------------------------------------------------------------------
# SMC Engines — ported from smc-backtester, adapted for live analysis
# Each module is stateless: takes candles/swings in, returns structured data out.
# ---------------------------------------------------------------------------

# Average True Range (Wilder smoothing)
module ATR
  def self.compute(candles, period: 14)
    return 0.0 if candles.size < period + 1

    tr_values = []
    (1...candles.size).each do |i|
      prev_close = candles[i - 1][:close]
      high = candles[i][:high]
      low = candles[i][:low]
      tr = [high - low, (high - prev_close).abs, (low - prev_close).abs].max
      tr_values << tr
    end

    atr = tr_values.first(period).sum / period.to_f
    tr_values[period..].each do |tr|
      atr = (atr * (period - 1) + tr) / period
    end
    atr
  end
end

# Swing high/low detection
module PivotDetector
  def self.detect(candles, left_bars: 5, right_bars: 5)
    highs = []
    lows = []

    (left_bars...candles.size - right_bars).each do |i|
      cur = candles[i]
      is_high = (i - left_bars..i + right_bars).all? { |j| j == i || cur[:high] >= candles[j][:high] }
      is_low  = (i - left_bars..i + right_bars).all? { |j| j == i || cur[:low]  <= candles[j][:low] }

      highs << { index: i, price: cur[:high], time: candles[i][:time] } if is_high
      lows  << { index: i, price: cur[:low],  time: candles[i][:time] } if is_low
    end

    { highs: highs, lows: lows }
  end
end

# Market structure: swing classification, BOS/CHoCH, trend, protected levels
module MarketStructure
  SWING_HIGH_TYPES = { high: :high }.freeze
  SWING_LOW_TYPES = { low: :low }.freeze

  def self.analyze(candles, swing_highs, swing_lows)
    # Classify swings relative to prior swings of same type
    classified_highs = classify_swings(swing_highs, :high)
    classified_lows  = classify_swings(swing_lows, :low)

    # Determine trend from last two highs and lows
    recent_h = classified_highs.last(2)
    recent_l = classified_lows.last(2)
    trend = if recent_h.size >= 2 && recent_l.size >= 2
      if recent_h[-1][:type] == :HH && recent_l[-1][:type] == :HL
        :bullish
      elsif recent_h[-1][:type] == :LH && recent_l[-1][:type] == :LL
        :bearish
      else
        :ranging
      end
    else
      :insufficient_data
    end

    # Detect BOS: price closed beyond the most recent unbroken swing
    bos_events = detect_bos(candles, swing_highs, swing_lows, trend)

    # Detect CHoCH: BOS against current trend (reversal signal)
    choch_events = detect_choch(bos_events, trend)

    # Protected levels: the last swing that was broken
    protected_levels = compute_protected_levels(bos_events, swing_highs, swing_lows)

    {
      trend: trend,
      swing_highs: classified_highs.map { |s| { price: s[:price], type: s[:type], index: s[:index] } },
      swing_lows:  classified_lows.map  { |s| { price: s[:price], type: s[:type], index: s[:index] } },
      bos_events: bos_events,
      choch_events: choch_events,
      protected_high: protected_levels[:high],
      protected_low: protected_levels[:low],
      last_swing_high: swing_highs.last&.dig(:price),
      last_swing_low: swing_lows.last&.dig(:price)
    }
  end

  def self.classify_swings(swings, kind)
    result = []
    swings.each_with_index do |s, i|
      prev = result.last
      type = if kind == :high
               prev ? (s[:price] > prev[:price] ? :HH : :LH) : :HH
             else
               prev ? (s[:price] < prev[:price] ? :LL : :HL) : :LL
             end
      result << { price: s[:price], index: s[:index], type: type, time: s[:time] }
    end
    result
  end

  def self.detect_bos(candles, swing_highs, swing_lows, trend)
    events = []
    broken_lows = Set.new
    broken_highs = Set.new

    candle_by_index = candles.each_with_index.to_h { |c, i| [i, c] }

    swing_highs.each do |sh|
      ci = sh[:index]
      (ci...candles.size).each do |j|
        next unless candles[j][:close] > sh[:price] && !broken_highs.include?(sh[:index])

        events << {
          index: j, price: sh[:price], type: :bullish_bos,
          reason: "close(#{(candles[j][:close]).round(2)}) > swing_high(#{(sh[:price]).round(2)})"
        }
        broken_highs << sh[:index]
        break
      end
    end

    swing_lows.each do |sl|
      ci = sl[:index]
      (ci...candles.size).each do |j|
        next unless candles[j][:close] < sl[:price] && !broken_lows.include?(sl[:index])

        events << {
          index: j, price: sl[:price], type: :bearish_bos,
          reason: "close(#{(candles[j][:close]).round(2)}) < swing_low(#{(sl[:price]).round(2)})"
        }
        broken_lows << sl[:index]
        break
      end
    end

    events.sort_by { |e| e[:index] }
  end

  def self.detect_choch(bos_events, trend)
    bos_events.select do |e|
      (trend == :bearish && e[:type] == :bullish_bos) ||
        (trend == :bullish && e[:type] == :bearish_bos)
    end.map { |e| e.merge(choch_type: trend == :bearish ? :bullish_choch : :bearish_choch) }
  end

  def self.compute_protected_levels(bos_events, swing_highs, swing_lows)
    last_bullish = bos_events.reverse.find { |e| e[:type] == :bullish_bos }
    last_bearish = bos_events.reverse.find { |e| e[:type] == :bearish_bos }

    prot_low  = last_bullish ? swing_lows.reverse.find { |sl| sl[:index] <= last_bullish[:index] }&.dig(:price) : nil
    prot_high = last_bearish ? swing_highs.reverse.find { |sh| sh[:index] <= last_bearish[:index] }&.dig(:price) : nil

    { low: prot_low, high: prot_high }
  end
end

# Displacement detection — ATR-based institutional impulse
module Displacement
  def self.detect(candles, atr, body_multiplier: 1.5, range_multiplier: 2.0, min_body_ratio: 0.6)
    result = []
    candles.each_with_index do |c, i|
      body = (c[:close] - c[:open]).abs
      range = c[:high] - c[:low]
      body_pass = body >= atr * body_multiplier
      range_pass = range >= atr * range_multiplier && (range > 0 ? body / range >= min_body_ratio : false)

      next unless body_pass || range_pass

      direction = c[:close] > c[:open] ? :bullish : :bearish
      method = if body_pass && range_pass then "body+range"
               elsif body_pass then "body"
               else "range"
               end
      result << {
        index: i,
        direction: direction,
        price: c[:close],
        method: method,
        body_size: body.round(2),
        range_size: range.round(2),
        atr: atr.round(2)
      }
    end
    result
  end
end

# Order blocks — created at BOS/CHoCH with displacement confirmation
module OrderBlock
  def self.detect(candles, bos_events, displacement_events)
    blocks = []
    displacement_indices = displacement_events.map { |d| [d[:index], d[:direction]] }.to_h

    bos_events.each do |bos|
      # Find the most recent displacement in the same direction before this BOS
      matching_disp = displacement_events.reverse.find { |d| d[:index] <= bos[:index] && d[:direction] == (bos[:type] == :bullish_bos ? :bullish : :bearish) }
      next unless matching_disp && bos[:index] - matching_disp[:index] <= 20

      # OB candle: the candle right before the displacement move started
      ob_idx = matching_disp[:index] - 1
      next if ob_idx < 0

      ob_candle = candles[ob_idx]
      is_bullish_ob = bos[:type] == :bullish_bos

      zone = is_bullish_ob ? [ob_candle[:low], ob_candle[:high]] : [ob_candle[:high], ob_candle[:low]]

      # Check mitigation: has price touched this zone?
      mitigated = false
      invalidation_reason = nil
      (ob_idx + 1...candles.size).each do |j|
        c = candles[j]
        if is_bullish_ob
          if c[:low] <= zone[1]  # touched OB high
            mitigated = true
          end
          if c[:close] <= zone[0] + (candles[ob_idx][:high] - candles[ob_idx][:low]) * 0.1  # close near/through OB low
            mitigated = true
          end
          if c[:close] < zone[0]  # closed below OB low → invalidated
            invalidation_reason = "close_below_ob_low"
            break
          end
        else
          if c[:high] >= zone[0]  # touched OB low
            mitigated = true
          end
          if c[:high] > zone[1]  # broke above OB high → invalidated
            invalidation_reason = "break_above_ob_high"
            break
          end
        end
      end

      blocks << {
        direction: is_bullish_ob ? :bullish : :bearish,
        zone: zone,
        zone_mid: ((zone[0] + zone[1]) / 2.0).round(2),
        created_at_bos: bos[:type],
        created_at_index: bos[:index],
        mitigated: mitigated,
        invalidated: !invalidation_reason.nil?,
        invalidation_reason: invalidation_reason,
        displacement_strength: matching_disp[:method]
      }
    end

    blocks
  end

  # Check if current price is retesting an OB
  def self.retesting?(price, ob)
    return false if ob[:invalidated]

    if ob[:direction] == :bullish
      price >= ob[:zone][0] && price <= ob[:zone][1]
    else
      price <= ob[:zone][1] && price >= ob[:zone][0]
    end
  end
end

# Liquidity sweeps — equal highs/lows + sweep with reclaim
module LiquiditySweep
  def self.find_equal_highs_lows(swing_highs, swing_lows, tolerance_pct: 0.001)
    equal_highs = []
    swing_highs.each_cons(2) do |a, b|
      diff = (a[:price] - b[:price]).abs / [a[:price], b[:price]].max
      if diff <= tolerance_pct
        avg = (a[:price] + b[:price]) / 2.0
        equal_highs << { price: avg.round(2), indices: [a[:index], b[:index]] }
      end
    end

    equal_lows = []
    swing_lows.each_cons(2) do |a, b|
      diff = (a[:price] - b[:price]).abs / [a[:price], b[:price]].max
      if diff <= tolerance_pct
        avg = (a[:price] + b[:price]) / 2.0
        equal_lows << { price: avg.round(2), indices: [a[:index], b[:index]] }
      end
    end

    { equal_highs: equal_highs, equal_lows: equal_lows }
  end

  def self.detect_sweeps(candles, swing_highs, swing_lows, equal_highs: [], equal_lows: [])
    sweeps = []

    # Sell-side liquidity sweep: low breaks below a swing low, close reclaims
    swing_lows.each do |sl|
      (sl[:index]...candles.size).each do |j|
        c = candles[j]
        if c[:low] < sl[:price] && c[:close] > sl[:price]
          sweeps << {
            type: :ssl_sweep, swept_level: sl[:price], swept_index: sl[:index],
            sweep_index: j, sweep_price: c[:low], close: c[:close]
          }
          break
        end
      end
    end

    # Buy-side liquidity sweep: high breaks above a swing high, close reclaims back below
    swing_highs.each do |sh|
      (sh[:index]...candles.size).each do |j|
        c = candles[j]
        if c[:high] > sh[:price] && c[:close] < sh[:price]
          sweeps << {
            type: :bsl_sweep, swept_level: sh[:price], swept_index: sh[:index],
            sweep_index: j, sweep_price: c[:high], close: c[:close]
          }
          break
        end
      end
    end

    sweeps.sort_by { |s| s[:sweep_index] }
  end
end

# Candle pattern confirmation
module EntryConfirmation
  def self.long_confirmed?(candles, index)
    return false if index < 1 || index >= candles.size

    cur = candles[index]
    prev = candles[index - 1]
    bullish_engulfing?(cur, prev) || bullish_rejection_wick?(cur)
  end

  def self.short_confirmed?(candles, index)
    return false if index < 1 || index >= candles.size

    cur = candles[index]
    prev = candles[index - 1]
    bearish_engulfing?(cur, prev) || bearish_rejection_wick?(cur)
  end

  def self.bullish_engulfing?(cur, prev)
    cur[:close] > cur[:open] &&
      prev[:close] < prev[:open] &&
      cur[:close] >= prev[:open] &&
      cur[:open] <= prev[:close]
  end

  def self.bearish_engulfing?(cur, prev)
    cur[:close] < cur[:open] &&
      prev[:close] > prev[:open] &&
      cur[:close] <= prev[:open] &&
      cur[:open] >= prev[:close]
  end

  def self.bullish_rejection_wick?(candle)
    range = candle[:high] - candle[:low]
    return false if range <= 0

    lower_wick = [candle[:open], candle[:close]].min - candle[:low]
    upper_wick = candle[:high] - [candle[:open], candle[:close]].max
    lower_wick >= range * 0.5 && upper_wick < range * 0.3
  end

  def self.bearish_rejection_wick?(candle)
    range = candle[:high] - candle[:low]
    return false if range <= 0

    upper_wick = candle[:high] - [candle[:open], candle[:close]].max
    lower_wick = [candle[:open], candle[:close]].min - candle[:low]
    upper_wick >= range * 0.5 && lower_wick < range * 0.3
  end
end

# Premium / Discount array
module PDArray
  def self.compute(high, low)
    range = high - low
    equilibrium = low + range / 2.0
    { high: high, low: low, equilibrium: equilibrium.round(2),
      discount_zone: low..equilibrium, premium_zone: equilibrium..high }
  end

  def self.discount?(price, pd)
    price <= pd[:equilibrium]
  end

  def self.premium?(price, pd)
    price >= pd[:equilibrium]
  end
end
