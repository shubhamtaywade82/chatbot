# frozen_string_literal: true

module Chatbot
  module Stores
    class Memory
      include Enumerable

      def initialize
        @records = []
      end

      def each(&block)
        @records.each(&block)
      end

      def persist(messages)
        @records = messages.map(&:to_h)
      end

      def load
        @records.map { |rec| Chatbot::UserMessage.new(content: rec[:content], role: rec[:role]) }
      end
    end
  end
end
