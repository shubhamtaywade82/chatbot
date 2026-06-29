# frozen_string_literal: true

require "time"

module Chatbot
  class Message
    attr_reader :role, :content, :metadata, :created_at

    def initialize(content:, metadata: {})
      @content = content
      @metadata = metadata
      @created_at = Time.now
    end

    def to_h
      { role: role, content: content, **metadata }
    end

    def self.from_h(hash)
      hash = hash.transform_keys(&:to_sym)
      case hash[:role]
      when "system" then SystemMessage.new(content: hash[:content], metadata: hash.except(:role, :content))
      when "user" then UserMessage.new(content: hash[:content], metadata: hash.except(:role, :content))
      when "assistant"
        AssistantMessage.new(
          content: hash[:content],
          reasoning: hash[:reasoning],
          tool_calls: hash[:tool_calls],
          metadata: hash.except(:role, :content, :reasoning, :tool_calls)
        )
      when "tool"
        ToolMessage.new(
          content: hash[:content],
          tool_call_id: hash[:tool_call_id],
          metadata: hash.except(:role, :content, :tool_call_id)
        )
      else
        new(content: hash[:content], metadata: hash.except(:role, :content))
      end
    end
  end

  class SystemMessage < Message
    def role; "system"; end
  end

  class UserMessage < Message
    def role; "user"; end
  end

  class AssistantMessage < Message
    attr_reader :tool_calls, :reasoning

    def initialize(content:, reasoning: nil, tool_calls: nil, **kwargs)
      super(content: content, **kwargs)
      @reasoning = reasoning
      @tool_calls = tool_calls
    end

    def role; "assistant"; end

    def to_h
      super.merge(reasoning: reasoning, tool_calls: tool_calls).compact
    end
  end

  class ToolMessage < Message
    attr_reader :tool_call_id

    def initialize(content:, tool_call_id:, **kwargs)
      super(content: content, **kwargs)
      @tool_call_id = tool_call_id
    end

    def role; "tool"; end

    def to_h
      super.merge(tool_call_id: tool_call_id)
    end
  end
end