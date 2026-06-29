# frozen_string_literal: true

require_relative "pipeline"

module Chatbot
  module Middleware
    class Metrics < Base
      def call(request, next_middleware)
        start = Time.now
        response = next_middleware.call(request)

        latency = Time.now - start
        # StatsD.measure("ollama.request", latency)
        # Prometheus.histogram(:ollama_latency).observe(latency)

        response
      end
    end
  end
end