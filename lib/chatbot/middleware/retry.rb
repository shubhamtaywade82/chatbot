# frozen_string_literal: true

require_relative "pipeline"

module Chatbot
  module Middleware
    class Retry < Base
      def initialize(max_retries: 3, backoff_base: 2)
        @max_retries = max_retries
        @backoff_base = backoff_base
      end

      def call(request, next_middleware)
        retries = 0
        begin
          next_middleware.call(request)
        rescue Ollama::Error, Errno::ECONNREFUSED => e
          retries += 1
          raise if retries > @max_retries
          sleep(@backoff_base ** retries)
          retry
        end
      end
    end
  end
end