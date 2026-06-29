# frozen_string_literal: true

module Chatbot
  module Stores
    class Base
      def save(messages); raise NotImplementedError; end
      def load; raise NotImplementedError; end
    end
  end
end