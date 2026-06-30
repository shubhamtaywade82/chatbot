# frozen_string_literal: true

require "time"

module Chatbot
  module Phase1
    class TraceLogger
      attr_reader :traces

      def initialize
        @traces = []
      end

      # Logs a new trace entry with all audit details
      def log_trace(decision_summary:, tool_calls:, tool_observations:, risk_checks:, final_intent:)
        trace = {
          timestamp: Time.now.iso8601,
          decision_summary: decision_summary,
          tool_calls: tool_calls,
          tool_observations: tool_observations,
          risk_checks: risk_checks,
          final_intent: final_intent
        }
        @traces << trace
        trace
      end

      # Formats the trace as a clean human-readable output
      def format_trace(trace)
        lines = []
        lines << "==================== TRACE AUDIT ===================="
        lines << "Time: #{trace[:timestamp]}"
        lines << "Decision Summary: #{trace[:decision_summary]}"
        lines << "Tool Calls:"
        trace[:tool_calls].each do |tc|
          lines << "  - #{tc[:name]}(#{tc[:args].map { |k, v| "#{k}: #{v}" }.join(", ")})"
        end
        lines << "Tool Observations:"
        trace[:tool_observations].each do |to|
          lines << "  - #{to[:name]}: #{to[:summary]}"
        end
        lines << "Risk Checks:"
        trace[:risk_checks].each do |k, v|
          lines << "  - #{k}: #{v}"
        end
        lines << "Final Intent:"
        lines << "  - Symbol: #{trace[:final_intent][:symbol]}"
        lines << "  - Action: #{trace[:final_intent][:action]}"
        lines << "  - Entry: #{trace[:final_intent][:entry_price]} | SL: #{trace[:final_intent][:stop_loss]} | TP: #{trace[:final_intent][:take_profit]}"
        lines << "====================================================="
        lines.join("\n")
      end
    end
  end
end
