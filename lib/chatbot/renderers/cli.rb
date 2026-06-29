# frozen_string_literal: true

require_relative "base"

module Chatbot
  module Renderers
    class CLI < Base
      COLORS = {
        thinking: "\e[38;5;240m",
        answer: "\e[0m",
        error: "\e[31m",
        system: "\e[33m",
        prompt: "\e[32m"
      }.freeze

      def initialize(output: $stdout)
        @output = output
      end

      def on_start
        @output.print "#{COLORS[:system]}thinking... #{COLORS[:answer]}"
        @output.flush
        @started = false
      end

      def on_token(token, type: :answer)
        unless @started
          @output.print "\r\e[K"
          @started = true
        end
        @output.print "#{COLORS[type]}#{token}#{COLORS[:answer]}"
      end

      def on_reasoning(token)
        on_token(token, type: :thinking)
      end

      def on_separator
        @output.puts "\n#{COLORS[:system]}---#{COLORS[:answer]}"
      end

      def on_tool(name, args)
        @output.puts "\n#{COLORS[:system]}[TOOL] #{name}(#{args.to_json})#{COLORS[:answer]}"
      end

      def on_message(text)
        @output.puts text
      end

      def on_finish
        @output.puts
      end

      def on_error(err)
        @output.puts "#{COLORS[:error]}[ERROR] #{err.message}#{COLORS[:answer]}"
      end

      def prompt(text)
        @output.print "#{COLORS[:prompt]}#{text} #{COLORS[:answer]}"
      end
    end
  end
end