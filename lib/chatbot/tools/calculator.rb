# frozen_string_literal: true

require_relative "base"

module Chatbot
  module Tools
    class Calculator < Base
      class CalculatorError < StandardError; end

      def self.name
        "calculate"
      end

      def self.description
        "Safely evaluate arithmetic expressions. Supports +, -, *, /, ** (right-associative), parentheses, and unary minus."
      end

      def self.parameters
        {
          type: "object",
          properties: {
            expression: {
              type: "string",
              description: "Expression like '2 + 3 * 4', '-5 ** 2', or '2 ** 3 ** 2'"
            }
          },
          required: ["expression"]
        }
      end

      def execute(args)
        expr = args["expression"].to_s
        tokens = Tokenizer.tokenize(expr)
        return { error: "Empty or invalid expression" } if tokens.empty?

        parser = PrattParser.new(tokens)
        ast = parser.parse
        result = parser.evaluate(ast)
        { result: result }
      rescue CalculatorError => e
        { error: e.message }
      end

      class Tokenizer
        TOKEN_REGEX = /(\d+\.?\d*|\*\*|[+\-*\/()])/

        def self.tokenize(expr)
          tokens = []
          expr.gsub(/\s+/, "").scan(TOKEN_REGEX) do |match|
            token = match[0]
            if token.match?(/^\d+\.?\d*$/)
              val = token.include?('.') ? token.to_f : token.to_i
              tokens << { type: :number, value: val }
            else
              tokens << { type: :op, value: token }
            end
          end
          tokens
        end
      end

      class PrattParser
        PRECEDENCE = {
          '+' => 10, '-' => 10,
          '*' => 20, '/' => 20,
          '**' => 30,
          'u-' => 40,
          'u+' => 40
        }.freeze

        def initialize(tokens)
          @tokens = tokens
          @pos = 0
        end

        def parse
          ast = expression(0)
          raise CalculatorError, "Unexpected tokens remaining" unless eof?
          ast
        end

        def evaluate(node)
          case node[:type]
          when :number
            node[:value]
          when :unary
            case node[:op]
            when '-' then -evaluate(node[:expr])
            when '+' then evaluate(node[:expr])
            else raise CalculatorError, "Unknown unary: #{node[:op]}"
            end
          when :binary
            left = evaluate(node[:left])
            right = evaluate(node[:right])
            case node[:op]
            when '+' then left + right
            when '-' then left - right
            when '*' then left * right
            when '/'
              right.zero? ? raise(CalculatorError, "Division by zero") : left / right
            when '**' then left ** right
            else raise CalculatorError, "Unknown binary: #{node[:op]}"
            end
          end
        end

        private

        def expression(min_prec)
          left = prefix_parse

          while !eof? && current[:type] == :op && precedence(current[:value]) >= min_prec
            op = current[:value]
            advance

            next_min = op == '**' ? precedence(op) : precedence(op) + 1
            right = expression(next_min)
            left = { type: :binary, op: op, left: left, right: right }
          end

          left
        end

        def prefix_parse
          if current[:type] == :number
            val = current[:value]
            advance
            return { type: :number, value: val }
          end

          if current[:type] == :op && current[:value] == '('
            advance
            expr = expression(0)
            expect(')')
            return expr
          end

          if current[:type] == :op && %w[- +].include?(current[:value])
            op = current[:value]
            advance
            expr = expression(PRECEDENCE["u#{op}"])
            return { type: :unary, op: op, expr: expr }
          end

          raise CalculatorError, "Unexpected token: #{current.inspect}"
        end

        def precedence(op)
          PRECEDENCE[op] || 0
        end

        def current
          @tokens[@pos] || { type: :eof }
        end

        def advance
          @pos += 1
        end

        def eof?
          @pos >= @tokens.length
        end

        def expect(expected)
          if current[:type] == :op && current[:value] == expected
            advance
          else
            raise CalculatorError, "Expected '#{expected}' but got #{current.inspect}"
          end
        end
      end
    end
  end
end