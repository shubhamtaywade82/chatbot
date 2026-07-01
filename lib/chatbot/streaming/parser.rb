module Chatbot
  module Streaming
    class Parser
      def initialize(extractor:)
        @extractor = extractor
        @buffers = { answer: +"", thinking: +"" }
      end

      def feed(chunk)
        parsed = @extractor.feed(chunk)
        @buffers[:answer] << parsed[:answer].to_s
        @buffers[:thinking] << parsed[:thinking].to_s if parsed[:thinking]
      end

      def flush
        self
      end

      def answer
        (@buffers[:answer]).to_s
      end

      def thinking
        @buffers[:thinking].to_s
      end
    end
  end
end
