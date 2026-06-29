# frozen_string_literal: true

module Chatbot
  class Config
    attr_accessor :base_url, :model, :api_keys, :enable_multi_key_concurrency,
                  :system_prompt, :timeout, :retries, :max_history_tokens,
                  :max_response_tokens, :max_tool_iterations, :min_history_messages,
                  :embedding_model, :conversation_persistence_path, :log_level,
                  :enable_streaming, :store_adapter

    attr_accessor :binance_api_key, :binance_api_secret

    def initialize
      @base_url = ENV.fetch("CHAT_BASE_URL", "http://localhost:11434")
      @model = ENV.fetch("OLLAMA_MODEL", "qwen3.5:4b")
      @api_keys = ENV["OLLAMA_API_KEYS"]
      @enable_multi_key_concurrency = ENV["ENABLE_MULTI_KEY_CONCURRENCY"] == "true"
      @system_prompt = "You are a helpful, concise assistant. Think step by step when solving problems."
      @timeout = 120
      @retries = 3
      @max_history_tokens = 4096
      @max_response_tokens = 1024
      @max_tool_iterations = 10
      @min_history_messages = 6
      @embedding_model = ENV.fetch("OLLAMA_EMBED_MODEL", "nomic-embed-text:latest")
      @conversation_persistence_path = ENV.fetch("CHAT_HISTORY_PATH", "./chat_history.json")
      @log_level = ENV.fetch("CHAT_LOG_LEVEL", "info").to_sym
      @enable_streaming = true
      @store_adapter = :json
      @binance_api_key = ENV["CHAT_BINANCE_API_KEY"]
      @binance_api_secret = ENV["CHAT_BINANCE_API_SECRET"]
    end

    def cloud?
      @base_url.include?("ollama.com") || @base_url.include?("https://")
    end
  end
end