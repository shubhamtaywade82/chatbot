# frozen_string_literal: true

require "json"
require_relative "base"

module Chatbot
  module Stores
    class JSON < Base
      def initialize(path:)
        @path = path
      end

      def save(messages)
        File.write(@path, ::JSON.pretty_generate(messages.map(&:to_h)))
      rescue => e
      end

      def load
        return [] unless File.exist?(@path)
        data = ::JSON.parse(File.read(@path), symbolize_names: true)
        data.map { |h| Message.from_h(h) }
      rescue => e
        []
      end
    end
  end
end