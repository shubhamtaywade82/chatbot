# frozen_string_literal: true

require_relative "../lib/chatbot/phase1/binance_adapter"
require_relative "../lib/chatbot/phase1/indicator_calculator"
require_relative "../lib/chatbot/phase1/risk_validator"
require_relative "../lib/chatbot/phase1/paper_exchange"
require_relative "../lib/chatbot/phase1/ollama_router"
require_relative "../lib/chatbot/phase1/tool_loop"

RSpec.describe "Phase 1 Crypto Futures Agent Components" do
  
  describe Chatbot::Phase1::BinanceAdapter do
    let(:adapter) { Chatbot::Phase1::BinanceAdapter.new }
    let(:symbol) { "ETHUSDT" }

    it "handles network errors gracefully in ticker" do
      allow(Net::HTTP).to receive(:get_response).and_raise("Network down")
      expect(adapter.ticker(symbol)).to eq({ "error" => "Network down" })
    end

    it "fetches klines and formats them correctly" do
      mock_response = double(
        is_a?: true,
        code: "200",
        message: "OK",
        body: [
          [1609459200000, "3000.0", "3100.0", "2900.0", "3050.0", "1500.0", 1609462799999]
        ].to_json
      )
      allow(Net::HTTP).to receive(:get_response).and_return(mock_response)
      
      klines = adapter.klines(symbol, "1h", 1)
      expect(klines.size).to eq(1)
      expect(klines.first[:open]).to eq(3000.0)
      expect(klines.first[:close]).to eq(3050.0)
    end
  end

  describe Chatbot::Phase1::IndicatorCalculator do
    # Simple artificial rising price candles
    let(:candles) do
      25.times.map do |i|
        {
          time: 1609459200 + i * 3600,
          open: 100.0 + i,
          high: 105.0 + i,
          low: 95.0 + i,
          close: 101.0 + i,
          volume: i > 20 ? 2000.0 + i : 1000.0 + i
        }
      end
    end

    it "calculates RSI correctly" do
      rsi = Chatbot::Phase1::IndicatorCalculator.calculate_rsi(candles, 14)
      expect(rsi.size).to eq(candles.size)
      expect(rsi.last).to be > 50.0
    end

    it "calculates EMA correctly" do
      ema20 = Chatbot::Phase1::IndicatorCalculator.calculate_ema(candles, 20)
      expect(ema20.size).to eq(candles.size)
      expect(ema20.last).to be_within(5.0).of(120.0)
    end

    it "calculates ATR correctly" do
      atr = Chatbot::Phase1::IndicatorCalculator.calculate_atr(candles, 14)
      expect(atr.size).to eq(candles.size)
      expect(atr.last).to be_within(1.0).of(10.0)
    end

    it "calculates Bollinger Bands correctly" do
      bb = Chatbot::Phase1::IndicatorCalculator.calculate_bollinger_bands(candles, 20)
      expect(bb[:basis].size).to eq(candles.size)
      expect(bb[:upper].last).to be > bb[:basis].last
      expect(bb[:lower].last).to be < bb[:basis].last
    end

    it "calculates Volume Trend correctly" do
      vol_trend = Chatbot::Phase1::IndicatorCalculator.calculate_volume_trend(candles, 20)
      expect(vol_trend[:trend]).to eq(:increasing)
    end
  end

  describe Chatbot::Phase1::RiskValidator do
    let(:candles) { [{ time: Time.now.to_i, close_time: Time.now.to_i, close: 100.0 }] }

    it "replaces BUY/SELL actions with HOLD when stop loss and take profit are invalid for long" do
      intent = {
        symbol: "ETHUSDT",
        action: "BUY",
        entry_price: 100.0,
        stop_loss: 105.0, # SL above entry is invalid for long
        take_profit: 110.0,
        risk_percent: 1.0,
        candles: candles
      }
      res = Chatbot::Phase1::RiskValidator.validate(intent, equity: 1000.0)
      expect(res[:approved]).to be false
      expect(res[:action]).to eq("HOLD")
    end

    it "replaces BUY/SELL actions with HOLD when R:R ratio is less than 1.5" do
      intent = {
        symbol: "ETHUSDT",
        action: "BUY",
        entry_price: 100.0,
        stop_loss: 95.0, # Risk = 5
        take_profit: 105.0, # Reward = 5 (R:R = 1.0, invalid)
        risk_percent: 1.0,
        candles: candles
      }
      res = Chatbot::Phase1::RiskValidator.validate(intent, equity: 1000.0)
      expect(res[:approved]).to be false
      expect(res[:risk_checks][:rr_valid]).to be false
    end

    it "approves trade when all rules align" do
      intent = {
        symbol: "ETHUSDT",
        action: "BUY",
        entry_price: 100.0,
        stop_loss: 90.0, # Risk = 10
        take_profit: 120.0, # Reward = 20 (R:R = 2.0, valid)
        risk_percent: 1.5,
        candles: candles
      }
      res = Chatbot::Phase1::RiskValidator.validate(intent, equity: 1000.0)
      expect(res[:approved]).to be true
      expect(res[:action]).to eq("BUY")
    end
  end

  describe Chatbot::Phase1::PaperExchange do
    let(:exchange) { Chatbot::Phase1::PaperExchange.new(1000.0) }

    it "executes orders, decreases balance, and tracks position correctly" do
      trade = {
        symbol: "ETHUSDT",
        action: "BUY",
        entry_price: 3000.0,
        stop_loss: 2900.0, # Risk = 100
        take_profit: 3200.0,
        risk_percent: 2.0 # 2% of 1000 = $20 risk
      }
      res = exchange.execute_order(trade)
      expect(res[:success]).to be true
      expect(res[:position][:quantity]).to eq(0.2) # $20 / 100
      expect(exchange.positions.size).to eq(1)
      expect(exchange.balance).to eq(1000.0 - (0.2 * 3000.0))
    end

    it "updates positions and realizes PnL on TP touch" do
      trade = {
        symbol: "ETHUSDT",
        action: "BUY",
        entry_price: 3000.0,
        stop_loss: 2900.0,
        take_profit: 3200.0,
        risk_percent: 2.0
      }
      exchange.execute_order(trade)
      
      candle = { high: 3250.0, low: 2950.0, close: 3100.0 }
      exchange.update_positions("ETHUSDT", candle)

      expect(exchange.positions.first[:status]).to eq("CLOSED")
      expect(exchange.positions.first[:exit_reason]).to eq("TAKE_PROFIT")
      expect(exchange.positions.first[:pnl]).to eq((3200.0 - 3000.0) * 0.2)
    end
  end

  describe Chatbot::Phase1::OllamaRouter do
    let(:endpoints) do
      [
        { url: "http://first-fail.local", model: "qwen" },
        { url: "http://second-success.local", model: "qwen" }
      ]
    end
    let(:router) { Chatbot::Phase1::OllamaRouter.new(endpoints) }

    it "falls back to the secondary endpoint if the first one fails" do
      # Mock the HTTP calls
      first_uri = URI("http://first-fail.local/api/chat")
      second_uri = URI("http://second-success.local/api/chat")

      # First call fails
      allow(Net::HTTP).to receive(:post).with(first_uri, anything, anything).and_raise("Connection refused")
      
      # Second call succeeds
      mock_ok_response = double(
        is_a?: true,
        code: "200",
        message: "OK",
        body: { message: { content: '{"action":"BUY","confidence":0.8}' } }.to_json
      )
      
      # We mock the http request for router
      stub_request_first = double
      allow(Net::HTTP).to receive(:new).with("first-fail.local", 80).and_return(stub_request_first)
      allow(stub_request_first).to receive(:read_timeout=)
      allow(stub_request_first).to receive(:open_timeout=)
      allow(stub_request_first).to receive(:request).and_raise("Connection refused")

      stub_request_second = double
      allow(Net::HTTP).to receive(:new).with("second-success.local", 80).and_return(stub_request_second)
      allow(stub_request_second).to receive(:read_timeout=)
      allow(stub_request_second).to receive(:open_timeout=)
      allow(stub_request_second).to receive(:request).and_return(mock_ok_response)

      resp = router.chat([{ role: "user", content: "test" }])
      expect(resp[:endpoint_index]).to eq(1)
      expect(resp[:content]).to eq('{"action":"BUY","confidence":0.8}')
    end
  end

  describe Chatbot::Phase1::ToolLoop do
    let(:endpoints) { [{ url: "http://localhost:11434", model: "qwen" }] }
    let(:loop_runner) { Chatbot::Phase1::ToolLoop.new(endpoints: endpoints) }

    it "runs an iteration, calls adapter/indicators, routes, and validates risk" do
      # Stub Binance calls
      allow(loop_runner.binance).to receive(:ticker).and_return({ "price" => "3000.0" })
      allow(loop_runner.binance).to receive(:klines).and_return(
        25.times.map do |i|
          { time: Time.now.to_i - (24 - i) * 3600, close_time: Time.now.to_i - (24 - i) * 3600, open: 3000.0, high: 3050.0, low: 2950.0, close: 3000.0, volume: 100.0 }
        end
      )
      allow(loop_runner.binance).to receive(:order_book).and_return({ bids: [[2999.0, 10.0]], asks: [[3001.0, 10.0]] })
      allow(loop_runner.binance).to receive(:stats_24hr).and_return({ "priceChangePercent" => "1.5", "highPrice" => "3100", "lowPrice" => "2900" })

      # Stub Ollama response
      mock_llm_response = {
        content: {
          action: "BUY",
          confidence: 0.85,
          entry_price: 3000.0,
          stop_loss: 2900.0,
          take_profit: 3200.0,
          risk_percent: 1.0,
          reason_codes: ["trend_aligned", "volume_confirmed"]
        }.to_json,
        model: "qwen",
        endpoint_index: 0
      }
      allow(loop_runner.router).to receive(:chat).and_return(mock_llm_response)

      result = loop_runner.run_iteration("ETHUSDT")

      expect(result[:symbol]).to eq("ETHUSDT")
      expect(result[:action]).to eq("BUY")
      expect(result[:risk_checks][:approved]).to be true
      expect(result[:position_size]).to be > 0.0
      expect(result[:tool_calls].size).to eq(4)
    end
  end
end

