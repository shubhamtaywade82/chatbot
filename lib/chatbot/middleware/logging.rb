# frozen_string_literal: true

require_relative "pipeline"

module Chatbot
  module Middleware
    class Logging < Base
      def initialize(logger)
        @logger = logger
      end

      def call(request, next_middleware)
        @logger.log(
          event: :request_start,
          model: request[:model],
          messages: request[:messages].length,
          tools: request[:tools] ? true : false
        )

        start = Time.now
        response = next_middleware.call(request)
        latency = ((Time.now - start) * 1000).round

        @logger.log(
          event: :request_complete,
          latency_ms: latency,
          success: response[:error].nil?
        )

        response
      rescue => e
        @logger.log(event: :request_error, error: e.message, class: e.class.name)
        raise
      end
    end
  end
end