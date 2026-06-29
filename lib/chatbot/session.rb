require "securerandom"
require "net/http"
require "uri"
require "ollama_agent"

# Return only custom tools — no built-in coding tools
module OllamaAgent
  def self.tools_for(read_only:, orchestrator:)
    Tools::Registry.custom_schemas
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

# Register chatbot tools
OllamaAgent::Tools.register("http_get", schema: {
  description: "Fetch any HTTP/HTTPS URL and return the response body. " \
               "Use for API calls (crypto prices, weather, etc.), web pages, or any public URL.",
  parameters: {
    type: "object",
    properties: {
      url: {
        type: "string",
        description: "Full URL to fetch (http:// or https:// only)"
      }
    },
    required: ["url"]
  }
}) do |args, root:, read_only:|
  uri = URI.parse(args["url"].to_s)
  raise "Only http/https allowed" unless %w[http https].include?(uri.scheme)

  Net::HTTP.get(uri)
rescue => e
  "Error: #{e.message}"
end

OllamaAgent::Tools.register("current_time", schema: {
  description: "Get the current date and time. Use when the user asks about today's date, " \
               "current time, day of week, or any time-related question.",
  parameters: {
    type: "object",
    properties: {},
    required: []
  }
}) do |args, root:, read_only:|
  Time.now.strftime("%Y-%m-%d %H:%M:%S %Z")
end

OllamaAgent::Tools.register("calculate", schema: {
  description: "Evaluate a mathematical expression and return the numeric result. " \
               "Supports +, -, *, /, ** (power), and parentheses. " \
               "Use for precise computation rather than mental arithmetic.",
  parameters: {
    type: "object",
    properties: {
      expression: {
        type: "string",
        description: "Arithmetic expression, e.g. '(12 + 8) / 5' or '2 ** 10'"
      }
    },
    required: ["expression"]
  }
}) do |args, root:, read_only:|
  expr = args["expression"].to_s
  raise "Empty expression" if expr.empty?
  raise "Only digits, operators, spaces, parens, and decimal points allowed" unless expr.match?(/\A[\d\s+\-*\/()%.,e]+\z/)

  eval(expr).to_s
rescue => e
  "Error: #{e.message}"
end

module Chatbot
  class Session
    SYSTEM_PROMPT = "You are a helpful, concise assistant with access to tools. " \
                    "Use http_get to fetch live data, current_time for time queries, " \
                    "and calculate for math."

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
      ENV["OLLAMA_AGENT_SKILLS"] = "0"
      ENV["OLLAMA_AGENT_EXTERNAL_SKILLS"] = "0"
    end
  end
end
