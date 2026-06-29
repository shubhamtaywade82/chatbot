require "securerandom"
require "ollama_agent"

# Disable all tools — pure chatbot, no file editing
module OllamaAgent
  def self.tools_for(read_only:, orchestrator:)
    []
  end
end

# Monkey-patch ChatStreamProcessor to accumulate tool_calls across chunks
module Ollama
  class Client
    class ChatStreamProcessor
      alias_method :orig_process_message_field, :process_message_field
      def process_message_field(obj)
        calls = obj.dig("message", "tool_calls")
        (@acc_tool_calls ||= []).concat(calls) if calls
        orig_process_message_field(obj)
      end

      alias_method :orig_build_result, :build_result
      def build_result
        result = orig_build_result
        calls = @acc_tool_calls
        if calls && !calls.empty?
          result["message"] ||= {}
          result["message"]["tool_calls"] = calls
        end
        result
      end
    end
  end
end

# Fix ChatCoordinator to provide correct hook keys for ollama-client v1.3.0
module OllamaAgent
  class Agent
    class ChatCoordinator
      private

      def ollama_stream_hooks
        turn = -> { @current_turn }
        {
          on_thought: lambda { |event|
            data = event.respond_to?(:data) ? event.data.to_s : event.to_s
            @hooks.emit(:on_thinking, { token: data, turn: turn.call })
          },
          on_token: lambda { |*args|
            token = args[0]
            logprobs = args[1]
            payload = { token: token, turn: turn.call }
            payload[:logprobs] = logprobs unless logprobs.nil?
            @hooks.emit(:on_token, payload)
          },
          on_tool_call: lambda { |tc|
            @hooks.emit(:on_tool_call, {
              name: tc.respond_to?(:name) ? tc.name : tc["name"],
              args: tc.respond_to?(:arguments) ? tc.arguments : tc["arguments"],
              turn: turn.call
            })
          },
          on_complete: lambda {
            @hooks.emit(:on_complete, {})
          }
        }
      end
    end
  end
end

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
