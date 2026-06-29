# frozen_string_literal: true

require_relative "base"

module Chatbot
  module Stores
    class Memory < Base
      def initialize
        @messages = []
      end

      def save(messages)
        @messages = messages.map(&:to_h)
      end

      def load
        @messages
      end
    end
  end
end