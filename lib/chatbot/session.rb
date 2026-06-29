# frozen_string_literal: true

require "timeout"
require "ollama_client"

module Chatbot
  class Session
    attr_reader :client, :conversation, :config, :renderer, :logger,
                :tool_registry, :events, :middleware, :cancelled

    def initialize(config:, renderer:, logger:, tool_registry:, store: nil, middleware: nil)
      @config = config
      @renderer = renderer
      @logger = logger
      @tool_registry = tool_registry
      @events = EventBus.new(logger: logger)
      @cancelled = false
      @middleware = middleware || Middleware::Pipeline.new

      ollama_config = Ollama::Config.new
      ollama_config.base_url = config.base_url
      ollama_config.timeout = config.timeout
      ollama_config.api_keys = config.api_keys if config.api_keys
      ollama_config.enable_multi_key_concurrency = config.enable_multi_key_concurrency

      @client = Ollama::Client.new(config: ollama_config)

      store ||= Stores::Memory.new
      @conversation = Conversation.new(config: config, store: store)

      setup_cancellation!
    end

    def chat(user_input, tools: false, schema: nil, think: true)
      return { error: "Session cancelled" } if @cancelled

      conversation.add(UserMessage.new(content: user_input))

      request = {
        model: config.model,
        messages: conversation.to_api,
        tools: tools ? tool_registry.schema : nil,
        schema: schema,
        think: think,
        options: { num_predict: config.max_response_tokens }
      }

      events.emit(:before_request, request: request)

      result = middleware.call(request) do |req|
        if schema
          structured_chat(schema)
        elsif tools && tool_registry.names.any?
          tool_chat
        else
          stream_chat(think: think)
        end
      end

      events.emit(:after_request, result: result)
      result
    rescue => e
      logger.log(event: :error, message: e.message, class: e.class.name)
      { error: e.message }
    end

    def embed(text)
      client.embeddings.embed(
        model: config.embedding_model,
        input: text
      )
    end

    def cancel!
      @cancelled = true
      events.emit(:cancelled)
    end

    def reset_cancel!
      @cancelled = false
    end

    def switch_model(new_model)
      config.model = new_model
      conversation.clear!
      renderer.on_message("Switched to #{new_model}. History cleared.")
    end

    private

    THINK_START = ''

    def stream_chat(think:)
      extractor = reasoning_extractor
      parser = Streaming::Parser.new(extractor: extractor)
      thought_buf = +""

      renderer.on_start

      client.chat(
        messages: conversation.to_api,
        model: config.model,
        think: think,
        options: { num_predict: config.max_response_tokens },
        hooks: {
          on_thought: ->(event) {
            case event.type
            when :thought_delta
              thought_buf << event.data
              renderer.on_token(event.data, type: :thinking)
            end
          },
          on_token: ->(token) {
            return if @cancelled
            parser.feed(token)
            type = parser.in_thinking ? :thinking : :answer
            renderer.on_token(token, type: type)
          },
          on_complete: -> {
            parser.flush
            renderer.on_finish
            reasoning = thought_buf.empty? ? parser.thinking : thought_buf
            conversation.add(AssistantMessage.new(
              content: parser.answer,
              reasoning: reasoning
            ))
          },
          on_error: ->(err) {
            renderer.on_error(err)
          }
        }
      )

      thinking = thought_buf.empty? ? parser.thinking : thought_buf
      { thinking: thinking, answer: parser.answer }
    end

    def tool_chat
      iteration = 0

      while iteration < config.max_tool_iterations
        iteration += 1
        return { error: "Cancelled" } if @cancelled

        response = client.chat(
          messages: conversation.to_api,
          model: config.model,
          tools: tool_registry.schema
        )

        msg = response.message

        if msg.tool_calls && !msg.tool_calls.empty?
          msg.tool_calls.each do |call|
            events.emit(:tool_call, name: call.name, arguments: call.arguments, iteration: iteration)
            renderer.on_tool(call.name, call.arguments)

            tool_result = Timeout.timeout(10) do
              tool_registry.execute(call.name, call.arguments)
            end

            conversation.add(AssistantMessage.new(
              content: nil,
              tool_calls: [call.to_h],
              metadata: { tool_call_id: call.name }
            ))

            conversation.add(ToolMessage.new(
              content: tool_result.to_json,
              tool_call_id: call.name
            ))
          end
        else
          conversation.add(AssistantMessage.new(content: msg.content))
          return { answer: msg.content, iterations: iteration }
        end
      end

      { error: "Max tool iterations (#{config.max_tool_iterations}) reached", iterations: iteration }
    rescue Timeout::Error
      { error: "Tool execution timeout" }
    end

    def structured_chat(schema)
      response = client.chat(
        messages: conversation.to_api,
        model: config.model,
        format: schema
      )

      content = response.message.content
      validator = SchemaValidator.new(schema)
      parsed = validator.validate(content)

      conversation.add(AssistantMessage.new(content: content))
      { raw: content, parsed: parsed }
    rescue SchemaValidator::ValidationError => e
      { raw: content, error: "Schema validation failed: #{e.message}" }
    end

    def reasoning_extractor
      case config.model
      when /qwen/i then Streaming::Reasoning::Qwen.new
      when /deepseek/i then Streaming::Reasoning::DeepSeek.new
      else Streaming::Reasoning::None.new
      end
    end

    def setup_cancellation!
      Signal.trap("INT") do
        if @cancelled
          exit 130
        else
          cancel!
          renderer.on_message("\n[Cancelling current request...]")
        end
      end
    end
  end
end