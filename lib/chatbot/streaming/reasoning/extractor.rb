# frozen_string_literal: true

# Minimal reasoning chunk extractors.

# Qwen + models: basic state machine that alternates between taking chunks as
# answer content and as thinking content. It supports simple Qwen reasoning
# by toggling on empty chunks, and also emits the final accumulated buffers
# on `flush`.
module Chatbot
  module Streaming
    module Reasoning
      class Qwen
        attr_reader :answer, :thinking

        def initialize
          @answer   = +""
          @thinking = +""
          @mode     = :answer
        end

        def feed(chunk)
          text = chunk.to_s

          if text.empty?
            @mode = (@mode == :answer ? :thinking : :answer)
            return { answer: "", thinking: "" }
          end

          if @mode == :thinking
            @thinking << text
            { answer: "", thinking: text }
          else
            @answer << text
            { answer: text, thinking: "" }
          end
        end

        def flush
          { answer: @answer.dup, thinking: @thinking.dup }
        end
      end

      # Passthrough extractor for models without structured reasoning tags.
      class Passthrough
        def initialize
          @answer = +""
        end

        def feed(chunk)
          text = chunk.to_s
          @answer << text
          { answer: text, thinking: "" }
        end

        def flush
          { answer: @answer.dup, thinking: "" }
        end

        def answer
          @answer.dup
        end

        def thinking
          ""
        end
      end
    end
  end
end
