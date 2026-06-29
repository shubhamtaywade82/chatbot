require "securerandom"
require "ollama_agent"

module Chatbot
  class Session
    SYSTEM_PROMPT = "You are a helpful, concise assistant."

    def initialize(config)
      @config = config
      @session_id = SecureRandom.uuid
      set_ollama_env(config)
      build_runner
    end

    def chat(input)
      @runner.run(input)
    rescue => e
      { error: e.message }
    end

    def reset!
      @session_id = SecureRandom.uuid
      build_runner
      "History cleared."
    end

    def switch_model(name)
      @config.model = name
      reset!
    end

    private

    def build_runner
      @runner = OllamaAgent::Runner.build(
        model: @config.model,
        system_prompt: SYSTEM_PROMPT,
        stream: true,
        read_only: true,
        skills_enabled: false,
        think: nil,
        http_timeout: @config.timeout,
        session_id: @session_id,
        resume: false
      )
    end

    def set_ollama_env(config)
      ENV["OLLAMA_BASE_URL"] = config.base_url
      ENV["OLLAMA_API_KEY"] = config.api_keys if config.api_keys&.length&.positive?
    end
  end
end
