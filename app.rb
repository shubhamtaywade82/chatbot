#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "config/config"
require_relative "lib/chatbot/session"
require_relative "lib/chatbot/repl"

module Chatbot
  def self.boot
    config = Config.new
    session = Session.new(config)

    puts "🏠 #{config.base_url}"
    puts "   Model: #{config.model}"

    REPL.new(session: session).run
  end
end

Chatbot.boot if __FILE__ == $0
