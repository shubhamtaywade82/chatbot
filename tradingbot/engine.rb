require_relative "config"
require_relative "storage"
require_relative "scanner"
require_relative "analyst"
require_relative "trader"
require_relative "../lib/chatbot/smc_engines"

module TradingBot
  class Engine
    BINANCE_API = "https://api.binance.com"

    def initialize(config)
      @config = config
      @storage = Storage.new
      @scanner = Scanner.new(@storage, config)
      @analyst = Analyst.new(config)
      @trader = Trader.new(@storage, config)
      @running = false
      @last_analysis = {}
      @symbol_states = {}
    end

    def run
      @running = true
      puts "=" * 60
      puts "TradingBot Engine — #{@config.mode.upcase} mode"
      puts "Symbols: #{@config.symbols.join(", ")}"
      puts "Poll: #{@config.poll_interval_sec}s | Model: #{@config.model}"
      puts "=" * 60

      @config.symbols.each do |symbol|
        @symbol_states[symbol] = { last_event_time: 0, last_analysis_time: 0 }
      end

      while @running
        begin
          tick
          sleep @config.poll_interval_sec
        rescue Interrupt
          puts "\nShutting down..."
          @running = false
        rescue => e
          puts "Engine error: #{e.message}"
          puts e.backtrace.first(3).join("\n") if @config.verbose?
          sleep 5
        end
      end
    end

    def stop
      @running = false
    end

    private

    def tick
      now = Time.now.to_f

      @config.symbols.each do |symbol|
        state = @symbol_states[symbol] || {}
        open_trades = @storage.open_trades(symbol: symbol).size

        log_status(symbol, now, state, open_trades)

        events = @scanner.scan(symbol)
        log_events(symbol, events)

        should_analyze = events.any? || time_for_periodic?(symbol, now)

        if should_analyze && can_analyze?(symbol, now) && open_trades < @config.max_open_trades
          perform_analysis(symbol, events, open_trades)
          state[:last_analysis_time] = now
        end

        if events.any?
          state[:last_event_time] = now
          events.each do |e|
            @storage.log_event(
              symbol: symbol,
              event_type: e[:type].to_s,
              timeframe: e[:timeframe],
              price: e[:price],
              description: e[:description]
            )
          end
        end

        @storage.set_state("last_tick_#{symbol}", now.to_s)

        check_open_positions(symbol)
      end

      print_summary if @config.verbose?
    end

    def perform_analysis(symbol, events, open_trades_count)
      puts "  Analyzing #{symbol}..." if @config.verbose?
      multi_tf = multi_tf_analysis(symbol)

      result = @analyst.analyze(
        symbol: symbol,
        events: events,
        multi_tf_data: multi_tf,
        open_trades_count: open_trades_count
      )

      @storage.log_llm_response(
        symbol: symbol,
        event_type: events.first&.dig(:type)&.to_s || "periodic",
        prompt: result[:prompt] || "",
        response: result[:raw_response] || "",
        parsed_action: result[:action],
        duration_ms: result[:duration_ms] || 0
      )

      if result[:action] == "trade"
        handle_trade_signal(symbol, result)
      elsif @config.verbose?
        puts "  #{symbol}: #{result[:reason]}"
      end
    end

    def multi_tf_analysis(symbol)
      @config.timeframes.map do |tf|
        candles = fetch_candles(symbol, tf, limit: @config.candle_limit)
        next nil unless candles && candles.size >= 30

        pivots = PivotDetector.detect(candles, left_bars: 4, right_bars: 4)
        ms = MarketStructure.analyze(candles, pivots[:highs], pivots[:lows])
        atr_val = ATR.compute(candles)
        displacements = Displacement.detect(candles, atr_val)
        obs = OrderBlock.detect(candles, ms[:bos_events], displacements)

        eq = LiquiditySweep.find_equal_highs_lows(pivots[:highs], pivots[:lows])

        recent = candles.last(50)
        range_high = recent.map { |c| c[:high] }.max || candles.last[:high]
        range_low  = recent.map { |c| c[:low] }.min  || candles.last[:low]
        pd = PDArray.compute(range_high, range_low)
        in_discount = PDArray.discount?(candles.last[:close], pd)

        {
          interval: tf,
          current_price: candles.last[:close],
          candles: candles.size,
          atr: atr_val.round(4),
          trend: ms[:trend],
          protected_high: ms[:protected_high],
          protected_low: ms[:protected_low],
          last_swing_high: ms[:last_swing_high],
          last_swing_low: ms[:last_swing_low],
          bos_events: ms[:bos_events].last(5).map { |e| "BOS #{e[:type]} @ $#{e[:price]}" },
          order_blocks: obs.select { |ob| !ob[:invalidated] }.last(4).map { |ob|
            dir = ob[:direction] == :bullish ? "Bullish" : "Bearish"
            state = ob[:mitigated] ? "mitigated" : "active"
            "#{dir} OB $#{ob[:zone].min}-$#{ob[:zone].max} (#{state})"
          },
          sweeps: eq[:equal_highs].last(3).map { |e| "EH $#{e[:price]}" } +
                  eq[:equal_lows].last(3).map { |e| "EL $#{e[:price]}" },
          discount_zone: in_discount,
          pd_range: { low: pd[:low].round(2), high: pd[:high].round(2),
                      equilibrium: pd[:equilibrium].round(2) }
        }
      end.compact
    end

    def handle_trade_signal(symbol, signal)
      signal[:symbol] = symbol
      puts "  TRADE SIGNAL: #{signal[:direction]} #{symbol} @ $#{signal[:entry_price]} R=#{signal[:rr_ratio]}"

      @storage.log_signal(
        symbol: symbol, direction: signal[:direction], confidence: signal[:confidence],
        entry_price: signal[:entry_price], stop_loss: signal[:stop_loss],
        take_profit_1: signal[:take_profit_1], take_profit_2: signal[:take_profit_2],
        take_profit_3: signal[:take_profit_3], rr_ratio: signal[:rr_ratio],
        reason: signal[:reason], raw_response: signal[:raw_response],
        event_type: signal[:event_type], model_name: @config.model
      )

      result = @trader.execute(signal)
      if result[:success]
        puts "  ✅ #{result[:type].upcase} #{signal[:direction]} #{symbol} | Entry: $#{result[:entry]} | Qty: #{result[:qty]}"
        @storage.log_event(symbol: symbol, event_type: "trade_executed",
                           price: signal[:entry_price],
                           description: "Executed #{signal[:direction]} #{symbol} @ $#{signal[:entry_price]}")
      else
        puts "  ❌ Trade rejected: #{result[:reason]}"
      end
    end

    def check_open_positions(symbol)
      @storage.open_trades(symbol: symbol).each do |trade|
        @trader.check_exit(trade)
      end
    end

    def can_analyze?(symbol, now)
      min_interval = @config.min_analysis_interval_sec
      last_time = @symbol_states.dig(symbol, :last_analysis_time) || 0
      (now - last_time) >= min_interval
    end

    def time_for_periodic?(symbol, now)
      min_interval = @config.min_analysis_interval_sec * 2
      last_time = @symbol_states.dig(symbol, :last_analysis_time) || 0
      (now - last_time) >= min_interval
    end

    def log_status(symbol, now, state, open_trades)
      last_event = state[:last_event_time] || 0
      time_since = ((now - last_event) / 60).round(1)
      print "#{Time.now.strftime("%H:%M:%S")} #{symbol} open=#{open_trades} events=#{time_since}m ago"
    end

    def log_events(symbol, events)
      if events.any?
        types = events.map { |e| e[:type] }.tally
        puts "  EVENTS: #{types.map { |k, v| "#{k}x#{v}" }.join(", ")}"
      else
        puts "  no events"
      end
    end

    def print_summary
      summary = @storage.summary
      puts "--- Bot Summary: #{summary[:total_trades]} trades, #{summary[:open_trades]} open, PnL: $#{summary[:total_pnl]}"
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
      warn "fetch_candles error #{symbol} #{interval}: #{e.message}" if @config.verbose?
      nil
    end
  end
end
