# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Chatbot
  module Phase1
    class OllamaRouter
      attr_reader :endpoints

      # @param endpoints [Array<Hash>] Array of fallback config maps, e.g.:
      #   [{ url: "http://localhost:11434", key: "...", model: "qwen3.5:latest" }]
      def initialize(endpoints)
        @endpoints = endpoints
      end

      # Sends chat request to the first active endpoint, falling back on failure
      # @param messages [Array<Hash>] chat messages
      # @param format [String] response format target (e.g. "json")
      def chat(messages, format: "json", temperature: 0.2)
        last_error = nil

        @endpoints.each_with_index do |endpoint, index|
          begin
            url = URI("#{endpoint[:url]}/api/chat")
            header = { "Content-Type" => "application/json" }
            header["Authorization"] = "Bearer #{endpoint[:key]}" if endpoint[:key]

            body = {
              model: endpoint[:model],
              messages: messages,
              options: { temperature: temperature },
              stream: false
            }
            body[:format] = "json" if format == "json"

            http = Net::HTTP.new(url.host, url.port)
            http.read_timeout = 60
            http.open_timeout = 10

            # Use SSL if https is specified
            http.use_ssl = true if url.scheme == "https"

            request = Net::HTTP::Post.new(url.request_uri, header)
            request.body = body.to_json

            response = http.request(request)

            if response.is_a?(Net::HTTPOK)
              parsed = JSON.parse(response.body)
              return normalize_response(parsed, endpoint[:model], index)
            else
              raise "HTTP error #{response.code}: #{response.message}"
            end
          rescue => e
            last_error = e
            # Log or warn and try the next fallback
            warn "Ollama Router: Fallback from endpoint #{index} due to: #{e.message}"
          end
        end

        raise "All Ollama endpoints failed. Last error: #{last_error&.message}"
      end

      private

      # Normalizes Ollama API response into a standard internal format
      def normalize_response(raw_resp, model, endpoint_index)
        content = raw_resp.dig("message", "content") || raw_resp["response"] || ""
        {
          content: content.strip,
          model: model,
          endpoint_index: endpoint_index,
          raw: raw_resp
        }
      end
    end
  end
end
