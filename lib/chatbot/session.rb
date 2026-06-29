require "securerandom"
require "net/http"
require "uri"
require "json"
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
# SMC Analysis tool — computes Smart Money Concepts levels from live data
# ---------------------------------------------------------------------------
OllamaAgent::Tools.register("find_smc_levels", schema: {
  description: "Perform Smart Money Concepts (SMC) analysis on a trading pair. " \
               "Automatically fetches live klines and computes: market structure (trend), " \
               "swing highs/lows, order blocks (institutional entry zones), " \
               "fair value gaps (FVGs), and key support/resistance levels. " \
               "Use this as the primary tool for trade entry analysis.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT', 'BTCUSDT', 'ETHUSDT'"
      },
      interval: {
        type: "string",
        description: "Candle interval for analysis: 1h, 4h, 1d (default: 1h)"
      }
    },
    required: ["symbol"]
  }
}) do |args, root:, read_only:|
  symbol = args["symbol"].to_s.upcase.strip
  interval = args["interval"] || "1h"

  # Fetch klines
  url = "#{BINANCE_API}/api/v3/klines?symbol=#{symbol}&interval=#{interval}&limit=150"
  raw = JSON.parse(Net::HTTP.get(URI(url)))
  candles = raw.map do |k|
    {
      time: k[0] / 1000,
      open: k[1].to_f, high: k[2].to_f, low: k[3].to_f, close: k[4].to_f,
      volume: k[5].to_f, close_time: k[6] / 1000
    }
  end

  # --- Market structure: find swing highs/lows ---
  swings = []
  candles.each_cons(3) do |prev, cur, nxt|
    swings << { type: "swing_high", price: cur[:high], time: Time.at(cur[:time]).utc.strftime("%H:%M %m/%d") } if cur[:high] > prev[:high] && cur[:high] > nxt[:high]
    swings << { type: "swing_low", price: cur[:low], time: Time.at(cur[:time]).utc.strftime("%H:%M %m/%d") } if cur[:low] < prev[:low] && cur[:low] < nxt[:low]
  end

  recent_highs = swings.select { |s| s[:type] == "swing_high" }.last(5).map { |s| s[:price] }
  recent_lows  = swings.select { |s| s[:type] == "swing_low" }.last(5).map { |s| s[:price] }

  # Determine trend: compare recent swing pattern
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

  # --- Order blocks: find the candle before a strong impulsive move ---
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
        time: Time.at(prev[:time]).utc.strftime("%H:%M %m/%d"),
        strength: body_cur > body_prev * 2.5 ? "strong" : "moderate"
      }
    end
  end

  # --- Fair Value Gaps (FVGs): 3-candle imbalance ---
  fvgs = []
  candles.each_cons(3) do |c1, c2, c3|
    fvg_top = [c1[:high], c2[:high], c3[:high]].min
    fvg_bot = [c1[:low], c2[:low], c3[:low]].max
    if c2[:high] < c3[:low]
      fvgs << { type: "bullish_fvg", zone: [c2[:high], c3[:low]], time: Time.at(c2[:time]).utc.strftime("%H:%M %m/%d") }
    elsif c2[:low] > c1[:high]
      fvgs << { type: "bearish_fvg", zone: [c1[:high], c2[:low]], time: Time.at(c2[:time]).utc.strftime("%H:%M %m/%d") }
    end
  end

  # --- Key levels from order book ---
  ob_url = "#{BINANCE_API}/api/v3/depth?symbol=#{symbol}&limit=100"
  ob_raw = JSON.parse(Net::HTTP.get(URI(ob_url)))
  bid_levels = ob_raw["bids"].map { |b| b[0].to_f }
  ask_levels = ob_raw["asks"].map { |a| a[0].to_f }
  bid_liquidity = (bid_levels.first(5).sum / 5).round(2) unless bid_levels.empty?
  ask_liquidity = (ask_levels.first(5).sum / 5).round(2) unless ask_levels.empty?

  last = candles.last
  current_price = last[:close]

  # Build result
  result = {
    symbol: symbol,
    interval: interval,
    current_price: current_price,
    timestamp: Time.now.utc.strftime("%Y-%m-%d %H:%M UTC"),
    market_structure: {
      trend: trend,
      last_swing_high: recent_highs.last,
      last_swing_low: recent_lows.last
    },
    key_levels: {
      resistance: recent_highs.last(3),
      support: recent_lows.last(3),
      order_book_bid_wall: bid_liquidity,
      order_book_ask_wall: ask_liquidity
    },
    order_blocks: order_blocks.last(5).map { |ob|
      dir_icon = ob[:direction] == "bullish" ? "🟢" : "🔴"
      zone_str = ob[:zone].is_a?(Array) ? "$#{ob[:zone].min} - $#{ob[:zone].max}" : "$#{ob[:zone]}"
      "#{dir_icon} #{ob[:direction]} OB at #{zone_str} (#{ob[:strength]}, #{ob[:time]})"
    },
    fair_value_gaps: fvgs.last(5).map { |fg|
      type_icon = fg[:type] == "bullish_fvg" ? "🟢" : "🔴"
      "#{type_icon} #{fg[:type]} at $#{fg[:zone].min} - $#{fg[:zone].max} (#{fg[:time]})"
    },
    trade_bias: case trend
    when "uptrend" then "Bullish — look for buy entries at order blocks or FVG fills"
    when "downtrend" then "Bearish — look for sell entries at order blocks or FVG fills"
    else "Neutral — wait for BOS/CHoCH confirmation"
    end
  }
  result.to_s
rescue => e
  "Error: #{e.message}"
end

module Chatbot
  class Session
    SYSTEM_PROMPT = "You are a crypto trading analyst with Smart Money Concepts (SMC) expertise. " \
                    "Always fetch LIVE data — never make up prices or levels. " \
                    "Tools: fetch_klines (candlesticks), fetch_ticker (24h stats), " \
                    "fetch_orderbook (order book depth), find_smc_levels (full SMC analysis), " \
                    "http_get (any URL), current_time, calculate."

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
    end
  end
end
