# frozen_string_literal: true

module Chatbot
  module Phase1
    class PaperExchange
      attr_reader :balance, :positions, :orders, :equity

      def initialize(initial_balance = 1000.0)
        @balance = initial_balance
        @equity = initial_balance
        @positions = []
        @orders = []
      end

      # Simulates execution of a trade signal
      # @param trade [Hash] with :symbol, :action (BUY/SELL), :entry_price, :stop_loss, :take_profit, :risk_percent
      def execute_order(trade)
        symbol = trade[:symbol]
        action = trade[:action]
        entry_price = trade[:entry_price].to_f
        sl = trade[:stop_loss].to_f
        tp = trade[:take_profit].to_f
        risk_pct = (trade[:risk_percent] || 2.0).to_f

        # Calculate position sizing based on risk per trade
        risk_amount = (entry_price - sl).abs
        if risk_amount == 0
          return { success: false, error: "Entry price matches stop loss" }
        end

        max_risk_dollars = @balance * (risk_pct / 100.0)
        position_size = max_risk_dollars / risk_amount

        # Check if we have sufficient funds (assuming 1x leverage, or we can use default leverage)
        required_margin = position_size * entry_price
        # If required margin exceeds balance, adjust position size to max available
        if required_margin > @balance
          position_size = @balance / entry_price
          required_margin = @balance
        end

        order = {
          id: SecureRandom.uuid,
          symbol: symbol,
          action: action,
          entry_price: entry_price,
          stop_loss: sl,
          take_profit: tp,
          quantity: position_size,
          required_margin: required_margin,
          status: "FILLED",
          timestamp: Time.now.to_i
        }

        @orders << order

        position = {
          order_id: order[:id],
          symbol: symbol,
          direction: action == "BUY" ? "LONG" : "SHORT",
          entry_price: entry_price,
          stop_loss: sl,
          take_profit: tp,
          quantity: position_size,
          status: "OPEN",
          pnl: 0.0,
          entry_time: Time.now.to_i
        }

        @positions << position
        @balance -= required_margin

        { success: true, order: order, position: position }
      end

      # Simulates ticks/candles to update open positions
      # Checks if price has hit SL or TP, updates positions and balance.
      # @param symbol [String]
      # @param candle [Hash] containing :high, :low, :close
      def update_positions(symbol, candle)
        high = candle[:high].to_f
        low = candle[:low].to_f
        close = candle[:close].to_f

        @positions.select { |p| p[:symbol] == symbol && p[:status] == "OPEN" }.each do |pos|
          is_long = pos[:direction] == "LONG"
          exit_price = nil
          exit_reason = nil

          if is_long
            if low <= pos[:stop_loss]
              exit_price = pos[:stop_loss]
              exit_reason = "STOP_LOSS"
            elsif high >= pos[:take_profit]
              exit_price = pos[:take_profit]
              exit_reason = "TAKE_PROFIT"
            end
          else
            if high >= pos[:stop_loss]
              exit_price = pos[:stop_loss]
              exit_reason = "STOP_LOSS"
            elsif low <= pos[:take_profit]
              exit_price = pos[:take_profit]
              exit_reason = "TAKE_PROFIT"
            end
          end

          if exit_price
            # Realize PnL
            pnl = is_long ? (exit_price - pos[:entry_price]) * pos[:quantity] : (pos[:entry_price] - exit_price) * pos[:quantity]
            pos[:status] = "CLOSED"
            pos[:exit_price] = exit_price
            pos[:exit_reason] = exit_reason
            pos[:exit_time] = Time.now.to_i
            pos[:pnl] = pnl

            # Return margin and add PnL
            @balance += pos[:quantity] * pos[:entry_price] + pnl
          else
            # Mark-to-market unrealized PnL
            pos[:pnl] = is_long ? (close - pos[:entry_price]) * pos[:quantity] : (pos[:entry_price] - close) * pos[:quantity]
          end
        end

        recalculate_equity(close)
      end

      private

      def recalculate_equity(current_price)
        unrealized_pnl = @positions.select { |p| p[:status] == "OPEN" }.sum { |p| p[:pnl] }
        allocated_margin = @positions.select { |p| p[:status] == "OPEN" }.sum { |p| p[:quantity] * p[:entry_price] }
        @equity = @balance + allocated_margin + unrealized_pnl
      end
    end
  end
end

require "securerandom"
