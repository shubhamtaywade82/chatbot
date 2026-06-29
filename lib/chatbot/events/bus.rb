# frozen_string_literal: true

require "timeout"

module Chatbot
  class EventBus
    def initialize(logger: nil)
      @handlers = Hash.new { |h, k| h[k] = [] }
      @logger = logger
    end

    def on(event, timeout: 5, &block)
      @handlers[event] << { handler: block, timeout: timeout }
    end

    def emit(event, payload = {})
      @handlers[event].each do |h|
        begin
          if h[:timeout]
            Timeout.timeout(h[:timeout]) { h[:handler].call(payload) }
          else
            h[:handler].call(payload)
          end
        rescue => e
          @logger&.log(event: :handler_error, event_name: event, error: e.message)
        end
      end
    end
  end
end