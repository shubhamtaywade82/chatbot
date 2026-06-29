# frozen_string_literal: true

module Chatbot
  module Middleware
    class Pipeline
      def initialize
        @middlewares = []
      end

      def use(middleware)
        @middlewares << middleware
      end

      def call(request)
        chain = @middlewares.reverse.reduce(yield) do |next_mw, mw|
          ->(req) { mw.call(req, next_mw) }
        end
        chain.call(request)
      end
    end

    class Base
      def call(request, next_middleware)
        next_middleware.call(request)
      end
    end
  end
end