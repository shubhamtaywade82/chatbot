# frozen_string_literal: true

require "json"
require "logger"

module Chatbot
  class StructuredLogger
    attr_reader :logger

    def initialize(level: :info)
      @logger = Logger.new($stderr)
      @logger.level = Logger.const_get(level.to_s.upcase)
      @logger.formatter = proc do |severity, datetime, _progname, msg|
        { ts: datetime.iso8601, level: severity, **msg }.to_json + "\n"
      end
    end

    def log(event, payload = {})
      @logger.info { { event: event, **payload } }
    end

    def request(model:, messages_count:, latency_ms:, tokens_in:, tokens_out:)
      log(:request, model: model, messages: messages_count, latency_ms: latency_ms,
                   tokens_in: tokens_in, tokens_out: tokens_out)
    end

    def tool_call(name:, arguments:, iteration:)
      log(:tool_call, name: name, arguments: arguments, iteration: iteration)
    end

    def error(err, context = {})
      log(:error, message: err.message, class: err.class.name, **context)
    end
  end
end