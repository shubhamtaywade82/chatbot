# frozen_string_literal: true

module Chatbot
  module Streaming
    class Parser
      attr_reader :buffer, :thinking, :answer, :in_thinking

      def initialize(extractor: nil)
        @buffer = +""
        @thinking = +""
        @answer = +""
        @in_thinking = false
        @extractor = extractor
      end

      def feed(chunk)
        @buffer << chunk
        process_buffer
      end

      def flush
        if @in_thinking
          @thinking << @buffer
        else
          @answer << @buffer
        end
        @buffer = +""
      end

      private

      def process_buffer
        loop do
          if !@in_thinking
            if @extractor && (result = @extractor.extract_start(@buffer))
              @answer << result[:before]
              @buffer = result[:after]
              @in_thinking = true
              next
            end
            break if @buffer.length < 50
            flush_answer
            break
          else
            if @extractor && (result = @extractor.extract_end(@buffer))
              @thinking << result[:before]
              @buffer = result[:after]
              @in_thinking = false
              next
            end
            break if @buffer.length < 50
            flush_thinking
            break
          end
        end
      end

      def flush_answer
        flush = @buffer[0...-10]
        @answer << flush
        @buffer = @buffer[-10..-1] || +""
      end

      def flush_thinking
        flush = @buffer[0...-10]
        @thinking << flush
        @buffer = @buffer[-10..-1] || +""
      end
    end
  end
end