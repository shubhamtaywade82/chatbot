# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Chatbot
  module Phase1
    class BinanceAdapter
      BASE_URL = "https://api.binance.com"

      def initialize(base_url = BASE_URL)
        @base_url = base_url
      end

      # Returns ticker price for a symbol
      # e.g., { "symbol" => "ETHUSDT", "price" => "3500.00" }
      def ticker(symbol)
        url = URI("#{@base_url}/api/v3/ticker/price?symbol=#{symbol.upcase}")
        get_json(url)
      end

      # Returns klines for a symbol and interval (e.g., "1h", "15m")
      # Returns parsed array of candles with formatted keys
      def klines(symbol, interval, limit = 100)
        url = URI("#{@base_url}/api/v3/klines?symbol=#{symbol.upcase}&interval=#{interval}&limit=#{limit}")
        raw = get_json(url)
        return [] unless raw.is_a?(Array)

        raw.map do |k|
          {
            time: k[0] / 1000,
            open: k[1].to_f,
            high: k[2].to_f,
            low: k[3].to_f,
            close: k[4].to_f,
            volume: k[5].to_f,
            close_time: k[6] / 1000
          }
        end
      end

      # Returns order book for a symbol
      def order_book(symbol, limit = 20)
        url = URI("#{@base_url}/api/v3/depth?symbol=#{symbol.upcase}&limit=#{limit}")
        raw = get_json(url)
        return { bids: [], asks: [] } unless raw.is_a?(Hash)

        {
          bids: (raw["bids"] || []).map { |b| [b[0].to_f, b[1].to_f] },
          asks: (raw["asks"] || []).map { |a| [a[0].to_f, a[1].to_f] }
        }
      end

      # Returns 24hr stats for a symbol
      def stats_24hr(symbol)
        url = URI("#{@base_url}/api/v3/ticker/24hr?symbol=#{symbol.upcase}")
        get_json(url)
      end

      private

      def get_json(url)
        response = Net::HTTP.get_response(url)
        if response.is_a?(Net::HTTPOK)
          JSON.parse(response.body)
        else
          raise "Failed to fetch from Binance: #{response.code} #{response.message}"
        end
      rescue => e
        { "error" => e.message }
      end
    end
  end
end
