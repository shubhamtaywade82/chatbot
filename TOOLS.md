# Tools Architecture

The chatbot uses `OllamaAgent::Tools.register` to supply the model with function-calling tools. The model decides when to call a tool based on its `description` and `parameters` schema — no manual routing needed.

## Quick Reference

```ruby
OllamaAgent::Tools.register("tool_name", schema: {
  description: "...",
  parameters: {
    type: "object",
    properties: {
      arg1: { type: "string", description: "..." }
    },
    required: ["arg1"]
  }
}) do |args, root:, read_only:|
  # args is a Hash with string keys matching parameter names
  # Return a String — this is what the model sees as the tool result
  do_something(args["arg1"]).to_s
end
```

## Tool Lifecycle

1. **Registration** — tools are registered at load time (in `session.rb`) via `OllamaAgent::Tools.register`
2. **Schema exposure** — `OllamaAgent.tools_for(read_only:, orchestrator:)` returns only custom tool schemas (the chatbot patches this to exclude built-in coding tools)
3. **Model invocation** — the model sees tool schemas with every request, decides to call a tool, and ollama-agent executes the handler
4. **Result rendering** — the tool's return value (converted to string) is sent back to the model as a tool result message

## Adding Tools

### To the Chatbot (lib/chatbot/session.rb)

Add a new `OllamaAgent::Tools.register` block in the tool registration section (after line ~74):

```ruby
OllamaAgent::Tools.register("my_tool", schema: {
  description: "What this tool does — this is how the model knows when to call it.",
  parameters: {
    type: "object",
    properties: {
      query: {
        type: "string",
        description: "Describe each parameter and what the model should pass"
      }
    },
    required: ["query"]
  }
}) do |args, root:, read_only:|
  # Implement the tool logic
  "result string"
end
```

Then update `SYSTEM_PROMPT` to mention the new tool.

### To ollama_agent (as a built-in)

To add the same tool as a built-in in ollama_agent:

1. **Add the tool registration** to the appropriate module or initializer inside `ollama_agent/lib/`
2. **Ensure the tool's `description` and `parameters` are detailed** — the model relies entirely on these to decide when to call the tool
3. **Handle errors gracefully** — always wrap in `rescue` and return a string, never raise

## Current Tools

### Market Data & SMC Analysis (public — no auth)

| Tool | What it does | When the model calls it |
|------|-------------|------------------------|
| `http_get` | Fetches any URL | Live data from any public API |
| `current_time` | Returns current datetime | Time, date, day-of-week queries |
| `calculate` | Evaluates math expressions | Arithmetic, percentages, conversions |
| `fetch_klines` | OHLCV candlesticks | Low-level chart data |
| `fetch_ticker` | 24h stats from Binance Spot | Quick price snapshot |
| `fetch_orderbook` | Order book depth | Liquidity levels |
| `find_smc_levels` | SMC on one TF (BOS/CHoCH, OBs, sweeps, PD) | Quick single-TF check |
| `analyze_multi_tf` | Multi-TF SMC with style support (BOS/CHoCH, OBs, sweeps, PD) | **PRIMARY analysis tool** |

### SMC Deep-Dive Tools (public — no auth)

| Tool | What it does | When the model calls it |
|------|-------------|------------------------|
| `analyze_market_structure` | BOS/CHoCH, HH/LH/HL/LL, protected levels | After analyze_multi_tf for structural context |
| `find_liquidity_sweeps` | Equal highs/lows, sweep events with reclaim | Entry timing, stop-hunt detection |
| `find_order_blocks` | Displacement-confirmed OBs, mitigation state | Entry level precision |
| `identify_trade_setup` | **FLAGSHIP**: full pipeline → entry/SL/TP1-3/R:R | Trade decisions — combines all engines |

### Futures Analysis (public — no auth)

| Tool | What it does | When the model calls it |
|------|-------------|------------------------|
| `get_funding_rate` | Current + historical funding rates | Sentiment, cost of holding |
| `get_open_interest` | Open interest (current + 24h trend) | Trend confirmation, reversals |

### Account & Position Management (requires API key)

| Tool | What it does | When the model calls it |
|------|-------------|------------------------|
| `get_account_balance` | Wallet balance, available margin per asset | Check available funds before trading |
| `get_positions` | Open positions: entry, liq price, PnL, leverage | Review current exposure |
| `get_open_orders` | List pending orders | Find order IDs, check what's queued |
| `set_leverage` | Set leverage per pair (1-125x) | Before placing a trade |

### Trade Execution (requires API key)

| Tool | What it does | When the model calls it |
|------|-------------|------------------------|
| `place_order` | Place MARKET/LIMIT/STOP/TP order | **Only after user confirms** trade details |
| `cancel_order` | Cancel an open order by symbol + orderId | Remove stale/mistaken orders |

### Risk Management (requires API key)

| Tool | What it does | When the model calls it |
|------|-------------|------------------------|
| `position_sizing` | Calculate position size from risk %, entry, stop | **Before** place_order to determine quantity |
| `risk_check` | Full risk assessment of proposed trade | **Before** place_order to validate safety |

## Trading Styles & Timeframes

The `analyze_multi_tf` tool maps trading styles to optimal timeframes:

| Style | Entry TF | Trend TF | Macro TF | Holding Period |
|-------|----------|----------|----------|----------------|
| `scalping` | 1m | 5m | — | Seconds–minutes |
| `intraday` | 15m | 1h | — | Minutes–hours |
| `swing` | 1h | 4h | 1d | Hours–days |
| `positional` | 4h | 1d | 1w | Days–weeks |

Each style analyzes 2-3 timeframes and reports:
- **Per timeframe**: trend, last swing high/low, order blocks, FVGs
- **Confluence**: do all timeframes agree on direction?
- **Bias**: specific trade recommendation based on alignment

## Tool Patterns

**Raw data tools** (`fetch_klines`, `fetch_ticker`, `fetch_orderbook`, `get_funding_rate`, `get_open_interest`):
- Fetch from Binance API (public endpoints)
- Parse JSON, extract relevant fields
- Return formatted string

**Engine-based compound tools** (`find_smc_levels`, `analyze_multi_tf`):
- Use `smc_engines.rb` modules (PivotDetector, MarketStructure, Displacement, OrderBlock, LiquiditySweep, PDArray)
- BOS/CHoCH detection, swing classification (HH/LH/HL/LL), protected levels
- ATR-based displacement confirmation for institutional impulse detection
- Order blocks with creation-at-BOS, mitigation, and invalidation lifecycle
- Equal highs/lows + sweep detection with reclaim confirmation
- Premium/discount zone evaluation

**Deep-dive SMC tools** (`analyze_market_structure`, `find_liquidity_sweeps`, `find_order_blocks`):
- Each exposes one engine layer for the model to inspect
- Called after `analyze_multi_tf` when the model needs precision timing/levels

**Flagship tool** (`identify_trade_setup`):
- Calls ALL engines internally across 2-3 timeframes (depending on trading style)
- Implements PB-7 Sweep+OB and PB-3 BOS Pullback trade setups (ported from smc-backtester)
- Returns concrete entry price, stop loss, TP1/TP2/TP3, and R:R ratio
- Uses EntryConfirmation module for candle pattern detection (engulfing, rejection wicks)

**State tools** (`get_account_balance`, `get_positions`, `get_open_orders`):
- Call Binance Futures signed endpoints (HMAC SHA256)
- Never modify state

**Execution tools** (`place_order`, `cancel_order`, `set_leverage`):
- Modify state on Binance Futures
- `place_order` always requires risk_check first and user confirmation

**Risk tools** (`position_sizing`, `risk_check`):
- Enforce position limits (max 2% risk per trade warning)
- Must be called before `place_order`

## Binance Futures API Authentication

Tools that require auth read credentials from environment variables:

```bash
export CHAT_BINANCE_API_KEY="your_binance_api_key"
export CHAT_BINANCE_API_SECRET="your_binance_api_secret"
```

Or add to `config/config.rb` — the `Config` class reads these from ENV and `Session#set_ollama_env` forwards them as env vars for tool handlers.

The signing uses HMAC SHA256:

```ruby
# In BinanceFutures.signed_request:
query = params.sort.map { |k, v| "#{k}=#{v}" }.join("&")
signature = OpenSSL::HMAC.hexdigest("SHA256", secret, query)
```

API key requirements (Binance Futures):
- Enable Futures trading on the API key
- Permissions: enable "Futures" (Enable Trading + Enable Withdrawals optional)
- Never share or commit your API secret

## Tool Workflow for Automated Trading

```
User: "Swing trade SOLUSDT"
  → analyze_multi_tf(SOLUSDT, swing)               # Multi-TF context
  → identify_trade_setup(SOLUSDT, swing)            # Concrete entry/SL/TP
 
  If setup found:
    → get_funding_rate(SOLUSDT)                      # Sentiment check
    → get_open_interest(SOLUSDT)                     # Trend confirmation
    → position_sizing(SOLUSDT, entry, SL, 1%, 3x)    # Quantity
    → risk_check(SOLUSDT, BUY, entry, qty, SL, 3x)   # Validate
    → Present to user: "Entry $X, SL $Y, TP1 $Z (1R), TP2 $Z (2R), TP3 $Z (3R). Confirm?"
    
  If NO setup:
    → analyze_market_structure(SOLUSDT, 1h)          # BOS/CHoCH deep dive
    → find_liquidity_sweeps(SOLUSDT, 15m)            # Sweep timing
    → find_order_blocks(SOLUSDT, 1h)                 # OB precision
    → Present levels to watch + what needs to happen for setup activation
  
User: "confirm"
  → set_leverage
  → place_order
  → get_positions (verify fill)
```

## SMC Engines Architecture

All engines are in `lib/chatbot/smc_engines.rb`, ported from the smc-backtester project:

```
Candles (Binance API)
  → PivotDetector (swing highs/lows with left/right bars)
  → MarketStructure (BOS/CHoCH, HH/LH/HL/LL, protected levels)  
  → ATR (Wilder smoothing, period 14)
  → Displacement (body 1.5x ATR, range 2x ATR, min body 60%)
  → OrderBlock (creation at BOS, mitigation, invalidation)
  → LiquiditySweep (equal highs/lows 0.1% tolerance, sweep+reclaim)
  → EntryConfirmation (bullish/bearish engulfing, rejection wicks)
  → PDArray (equilibrium, discount/premium zones)
  → TradeSetups (PB-7 Sweep+OB, PB-3 BOS Pullback)
```

## Model Compatibility

| Model | Tool Calling | Notes |
|-------|-------------|-------|
| qwen3.5:4b | Excellent | Calls tools correctly, follows descriptions |
| qwen3:8b | Excellent | Better multi-step reasoning, 8k+ context |
| qwen3.5:9.7b | Excellent | Best for complex multi-tool analysis |
| llama3.1:8b | Poor | Hallucinates parameter names, calls tools for "hello" |
| llama3.2:3b | Unusable | Too small for tool calling |

## Error Handling Pattern

```ruby
rescue => e
  "Error: #{e.message}"
```

Always return errors as strings. Never let exceptions propagate — they crash the tool loop.
