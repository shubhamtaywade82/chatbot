require_relative "config"
require_relative "storage"
require_relative "scanner"
require_relative "analyst"
require_relative "trader"
require_relative "telegram_notifier"
require_relative "self_learning"
require_relative "../lib/chatbot/terminal_markdown"
require_relative "../lib/chatbot/smc_engines"

module TradingBot
  class Engine
    BINANCE_API = "https://api.binance.com"

    def initialize(config)
      @config = config
      @storage = Storage.new
      @scanner = Scanner.new(@storage, config)
      @analyst = Analyst.new(config, @storage)
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
        @symbol_states[symbol] = { last_event_time: nil, last_analysis_time: 0 }
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
        total_open_trades = @storage.open_trades.size

        log_status(symbol, now, state, open_trades)

        events = @scanner.scan(symbol)
        log_events(symbol, events)

        should_analyze = events.any? || time_for_periodic?(symbol, now)

        if should_analyze && can_analyze?(symbol, now) &&
           open_trades < @config.max_setups_per_symbol &&
           total_open_trades < @config.max_open_trades
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

      # Self-Learning Feedback Loop
      SelfLearning.process_closed_trades(@storage, @config)

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
        result[:reason].to_s.each_line do |line|
          puts "  " + Chatbot::TerminalMarkdown.render_line(line.chomp)
        end
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
      puts "  \e[33m⚡ TRADE SIGNAL:\e[0m \e[1m#{signal[:direction]} #{symbol}\e[0m @ \e[36m$#{signal[:entry_price]}\e[0m R=\e[32m#{signal[:rr_ratio]}\e[0m"

      # Send Telegram alert for signal
      alert_msg = "⚡ *TRADE SIGNAL: #{signal[:direction]} #{symbol}*\n" \
                  "Entry: $#{signal[:entry_price]}\n" \
                  "Stop Loss: $#{signal[:stop_loss]}\n" \
                  "Take Profit 1: $#{signal[:take_profit_1]}\n" \
                  "Risk/Reward: #{signal[:rr_ratio]}\n" \
                  "Reason: #{signal[:reason]}"
      TelegramNotifier.send_alert(@config, alert_msg)

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
        puts "  ✅ \e[32m#{result[:type].upcase} #{signal[:direction]} #{symbol}\e[0m | Entry: \e[36m$#{result[:entry]}\e[0m | Qty: \e[35m#{result[:qty]}\e[0m"
        @storage.log_event(symbol: symbol, event_type: "trade_executed",
                           price: signal[:entry_price],
                           description: "Executed #{signal[:direction]} #{symbol} @ $#{signal[:entry_price]}")
        # Send Telegram execution success alert
        exec_msg = "✅ *EXECUTION SUCCESS: #{result[:type].upcase} #{signal[:direction]} #{symbol}*\n" \
                   "Price: $#{result[:entry]}\n" \
                   "Quantity: #{result[:qty]}"
        TelegramNotifier.send_alert(@config, exec_msg)
      else
        puts "  ❌ \e[31mTrade rejected: #{result[:reason]}\e[0m"
        # Send Telegram execution rejection alert
        rej_msg = "❌ *TRADE REJECTED: #{signal[:direction]} #{symbol}*\n" \
                  "Reason: #{result[:reason]}"
        TelegramNotifier.send_alert(@config, rej_msg)
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
      last_event = state[:last_event_time]
      time_since = last_event ? "#{((now - last_event) / 60).round(1)}m ago" : "never"
      print "\e[36m#{Time.now.strftime("%H:%M:%S")}\e[0m \e[1m#{symbol}\e[0m open=\e[33m#{open_trades}\e[0m events=\e[35m#{time_since}\e[0m"
    end

    def log_events(symbol, events)
      if events.any?
        types = events.map { |e| e[:type] }.tally
        puts "  \e[33mEVENTS:\e[0m #{types.map { |k, v| "\e[32m#{k}\e[0mx\e[1m#{v}\e[0m" }.join(", ")}"
      else
        puts "  \e[90mno events\e[0m"
      end
    end

    def print_summary
      summary = @storage.summary
      pnl = summary[:total_pnl] || 0.0
      pnl_colored = if pnl > 0
                      "\e[32m$#{pnl.round(2)}\e[0m"
                    elsif pnl < 0
                      "\e[31m$#{pnl.round(2)}\e[0m"
                    else
                      "$#{pnl.round(2)}"
                    end
      puts "\e[90m───\e[0m \e[1mBot Summary:\e[0m #{summary[:total_trades]} trades, #{summary[:open_trades]} open | PnL: #{pnl_colored}"
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
