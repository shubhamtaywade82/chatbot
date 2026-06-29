# frozen_string_literal: true

module Chatbot
  module Renderers
    class Base
      def on_start; end
      def on_token(token, type: :answer); end
      def on_reasoning(token); end
      def on_tool(name, args); end
      def on_message(text); end
      def on_finish; end
      def on_error(err); end
      def prompt(text); end
    end
  end
end