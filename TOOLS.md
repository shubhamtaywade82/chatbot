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

### Market Data (public — no auth)

| Tool | What it does | When the model calls it |
|------|-------------|------------------------|
| `http_get` | Fetches any URL | Need live data from any public API |
| `current_time` | Returns current datetime | Time, date, day-of-week queries |
| `calculate` | Evaluates math expressions | Arithmetic, percentages, conversions |
| `fetch_klines` | OHLCV candlesticks from Binance Spot | Chart patterns, trend analysis, indicator calc |
| `fetch_ticker` | 24h stats from Binance Spot | Current price snapshot, momentum check |
| `fetch_orderbook` | Order book depth from Binance Spot | Liquidity levels, support/resistance walls |
| `find_smc_levels` | Full SMC analysis (Spot klines) | Trade entry analysis, SMC concepts |

### Futures Analysis (public — no auth)

| Tool | What it does | When the model calls it |
|------|-------------|------------------------|
| `get_funding_rate` | Current + historical funding rates | Assess sentiment, cost of holding |
| `get_open_interest` | Open interest (current + 24h trend) | Confirm trend strength, detect reversals |

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

## Tool Patterns

**Raw data tools** (`fetch_klines`, `fetch_ticker`, `fetch_orderbook`, `get_funding_rate`, `get_open_interest`):
- Fetch from Binance API (public endpoints, no auth needed for Futures analysis tools)
- Parse JSON, extract relevant fields
- Return formatted string

**Compound analysis tools** (`find_smc_levels`):
- Fetch raw data internally (klines + order book)
- Apply algorithmic analysis (swing points, order blocks, FVGs)
- Return structured analysis with current price, trend, levels, and trade bias
- One tool call = complete analysis (reduces model turn count)

**State tools** (`get_account_balance`, `get_positions`, `get_open_orders`):
- Call Binance Futures signed endpoints (HMAC SHA256)
- Used by the model to understand current portfolio state
- Never modify state

**Execution tools** (`place_order`, `cancel_order`, `set_leverage`):
- Modify state on Binance Futures
- `place_order` system prompt instructs the model to **always** present trade details and ask for user confirmation before executing

**Risk tools** (`position_sizing`, `risk_check`):
- Pure computation layered on account state
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
User: "analysis + trade suggestion"
  → find_smc_levels (trend, OBs, FVGs)
  → get_funding_rate (sentiment)
  → get_open_interest (trend confirmation)
  → position_sizing (calculate quantity)
  → risk_check (validate the trade)
  → Present to user: "Here's the setup. Confirm?"
  
User: "confirm"
  → set_leverage
  → place_order
  → get_positions (verify fill)
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
