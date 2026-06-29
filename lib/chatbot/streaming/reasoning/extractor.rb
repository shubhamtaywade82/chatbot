# frozen_string_literal: true

module Chatbot
  module Streaming
    module Reasoning
      class Extractor
        def extract_start(buffer); raise NotImplementedError; end
        def extract_end(buffer); raise NotImplementedError; end
      end

      class Qwen < Extractor
        START_TAG = '<think>'
        END_TAG = '</think>'

        def extract_start(buffer)
          return nil unless (idx = buffer.index(START_TAG))
          {
            before: buffer[0...idx],
            after: buffer[(idx + START_TAG.length)..-1] || +""
          }
        end

        def extract_end(buffer)
          return nil unless (idx = buffer.index(END_TAG))
          {
            before: buffer[0...idx],
            after: buffer[(idx + END_TAG.length)..-1] || +""
          }
        end
      end

      class DeepSeek < Extractor
        START_TAG = '<think>'
        END_TAG = '</think>'

        def extract_start(buffer)
          return nil unless (idx = buffer.index(START_TAG))
          {
            before: buffer[0...idx],
            after: buffer[(idx + START_TAG.length)..-1] || +""
          }
        end

        def extract_end(buffer)
          return nil unless (idx = buffer.index(END_TAG))
          {
            before: buffer[0...idx],
            after: buffer[(idx + END_TAG.length)..-1] || +""
          }
        end
      end

      class None < Extractor
        def extract_start(buffer); nil; end
        def extract_end(buffer); nil; end
      end
    end
  end
end