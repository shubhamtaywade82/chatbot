# frozen_string_literal: true

require "json"

module Chatbot
  class SchemaValidator
    class ValidationError < StandardError; end

    def initialize(schema)
      @schema = schema
    end

    def validate(json_string)
      parsed = JSON.parse(json_string)
      validate_node(parsed, @schema)
      parsed
    rescue JSON::ParserError => e
      raise ValidationError, "Invalid JSON: #{e.message}"
    end

    private

    def validate_node(value, schema)
      case schema["type"]
      when "object"
        raise ValidationError, "Expected object, got #{value.class}" unless value.is_a?(Hash)
        schema["required"]&.each do |key|
          raise ValidationError, "Missing required key: #{key}" unless value.key?(key)
        end
        schema["properties"]&.each do |key, prop_schema|
          validate_node(value[key], prop_schema) if value.key?(key)
        end
      when "string"
        raise ValidationError, "Expected string, got #{value.class}" unless value.is_a?(String)
      when "number"
        raise ValidationError, "Expected number, got #{value.class}" unless value.is_a?(Numeric)
      when "integer"
        raise ValidationError, "Expected integer, got #{value.class}" unless value.is_a?(Integer)
      when "boolean"
        raise ValidationError, "Expected boolean" unless [true, false].include?(value)
      when "array"
        raise ValidationError, "Expected array, got #{value.class}" unless value.is_a?(Array)
        value.each { |item| validate_node(item, schema["items"]) } if schema["items"]
      when "null"
        raise ValidationError, "Expected null" unless value.nil?
      end
    end
  end
end