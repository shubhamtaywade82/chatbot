# frozen_string_literal: true

module Chatbot
  module Tools
    class Base
      def self.name
        raise NotImplementedError
      end

      def self.description
        raise NotImplementedError
      end

      def self.parameters
        { type: "object", properties: {}, required: [] }
      end

      def self.to_ollama_schema
        {
          type: "function",
          function: {
            name: name,
            description: description,
            parameters: parameters
          }
        }
      end

      def execute(args)
        raise NotImplementedError
      end
    end
  end
end