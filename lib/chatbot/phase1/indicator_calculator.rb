# frozen_string_literal: true

module Chatbot
  module Phase1
    class IndicatorCalculator
      # Computes RSI (Relative Strength Index)
      def self.calculate_rsi(candles, period = 14)
        return [] if candles.size < period + 1

        closes = candles.map { |c| c[:close] }
        gains = []
        losses = []

        (1...closes.size).each do |i|
          change = closes[i] - closes[i - 1]
          gains << (change > 0 ? change : 0.0)
          losses << (change < 0 ? change.abs : 0.0)
        end

        rsi_values = Array.new(period, nil)

        avg_gain = gains.first(period).sum / period.to_f
        avg_loss = losses.first(period).sum / period.to_f

        if avg_loss == 0
          rsi_values << 100.0
        else
          rs = avg_gain / avg_loss
          rsi_values << (100.0 - (100.0 / (1.0 + rs)))
        end

        (period...gains.size).each do |i|
          avg_gain = (avg_gain * (period - 1) + gains[i]) / period.to_f
          avg_loss = (avg_loss * (period - 1) + losses[i]) / period.to_f

          if avg_loss == 0
            rsi_values << 100.0
          else
            rs = avg_gain / avg_loss
            rsi_values << (100.0 - (100.0 / (1.0 + rs)))
          end
        end

        rsi_values
      end

      # Computes EMA (Exponential Moving Average)
      def self.calculate_ema(candles, period)
        return [] if candles.size < period

        closes = candles.map { |c| c[:close] }
        multiplier = 2.0 / (period + 1)
        
        # Initial value is SMA
        sma = closes.first(period).sum / period.to_f
        ema_values = Array.new(period - 1, nil)
        ema_values << sma

        current_ema = sma
        (period...closes.size).each do |i|
          current_ema = (closes[i] - current_ema) * multiplier + current_ema
          ema_values << current_ema
        end

        ema_values
      end

      # Computes MACD (Moving Average Convergence Divergence)
      def self.calculate_macd(candles, fast_period = 12, slow_period = 26, signal_period = 9)
        fast_ema = calculate_ema(candles, fast_period)
        slow_ema = calculate_ema(candles, slow_period)

        macd_line = []
        candles.size.times do |i|
          if fast_ema[i] && slow_ema[i]
            macd_line << fast_ema[i] - slow_ema[i]
          else
            macd_line << nil
          end
        end

        # Calculate signal line: EMA of MACD Line (ignoring leading nil values for computation)
        non_nil_start = macd_line.find_index { |x| !x.nil? }
        return { macd: [], signal: [], histogram: [] } if !non_nil_start || macd_line.size - non_nil_start < signal_period

        macd_subset = macd_line[non_nil_start..].map { |val| { close: val } }
        signal_subset = calculate_ema(macd_subset, signal_period)

        signal_line = Array.new(non_nil_start, nil) + signal_subset
        histogram = []
        candles.size.times do |i|
          if macd_line[i] && signal_line[i]
            histogram << macd_line[i] - signal_line[i]
          else
            histogram << nil
          end
        end

        {
          macd: macd_line,
          signal: signal_line,
          histogram: histogram
        }
      end

      # Computes ATR (Average True Range)
      def self.calculate_atr(candles, period = 14)
        return [] if candles.size < period + 1

        tr_values = []
        (1...candles.size).each do |i|
          prev_close = candles[i - 1][:close]
          high = candles[i][:high]
          low = candles[i][:low]
          tr = [high - low, (high - prev_close).abs, (low - prev_close).abs].max
          tr_values << tr
        end

        atr_values = Array.new(period, nil)
        
        # First ATR is SMA of True Range values
        atr = tr_values.first(period).sum / period.to_f
        atr_values << atr

        (period...tr_values.size).each do |i|
          atr = (atr * (period - 1) + tr_values[i]) / period.to_f
          atr_values << atr
        end

        atr_values
      end

      # Computes Bollinger Bands
      def self.calculate_bollinger_bands(candles, period = 20, multiplier = 2.0)
        return { basis: [], upper: [], lower: [] } if candles.size < period

        closes = candles.map { |c| c[:close] }
        basis_values = Array.new(period - 1, nil)
        upper_values = Array.new(period - 1, nil)
        lower_values = Array.new(period - 1, nil)

        (period - 1...closes.size).each do |i|
          slice = closes[(i - period + 1)..i]
          mean = slice.sum / period.to_f
          variance = slice.map { |x| (x - mean)**2 }.sum / period.to_f
          std_dev = Math.sqrt(variance)

          basis_values << mean
          upper_values << mean + (multiplier * std_dev)
          lower_values << mean - (multiplier * std_dev)
        end

        {
          basis: basis_values,
          upper: upper_values,
          lower: lower_values
        }
      end

      # Computes Volume Trend
      # Returns volume SMA and whether the recent volume is above it
      def self.calculate_volume_trend(candles, period = 20)
        return { volume_sma: [], trend: :flat } if candles.size < period

        volumes = candles.map { |c| c[:volume] }
        volume_sma_values = Array.new(period - 1, nil)

        (period - 1...volumes.size).each do |i|
          slice = volumes[(i - period + 1)..i]
          volume_sma_values << (slice.sum / period.to_f)
        end

        # Compare short volume SMA (5-period) vs long volume SMA (20-period)
        short_period = [candles.size, 5].min
        recent_avg = volumes.last(short_period).sum / short_period.to_f
        long_avg = volume_sma_values.last || recent_avg

        trend = if recent_avg > long_avg * 1.1
                  :increasing
                elsif recent_avg < long_avg * 0.9
                  :decreasing
                else
                  :flat
                end

        {
          volume_sma: volume_sma_values,
          trend: trend,
          ratio: long_avg > 0 ? (recent_avg / long_avg).round(2) : 1.0
        }
      end
    end
  end
end
