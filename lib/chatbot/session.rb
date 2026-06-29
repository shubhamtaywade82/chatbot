require "securerandom"
require "net/http"
require "uri"
require "json"
require "openssl"
require "ollama_agent"

# Return only custom tools — no built-in coding tools
module OllamaAgent
  def self.tools_for(read_only:, orchestrator:)
    Tools::Registry.custom_schemas
  end
end

# Monkey-patch ChatStreamProcessor to accumulate tool_calls across chunks
module Ollama
  class Client
    class ChatStreamProcessor
      alias_method :orig_process_message_field, :process_message_field
      def process_message_field(obj)
        calls = obj.dig("message", "tool_calls")
        (@acc_tool_calls ||= []).concat(calls) if calls
        orig_process_message_field(obj)
      end

      alias_method :orig_build_result, :build_result
      def build_result
        result = orig_build_result
        calls = @acc_tool_calls
        if calls && !calls.empty?
          result["message"] ||= {}
          result["message"]["tool_calls"] = calls
        end
        result
      end
    end
  end
end

# Fix ChatCoordinator to provide correct hook keys for ollama-client v1.3.0
module OllamaAgent
  class Agent
    class ChatCoordinator
      private

      def ollama_stream_hooks
        turn = -> { @current_turn }
        {
          on_thought: lambda { |event|
            data = event.respond_to?(:data) ? event.data.to_s : event.to_s
            @hooks.emit(:on_thinking, { token: data, turn: turn.call })
          },
          on_token: lambda { |*args|
            token = args[0]
            logprobs = args[1]
            payload = { token: token, turn: turn.call }
            payload[:logprobs] = logprobs unless logprobs.nil?
            @hooks.emit(:on_token, payload)
          },
          on_tool_call: lambda { |tc|
            @hooks.emit(:on_tool_call, {
              name: tc.respond_to?(:name) ? tc.name : tc["name"],
              args: tc.respond_to?(:arguments) ? tc.arguments : tc["arguments"],
              turn: turn.call
            })
          },
          on_complete: lambda {
            @hooks.emit(:on_complete, {})
          }
        }
      end
    end
  end
end

# Register chatbot tools
OllamaAgent::Tools.register("http_get", schema: {
  description: "Fetch any HTTP/HTTPS URL and return the response body. " \
               "Use for API calls (crypto prices, weather, etc.), web pages, or any public URL.",
  parameters: {
    type: "object",
    properties: {
      url: {
        type: "string",
        description: "Full URL to fetch (http:// or https:// only)"
      }
    },
    required: ["url"]
  }
}) do |args, root:, read_only:|
  uri = URI.parse(args["url"].to_s)
  raise "Only http/https allowed" unless %w[http https].include?(uri.scheme)

  Net::HTTP.get(uri)
rescue => e
  "Error: #{e.message}"
end

OllamaAgent::Tools.register("current_time", schema: {
  description: "Get the current date and time. Use when the user asks about today's date, " \
               "current time, day of week, or any time-related question.",
  parameters: {
    type: "object",
    properties: {},
    required: []
  }
}) do |args, root:, read_only:|
  Time.now.strftime("%Y-%m-%d %H:%M:%S %Z")
end

OllamaAgent::Tools.register("calculate", schema: {
  description: "Evaluate a mathematical expression and return the numeric result. " \
               "Supports +, -, *, /, ** (power), and parentheses. " \
               "Use for precise computation rather than mental arithmetic.",
  parameters: {
    type: "object",
    properties: {
      expression: {
        type: "string",
        description: "Arithmetic expression, e.g. '(12 + 8) / 5' or '2 ** 10'"
      }
    },
    required: ["expression"]
  }
}) do |args, root:, read_only:|
  expr = args["expression"].to_s
  raise "Empty expression" if expr.empty?
  raise "Only digits, operators, spaces, parens, and decimal points allowed" unless expr.match?(/\A[\d\s+\-*\/()%.,e]+\z/)

  eval(expr).to_s
rescue => e
  "Error: #{e.message}"
end

# ---------------------------------------------------------------------------
# Market data tools — Binance public API (no auth required)
# ---------------------------------------------------------------------------
BINANCE_API = "https://api.binance.com"

OllamaAgent::Tools.register("fetch_klines", schema: {
  description: "Get OHLCV candlestick data for a cryptocurrency trading pair from Binance. " \
               "Returns open, high, low, close, volume for each candle. " \
               "Use for technical analysis, chart patterns, and SMC level detection.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT', 'BTCUSDT', 'ETHUSDT'"
      },
      interval: {
        type: "string",
        description: "Candle interval: 1m, 5m, 15m, 30m, 1h, 4h, 1d, 1w, 1M"
      },
      limit: {
        type: "integer",
        description: "Number of candles to return (max 1000, default 100)"
      }
    },
    required: ["symbol", "interval"]
  }
}) do |args, root:, read_only:|
  symbol = args["symbol"].to_s.upcase.strip
  interval = args["interval"].to_s.strip
  limit = args["limit"] || 100
  url = "#{BINANCE_API}/api/v3/klines?symbol=#{symbol}&interval=#{interval}&limit=#{limit}"
  JSON.parse(Net::HTTP.get(URI(url))).map do |k|
    {
      time: Time.at(k[0] / 1000).utc.strftime("%Y-%m-%d %H:%M"),
      open: k[1].to_f, high: k[2].to_f, low: k[3].to_f, close: k[4].to_f,
      volume: k[5].to_f
    }
  end.to_s
rescue => e
  "Error: #{e.message}"
end

OllamaAgent::Tools.register("fetch_ticker", schema: {
  description: "Get 24-hour ticker statistics for a cryptocurrency trading pair from Binance. " \
               "Includes current price, 24h change, high, low, volume, and more. " \
               "Use for current market snapshot and momentum assessment.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT', 'BTCUSDT', 'ETHUSDT'"
      }
    },
    required: ["symbol"]
  }
}) do |args, root:, read_only:|
  symbol = args["symbol"].to_s.upcase.strip
  url = "#{BINANCE_API}/api/v3/ticker/24hr?symbol=#{symbol}"
  data = JSON.parse(Net::HTTP.get(URI(url)))
  {
    symbol: data["symbol"],
    price: data["lastPrice"].to_f,
    change_24h: data["priceChange"].to_f,
    change_percent: data["priceChangePercent"].to_f,
    high_24h: data["highPrice"].to_f,
    low_24h: data["lowPrice"].to_f,
    volume: data["volume"].to_f,
    quote_volume: data["quoteVolume"].to_f,
    weighted_avg_price: data["weightedAvgPrice"].to_f
  }.to_s
rescue => e
  "Error: #{e.message}"
end

OllamaAgent::Tools.register("fetch_orderbook", schema: {
  description: "Get current order book depth for a cryptocurrency trading pair from Binance. " \
               "Returns top bids and asks with price and quantity. " \
               "Use for liquidity analysis, support/resistance levels, and order flow.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT', 'BTCUSDT', 'ETHUSDT'"
      },
      limit: {
        type: "integer",
        description: "Number of price levels per side (5, 10, 20, 50, 100, 500, 1000; default 20)"
      }
    },
    required: ["symbol"]
  }
}) do |args, root:, read_only:|
  symbol = args["symbol"].to_s.upcase.strip
  limit = args["limit"] || 20
  url = "#{BINANCE_API}/api/v3/depth?symbol=#{symbol}&limit=#{limit}"
  data = JSON.parse(Net::HTTP.get(URI(url)))
  format_level = ->(level) { { price: level[0].to_f, qty: level[1].to_f } }
  {
    symbol: symbol,
    bids: data["bids"].map(&format_level),
    asks: data["asks"].map(&format_level)
  }.to_s
rescue => e
  "Error: #{e.message}"
end

# ---------------------------------------------------------------------------
# SMC analysis engine — reusable across single-TF and multi-TF tools
# ---------------------------------------------------------------------------
module SMC
  # Fetch klines from Binance Spot and parse into candle hashes
  def self.fetch_candles(symbol, interval, limit: 150)
    url = "#{BINANCE_API}/api/v3/klines?symbol=#{symbol}&interval=#{interval}&limit=#{limit}"
    raw = JSON.parse(Net::HTTP.get(URI(url)))
    raw.map do |k|
      {
        time: k[0] / 1000,
        open: k[1].to_f, high: k[2].to_f, low: k[3].to_f, close: k[4].to_f,
        volume: k[5].to_f
      }
    end
  end

  # Analyze candles and return structured SMC hash
  def self.analyze(candles, symbol, interval)
    # Market structure: find swing highs/lows
    swings = []
    candles.each_cons(3) do |prev, cur, nxt|
      swings << { type: "swing_high", price: cur[:high] } if cur[:high] > prev[:high] && cur[:high] > nxt[:high]
      swings << { type: "swing_low",  price: cur[:low] }  if cur[:low]  < prev[:low]  && cur[:low]  < nxt[:low]
    end

    recent_highs = swings.select { |s| s[:type] == "swing_high" }.last(5).map { |s| s[:price] }
    recent_lows  = swings.select { |s| s[:type] == "swing_low"  }.last(5).map { |s| s[:price] }

    trend = if recent_highs.size >= 2 && recent_lows.size >= 2
      if recent_highs[-1] > recent_highs[-2] && recent_lows[-1] > recent_lows[-2]
        "uptrend"
      elsif recent_highs[-1] < recent_highs[-2] && recent_lows[-1] < recent_lows[-2]
        "downtrend"
      else
        "ranging"
      end
    else
      "insufficient_data"
    end

    # Order blocks: candle before a strong impulsive move
    order_blocks = []
    candles.each_cons(2) do |prev, cur|
      body_prev = (prev[:close] - prev[:open]).abs
      body_cur  = (cur[:close] - cur[:open]).abs
      range_cur = (cur[:high] - cur[:low]).abs
      if range_cur > 0 && body_cur / range_cur > 0.6 && body_cur > body_prev * 1.5
        direction = cur[:close] > cur[:open] ? "bullish" : "bearish"
        order_blocks << {
          direction: direction,
          zone: direction == "bullish" ? [prev[:low], prev[:high]] : [prev[:high], prev[:low]],
          strength: body_cur > body_prev * 2.5 ? "strong" : "moderate"
        }
      end
    end

    # Fair Value Gaps: 3-candle imbalance
    fvgs = []
    candles.each_cons(3) do |c1, c2, c3|
      if c2[:high] < c3[:low]
        fvgs << { type: "bullish_fvg", zone: [c2[:high], c3[:low]] }
      elsif c2[:low] > c1[:high]
        fvgs << { type: "bearish_fvg", zone: [c1[:high], c2[:low]] }
      end
    end

    last = candles.last
    current_price = last[:close]

    {
      symbol: symbol,
      interval: interval,
      current_price: current_price,
      candles_count: candles.size,
      market_structure: {
        trend: trend,
        last_swing_high: recent_highs.last,
        last_swing_low: recent_lows.last
      },
      key_levels: {
        resistance: recent_highs.last(3),
        support: recent_lows.last(3)
      },
      order_blocks: order_blocks.last(5).map { |ob|
        dir_icon = ob[:direction] == "bullish" ? "🟢" : "🔴"
        zone_str = "$#{ob[:zone].min} - $#{ob[:zone].max}"
        "#{dir_icon} #{ob[:direction]} OB #{zone_str} (#{ob[:strength]})"
      },
      fair_value_gaps: fvgs.last(5).map { |fg|
        type_icon = fg[:type] == "bullish_fvg" ? "🟢" : "🔴"
        "#{type_icon} #{fg[:type]} $#{fg[:zone].min} - $#{fg[:zone].max}"
      },
      trade_bias: case trend
      when "uptrend" then "Bullish"
      when "downtrend" then "Bearish"
      else "Neutral"
      end
    }
  end
end

# ---------------------------------------------------------------------------
# SMC single-timeframe tool
# ---------------------------------------------------------------------------
OllamaAgent::Tools.register("find_smc_levels", schema: {
  description: "Perform Smart Money Concepts (SMC) analysis on one timeframe. " \
               "Returns trend, swing-highs/lows, order blocks, and fair value gaps. " \
               "For a complete picture across multiple timeframes use analyze_multi_tf.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT', 'BTCUSDT', 'ETHUSDT'"
      },
      interval: {
        type: "string",
        description: "Candle interval: 1m, 5m, 15m, 30m, 1h, 4h, 1d, 1w (default: 1h)"
      }
    },
    required: ["symbol"]
  }
}) do |args, **|
  symbol = args["symbol"].to_s.upcase.strip
  interval = args["interval"] || "1h"
  candles = SMC.fetch_candles(symbol, interval)
  result = SMC.analyze(candles, symbol, interval)
  result[:timestamp] = Time.now.utc.strftime("%Y-%m-%d %H:%M UTC")
  result.to_s
rescue => e
  "Error: #{e.message}"
end

# ---------------------------------------------------------------------------
# Multi-timeframe analysis + trading style support
# ---------------------------------------------------------------------------
TRADING_STYLES = {
  "scalping"   => { entry: "1m",  trend: "5m",  label: "Scalping (seconds-minutes)" },
  "intraday"   => { entry: "15m", trend: "1h",  label: "Intraday (minutes-hours)" },
  "swing"      => { entry: "1h",  trend: "4h",  macro: "1d",  label: "Swing (hours-days)" },
  "positional" => { entry: "4h",  trend: "1d",  macro: "1w",  label: "Positional (days-weeks)" }
}.freeze

OllamaAgent::Tools.register("analyze_multi_tf", schema: {
  description: "Multi-timeframe SMC analysis with trading style support. " \
               "Automatically selects the right timeframes for your style: " \
               "scalping (1m/5m), intraday (15m/1h), swing (1h/4h/1d), positional (4h/1d/1w). " \
               "For each timeframe returns trend, order blocks, and FVGs. " \
               "Provides confluence assessment and specific trade setup recommendations. " \
               "Use this as the primary entry analysis tool — it replaces multiple find_smc_levels calls.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT', 'BTCUSDT'"
      },
      trading_style: {
        type: "string",
        enum: ["scalping", "intraday", "swing", "positional"],
        description: "Your trading style. Determines which timeframes are analyzed. (default: swing)"
      }
    },
    required: ["symbol"]
  }
}) do |args, **|
  symbol = args["symbol"].to_s.upcase.strip
  style = (args["trading_style"] || "swing").to_s.downcase.strip
  tf = TRADING_STYLES[style]
  next "Unknown style: #{style}. Choose: scalping, intraday, swing, positional" unless tf

  # Fetch + analyze each timeframe
  levels = {}
  tfs = [tf[:entry], tf[:trend]]
  tfs << tf[:macro] if tf[:macro]

  tfs.each do |interval|
    candles = SMC.fetch_candles(symbol, interval, limit: 100)
    levels[interval] = SMC.analyze(candles, symbol, interval)
  end

  # Confluence: do all timeframes agree?
  trends = levels.values.map { |l| l[:market_structure][:trend] }
  unique_trends = trends.uniq
  aligned = unique_trends.size == 1
  majority_trend = trends.max_by { |t| trends.count(t) }

  # Determine entry bias
  entry_trend = levels[tf[:entry]][:market_structure][:trend]
  trend_trend = levels[tf[:trend]][:market_structure][:trend]
  macro_trend = tf[:macro] ? levels[tf[:macro]][:market_structure][:trend] : nil

  bias = if aligned
    case majority_trend
    when "uptrend"   then "Strong bullish — all TFs aligned. Look for long entries on pullbacks to OBs."
    when "downtrend" then "Strong bearish — all TFs aligned. Look for short entries on rallies to OBs."
    else "Ranging — wait for BOS/CHoCH before entering."
    end
  else
    if macro_trend == "uptrend" && entry_trend == "downtrend"
      "Bullish on higher TF, bearish on entry TF — possible pullback. Wait for HTF support and entry-TF reversal."
    elsif macro_trend == "downtrend" && entry_trend == "uptrend"
      "Bearish on higher TF, bullish on entry TF — possible relief rally. Wait for HTF resistance and entry-TF rejection."
    else
      "Mixed signals — reduce position size or wait for clearer alignment."
    end
  end

  # Build result
  tf_sections = tfs.map do |interval|
    l = levels[interval]
    role = case interval
           when tf[:entry] then "ENTRY"
           when tf[:trend] then "TREND"
           else "MACRO"
           end
    ob_lines = l[:order_blocks].empty? ? "  (none)" : l[:order_blocks].map { |ob| "  #{ob}" }.join("\n")
    fvg_lines = l[:fair_value_gaps].empty? ? "  (none)" : l[:fair_value_gaps].map { |fg| "  #{fg}" }.join("\n")
    <<~SECTION.chomp
      [#{role} #{interval}] #{l[:market_structure][:trend]} @ $#{l[:current_price]}
        Swing high: $#{l[:market_structure][:last_swing_high] || "N/A"}
        Swing low:  $#{l[:market_structure][:last_swing_low] || "N/A"}
        OBs:
        #{ob_lines}
        FVGs:
        #{fvg_lines}
    SECTION
  end.join("\n")

  result = <<~RESULT
    Multi-Timeframe SMC Analysis: #{symbol}
    Style: #{style} — #{tf[:label]}
    Time: #{Time.now.utc.strftime("%Y-%m-%d %H:%M UTC")}
    Current Price: $#{levels[tf[:entry]][:current_price]}

    #{tf_sections}

    Confluence: #{aligned ? "✅ All timeframes aligned" : "⚠️ Timeframes disagree"}
    Bias: #{bias}
  RESULT
  result
rescue => e
  "Error: #{e.message}"
end

# ---------------------------------------------------------------------------
# Binance Futures API helper — HMAC SHA256 signed requests
# ---------------------------------------------------------------------------
BINANCE_FUTURES = "https://fapi.binance.com"

module BinanceFutures
  def self.signed_request(method, path, params = {})
    key = ENV["CHAT_BINANCE_API_KEY"].to_s.strip
    secret = ENV["CHAT_BINANCE_API_SECRET"].to_s.strip
    return { error: "Binance API key not configured. Set CHAT_BINANCE_API_KEY and CHAT_BINANCE_API_SECRET." }.to_s if key.empty? || secret.empty?

    params[:timestamp] = (Time.now.to_f * 1000).to_i
    params[:recvWindow] = 5000
    query = params.sort.map { |k, v| "#{k}=#{v}" }.join("&")
    signature = OpenSSL::HMAC.hexdigest("SHA256", secret, query)
    uri = URI("#{BINANCE_FUTURES}#{path}?#{query}&signature=#{signature}")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 10

    req = case method
          when :post   then Net::HTTP::Post.new(uri)
          when :delete then Net::HTTP::Delete.new(uri)
          else              Net::HTTP::Get.new(uri)
          end
    req["X-MBX-APIKEY"] = key

    JSON.parse(http.request(req).body)
  rescue => e
    { error: e.message }
  end

  def self.public_get(path, params = {})
    uri = URI("#{BINANCE_FUTURES}#{path}")
    uri.query = URI.encode_www_form(params) unless params.empty?
    JSON.parse(Net::HTTP.get(uri))
  rescue => e
    { error: e.message }
  end
end

# ---------------------------------------------------------------------------
# Trading execution tools — Binance Futures (requires API key)
# ---------------------------------------------------------------------------
OllamaAgent::Tools.register("get_account_balance", schema: {
  description: "Get Binance Futures account balance and margin information. " \
               "Returns available balance, wallet balance, cross wallet balance, and margin info per asset. " \
               "Use before trading to verify available funds.",
  parameters: {
    type: "object",
    properties: {},
    required: []
  }
}) do |args, **|
  data = BinanceFutures.signed_request(:get, "/fapi/v2/account")
  next data.to_s if data.is_a?(Hash) && data[:error]

  assets = (data["assets"] || []).map do |a|
    {
      asset: a["asset"],
      wallet_balance: a["walletBalance"].to_f,
      cross_wallet: a["crossWalletBalance"].to_f,
      available: a["availableBalance"].to_f,
      margin: a["marginBalance"].to_f
    }
  end
  { assets: assets, total_wallet: assets.sum { |a| a[:wallet_balance] } }.to_s
end

OllamaAgent::Tools.register("get_positions", schema: {
  description: "Get all open positions for Binance Futures. " \
               "Returns entry price, liquidation price, unrealized PnL, leverage, position size, and margin. " \
               "Use to check current exposure before opening new trades.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT'. Optional — omit to get all positions."
      }
    },
    required: []
  }
}) do |args, **|
  params = {}
  symbol = args["symbol"].to_s.strip.upcase
  params[:symbol] = symbol unless symbol.empty?
  data = BinanceFutures.signed_request(:get, "/fapi/v2/positionRisk", params)
  next data.to_s if data.is_a?(Hash) && data[:error]

  positions = (data.is_a?(Array) ? data : [data]).select { |p| p["positionAmt"].to_f != 0 }
  next "No open positions." if positions.empty?

  positions.map do |p|
    {
      symbol: p["symbol"],
      side: p["positionAmt"].to_f > 0 ? "LONG" : "SHORT",
      size: p["positionAmt"].to_f.abs,
      entry_price: p["entryPrice"].to_f,
      mark_price: p["markPrice"].to_f,
      liquidation_price: p["liquidationPrice"].to_f,
      leverage: p["leverage"].to_f,
      unrealized_pnl: p["unRealizedProfit"].to_f,
      margin: p["isolatedMargin"].to_f
    }
  end.to_s
end

OllamaAgent::Tools.register("set_leverage", schema: {
  description: "Set leverage for a Binance Futures trading pair. " \
               "Always call this before placing a trade to ensure correct leverage. " \
               "Max leverage depends on the symbol and your account tier.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT'"
      },
      leverage: {
        type: "integer",
        description: "Leverage value (1-125 depending on symbol)"
      }
    },
    required: ["symbol", "leverage"]
  }
}) do |args, **|
  symbol = args["symbol"].to_s.upcase.strip
  leverage = args["leverage"].to_i
  data = BinanceFutures.signed_request(:post, "/fapi/v1/leverage", symbol: symbol, leverage: leverage)
  data.to_s
end

OllamaAgent::Tools.register("place_order", schema: {
  description: "Place an order on Binance Futures. Supports MARKET, LIMIT, STOP, TAKE_PROFIT orders. " \
               "⚠️ ONLY call this when the user explicitly confirms they want to execute a trade. " \
               "Always present the trade details first and ask for confirmation. " \
               "For MARKET orders, price is not needed. For LIMIT orders, price is required.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT'"
      },
      side: {
        type: "string",
        enum: ["BUY", "SELL"],
        description: "BUY for long, SELL for short"
      },
      type: {
        type: "string",
        enum: ["MARKET", "LIMIT", "STOP", "STOP_MARKET", "TAKE_PROFIT", "TAKE_PROFIT_MARKET"],
        description: "Order type. MARKET = execute immediately at best price. LIMIT = set a specific price."
      },
      quantity: {
        type: "number",
        description: "Position size in base asset units (e.g. 0.5 SOL). Use position_sizing tool to calculate."
      },
      price: {
        type: "number",
        description: "Limit price (required for LIMIT, STOP, TAKE_PROFIT orders). Not used for MARKET."
      },
      stopPrice: {
        type: "number",
        description: "Stop trigger price (required for STOP orders only)"
      },
      reduceOnly: {
        type: "boolean",
        description: "If true, the order will only reduce an existing position. Use for stop losses."
      },
      timeInForce: {
        type: "string",
        enum: ["GTC", "IOC", "FOK"],
        description: "GTC = Good till cancelled, IOC = Immediate or Cancel, FOK = Fill or Kill (default: GTC)"
      }
    },
    required: ["symbol", "side", "type", "quantity"]
  }
}) do |args, **|
  symbol = args["symbol"].to_s.upcase.strip
  side = args["side"].to_s.upcase.strip
  type = args["type"].to_s.upcase.strip
  quantity = args["quantity"].to_s

  params = { symbol: symbol, side: side, type: type, quantity: quantity }
  params[:price] = args["price"].to_s if args["price"]
  params[:stopPrice] = args["stopPrice"].to_s if args["stopPrice"]
  params[:reduceOnly] = true if args["reduceOnly"]
  params[:timeInForce] = args["timeInForce"] if args["timeInForce"]

  data = BinanceFutures.signed_request(:post, "/fapi/v1/order", params)
  data.to_s
end

OllamaAgent::Tools.register("cancel_order", schema: {
  description: "Cancel an open order on Binance Futures by symbol and order ID.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT'"
      },
      orderId: {
        type: "integer",
        description: "Order ID to cancel (from get_open_orders)"
      }
    },
    required: ["symbol", "orderId"]
  }
}) do |args, **|
  symbol = args["symbol"].to_s.upcase.strip
  order_id = args["orderId"].to_i
  data = BinanceFutures.signed_request(:delete, "/fapi/v1/order", symbol: symbol, orderId: order_id)
  data.to_s
end

OllamaAgent::Tools.register("get_open_orders", schema: {
  description: "List all open orders on Binance Futures. " \
               "Use to check pending orders before placing new ones or to find order IDs to cancel.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT'. Optional — omit to get all open orders."
      }
    },
    required: []
  }
}) do |args, **|
  params = {}
  symbol = args["symbol"].to_s.strip.upcase
  params[:symbol] = symbol unless symbol.empty?
  data = BinanceFutures.signed_request(:get, "/fapi/v1/openOrders", params)
  data.to_s
end

OllamaAgent::Tools.register("get_funding_rate", schema: {
  description: "Get current and historical funding rates for a Binance Futures pair. " \
               "Positive funding = longs pay shorts (bearish sentiment). " \
               "Negative funding = shorts pay longs (bullish sentiment). " \
               "Use to assess market sentiment and cost of holding positions overnight.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT'"
      },
      limit: {
        type: "integer",
        description: "Number of records to return (default: 5, max: 1000)"
      }
    },
    required: ["symbol"]
  }
}) do |args, **|
  symbol = args["symbol"].to_s.upcase.strip
  limit = args["limit"] || 5
  data = BinanceFutures.public_get("/fapi/v1/fundingRate", symbol: symbol, limit: limit)
  next data.to_s if data.is_a?(Hash) && data[:error]

  # Also get predicted funding rate
  premium = BinanceFutures.public_get("/fapi/v1/premiumIndex", symbol: symbol)
  predicted = premium.is_a?(Hash) ? premium["lastFundingRate"] : nil

  rates = (data.is_a?(Array) ? data : []).map do |r|
    {
      time: Time.at(r["fundingTime"].to_i / 1000).utc.strftime("%Y-%m-%d %H:%M"),
      rate: (r["fundingRate"].to_f * 100).round(4).to_s + "%"
    }
  end
  {
    symbol: symbol,
    current_rate: (premium.is_a?(Hash) ? premium["lastFundingRate"].to_f * 100 : nil)&.round(4)&.to_s + "%",
    predicted_rate: predicted ? (predicted.to_f * 100).round(4).to_s + "%" : "N/A",
    countdown_to_next: premium.is_a?(Hash) ? "#{((premium["countDownTime"].to_i / 1000) / 3600).round(1)}h" : "N/A",
    history: rates
  }.to_s
end

OllamaAgent::Tools.register("get_open_interest", schema: {
  description: "Get current open interest for a Binance Futures trading pair. " \
               "High and rising OI confirms trend strength. " \
               "High and falling OI suggests trend weakening / liquidation cascade. " \
               "Use alongside SMC analysis for confluence.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT'"
      }
    },
    required: ["symbol"]
  }
}) do |args, **|
  symbol = args["symbol"].to_s.upcase.strip
  oi = BinanceFutures.public_get("/fapi/v1/openInterest", symbol: symbol)
  oi_hist = BinanceFutures.public_get("/fapi/v1/openInterestHist", symbol: symbol, period: "1h", limit: 24)
  current = oi.is_a?(Hash) ? oi["openInterest"].to_f : nil
  history = (oi_hist.is_a?(Array) ? oi_hist : []).map { |h| { time: h["timestamp"], oi: h["sumOpenInterest"].to_f } }
  change_24h = history.size >= 2 ? ((history.last[:oi] - history.first[:oi]) / history.first[:oi] * 100).round(2) : nil
  {
    symbol: symbol,
    current_open_interest: current,
    change_24h_percent: change_24h,
    note: change_24h && change_24h > 10 ? "OI rising significantly — strong trend" :
          change_24h && change_24h < -10 ? "OI dropping — possible reversal" :
          "OI stable — trend confirmation needed"
  }.to_s
end

# ---------------------------------------------------------------------------
# Risk management tools
# ---------------------------------------------------------------------------
OllamaAgent::Tools.register("position_sizing", schema: {
  description: "Calculate the optimal position size for a trade based on risk percentage and stop loss. " \
               "Use this BEFORE place_order to determine how many units to trade. " \
               "Risk 1-2% per trade as a general rule.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT'"
      },
      entry_price: {
        type: "number",
        description: "Planned entry price for the trade"
      },
      stop_loss: {
        type: "number",
        description: "Stop loss price"
      },
      risk_percent: {
        type: "number",
        description: "Percentage of available balance to risk (e.g. 1.0 = 1%%, 2.0 = 2%%). Default: 1.0"
      },
      leverage: {
        type: "integer",
        description: "Leverage to use (default: 1)"
      }
    },
    required: ["symbol", "entry_price", "stop_loss"]
  }
}) do |args, **|
  symbol = args["symbol"].to_s.upcase.strip
  entry = args["entry_price"].to_f
  stop = args["stop_loss"].to_f
  risk_pct = (args["risk_percent"] || 1.0).to_f
  lev = (args["leverage"] || 1).to_i
  lev = 1 if lev < 1

  # Get available balance
  acct = BinanceFutures.signed_request(:get, "/fapi/v2/account")
  next "Error: cannot fetch account" if acct.is_a?(Hash) && acct[:error]

  balance = (acct["assets"] || []).find { |a| a["asset"] == "USDT" }
  next "Error: USDT balance not found" unless balance

  available = balance["availableBalance"].to_f
  risk_amount = available * (risk_pct / 100.0) * lev
  price_diff = (entry - stop).abs
  quantity = price_diff > 0 ? (risk_amount / price_diff).round(3) : 0

  # Get step size / lot size filter for precision
  info = BinanceFutures.public_get("/fapi/v1/exchangeInfo")
  symbol_info = (info["symbols"] || []).find { |s| s["symbol"] == symbol } if info.is_a?(Hash)
  filters = (symbol_info["filters"] || []) if symbol_info
  lot_size = filters.find { |f| f["filterType"] == "LOT_SIZE" } if filters
  step_size = lot_size ? lot_size["stepSize"].to_f : 0.001
  precision = step_size > 0 ? [Math.log10(1.0 / step_size).ceil, 0].max : 3
  quantity = (quantity / step_size).floor * step_size if step_size > 0

  {
    symbol: symbol,
    available_balance: available,
    risk_percent: risk_pct,
    risk_amount_usdt: (risk_amount / lev).round(2),
    leverage: lev,
    quantity: quantity.round(precision),
    entry_price: entry,
    stop_loss: stop,
    stop_distance_percent: (price_diff / entry * 100).round(2),
    max_loss_usdt: (quantity * price_diff / lev).round(2)
  }.to_s
end

OllamaAgent::Tools.register("risk_check", schema: {
  description: "Analyze the risk of a proposed trade before execution. " \
               "Checks current positions, available margin, distance to liquidation, " \
               "and portfolio exposure. Call this BEFORE place_order when the user requests a trade. " \
               "If risk is acceptable, ask the user to confirm before placing the order.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT'"
      },
      side: {
        type: "string",
        enum: ["BUY", "SELL"],
        description: "BUY for long, SELL for short"
      },
      entry_price: {
        type: "number",
        description: "Planned entry price"
      },
      quantity: {
        type: "number",
        description: "Planned position size in base asset units"
      },
      stop_loss: {
        type: "number",
        description: "Stop loss price"
      },
      leverage: {
        type: "integer",
        description: "Leverage to use"
      }
    },
    required: ["symbol", "side", "entry_price", "quantity", "stop_loss", "leverage"]
  }
}) do |args, **|
  symbol = args["symbol"].to_s.upcase.strip
  side = args["side"].to_s.upcase.strip
  entry = args["entry_price"].to_f
  qty = args["quantity"].to_f
  sl = args["stop_loss"].to_f
  lev = args["leverage"].to_i
  lev = 1 if lev < 1

  acct = BinanceFutures.signed_request(:get, "/fapi/v2/account")
  next "Error: cannot fetch account" if acct.is_a?(Hash) && acct[:error]

  balance = (acct["assets"] || []).find { |a| a["asset"] == "USDT" }
  next "Error: USDT balance not found" unless balance

  available = balance["availableBalance"].to_f
  wallet = balance["walletBalance"].to_f
  positions = (BinanceFutures.signed_request(:get, "/fapi/v2/positionRisk") rescue [])
  existing = (positions.is_a?(Array) ? positions : []).select { |p| p["symbol"] == symbol && p["positionAmt"].to_f != 0 }

  position_value = entry * qty
  margin_used = position_value / lev
  risk_per_trade = ((entry - sl).abs * qty) / lev
  risk_pct = available > 0 ? (risk_per_trade / available * 100).round(2) : 0

  # Estimate liquidation price (simplified: cross-margin)
  liq_price = side == "BUY" ? entry - (entry / lev) : entry + (entry / lev)

  warnings = []
  warnings << "⚠️ Risking #{risk_pct}% of available balance (recommended max: 2%)" if risk_pct > 2
  warnings << "⚠️ High leverage (#{lev}x)" if lev > 10
  warnings << "⚠️ Existing position in #{symbol}" unless existing.empty?
  warnings << "⚠️ Insufficient balance (#{available.round(2)} USDT available, need #{margin_used.round(2)})" if margin_used > available

  {
    symbol: symbol,
    side: side,
    assessment: warnings.empty? ? "✅ Trade risk is acceptable" : "⚠️ Review warnings",
    available_balance: available.round(2),
    wallet_balance: wallet.round(2),
    position_value: position_value.round(2),
    margin_required: margin_used.round(2),
    margin_used_percent: (margin_used / [wallet, 1].max * 100).round(2),
    risk_per_trade_usdt: risk_per_trade.round(2),
    risk_percent_of_balance: risk_pct,
    estimated_liquidation_price: liq_price.round(2),
    distance_to_liquidation: "#{((entry - liq_price).abs / entry * 100).round(2)}%",
    stop_loss_percent: ((entry - sl).abs / entry * 100).round(2),
    warnings: warnings
  }.to_s
end

# ---------------------------------------------------------------------------
# Session — orchestrates config + runner + env
# ---------------------------------------------------------------------------
module Chatbot
  class Session
    SYSTEM_PROMPT = "You are an automated crypto futures trading agent with SMC expertise. " \
                    "Always fetch LIVE data — never make up prices or levels. " \
                    "Analyze with: analyze_multi_tf (MULTI-TIMEFRAME — primary entry tool, use trading_style: scalping/intraday/swing/positional), " \
                    "find_smc_levels (single timeframe), fetch_klines, fetch_ticker, fetch_orderbook, " \
                    "get_funding_rate, get_open_interest. " \
                    "Manage risk with: position_sizing, risk_check. " \
                    "Check state: get_account_balance, get_positions, get_open_orders. " \
                    "Execute only after user confirms: set_leverage, place_order, cancel_order. " \
                    "Never place an order without risk_check first and user confirmation."

    def initialize(config)
      @config = config
      @session_id = SecureRandom.uuid
      set_ollama_env(config)
      build_runner
    end

    def chat(input)
      @runner.run(input)
    rescue => e
      { error: e.message }
    end

    def reset!
      @session_id = SecureRandom.uuid
      build_runner
      "History cleared."
    end

    def switch_model(name)
      @config.model = name
      reset!
    end

    private

    def build_runner
      @runner = OllamaAgent::Runner.build(
        model: @config.model,
        system_prompt: SYSTEM_PROMPT,
        stream: true,
        read_only: true,
        skills_enabled: false,
        think: nil,
        http_timeout: @config.timeout,
        session_id: @session_id,
        resume: false
      )
    end

    def set_ollama_env(config)
      ENV["OLLAMA_BASE_URL"] = config.base_url
      ENV["OLLAMA_API_KEY"] = config.api_keys if config.api_keys&.length&.positive?
      ENV["OLLAMA_AGENT_SKILLS"] = "0"
      ENV["OLLAMA_AGENT_EXTERNAL_SKILLS"] = "0"
      ENV.delete("OLLAMA_AGENT_THINK")
      ENV["CHAT_BINANCE_API_KEY"] = config.binance_api_key if config.binance_api_key
      ENV["CHAT_BINANCE_API_SECRET"] = config.binance_api_secret if config.binance_api_secret
    end
  end
end
