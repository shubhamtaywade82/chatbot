# frozen_string_literal: true

require_relative "base"

module Chatbot
  module Tools
    class Weather < Base
      def self.name
        "get_weather"
      end

      def self.description
        "Get current weather for a city."
      end

      def self.parameters
        {
          type: "object",
          properties: {
            city: { type: "string", description: "City name" },
            unit: { type: "string", enum: %w[celsius fahrenheit], default: "celsius" }
          },
          required: ["city"]
        }
      end

      def execute(args)
        city = args["city"]
        {
          city: city,
          temperature: 22,
          condition: "sunny",
          humidity: 45,
          unit: args["unit"] || "celsius"
        }
      end
    end
  end
end