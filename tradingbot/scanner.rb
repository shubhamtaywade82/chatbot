require_relative "../lib/chatbot/smc_engines"

module TradingBot
  class Scanner
    BINANCE_API = "https://api.binance.com"
    EVENTS = %i[
      liquidity_sweep structure_break order_block_retest
      displacement funding_rate_extreme periodic_check
    ].freeze

    def initialize(storage, config)
      @storage = storage
      @config = config
      @last_check = {}
      @event_cooldown = 300
    end

    def scan(symbol, timeframes = @config.timeframes)
      events = []
      timeframes.each do |tf|
        candles = fetch_candles(symbol, tf, limit: @config.candle_limit)
        next if candles.nil? || candles.size < 30

        pivots = PivotDetector.detect(candles, left_bars: 4, right_bars: 4)
        ms = MarketStructure.analyze(candles, pivots[:highs], pivots[:lows])
        atr_val = ATR.compute(candles)
        displacements = Displacement.detect(candles, atr_val)
        obs = OrderBlock.detect(candles, ms[:bos_events], displacements)

        eq = LiquiditySweep.find_equal_highs_lows(pivots[:highs], pivots[:lows])
        sweeps = LiquiditySweep.detect_sweeps(candles, pivots[:highs], pivots[:lows],
                                               equal_highs: eq[:equal_highs],
                                               equal_lows: eq[:equal_lows])

        events.concat(detect_events(symbol, tf, candles, ms, displacements, obs, sweeps, atr_val))
      end
      events
    end

    private

    def detect_events(symbol, tf, candles, ms, displacements, obs, sweeps, atr_val)
      events = []
      last_candle = candles.last
      current_price = last_candle[:close]
      last_check_key = "#{symbol}:#{tf}"
      last_check_time = @last_check[last_check_key] || 0
      now = Time.now.to_f

      # Liquidity sweep event
      if sweeps.any? && (now - last_check_time) > @event_cooldown
        recent_sweeps = sweeps.select { |s| s[:sweep_index] >= candles.size - 10 }
        if recent_sweeps.any?
          s = recent_sweeps.last
          events << {
            type: :liquidity_sweep, symbol: symbol, timeframe: tf,
            price: current_price, atr: atr_val,
            description: "#{s[:type]} of $#{s[:swept_level]} at candle #{s[:sweep_index]}",
            data: { sweep: s, pivots: { high: ms[:last_swing_high], low: ms[:last_swing_low] },
                    protected_high: ms[:protected_high], protected_low: ms[:protected_low],
                    trend: ms[:trend] }
          }
        end
      end

      # Structure break event
      recent_bos = ms[:bos_events].select { |e| e[:index] >= candles.size - 8 }
      if recent_bos.any? && (now - last_check_time) > @event_cooldown
        recent_bos.last(2).each do |bos|
          events << {
            type: :structure_break, symbol: symbol, timeframe: tf,
            price: current_price, atr: atr_val,
            description: "BOS #{bos[:type]} @ $#{bos[:price]} (candle #{bos[:index]})",
            data: { bos: bos, trend: ms[:trend],
                    protected_high: ms[:protected_high], protected_low: ms[:protected_low] }
          }
        end
      end

      # CHoCH detection
      recent_choch = ms[:choch_events].select { |e| e[:index] >= candles.size - 15 }
      if recent_choch.any? && (now - last_check_time) > @event_cooldown
        recent_choch.last(2).each do |choch|
          events << {
            type: :structure_break, symbol: symbol, timeframe: tf,
            price: current_price, atr: atr_val,
            description: "CHoCH #{choch[:choch_type]} @ $#{choch[:price]} (candle #{choch[:index]})",
            data: { choch: choch, trend: ms[:trend] }
          }
        end
      end

      # Order block retest event
      active_obs = obs.select { |ob| !ob[:invalidated] }
      active_obs.each do |ob|
        zone_min, zone_max = ob[:zone].minmax
        proximity = ((current_price - zone_min).abs / (zone_max - zone_min + 0.01))
        if proximity < 0.15 && (now - last_check_time) > @event_cooldown
          events << {
            type: :order_block_retest, symbol: symbol, timeframe: tf,
            price: current_price, atr: atr_val,
            description: "Price retesting #{ob[:direction]} OB $#{zone_min}-$#{zone_max}",
            data: { order_block: ob }
          }
        end
      end

      # Displacement event
      recent_disp = displacements.select { |d| d[:index] >= candles.size - 5 }
      if recent_disp.any? && (now - last_check_time) > @event_cooldown
        recent_disp.last(2).each do |d|
          events << {
            type: :displacement, symbol: symbol, timeframe: tf,
            price: current_price, atr: atr_val,
            description: "Strong #{d[:direction]} displacement at candle #{d[:index]}",
            data: { displacement: d }
          }
        end
      end

      @last_check[last_check_key] = now if events.any?
      events
    end

    def fetch_candles(symbol, interval, limit: 150)
      url = "#{BINANCE_API}/api/v3/klines?symbol=#{symbol}&interval=#{interval}&limit=#{limit}"
      resp = Net::HTTP.get_response(URI(url))
      return nil unless resp.is_a?(Net::HTTPOK)
      JSON.parse(resp.body).map do |k|
        { time: k[0] / 1000, open: k[1].to_f, high: k[2].to_f,
          low: k[3].to_f, close: k[4].to_f, volume: k[5].to_f }
      end
    rescue => e
      warn "Scanner fetch error #{symbol} #{interval}: #{e.message}" if @config.verbose?
      nil
    end
  end
end
