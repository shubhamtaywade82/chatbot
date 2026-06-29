# frozen_string_literal: true

module Chatbot
  class ToolRegistry
    attr_reader :tools

    def initialize
      @tools = {}
    end

    def register(tool_class)
      @tools[tool_class.name] = tool_class.new
    end

    def schema
      @tools.values.map { |t| t.class.to_ollama_schema }
    end

    def execute(name, arguments)
      tool = @tools[name]
      return { error: "Unknown tool: #{name}" } unless tool

      tool.execute(arguments)
    rescue => e
      { error: "Tool execution failed: #{e.message}" }
    end

    def names
      @tools.keys
    end
  end
end