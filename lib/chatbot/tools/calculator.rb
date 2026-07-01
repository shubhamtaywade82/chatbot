# frozen_string_literal: true

module Chatbot
  module Tools
    class Calculator
      NAME = "calculate"

      def self.schema
        {
          type: "function",
          function: {
            name: NAME,
            description: "Evaluate a mathematical expression and return the numeric result. Supports +, -, *, /, ** (power), and parentheses.",
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
          }
        }
      end

      def execute(args)
        expr = args["expression"].to_s
        return { error: "Empty or invalid expression" } if expr.strip.empty?
        return { error: "Empty or invalid expression" } unless expr.match?(/\A[\d\s+\-*\/()%.,e]+\z/)

        begin
          { result: eval(expr) }
        rescue ZeroDivisionError
          { error: "Division by zero" }
        rescue SyntaxError, NameError
          { error: "Unexpected tokens remaining" }
        end
      end
    end
  end
end
