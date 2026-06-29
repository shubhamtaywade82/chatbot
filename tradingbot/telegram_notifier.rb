# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module TradingBot
  class TelegramNotifier
    def self.send_alert(config, message)
      enabled = ENV["TELEGRAM_ENABLED"] == "true" || config.telegram_enabled
      return unless enabled

      token = ENV["TELEGRAM_BOT_TOKEN"] || config.telegram_bot_token
      chat_id = ENV["TELEGRAM_CHAT_ID"] || config.telegram_chat_id

      return if token.nil? || token.empty? || chat_id.nil? || chat_id.empty?

      Thread.new do
        begin
          uri = URI("https://api.telegram.org/bot#{token}/sendMessage")
          # Strip any ANSI color codes from message before sending to Telegram
          clean_msg = message.gsub(/\e\[\d+m/, "")
          
          params = {
            chat_id: chat_id,
            text: clean_msg,
            parse_mode: "Markdown"
          }
          
          response = Net::HTTP.post_form(uri, params)
          unless response.code == "200"
            warn "Telegram send failed: #{response.body}"
          end
        rescue => e
          warn "Telegram error: #{e.message}"
        end
      end
    end
  end
end
