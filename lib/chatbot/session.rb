require "securerandom"
require "net/http"
require "uri"
require "json"
require "openssl"
require "set"
require "ollama_agent"
require_relative "smc_engines"
require_relative "terminal_markdown"

# Monkeypatch ConsoleStreamer to style markdown line-by-line
module OllamaAgent
  module Streaming
    class ConsoleStreamer
      def attach(hooks)
        @line_buffer = +""
        @thinking_active = false

        hooks.on(:on_thinking) do |payload|
          if !@thinking_active
            print "\e[36m💭 Thinking...\e[0m"
            @thinking_active = true
          end
        end

        hooks.on(:on_token) do |payload|
          if @thinking_active
            print "\r\e[K" # Clear the thinking line
            @thinking_active = false
          end

          @line_buffer << payload[:token]

          if @line_buffer.include?("\n")
            lines = @line_buffer.split("\n", -1)
            @line_buffer = lines.pop || ""
            lines.each do |line|
              puts Chatbot::TerminalMarkdown.render_line(line)
            end
          end
        end

        hooks.on(:on_tool_call) do |payload|
          if @thinking_active
            print "\r\e[K"
            @thinking_active = false
          end
          warn Console.tool_call_line(payload[:name], payload[:args])
        end

        hooks.on(:on_tool_result) do |payload|
          warn Console.tool_result_line(payload[:name], payload[:result])
        end

        hooks.on(:on_complete) do
          if @thinking_active
            print "\r\e[K"
            @thinking_active = false
          end
          if !@line_buffer.empty?
            puts Chatbot::TerminalMarkdown.render_line(@line_buffer)
            @line_buffer = +""
          end
          puts
        end
      end
    end
  end
end

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

# Show more of tool results in stderr preview (default gem truncates to 60 chars)
module OllamaAgent
  module Console
    module_function

    def tool_result_line(name, result)
      preview = result.to_s[0, 200].gsub(/\s+/, " ")
      preview += "..." if result.to_s.length > 200
      dim("◀ #{name}: #{preview}")
    end
  end
end

# Hard interceptor: block duplicate tool calls AND enforce max calls per query.
# The model (qwen3.5) gets stuck calling the same tools repeatedly.
# Patch Toolbox#execute — the FINAL point where ALL tools are executed.
module OllamaAgent
  class Toolbox
    MAX_TOOL_CALLS_PER_QUERY = 8

    alias_method :orig_execute, :execute

    def execute(name, args, context:)
      # Global tracker (persists across tool calls within a session)
      unless @_tc_history
        @_tc_history = {}
        @_tc_count = 0
      end

      @_tc_count += 1

      if @_tc_count > MAX_TOOL_CALLS_PER_QUERY
        $stderr.puts "\e[33m⛔ BLOCKED: max #{MAX_TOOL_CALLS_PER_QUERY} tool calls reached\e[0m"
        $stderr.flush
        return "STOP: You have made #{@_tc_count} tool calls. You have enough data. Write your final analysis NOW. Do NOT call any more tools."
      end

      fp = "#{name}|#{(args || {}).sort_by { |k, _| k.to_s }.map { |k, v| "#{k}=#{v}" }.join(",")}"
      if @_tc_history[fp]
        $stderr.puts "\e[33m⛔ BLOCKED duplicate: #{name}\e[0m"
        $stderr.flush
        return "DUPLICATE: You already called #{name} with these exact args. Move to the NEXT step."
      end

      @_tc_history[fp] = true
      orig_execute(name, args, context: context)
    end
  end
end

# Monkeypatch Ollama provider to pass num_predict for adequate output length
module OllamaAgent
  module Providers
    class Ollama < Base
      private

      alias_method :orig_build_request, :build_request
      def build_request(messages:, model:, tools:, temperature:, think:)
        req = orig_build_request(messages: messages, model: model, tools: tools, temperature: temperature, think: think)
        req[:options] ||= {}
        req[:options][:num_predict] = 4096
        req
      end
    end
  end
end

# Phase 1 Agent components
require_relative "phase1/binance_adapter"
require_relative "phase1/indicator_calculator"
require_relative "phase1/risk_validator"
require_relative "phase1/paper_exchange"

# Singleton paper exchange instance shared across tool calls within a session
$phase1_paper_exchange = Chatbot::Phase1::PaperExchange.new(1000.0)

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
               "Use for technical analysis, chart patterns, SMC level detection, and as input to calculate_indicators.",
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
               "Use for liquidity analysis, support/resistance levels, order flow, and spread assessment before execution.",
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
# SMC module — uses engines from smc_engines.rb, shared by all analysis tools
# ---------------------------------------------------------------------------
module SMC
  def self.fetch_candles(symbol, interval, limit: 150)
    url = "#{BINANCE_API}/api/v3/klines?symbol=#{symbol}&interval=#{interval}&limit=#{limit}"
    resp = Net::HTTP.get_response(URI(url))
    raise "Binance API request failed (Invalid symbol or API error): #{resp.message}" unless resp.is_a?(Net::HTTPOK)
    raw = JSON.parse(resp.body)
    raise "Invalid candles data received" unless raw.is_a?(Array)

    raw.map do |k|
      {
        time: k[0] / 1000,
        open: k[1].to_f, high: k[2].to_f, low: k[3].to_f, close: k[4].to_f,
        volume: k[5].to_f
      }
    end
  end

  # Full SMC analysis using all engines
  def self.analyze(candles, symbol, interval, find_sweeps: false)
    pivots = PivotDetector.detect(candles, left_bars: 4, right_bars: 4)
    ms = MarketStructure.analyze(candles, pivots[:highs], pivots[:lows])
    atr = ATR.compute(candles)
    displacements = Displacement.detect(candles, atr)
    obs = OrderBlock.detect(candles, ms[:bos_events], displacements)

    eq = LiquiditySweep.find_equal_highs_lows(pivots[:highs], pivots[:lows])
    sweeps = find_sweeps ? LiquiditySweep.detect_sweeps(candles, pivots[:highs], pivots[:lows], equal_highs: eq[:equal_highs], equal_lows: eq[:equal_lows]) : []

    recent = candles.last(50)
    range_high = recent.map { |c| c[:high] }.max || candles.last[:high]
    range_low  = recent.map { |c| c[:low] }.min  || candles.last[:low]
    pd = PDArray.compute(range_high, range_low)

    last_c = candles.last
    in_discount = PDArray.discount?(last_c[:close], pd)

    {
      symbol: symbol, interval: interval,
      current_price: last_c[:close],
      candles: candles.size,
      atr: atr.round(4),
      timestamp: Time.now.utc.strftime("%Y-%m-%d %H:%M UTC"),
      trend: ms[:trend],
      bos_events: ms[:bos_events].last(5).map { |e| "BOS #{e[:type]} @ $#{e[:price]} (candle #{e[:index]})" },
      choch_events: ms[:choch_events].last(3).map { |e| "CHoCH #{e[:choch_type]} @ $#{e[:price]}" },
      protected_high: ms[:protected_high],
      protected_low: ms[:protected_low],
      last_swing_high_value: ms[:last_swing_high],
      last_swing_low_value: ms[:last_swing_low],
      displacement_count: displacements.size,
      order_blocks: obs.select { |ob| !ob[:invalidated] }.last(4).map { |ob|
        dir = ob[:direction] == :bullish ? "🟢 Bullish" : "🔴 Bearish"
        state = ob[:mitigated] ? "mitigated" : "active"
        "#{dir} OB $#{ob[:zone].min} - $#{ob[:zone].max} (#{state})"
      },
      equal_highs: eq[:equal_highs].last(3).map { |e| "$#{e[:price]}" },
      equal_lows: eq[:equal_lows].last(3).map { |e| "$#{e[:price]}" },
      sweeps: sweeps.last(3).map { |s| "#{s[:type]} of $#{s[:swept_level]} at candle #{s[:sweep_index]}" },
      discount_zone: in_discount,
      pd_range: { low: pd[:low].round(2), high: pd[:high].round(2), equilibrium: pd[:equilibrium] },
      trade_bias: case ms[:trend]
                  when :bullish then "Bullish"
                  when :bearish then "Bearish"
                  else "Neutral"
                  end
    }
  end
end

# ---------------------------------------------------------------------------
# SMC single-timeframe tool
# ---------------------------------------------------------------------------
OllamaAgent::Tools.register("find_smc_levels", schema: {
  description: "Full SMC analysis on one timeframe using institutional-grade engines (BOS/CHoCH, displacement, order blocks, sweeps, PD array). " \
               "Returns trend, protected levels, order blocks with mitigation state, displacement count, sweeps, and premium/discount zone.",
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
      },
      find_sweeps: {
        type: "boolean",
        description: "Whether to also detect liquidity sweeps (default: false for speed)"
      }
    },
    required: ["symbol"]
  }
}) do |args, **|
  symbol = args["symbol"].to_s.upcase.strip
  interval = args["interval"] || "1h"
  sweeps = args["find_sweeps"] == true
  candles = SMC.fetch_candles(symbol, interval)
  result = SMC.analyze(candles, symbol, interval, find_sweeps: sweeps)
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
               "Auto-selects timeframes per style: scalping (1m/5m), intraday (15m/1h), swing (1h/4h/1d), positional (4h/1d/1w). " \
               "Returns per-TF trend with BOS/CHoCH events, order blocks, displacement, sweeps, PD zones. " \
               "Includes confluence assessment. THE BEST TOOL for initial market analysis.",
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

  levels = {}
  tfs = [tf[:entry], tf[:trend]]
  tfs << tf[:macro] if tf[:macro]

  tfs.each do |interval|
    candles = SMC.fetch_candles(symbol, interval, limit: 120)
    levels[interval] = SMC.analyze(candles, symbol, interval, find_sweeps: true)
  end

  trends = levels.values.map { |l| l[:trend] }
  aligned = trends.uniq.size == 1
  entry_t = levels[tf[:entry]]
  trend_t = levels[tf[:trend]]
  macro_t = tf[:macro] ? levels[tf[:macro]] : nil

  bias = if aligned
    case entry_t[:trend]
    when :bullish then "Strong bullish — all TFs aligned. Long entries on OB retests in discount zone."
    when :bearish then "Strong bearish — all TFs aligned. Short entries on OB retests in premium zone."
    else "Ranging — wait for BOS/CHoCH before entering."
    end
  else
    if macro_t && macro_t[:trend] == :bullish && entry_t[:trend] == :bearish
      "Bullish HTF, bearish LTF — possible pullback. Fade LTF bearish when price hits HTF discount / OB."
    elsif macro_t && macro_t[:trend] == :bearish && entry_t[:trend] == :bullish
      "Bearish HTF, bullish LTF — possible relief rally. Fade LTF bullish when price hits HTF premium / OB."
    else
      "Mixed signals — reduce position size or wait for clearer alignment."
    end
  end

  tf_sections = tfs.map do |interval|
    l = levels[interval]
    role = case interval
           when tf[:entry] then "ENTRY"
           when tf[:trend] then "TREND"
           else "MACRO"
           end
    ob_str = l[:order_blocks].empty? ? "  (none)" : l[:order_blocks].map { |ob| "  #{ob}" }.join("\n")
    <<~SECTION.chomp
      [#{role} #{interval}] #{l[:trend]} @ $#{l[:current_price]}
        ATR: #{l[:atr]}  Displacements: #{l[:displacement_count]}
        Prot Low: $#{l[:protected_low] || "N/A"}  Prot High: $#{l[:protected_high] || "N/A"}
        OBs:
        #{ob_str}
        Sweeps:
          #{l[:sweeps].empty? ? "  (none)" : l[:sweeps].map { |s| "  #{s}" }.join("\n")}
        PD: #{l[:discount_zone] ? "DISCOUNT" : "PREMIUM"}  Equilibrium: $#{l[:pd_range][:equilibrium]}
    SECTION
  end.join("\n")

  entry_choch = entry_t[:choch_events]
  entry_bos = entry_t[:bos_events]
  choch_str = entry_choch.empty? ? "" : "\nCHoCH signals: #{entry_choch.join(", ")}"
  bos_str = entry_bos.empty? ? "" : "\nBOS signals: #{entry_bos.first(3).join(", ")}"

  <<~RESULT
    Multi-TF SMC: #{symbol}
    Style: #{style}
    Price: $#{entry_t[:current_price]}  Vol: #{entry_t[:candles]} candles
    #{choch_str}#{bos_str}

    #{tf_sections}

    Confluence: #{aligned ? "✅ All TFs aligned" : "⚠️ TFs disagree"}
    Bias: #{bias}
    Action: #{aligned && entry_t[:trend] != :ranging ? "Ready for #{entry_t[:trend]} setups. Use identify_trade_setup for entry/SL/TP." : "Wait for structure to develop. Use identify_trade_setup to check."}
  RESULT
rescue => e
  "Error: #{e.message}"
end

# ---------------------------------------------------------------------------
# Market Structure deep-dive tool
# ---------------------------------------------------------------------------
OllamaAgent::Tools.register("analyze_market_structure", schema: {
  description: "Deep market structure analysis: BOS/CHoCH events, HH/LH/HL/LL swing classification, protected levels, and trend strength. " \
               "Use when you need to understand the structural state of the market — is it trending or ranging? Are there reversal signals? " \
               "Calls after analyze_multi_tf for deeper context on a specific timeframe.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT'"
      },
      interval: {
        type: "string",
        description: "Candle interval to analyze (default: 1h)"
      }
    },
    required: ["symbol"]
  }
}) do |args, **|
  symbol = args["symbol"].to_s.upcase.strip
  interval = args["interval"] || "1h"
  candles = SMC.fetch_candles(symbol, interval, limit: 150)
  pivots = PivotDetector.detect(candles, left_bars: 4, right_bars: 4)
  ms = MarketStructure.analyze(candles, pivots[:highs], pivots[:lows])
  atr = ATR.compute(candles)

  swing_report = ms[:swing_highs].last(10).map { |s| "#{s[:type]} @ $#{s[:price]}" }.join(", ")
  swing_report_l = ms[:swing_lows].last(10).map { |s| "#{s[:type]} @ $#{s[:price]}" }.join(", ")

  <<~RESULT
    Market Structure: #{symbol} #{interval}
    Trend: #{ms[:trend]}
    ATR: #{atr.round(4)}
    Protected High: $#{ms[:protected_high] || "N/A"}
    Protected Low: $#{ms[:protected_low] || "N/A"}
    Last Swing High: $#{ms[:last_swing_high] || "N/A"}
    Last Swing Low: $#{ms[:last_swing_low] || "N/A"}

    Recent BOS events:
    #{ms[:bos_events].empty? ? "  (none)" : ms[:bos_events].last(5).map { |e| "  #{e[:type]} @ $#{e[:price]} (candle #{e[:index]})" }.join("\n")}

    Recent CHoCH events:
    #{ms[:choch_events].empty? ? "  (none)" : ms[:choch_events].last(3).map { |e| "  #{e[:choch_type]} @ $#{e[:price]}" }.join("\n")}

    Recent Swing Highs (type/price): #{swing_report}
    Recent Swing Lows (type/price): #{swing_report_l}
  RESULT
rescue => e
  "Error: #{e.message}"
end

# ---------------------------------------------------------------------------
# Liquidity sweep detector
# ---------------------------------------------------------------------------
OllamaAgent::Tools.register("find_liquidity_sweeps", schema: {
  description: "Detect liquidity sweeps (stop hunts) — equal highs/lows and sweep events with reclaim confirmation. " \
               "Sell-side sweep (SSL) = low breaks below swing low, close reclaims. Buy-side sweep (BSL) = high breaks above swing high, close reclaims. " \
               "Sweeps often precede reversals. Use after analyze_multi_tf for entry timing.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT'"
      },
      interval: {
        type: "string",
        description: "Candle interval (default: 15m for entry timing)"
      },
      tolerance_pct: {
        type: "number",
        description: "Tolerance for equal highs/lows detection as decimal (default: 0.001 = 0.1%%)"
      }
    },
    required: ["symbol"]
  }
}) do |args, **|
  symbol = args["symbol"].to_s.upcase.strip
  interval = args["interval"] || "15m"
  tol = (args["tolerance_pct"] || 0.001).to_f
  candles = SMC.fetch_candles(symbol, interval, limit: 200)
  pivots = PivotDetector.detect(candles, left_bars: 4, right_bars: 4)
  eq = LiquiditySweep.find_equal_highs_lows(pivots[:highs], pivots[:lows], tolerance_pct: tol)
  sweeps = LiquiditySweep.detect_sweeps(candles, pivots[:highs], pivots[:lows], equal_highs: eq[:equal_highs], equal_lows: eq[:equal_lows])

  eqh = eq[:equal_highs].last(5).map { |e| "$#{e[:price]} (indices #{e[:indices].join(", ")})" }
  eql = eq[:equal_lows].last(5).map { |e| "$#{e[:price]} (indices #{e[:indices].join(", ")})" }

  sweep_lines = sweeps.last(8).map { |s| "  #{s[:type]} sweeping $#{s[:swept_level]} at candle #{s[:sweep_index]}, reclaimed at $#{s[:close].round(2)}" }

  <<~RESULT
    Liquidity Sweeps: #{symbol} #{interval}
    Current Price: $#{candles.last[:close]}

    Equal Highs (BSL targets):
    #{eqh.empty? ? "  (none)" : eqh.map { |e| "  #{e}" }.join("\n")}

    Equal Lows (SSL targets):
    #{eql.empty? ? "  (none)" : eql.map { |e| "  #{e}" }.join("\n")}

    Recent Sweep Events:
    #{sweep_lines.empty? ? "  (none)" : sweep_lines.join("\n")}

    Total: #{eqh.size + eql.size} levels, #{sweeps.size} sweeps detected
  RESULT
rescue => e
  "Error: #{e.message}"
end

# ---------------------------------------------------------------------------
# Order block detector with displacement confirmation
# ---------------------------------------------------------------------------
OllamaAgent::Tools.register("find_order_blocks", schema: {
  description: "Find institutional order blocks confirmed by displacement (ATR-based impulse). " \
               "Each OB shows: direction, zone, mitigation state, and invalidation status. " \
               "Mitigated OBs = already used by institutions. Invalidated OBs = failed levels. Active OBs = potential entry zones. " \
               "Use after analyze_market_structure for entry level precision.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT'"
      },
      interval: {
        type: "string",
        description: "Candle interval (default: 1h)"
      }
    },
    required: ["symbol"]
  }
}) do |args, **|
  symbol = args["symbol"].to_s.upcase.strip
  interval = args["interval"] || "1h"
  candles = SMC.fetch_candles(symbol, interval, limit: 200)
  pivots = PivotDetector.detect(candles, left_bars: 4, right_bars: 4)
  ms = MarketStructure.analyze(candles, pivots[:highs], pivots[:lows])
  atr = ATR.compute(candles)
  displacements = Displacement.detect(candles, atr)
  obs = OrderBlock.detect(candles, ms[:bos_events], displacements)

  price = candles.last[:close]
  retesting = obs.select { |ob| !ob[:invalidated] && OrderBlock.retesting?(price, ob) }

  ob_lines = obs.map.with_index do |ob, i|
    dir = ob[:direction] == :bullish ? "🟢 Bullish" : "🔴 Bearish"
    status = if ob[:invalidated] then "INVALIDATED"
             elsif ob[:mitigated] then "MITIGATED"
             else "ACTIVE"
             end
    retest = OrderBlock.retesting?(price, ob) ? " ⬅️ PRICE HERE" : ""
    "  #{dir} OB $#{ob[:zone].min} - $#{ob[:zone].max} [#{status}]#{retest}"
  end

  disp_lines = displacements.last(5).map { |d| "  #{d[:direction]} displacement @ $#{d[:price]} method=#{d[:method]}" }

  <<~RESULT
    Order Blocks: #{symbol} #{interval}
    ATR: #{atr.round(4)}  Displacements: #{displacements.size}

    Displacements (last 5):
    #{disp_lines.empty? ? "  (none)" : disp_lines.join("\n")}

    All OBs (#{obs.size}):
    #{ob_lines.empty? ? "  (none)" : ob_lines.join("\n")}

    Price Currently Retesting: #{retesting.empty? ? "None" : "$#{price}"}
  RESULT
rescue => e
  "Error: #{e.message}"
end

# ---------------------------------------------------------------------------
# FLAGSHIP: identify_trade_setup — full pipeline, concrete entry/SL/TP
# ---------------------------------------------------------------------------
OllamaAgent::Tools.register("identify_trade_setup", schema: {
  description: "🚀 FLAGSHIP TOOL: Complete trade setup identification. " \
               "Runs the full SMC pipeline (market structure, BOS/CHoCH, displacement, sweeps, OBs, PD array, candle confirmation) " \
               "and identifies concrete trade setups: PB-7 Sweep+OB and PB-3 BOS Pullback. " \
               "Returns actionable entry price, stop loss, 3 take-profit levels, R:R ratio, confidence assessment, and risk warnings. " \
               "Call this when the user asks for a trade setup, entry, or signal. The ONE tool for trade decisions.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. 'SOLUSDT'"
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

  # Fetch candles for entry and trend TFs
  entry_candles = SMC.fetch_candles(symbol, tf[:entry], limit: 200)
  trend_candles = SMC.fetch_candles(symbol, tf[:trend], limit: 200)
  macro_candles = tf[:macro] ? SMC.fetch_candles(symbol, tf[:macro], limit: 100) : nil

  # Full analysis on entry TF
  entry_pivots = PivotDetector.detect(entry_candles, left_bars: 4, right_bars: 4)
  entry_ms = MarketStructure.analyze(entry_candles, entry_pivots[:highs], entry_pivots[:lows])
  entry_atr = ATR.compute(entry_candles)
  entry_disp = Displacement.detect(entry_candles, entry_atr)
  entry_obs = OrderBlock.detect(entry_candles, entry_ms[:bos_events], entry_disp)
  entry_eq = LiquiditySweep.find_equal_highs_lows(entry_pivots[:highs], entry_pivots[:lows])
  entry_ssl = LiquiditySweep.detect_sweeps(entry_candles, entry_pivots[:highs], entry_pivots[:lows])

  # Trend TF analysis for context
  trend_pivots = PivotDetector.detect(trend_candles, left_bars: 5, right_bars: 5)
  trend_ms = MarketStructure.analyze(trend_candles, trend_pivots[:highs], trend_pivots[:lows])

  # Macro analysis
  macro_ms = if macro_candles
    mp = PivotDetector.detect(macro_candles, left_bars: 5, right_bars: 5)
    MarketStructure.analyze(macro_candles, mp[:highs], mp[:lows])
  end

  price = entry_candles.last[:close]
  recent = entry_candles.last(50)
  pd = PDArray.compute(recent.map { |c| c[:high] }.max, recent.map { |c| c[:low] }.min)
  in_discount = PDArray.discount?(price, pd)

  # === Detect PB-7 Sweep+OB ===
  pb7 = nil
  recent_ssl = entry_ssl.reverse.find { |s| s[:type] == :ssl_sweep && entry_candles.size - s[:sweep_index] <= 30 }
  recent_bsl = entry_ssl.reverse.find { |s| s[:type] == :bsl_sweep && entry_candles.size - s[:sweep_index] <= 30 }

  if entry_ms[:trend] == :bullish && recent_ssl
    # Find CHoCH and BOS after the sweep
    sweep_idx = recent_ssl[:sweep_index]
    after_choch = entry_ms[:choch_events].select { |c| c[:index] > sweep_idx && c[:choch_type] == :bullish_choch }
    after_bos = entry_ms[:bos_events].select { |b| b[:index] > sweep_idx && b[:type] == :bullish_bos }
    after_bos_from_choch = after_bos.select { |b| after_choch.empty? || b[:index] > (after_choch.first[:index] rescue 0) }

    if after_choch.any? && after_bos_from_choch.any?
      active_obs = entry_obs.select { |ob| ob[:direction] == :bullish && !ob[:invalidated] }
      retesting = active_obs.select { |ob| OrderBlock.retesting?(price, ob) }
      entry_ob = retesting.first || active_obs.first

      if entry_ob
        sl_price = [entry_ob[:zone].min, recent_ssl[:swept_level]].min
        sl = (sl_price - (entry_ob[:zone][1] - entry_ob[:zone][0]) * 0.1).round(2)
        entry_price = [price, entry_ob[:zone].max].min.round(2)
        risk = (entry_price - sl).abs
        tp1 = (entry_price + risk * 1).round(2)
        tp2 = (entry_price + risk * 2).round(2)
        tp3 = (entry_price + risk * 3).round(2)
        rr = (risk > 0 ? ((tp3 - entry_price) / risk).round(2) : 0)

        confirmed = EntryConfirmation.long_confirmed?(entry_candles, entry_candles.size - 1) ||
                    EntryConfirmation.long_confirmed?(entry_candles, entry_candles.size - 2)

        pb7 = {
          setup: "PB-7 Sweep+OB (LONG)",
          entry: entry_price, sl: sl,
          tp1: tp1, tp2: tp2, tp3: tp3,
          rr: rr,
          confidence: confirmed ? "HIGH" : "MEDIUM",
          confirmed_candle: confirmed,
          ob_zone: "$#{entry_ob[:zone].min} - $#{entry_ob[:zone].max}",
          ob_mitigated: entry_ob[:mitigated],
          ob_mitigation_note: entry_ob[:mitigated] ? "OB already touched — reduced edge" : "OB untouched — fresh level",
          sweep_price: recent_ssl[:swept_level],
          discount_entry: in_discount,
          reason: "SSL sweep → CHoCH → BOS → OB retest in discount zone"
        }
      end
    end
  end

  if entry_ms[:trend] == :bearish && recent_bsl && pb7.nil?
    after_choch = entry_ms[:choch_events].select { |c| c[:index] > recent_bsl[:sweep_index] && c[:choch_type] == :bearish_choch }
    after_bos = entry_ms[:bos_events].select { |b| b[:index] > recent_bsl[:sweep_index] && b[:type] == :bearish_bos }
    after_bos_from_choch = after_bos.select { |b| after_choch.empty? || b[:index] > (after_choch.first[:index] rescue 0) }

    if after_choch.any? && after_bos_from_choch.any?
      active_obs = entry_obs.select { |ob| ob[:direction] == :bearish && !ob[:invalidated] }
      retesting = active_obs.select { |ob| OrderBlock.retesting?(price, ob) }
      entry_ob = retesting.first || active_obs.first

      if entry_ob
        sl_price = [entry_ob[:zone].max, recent_bsl[:swept_level]].max
        sl = (sl_price + (entry_ob[:zone][1] - entry_ob[:zone][0]) * 0.1).round(2)
        entry_price = [price, entry_ob[:zone].min].max.round(2)
        risk = (sl - entry_price).abs
        tp1 = (entry_price - risk * 1).round(2)
        tp2 = (entry_price - risk * 2).round(2)
        tp3 = (entry_price - risk * 3).round(2)
        rr = (risk > 0 ? ((entry_price - tp3) / risk).round(2) : 0)

        confirmed = EntryConfirmation.short_confirmed?(entry_candles, entry_candles.size - 1) ||
                    EntryConfirmation.short_confirmed?(entry_candles, entry_candles.size - 2)

        pb7 = {
          setup: "PB-7 Sweep+OB (SHORT)",
          entry: entry_price, sl: sl,
          tp1: tp1, tp2: tp2, tp3: tp3,
          rr: rr,
          confidence: confirmed ? "HIGH" : "MEDIUM",
          confirmed_candle: confirmed,
          ob_zone: "$#{entry_ob[:zone].min} - $#{entry_ob[:zone].max}",
          ob_mitigated: entry_ob[:mitigated],
          sweep_price: recent_bsl[:swept_level],
          discount_entry: !in_discount,
          reason: "BSL sweep → CHoCH → BOS → OB retest in premium zone"
        }
      end
    end
  end

  # === Detect PB-3 BOS Pullback ===
  pb3 = nil
  if entry_ms[:trend] == :bullish
    recent_bos = entry_ms[:bos_events].reverse.find { |b| b[:type] == :bullish_bos && entry_candles.size - b[:index] <= 40 }
    if recent_bos
      # Find HL after BOS
      hls_after = entry_ms[:swing_lows].select { |s| s[:type] == :HL && s[:index] > recent_bos[:index] }
      last_hl = hls_after.last
      if last_hl && price <= last_hl[:price] * 1.005
        sl = (last_hl[:price] * 0.999).round(2)
        risk = (price - sl).abs
        entry_price = price.round(2)
        tp1 = (entry_price + risk * 1).round(2)
        tp2 = (entry_price + risk * 2).round(2)
        tp3 = (entry_price + risk * 3).round(2)
        rr = (risk > 0 ? ((tp3 - entry_price) / risk).round(2) : 0)

        confirmed = EntryConfirmation.long_confirmed?(entry_candles, entry_candles.size - 1)

        pb3 = {
          setup: "PB-3 BOS Pullback (LONG)",
          entry: entry_price, sl: sl,
          tp1: tp1, tp2: tp2, tp3: tp3,
          rr: rr,
          confidence: confirmed ? "HIGH" : "MEDIUM",
          confirmed_candle: confirmed,
          hl_price: last_hl[:price],
          bos_price: recent_bos[:price],
          discount_entry: in_discount,
          reason: "Bullish BOS → HL formed → price pulled back to HL level"
        }
      end
    end
  elsif entry_ms[:trend] == :bearish
    recent_bos = entry_ms[:bos_events].reverse.find { |b| b[:type] == :bearish_bos && entry_candles.size - b[:index] <= 40 }
    if recent_bos
      lhs_after = entry_ms[:swing_highs].select { |s| s[:type] == :LH && s[:index] > recent_bos[:index] }
      last_lh = lhs_after.last
      if last_lh && price >= last_lh[:price] * 0.995
        sl = (last_lh[:price] * 1.001).round(2)
        risk = (sl - price).abs
        entry_price = price.round(2)
        tp1 = (entry_price - risk * 1).round(2)
        tp2 = (entry_price - risk * 2).round(2)
        tp3 = (entry_price - risk * 3).round(2)
        rr = (risk > 0 ? ((entry_price - tp3) / risk).round(2) : 0)

        confirmed = EntryConfirmation.short_confirmed?(entry_candles, entry_candles.size - 1)

        pb3 = {
          setup: "PB-3 BOS Pullback (SHORT)",
          entry: entry_price, sl: sl,
          tp1: tp1, tp2: tp2, tp3: tp3,
          rr: rr,
          confidence: confirmed ? "HIGH" : "MEDIUM",
          confirmed_candle: confirmed,
          lh_price: last_lh[:price],
          bos_price: recent_bos[:price],
          discount_entry: !in_discount,
          reason: "Bearish BOS → LH formed → price pulled back to LH level"
        }
      end
    end
  end

  # Build output
  trend_align = [entry_ms[:trend], trend_ms[:trend], macro_ms&.dig(:trend)].compact
  aligned = trend_align.uniq.size == 1

  output = <<~HEADER
    ===== Trade Setup Report: #{symbol} (#{style}) =====
    Time: #{Time.now.utc.strftime("%Y-%m-%d %H:%M UTC")}
    Current Price: $#{price}

    === Market Context ===
    Entry TF (#{tf[:entry]}): #{entry_ms[:trend]}
    Trend TF (#{tf[:trend]}): #{trend_ms[:trend]}
    #{macro_ms ? "Macro TF (#{tf[:macro]}): #{macro_ms[:trend]}" : ""}
    Alignment: #{aligned ? "✅" : "⚠️"}
    Displacements: #{entry_disp.size}
    Active OBs: #{entry_obs.reject { |ob| ob[:invalidated] }.size}
    Sweeps detected: #{entry_ssl.size}
    Price in #{in_discount ? "DISCOUNT" : "PREMIUM"} zone
  HEADER

  if pb7
    mit_note = pb7[:ob_mitigated] ? " (already touched — partial edge)" : " (fresh — full edge)"
    conf_star = pb7[:confidence] == "HIGH" ? "⭐ " : ""
    output += <<~PB7

      #{conf_star}=== ACTIVE SETUP: #{pb7[:setup]} ===
      Confidence: #{pb7[:confidence]} | Risk/Reward: #{pb7[:rr]}:1

      Entry: $#{pb7[:entry]}
      Stop Loss: $#{pb7[:sl]}
      TP1 (1R): $#{pb7[:tp1]}
      TP2 (2R): $#{pb7[:tp2]}
      TP3 (3R): $#{pb7[:tp3]}

      OB Zone: #{pb7[:ob_zone]}#{mit_note}
      Swept Level: $#{pb7[:sweep_price]}
      Reason: #{pb7[:reason]}
      Discount Entry: #{pb7[:discount_entry]}

      Risk: $#{((pb7[:entry] - pb7[:sl]).abs * 100).round(2)} per 100 units
    PB7
  end

  if pb3
    conf_star = pb3[:confidence] == "HIGH" ? "⭐ " : ""
    output += <<~PB3

      #{conf_star}=== ACTIVE SETUP: #{pb3[:setup]} ===
      Confidence: #{pb3[:confidence]} | Risk/Reward: #{pb3[:rr]}:1

      Entry: $#{pb3[:entry]}
      Stop Loss: $#{pb3[:sl]}
      TP1 (1R): $#{pb3[:tp1]}
      TP2 (2R): $#{pb3[:tp2]}
      TP3 (3R): $#{pb3[:tp3]}

      Swing Level: #{pb3[:hl_price] || pb3[:lh_price]}
      BOS Level: $#{pb3[:bos_price]}
      Reason: #{pb3[:reason]}
      Discount Entry: #{pb3[:discount_entry]}
    PB3
  end

  if pb7.nil? && pb3.nil?
    directions = []
    directions << "LONG" if in_discount && entry_ms[:trend] == :bullish
    directions << "SHORT" if !in_discount && entry_ms[:trend] == :bearish

    output += <<~NONE

      No active trade setup detected.

      What to watch:
      #{"- Price in discount zone with bullish trend — watch for sweep + CHoCH to trigger PB-7" if entry_ms[:trend] == :bullish}
      #{"- Price in premium zone with bearish trend — watch for sweep + CHoCH to trigger PB-7" if entry_ms[:trend] == :bearish}
      #{"- Trend is ranging — wait for BOS/CHoCH before considering entries" if entry_ms[:trend] == :ranging}
      - Key levels: last swing high $#{entry_ms[:last_swing_high] || "N/A"}, last swing low $#{entry_ms[:last_swing_low] || "N/A"}
      - ATR: #{entry_atr.round(4)} — average candle range
      - Consider: analyze_market_structure, find_liquidity_sweeps, find_order_blocks for deeper view
    NONE
  end

  output
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
  description: "Analyze the risk of a proposed trade against the live Binance account before execution. " \
               "Checks available margin, position value, liquidation distance, and portfolio exposure. " \
               "Requires API credentials. Call this BEFORE place_order. " \
               "For symbol-universe symbol (ETHUSDT/SOLUSDT/XRPUSDT), also call validate_trade_risk which enforces " \
               "stop direction, R:R >= 1.5, and data freshness without needing an API key.",
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
# CoinDCX API — HMAC SHA256 signed requests for trade execution
# ---------------------------------------------------------------------------
COINDX_API = "https://api.coindcx.com"

module CoinDCX
  def self.signed_post(path, body_data)
    key = ENV["CHAT_COINDCX_API_KEY"].to_s.strip
    secret = ENV["CHAT_COINDCX_API_SECRET"].to_s.strip
    return { error: "CoinDCX API key not configured. Set CHAT_COINDCX_API_KEY and CHAT_COINDCX_API_SECRET." }.to_s if key.empty? || secret.empty?

    json_body = JSON.generate(body_data)
    signature = OpenSSL::HMAC.hexdigest("SHA256", secret, json_body)
    uri = URI("#{COINDX_API}#{path}")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 10

    req = Net::HTTP::Post.new(uri)
    req["X-AUTH-APIKEY"] = key
    req["X-AUTH-SIGNATURE"] = signature
    req["Content-Type"] = "application/json"
    req.body = json_body

    JSON.parse(http.request(req).body)
  rescue => e
    { error: e.message }
  end

  def self.public_get(path, params = {})
    uri = URI("#{COINDX_API}#{path}")
    uri.query = URI.encode_www_form(params) unless params.empty?
    JSON.parse(Net::HTTP.get(uri))
  rescue => e
    { error: e.message }
  end
end

# ---------------------------------------------------------------------------
# CoinDCX account tools
# ---------------------------------------------------------------------------
OllamaAgent::Tools.register("coindcx_get_balance", schema: {
  description: "Get CoinDCX account balance for all assets. Returns available balance, locked amount, and total per coin. " \
               "Use to check funds available for trading on CoinDCX. Alternative to get_account_balance (which is Binance).",
  parameters: { type: "object", properties: {}, required: [] }
}) do |args, **|
  data = CoinDCX.signed_post("/trade/v1/users/balances", { timestamp: (Time.now.to_f * 1000).to_i })
  next data.to_s if data.is_a?(Hash) && data[:error]

  coins = (data.is_a?(Array) ? data : []).select { |c| c["balance"].to_f > 0 || c["locked_balance"].to_f > 0 }
  next "No balances found." if coins.empty?

  coins.map do |c|
    { coin: c["currency"], available: c["balance"].to_f, locked: c["locked_balance"].to_f,
      total: c["balance"].to_f + c["locked_balance"].to_f }
  end.to_s
end

OllamaAgent::Tools.register("coindcx_get_open_orders", schema: {
  description: "Get open orders on CoinDCX. Shows order ID, market, side, type, price, quantity, and status. " \
               "Use to review pending orders before placing new ones or to find order IDs for cancellation.",
  parameters: {
    type: "object",
    properties: {
      market: {
        type: "string",
        description: "Trading pair, e.g. 'SOLUSDT' or 'BTCUSDT'. Optional — omit for all markets."
      }
    },
    required: []
  }
}) do |args, **|
  body = { timestamp: (Time.now.to_f * 1000).to_i }
  market = args["market"].to_s.strip.upcase
  body[:market] = market unless market.empty?
  data = CoinDCX.signed_post("/trade/v1/orders/active_orders", body)
  orders = data.is_a?(Array) ? data : (data.is_a?(Hash) && data[:error] ? [data] : [])
  orders.empty? ? "No open orders." : orders.map { |o|
    { id: o["id"], market: o["market"], side: o["side"], type: o["order_type"],
      price: o["price"], qty: o["quantity"], status: o["status"] }
  }.to_s
end

OllamaAgent::Tools.register("coindcx_place_order", schema: {
  description: "Place an order on CoinDCX. Supports market and limit orders. " \
               "⚠️ ONLY call when user explicitly confirms. Always present details and ask for confirmation first. " \
               "For market orders, price is not needed. For limit orders, price is required.",
  parameters: {
    type: "object",
    properties: {
      market: {
        type: "string",
        description: "Trading pair, e.g. 'SOLUSDT'"
      },
      side: {
        type: "string", enum: ["buy", "sell"],
        description: "buy or sell"
      },
      order_type: {
        type: "string", enum: ["market", "limit"],
        description: "market for immediate fill, limit for specific price"
      },
      quantity: {
        type: "number",
        description: "Quantity in base asset units (e.g. 0.5 SOL)"
      },
      price: {
        type: "number",
        description: "Limit price (required for limit orders)"
      }
    },
    required: ["market", "side", "order_type", "quantity"]
  }
}) do |args, **|
  body = {
    timestamp: (Time.now.to_f * 1000).to_i,
    market: args["market"].to_s.upcase.strip,
    side: args["side"].to_s.downcase.strip,
    order_type: args["order_type"].to_s.downcase.strip,
    quantity: args["quantity"].to_s
  }
  body[:price] = args["price"].to_s if args["price"]
  data = CoinDCX.signed_post("/trade/v1/orders/create", body)
  data.to_s
end

OllamaAgent::Tools.register("coindcx_cancel_order", schema: {
  description: "Cancel an open order on CoinDCX by order ID. Use coindcx_get_open_orders to find the ID.",
  parameters: {
    type: "object",
    properties: {
      id: {
        type: "string",
        description: "Order ID to cancel (from coindcx_get_open_orders)"
      },
      market: {
        type: "string",
        description: "Trading pair, e.g. 'SOLUSDT'"
      }
    },
    required: ["id", "market"]
  }
}) do |args, **|
  data = CoinDCX.signed_post("/trade/v1/orders/cancel", {
    timestamp: (Time.now.to_f * 1000).to_i,
    id: args["id"].to_s,
    market: args["market"].to_s.upcase.strip
  })
  data.to_s
end

OllamaAgent::Tools.register("coindcx_get_positions", schema: {
  description: "Get current positions on CoinDCX. Returns entry price, current price, PnL, and quantity for each position. " \
               "Use to check current exposure before opening new trades.",
  parameters: {
    type: "object",
    properties: {
      market: {
        type: "string",
        description: "Trading pair, e.g. 'SOLUSDT'. Optional — omit for all positions."
      }
    },
    required: []
  }
}) do |args, **|
  body = { timestamp: (Time.now.to_f * 1000).to_i }
  data = CoinDCX.signed_post("/trade/v1/orders/position", body)
  positions = data.is_a?(Array) ? data : (data.is_a?(Hash) && data[:error] ? [] : [data])
  if args["market"].to_s.strip != ""
    m = args["market"].to_s.upcase.strip
    positions = positions.select { |p| p["market"] == m || p["symbol"] == m }
  end
  positions.empty? ? "No open positions." : positions.map { |p|
    { market: p["market"] || p["symbol"], side: p["side"],
      entry: p["entry_price"] || p["buy_price"], current: p["current_price"] || p["last_price"],
      qty: p["quantity"], pnl: p["pnl"] || p["unrealized_pnl"] }
  }.to_s
end

# ---------------------------------------------------------------------------
# WebSocket market data — Binance real-time streams
# ---------------------------------------------------------------------------
OllamaAgent::Tools.register("subscribe_market_data", schema: {
  description: "Get REAL-TIME market data via WebSocket. Connects to Binance for N seconds and returns live klines, trades, or depth. " \
               "Use for entry timing when you need the latest tick-level data. Longer duration = more data but slower response.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair, e.g. 'SOLUSDT'"
      },
      channel: {
        type: "string",
        enum: ["trade", "kline_1m", "kline_5m", "depth20"],
        description: "Data stream: trade (live trades), kline_1m/5m (candles), depth20 (top 20 bids/asks). (default: trade)"
      },
      duration_sec: {
        type: "integer",
        description: "How many seconds to collect data for (1-30, default: 5). 5 seconds typically gives 5-20 trade prints."
      }
    },
    required: ["symbol"]
  }
}) do |args, **|
  require "websocket-client-simple"

  symbol = args["symbol"].to_s.downcase.strip.sub("usdt", "usdt")
  channel = args["channel"] || "trade"
  duration = [args["duration_sec"]&.to_i || 5, 30].min

  stream_name = case channel
                when "trade" then "#{symbol}@trade"
                when "kline_1m" then "#{symbol}@kline_1m"
                when "kline_5m" then "#{symbol}@kline_5m"
                when "depth20" then "#{symbol}@depth20"
                else "#{symbol}@trade"
                end

  url = "wss://stream.binance.com:9443/ws/#{stream_name}"
  data_buf = []
  connected = false

  ws = WebSocket::Client::Simple.connect(url)

  ws.on(:open) { connected = true }
  ws.on(:message) { |msg| data_buf << msg.data }
  ws.on(:error) { }
  ws.on(:close) { }

  # Wait for connection (up to 2s) then collect data for requested duration
  20.times { break if connected; sleep 0.1 }
  unless connected
    ws.close rescue nil
    next "WebSocket connection timeout (2s) to #{url}"
  end

  # Poll for data: up to `duration` seconds, exit early if data arrives
  deadline = Time.now + duration
  while Time.now < deadline
    break if data_buf.any?
    sleep 0.05
  end

  ws.close rescue nil
  sleep 0.1

  if data_buf.any?
    parsed = data_buf.map { |d| JSON.parse(d) rescue nil }.compact
    count = parsed.size

    case channel
    when "trade"
      prices = parsed.map { |t| t["p"].to_f }.compact
      vol = parsed.map { |t| t["q"].to_f }.compact
      { channel: "trade", count: count, symbol: symbol,
        last_price: prices.last, avg_price: (prices.sum / prices.size).round(4),
        high: prices.max, low: prices.min,
        total_volume: vol.sum.round(4),
        sample: parsed.last(3).map { |t| { price: t["p"], qty: t["q"], time: Time.at(t["T"].to_i / 1000).utc.strftime("%H:%M:%S") } }
      }.to_s
    when /^kline/
      last = parsed.last
      k = last["k"] rescue nil
      if k
        { channel: channel, symbol: symbol,
          open: k["o"], high: k["h"], low: k["l"], close: k["c"], volume: k["v"],
          closed: k["x"], time: Time.at(k["t"].to_i / 1000).utc.strftime("%H:%M:%S")
        }.to_s
      else
        "No kline data received"
      end
    when "depth20"
      last = parsed.last
      { channel: "depth20", symbol: symbol,
        bids: (last["b"] || []).first(5).map { |b| { price: b[0].to_f, qty: b[1].to_f } },
        asks: (last["a"] || []).first(5).map { |a| { price: a[0].to_f, qty: a[1].to_f } }
      }.to_s
    end
  else
    "No data received in #{duration}s on #{channel} for #{symbol}."
  end
rescue => e
  "WebSocket error: #{e.message}"
end

# ---------------------------------------------------------------------------
# Indicator Engine — deterministic Ruby calculations, no model math
# Works for any Binance symbol; feeds into identify_trade_setup and risk decisions.
# ---------------------------------------------------------------------------
OllamaAgent::Tools.register("calculate_indicators", schema: {
  description: "Compute technical indicators (RSI 14, EMA 20, EMA 50, MACD, ATR 14, Bollinger Bands, Volume Trend) " \
               "for any symbol and timeframe using deterministic Ruby — the model must NEVER compute these itself. " \
               "Call after fetch_klines and before identify_trade_setup or validate_trade_risk. " \
               "Returns a structured indicator summary including EMA trend bias.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. ETHUSDT, SOLUSDT, XRPUSDT, BTCUSDT"
      },
      interval: {
        type: "string",
        description: "Candle interval: 1m, 5m, 15m, 1h, 4h, 1d (default: 1h)"
      }
    },
    required: ["symbol"]
  }
}) do |args, **|
  symbol   = args["symbol"].to_s.upcase.strip
  interval = args["interval"]&.to_s&.strip || "1h"
  url      = "#{BINANCE_API}/api/v3/klines?symbol=#{symbol}&interval=#{interval}&limit=100"
  raw      = JSON.parse(Net::HTTP.get(URI(url)))
  candles  = raw.map { |k| { time: k[0] / 1000, open: k[1].to_f, high: k[2].to_f, low: k[3].to_f, close: k[4].to_f, volume: k[5].to_f, close_time: k[6] / 1000 } }
  next "No candle data for #{symbol} #{interval}" if candles.empty?

  calc      = Chatbot::Phase1::IndicatorCalculator
  rsi       = calc.calculate_rsi(candles, 14).compact.last&.round(2)
  ema20     = calc.calculate_ema(candles, 20).compact.last&.round(4)
  ema50     = calc.calculate_ema(candles, 50).compact.last&.round(4)
  macd_data = calc.calculate_macd(candles)
  macd      = macd_data[:macd].compact.last&.round(6)
  macd_sig  = macd_data[:signal].compact.last&.round(6)
  macd_hist = macd_data[:histogram].compact.last&.round(6)
  atr       = calc.calculate_atr(candles, 14).compact.last&.round(6)
  bb        = calc.calculate_bollinger_bands(candles, 20, 2.0)
  vol       = calc.calculate_volume_trend(candles, 20)
  price     = candles.last[:close]

  ema_bias  = ema20 && ema50 ? (ema20 > ema50 ? "BULLISH (EMA20 > EMA50)" : "BEARISH (EMA20 < EMA50)") : "N/A"
  rsi_note  = rsi ? (rsi > 70 ? " [Overbought]" : rsi < 30 ? " [Oversold]" : "") : ""

  [
    "Indicators #{symbol} #{interval}:",
    "Price: #{price}",
    "RSI(14): #{rsi}#{rsi_note}",
    "EMA20: #{ema20}  EMA50: #{ema50}  Bias: #{ema_bias}",
    "MACD: #{macd}  Signal: #{macd_sig}  Histogram: #{macd_hist}",
    "ATR(14): #{atr}",
    "Bollinger Bands(20,2): Upper=#{bb[:upper].compact.last&.round(4)}  Basis=#{bb[:basis].compact.last&.round(4)}  Lower=#{bb[:lower].compact.last&.round(4)}",
    "Volume Trend: #{vol[:trend]} (ratio: #{vol[:ratio]})"
  ].join("\n")
rescue => e
  "Error: #{e.message}"
end

# ---------------------------------------------------------------------------
# Risk gate — deterministic stop/R:R/staleness validation, no API key needed.
# Complements risk_check (which requires a live Binance account).
# ---------------------------------------------------------------------------
OllamaAgent::Tools.register("validate_trade_risk", schema: {
  description: "Deterministic pre-trade risk gate. Validates: (1) stop loss direction is correct for BUY/SELL, " \
               "(2) R:R ratio >= 1.5, (3) risk percent within 2% cap, (4) candle data is fresh (< 5 min old). " \
               "Returns APPROVED or HOLD with per-check detail. No API key required. " \
               "Call this AFTER identify_trade_setup and BEFORE risk_check + place_order. " \
               "If result is HOLD, abort the trade — do not proceed to execution.",
  parameters: {
    type: "object",
    properties: {
      symbol: {
        type: "string",
        description: "Trading pair symbol, e.g. ETHUSDT, SOLUSDT, XRPUSDT"
      },
      action: {
        type: "string",
        enum: ["BUY", "SELL"],
        description: "BUY for long, SELL for short"
      },
      entry_price: { type: "number", description: "Proposed entry price" },
      stop_loss:   { type: "number", description: "Proposed stop loss price" },
      take_profit: { type: "number", description: "Proposed take profit price" },
      risk_percent: { type: "number", description: "Percentage of equity to risk, e.g. 1.0" }
    },
    required: ["symbol", "action", "entry_price", "stop_loss", "take_profit", "risk_percent"]
  }
}) do |args, **|
  symbol = args["symbol"].to_s.upcase.strip
  # Fetch a small candle set just for freshness check — reuses BINANCE_API constant
  url     = "#{BINANCE_API}/api/v3/klines?symbol=#{symbol}&interval=1h&limit=3"
  raw     = JSON.parse(Net::HTTP.get(URI(url)))
  candles = raw.map { |k| { time: k[0] / 1000, close: k[4].to_f, close_time: k[6] / 1000 } }

  intent = {
    symbol:       symbol,
    action:       args["action"].to_s.upcase,
    entry_price:  args["entry_price"].to_f,
    stop_loss:    args["stop_loss"].to_f,
    take_profit:  args["take_profit"].to_f,
    risk_percent: args["risk_percent"].to_f,
    candles:      candles
  }

  equity  = $phase1_paper_exchange.equity
  result  = Chatbot::Phase1::RiskValidator.validate(intent, equity: equity, max_risk_pct: 2.0)
  checks  = result[:risk_checks]

  [
    "Risk Gate: #{symbol} #{args['action']}",
    "Verdict       : #{result[:action]} (#{result[:approved] ? 'APPROVED' : 'HOLD'})",
    "Reason        : #{result[:reason]}",
    "Stop Valid    : #{checks[:stop_valid]}   (BUY: SL<entry<TP | SELL: TP<entry<SL)",
    "R:R >= 1.5    : #{checks[:rr_valid]}",
    "Risk <= 2%    : #{checks[:risk_within_limit]}",
    "Data Fresh    : #{checks[:schema_valid]}",
    "Paper Equity  : $#{equity.round(2)}"
  ].join("\n")
rescue => e
  "Error: #{e.message}"
end

# ---------------------------------------------------------------------------
# Session — orchestrates config + runner + env
# ---------------------------------------------------------------------------
module Chatbot
  class Session
    SYSTEM_PROMPT = "You are an automated crypto futures trading agent with institutional SMC expertise. " \
                    "Always fetch LIVE data — never make up prices or levels. " \
                    "You have 30 tools. USE THEM AUTONOMOUSLY in this order:\n" \
                    "\n" \
                    "1. MARKET DATA (raw inputs — call first):\n" \
                    "   - fetch_ticker(symbol) — current price, 24h high/low/volume/change\n" \
                    "   - fetch_klines(symbol, interval, limit?) — OHLCV candles\n" \
                    "   - fetch_orderbook(symbol, limit?) — bid/ask depth, spread\n" \
                    "   - get_funding_rate(symbol) — market sentiment\n" \
                    "   - get_open_interest(symbol) — trend confirmation\n" \
                    "   - subscribe_market_data(symbol, channel, duration_sec) — real-time WebSocket stream\n" \
                    "\n" \
                    "2. INDICATOR ENGINE (always call before deciding — never compute these yourself):\n" \
                    "   - calculate_indicators(symbol, interval) — RSI 14, EMA 20/50, MACD, ATR 14, Bollinger Bands, Volume Trend (all Ruby, deterministic)\n" \
                    "\n" \
                    "3. SMC ANALYSIS:\n" \
                    "   - analyze_multi_tf(symbol, trading_style) — PRIMARY: multi-TF trend, BOS/CHoCH, OBs, sweeps, PD\n" \
                    "   - find_smc_levels(symbol, interval) — single-TF deep dive\n" \
                    "   - analyze_market_structure(symbol, interval) — BOS/CHoCH, HH/LH/HL/LL, protected levels\n" \
                    "   - find_liquidity_sweeps(symbol, interval) — stop hunts, equal highs/lows\n" \
                    "   - find_order_blocks(symbol, interval) — displacement-confirmed OBs, mitigation state\n" \
                    "\n" \
                    "4. TRADE SETUP (flagship — combines all SMC engines):\n" \
                    "   - identify_trade_setup(symbol, trading_style) — concrete entry/SL/TP1/TP2/TP3 with R:R\n" \
                    "\n" \
                    "5. RISK MANAGEMENT (always in this order):\n" \
                    "   - validate_trade_risk(symbol, action, entry_price, stop_loss, take_profit, risk_percent) — deterministic gate: stop direction, R:R>=1.5, risk cap, freshness. No API key needed. HOLD = abort.\n" \
                    "   - position_sizing(symbol, entry_price, stop_loss, risk_percent, leverage) — optimal quantity from live balance\n" \
                    "   - risk_check(symbol, side, entry_price, quantity, stop_loss, leverage) — live account: margin, liquidation, portfolio exposure\n" \
                    "\n" \
                    "6. ACCOUNT STATE:\n" \
                    "   - get_account_balance — Binance margin\n" \
                    "   - get_positions(symbol) — Binance open positions\n" \
                    "   - get_open_orders(symbol) — Binance pending orders\n" \
                    "   - coindcx_get_balance — CoinDCX balances\n" \
                    "   - coindcx_get_positions(market) — CoinDCX positions\n" \
                    "   - coindcx_get_open_orders(market) — CoinDCX pending orders\n" \
                    "\n" \
                    "7. EXECUTION:\n" \
                    "   - coindcx_place_order(market, side, order_type, quantity, price?) — preferred execution\n" \
                    "   - coindcx_cancel_order(id, market)\n" \
                    "   - set_leverage(symbol, leverage)\n" \
                    "   - place_order / cancel_order — Binance fallback\n" \
                    "\n" \
                    "HARD RULES:\n" \
                    " - NEVER compute RSI, EMA, MACD, ATR yourself — always call calculate_indicators.\n" \
                    " - validate_trade_risk must return APPROVED before any order. If HOLD, abort.\n" \
                    " - Standard workflow: fetch_ticker → calculate_indicators → analyze_multi_tf → identify_trade_setup → validate_trade_risk → position_sizing → risk_check → [confirm with user] → place order.\n" \
                    " - Use subscribe_market_data for tick-precise entry timing.\n" \
                    " - Prefer CoinDCX for execution; Binance tools for market data only.\n" \
                    " - Never place an order without validate_trade_risk + risk_check passed and explicit user confirmation.\n" \
                    "\n" \
                    "ANTI-LOOP RULES (CRITICAL):\n" \
                    " - NEVER call the same tool twice with the same arguments in one turn.\n" \
                    " - Step 1 (market data): call fetch_ticker, fetch_klines, fetch_orderbook ONCE each. Done. Move on.\n" \
                    " - After step 1 data is returned, PROCEED to step 2 (calculate_indicators). Do NOT re-fetch market data.\n" \
                    " - If you already have ticker/klines/orderbook data for a symbol, you have ENOUGH. Stop fetching.\n" \
                    " - Maximum total tool calls per response: 8. After 8 calls, STOP and write your analysis.\n" \
                    " - After calling calculate_indicators + analyze_multi_tf + identify_trade_setup, you MUST write your final analysis text. No more tool calls."

    attr_reader :config

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
        max_tokens: @config.max_response_tokens,
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
      ENV["CHAT_COINDCX_API_KEY"] = config.coindcx_api_key if config.coindcx_api_key
      ENV["CHAT_COINDCX_API_SECRET"] = config.coindcx_api_secret if config.coindcx_api_secret
    end
  end
end
