require "json"
require "net/http"
require "openssl"

module TradingBot
  class Trader
    def initialize(storage, config)
      @storage = storage
      @config = config
      @slippage = config.slippage_pct / 100.0
    end

    def execute(signal)
      return paper_execute(signal) if @config.paper?
      live_execute(signal)
    end

    def paper_execute(signal)
      entry = apply_slippage(signal[:entry_price], signal[:direction] == "LONG")
      sl = signal[:stop_loss]
      qty = compute_quantity(entry, sl, signal[:direction])
      risk_pct = ((entry - sl).abs / entry * 100).round(2)

      if risk_pct > @config.max_risk_per_trade_pct
        return { success: false, reason: "Risk #{risk_pct}% exceeds max #{@config.max_risk_per_trade_pct}%" }
      end

      trade = {
        symbol: signal[:symbol], direction: signal[:direction],
        entry_price: entry.round(4), quantity: qty.round(4),
        stop_loss: sl.round(4),
        take_profit_1: signal[:take_profit_1]&.round(4),
        take_profit_2: signal[:take_profit_2]&.round(4),
        take_profit_3: signal[:take_profit_3]&.round(4),
        entry_reason: signal[:reason],
        strategy: "smc",
        model_name: @config.model,
        metadata: JSON.generate({ event_type: signal[:event_type], confidence: signal[:confidence],
                                   rr_ratio: signal[:rr_ratio], mode: "paper" })
      }

      trade_id = @storage.open_trade(trade)
      @storage.log_event(
        symbol: signal[:symbol], event_type: "trade_opened",
        timeframe: signal[:timeframe], price: entry,
        description: "PAPER #{signal[:direction]} #{signal[:symbol]} @ $#{entry.round(4)} qty=#{qty.round(4)} SL=$#{sl.round(4)} R=#{signal[:rr_ratio]}")
      { success: true, trade_id: trade_id, type: "paper", entry: entry.round(4),
        qty: qty.round(4), sl: sl.round(4), risk_pct: risk_pct }
    end

    def live_execute(signal)
      return paper_execute(signal) unless coindcx_available?

      entry = apply_slippage(signal[:entry_price], signal[:direction] == "LONG")
      sl = signal[:stop_loss]
      qty = compute_quantity(entry, sl, signal[:direction])
      risk_pct = ((entry - sl).abs / entry * 100).round(2)

      if risk_pct > @config.max_risk_per_trade_pct
        return { success: false, reason: "Risk #{risk_pct}% exceeds max #{@config.max_risk_per_trade_pct}%" }
      end

      market_name = signal[:symbol].sub("USDT", "USDT")
      order_type = "market"
      side = signal[:direction] == "LONG" ? "buy" : "sell"

      body = {
        timestamp: (Time.now.to_f * 1000).to_i,
        market: market_name,
        side: side,
        order_type: order_type,
        quantity: qty.to_s
      }
      key = @config.coindcx_api_key
      secret = @config.coindcx_api_secret
      json_body = JSON.generate(body)
      signature = OpenSSL::HMAC.hexdigest("SHA256", secret, json_body)

      uri = URI("https://api.coindcx.com/trade/v1/orders/create")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 10

      req = Net::HTTP::Post.new(uri)
      req["X-AUTH-APIKEY"] = key
      req["X-AUTH-SIGNATURE"] = signature
      req["Content-Type"] = "application/json"
      req.body = json_body

      resp = JSON.parse(http.request(req).body)

      if resp.is_a?(Hash) && resp["id"]
        trade = {
          symbol: signal[:symbol], direction: signal[:direction],
          entry_price: entry.round(4), quantity: qty.round(4),
          stop_loss: sl.round(4),
          take_profit_1: signal[:take_profit_1]&.round(4),
          take_profit_2: signal[:take_profit_2]&.round(4),
          take_profit_3: signal[:take_profit_3]&.round(4),
          entry_reason: signal[:reason],
          strategy: "smc",
          model_name: @config.model,
          metadata: JSON.generate({ order_id: resp["id"], event_type: signal[:event_type],
                                     confidence: signal[:confidence], rr_ratio: signal[:rr_ratio], mode: "live" })
        }
        trade_id = @storage.open_trade(trade)
        @storage.log_event(symbol: signal[:symbol], event_type: "trade_opened",
                           timeframe: signal[:timeframe], price: entry,
                           description: "LIVE #{signal[:direction]} #{signal[:symbol]} @ $#{entry.round(4)} order=#{resp["id"]}")
        { success: true, trade_id: trade_id, order_id: resp["id"], type: "live",
          entry: entry.round(4), qty: qty.round(4), risk_pct: risk_pct }
      else
        { success: false, reason: "CoinDCX order failed: #{resp}" }
      end
    rescue => e
      { success: false, reason: "Live execution error: #{e.message}" }
    end

    def check_exit(trade)
      return unless trade["status"] == "open"

      symbol = trade["symbol"]
      current_price = fetch_price(symbol)
      return unless current_price

      direction = trade["direction"]
      entry = trade["entry_price"].to_f
      sl = trade["stop_loss"].to_f
      tp1 = trade["take_profit_1"]&.to_f
      tp2 = trade["take_profit_2"]&.to_f
      tp3 = trade["take_profit_3"]&.to_f

      return close_trade(trade, current_price, "stop_loss") if direction == "LONG" && current_price <= sl
      return close_trade(trade, current_price, "stop_loss") if direction == "SHORT" && current_price >= sl
      return close_trade(trade, current_price, "take_profit_3") if tp3 && direction == "LONG" && current_price >= tp3
      return close_trade(trade, current_price, "take_profit_3") if tp3 && direction == "SHORT" && current_price <= tp3
    end

    def close_trade(trade_record, exit_price, reason)
      trade = {
        id: trade_record["id"], entry_price: trade_record["entry_price"].to_f,
        exit_price: exit_price, direction: trade_record["direction"],
        quantity: trade_record["quantity"].to_f
      }
      pnl = trade[:direction] == "LONG" ?
        (exit_price - trade[:entry_price]) * trade[:quantity] :
        (trade[:entry_price] - exit_price) * trade[:quantity]
      pnl_pct = ((exit_price / trade[:entry_price]) - 1) * 100
      pnl_pct *= -1 if trade[:direction] == "SHORT"
      rr = (exit_price - trade[:entry_price]).abs / (trade[:entry_price] - trade_record["stop_loss"].to_f).abs

      @storage.close_trade(
        trade_record["id"],
        exit_price: exit_price.round(4),
        pnl: pnl.round(2),
        pnl_pct: pnl_pct.round(2),
        rr_ratio: rr.round(2),
        exit_reason: reason,
        fees: (pnl.abs * [@config.taker_fee, @config.maker_fee].max).round(2)
      )
      @storage.log_event(symbol: trade_record["symbol"], event_type: "trade_closed",
                         price: exit_price, description: "#{reason} PnL=#{pnl.round(2)}")
    end

    private

    def apply_slippage(price, is_buy)
      is_buy ? price * (1 + @slippage) : price * (1 - @slippage)
    end

    def compute_quantity(entry, sl, direction)
      risk_per_trade = @config.initial_balance * (@config.max_risk_per_trade_pct / 100.0) * @config.default_leverage
      risk_per_unit = (entry - sl).abs
      return 0.01 if risk_per_unit <= 0
      (risk_per_trade / risk_per_unit).round(4)
    end

    def coindcx_available?
      @config.coindcx_api_key && @config.coindcx_api_secret &&
        !@config.coindcx_api_key.empty? && !@config.coindcx_api_secret.empty?
    end

    def fetch_price(symbol)
      url = "https://api.binance.com/api/v3/ticker/price?symbol=#{symbol}"
      resp = JSON.parse(Net::HTTP.get(URI(url)))
      resp["price"].to_f
    rescue
      nil
    end
  end
end
