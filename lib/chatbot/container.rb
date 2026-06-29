# frozen_string_literal: true

module Chatbot
  class Container
    class DependencyError < StandardError; end

    def initialize
      @registry = {}
    end

    def register(name, instance)
      @registry[name] = instance
    end

    def resolve(name)
      @registry[name] || raise(DependencyError, "Unknown dependency: #{name}")
    end

    def registered?(name)
      @registry.key?(name)
    end
  end
end