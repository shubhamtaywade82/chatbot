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

| Tool | What it does | When the model calls it |
|------|-------------|------------------------|
| `http_get` | Fetches any URL | Need live data from any public API |
| `current_time` | Returns current datetime | Time, date, day-of-week queries |
| `calculate` | Evaluates math expressions | Arithmetic, percentages, conversions |
| `fetch_klines` | OHLCV candlesticks from Binance | Chart patterns, trend analysis, indicator calc |
| `fetch_ticker` | 24h stats from Binance | Current price snapshot, momentum check |
| `fetch_orderbook` | Order book depth from Binance | Liquidity levels, support/resistance walls |
| `find_smc_levels` | Full SMC analysis | Trade entry analysis, SMC concepts |

### Tool Patterns

**Raw data tools** (`fetch_klines`, `fetch_ticker`, `fetch_orderbook`):
- Fetch from Binance public API (no auth)
- Parse JSON, extract relevant fields
- Return formatted string

**Compound analysis tools** (`find_smc_levels`):
- Fetch raw data internally
- Apply algorithmic analysis (swing points, order blocks, FVGs)
- Return structured analysis with current price, trend, levels, and trade bias
- One tool call = complete analysis (reduces model turn count)

## Model Compatibility

| Model | Tool Calling | Notes |
|-------|-------------|-------|
| qwen3.5:4b | Excellent | Calls tools correctly, follows descriptions |
| qwen3:8b | Excellent | Better multi-step reasoning, 8k+ context |
| qwen3.5:9.7b | Excellent | Best for complex multi-tool analysis |
| llama3.1:8b | Poor | Hallucinates parameter names, calls tools for "hello" |
| llama3.2:3b | Unusable | Too small for tool calling |

## Passing the Binance API URL

```ruby
BINANCE_API = "https://api.binance.com"
```

This is defined once at module level in `session.rb`. All market tools use it. If you need a different exchange, add a `base_url` parameter to the tool.

## Error Handling Pattern

```ruby
rescue => e
  "Error: #{e.message}"
```

Always return errors as strings. Never let exceptions propagate — they crash the tool loop.
