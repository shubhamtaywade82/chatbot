# frozen_string_literal: true

module Chatbot
  class ToolRegistry
    def initialize
      @tools = {}
    end

    def register(tool_class)
      name = tool_class::NAME
      @tools[name] = tool_class
    end

    def names
      @tools.keys
    end

    def schema
      @tools.values.map { |tool|
        schema = tool.schema
        { type: schema[:type] || "function", function: schema[:function] }
      }
    end

    def execute(name, args = {})
      tool_class = @tools[name]
      return { error: "Unknown tool" } unless tool_class
      tool_class.new.execute(args)
    end
  end
end
