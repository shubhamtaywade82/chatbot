#!/usr/bin/env ruby
# frozen_string_literal: true

require "ollama_client"
require_relative "config/config"
require_relative "lib/chatbot/message"
require_relative "lib/chatbot/config"
require_relative "lib/chatbot/schema_validator"
require_relative "lib/chatbot/streaming/reasoning/extractor"
require_relative "lib/chatbot/streaming/parser"
require_relative "lib/chatbot/middleware/pipeline"
require_relative "lib/chatbot/middleware/logging"
require_relative "lib/chatbot/middleware/retry"
require_relative "lib/chatbot/middleware/metrics"
require_relative "lib/chatbot/events/bus"
require_relative "lib/chatbot/stores/base"
require_relative "lib/chatbot/stores/memory"
require_relative "lib/chatbot/stores/json"
require_relative "lib/chatbot/stores/sqlite"
require_relative "lib/chatbot/conversation"
require_relative "lib/chatbot/tools/base"
require_relative "lib/chatbot/tools/calculator"
require_relative "lib/chatbot/tools/weather"
require_relative "lib/chatbot/tool_registry"
require_relative "lib/chatbot/renderers/base"
require_relative "lib/chatbot/renderers/cli"
require_relative "lib/chatbot/session"
require_relative "lib/chatbot/repl"
require_relative "lib/chatbot/plugins/registry"
require_relative "lib/chatbot/container"
require_relative "lib/chatbot/logger"

module Chatbot
  def self.boot
    config = Config.new

    logger = StructuredLogger.new(level: config.log_level)

    store = case config.store_adapter
            when :sqlite then Stores::SQLite.new
            when :json then Stores::JSON.new(path: config.conversation_persistence_path)
            else Stores::Memory.new
            end

    renderer = Renderers::CLI.new

    registry = ToolRegistry.new
    registry.register(Tools::Calculator)
    registry.register(Tools::Weather)

    pipeline = Middleware::Pipeline.new
    pipeline.use(Middleware::Retry.new(max_retries: config.retries))
    pipeline.use(Middleware::Metrics.new)

    session = Session.new(
      config: config,
      renderer: renderer,
      logger: logger,
      tool_registry: registry,
      store: store,
      middleware: pipeline
    )

    if config.cloud?
      puts "☁️  Cloud mode: #{config.base_url}"
      puts "   Model: #{config.model}"
      puts "   Keys: #{config.api_keys.to_s.split(',').length} configured"
    else
      puts "🏠 Local mode: #{config.base_url}"
      puts "   Model: #{config.model}"
    end

    REPL.new(session: session).run
  end
end

Chatbot.boot if __FILE__ == $0