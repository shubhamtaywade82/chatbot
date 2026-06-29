# frozen_string_literal: true

module Chatbot
  class PluginRegistry
    def initialize
      @plugins = {}
    end

    def register(name, plugin)
      @plugins[name] = plugin
      plugin.setup if plugin.respond_to?(:setup)
    end

    def get(name)
      @plugins[name]
    end

    def all
      @plugins.values
    end

    def setup_all(session)
      @plugins.each do |name, plugin|
        plugin.setup(session) if plugin.respond_to?(:setup)
      end
    end
  end

  class Plugin
    def self.inherited(subclass)
      subclass.extend(ClassMethods)
    end

    module ClassMethods
      def register!(registry, **config)
        registry.register(name, new(**config))
      end
    end

    def setup(session); end
  end
end