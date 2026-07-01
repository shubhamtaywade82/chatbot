# frozen_string_literal: true

module Chatbot
  class Conversation
    attr_reader :messages

    def initialize(config:, store:)
      @config = config
      @store = store
      @messages = []
      add(Chatbot::UserMessage.new(content: config.system_prompt, role: :system))
    end

    def add(message)
      @messages << message
      @store.persist(@messages)
      trim!
      self
    end

    def to_api
      @messages.map { |m| { role: m.role.to_s, content: m.content } }
    end

    private

    def trim!
      return unless @config.max_history_tokens && @config.max_history_tokens.positive?
      while token_count > @config.max_history_tokens && @messages.size > @config.min_history_messages.to_i
        @messages.shift
      end
    end

    def token_count
      @messages.sum { |m| m.content.to_s.split.size }
    end
  end
end
