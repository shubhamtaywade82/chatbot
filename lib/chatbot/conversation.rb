# frozen_string_literal: true

module Chatbot
  class Conversation
    attr_reader :messages, :config, :store, :pinned

    def initialize(config:, store:)
      @config = config
      @store = store
      @messages = []
      @pinned = []
      load!
      add_system(config.system_prompt) if config.system_prompt
    end

    def add(message)
      @messages << message
      trim!
      persist!
      message
    end

    def pin(message)
      @pinned << message
      persist!
    end

    def to_api
      (@pinned + @messages).map(&:to_h)
    end

    def clear!
      @messages.clear
      @pinned.clear
      add_system(config.system_prompt) if config.system_prompt
      persist!
    end

    def estimated_tokens
      total_chars = (@pinned + @messages).sum { |m| m.content.to_s.length }
      (total_chars / 3.5).ceil + (@pinned + @messages).length * 4
    end

    private

    def add_system(content)
      @pinned << SystemMessage.new(content: content)
    end

    def trim!
      return unless estimated_tokens > config.max_history_tokens

      while estimated_tokens > config.max_history_tokens && @messages.length > config.min_history_messages
        @messages.shift
      end

      summarize! if estimated_tokens > config.max_history_tokens
    end

    def summarize!
      @messages = @messages.last(config.min_history_messages)
    end

    def persist!
      store.save(@pinned + @messages)
    end

    def load!
      loaded = store.load
      loaded.each do |msg|
        if msg.is_a?(SystemMessage)
          @pinned << msg
        else
          @messages << msg
        end
      end
    end
  end
end