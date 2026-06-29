# frozen_string_literal: true

require_relative "../../lib/chatbot/conversation"
require_relative "../../lib/chatbot/stores/memory"
require_relative "../../lib/chatbot/message"

RSpec.describe Chatbot::Conversation do
  let(:config) do
    Chatbot::Config.new.tap do |c|
      c.max_history_tokens = 100
      c.min_history_messages = 2
    end
  end

  let(:store) { Chatbot::Stores::Memory.new }
  let(:conversation) { described_class.new(config: config, store: store) }

  it "adds messages" do
    conversation.add(Chatbot::UserMessage.new(content: "Hello"))
    expect(conversation.messages.length).to eq(1)
  end

  it "trims when token limit exceeded" do
    20.times do |i|
      conversation.add(Chatbot::UserMessage.new(content: "Message #{i} " * 50))
    end
    expect(conversation.messages.length).to be <= 20
  end

  it "persists to store" do
    conversation.add(Chatbot::UserMessage.new(content: "Test"))
    loaded = store.load
    expect(loaded.length).to be > 0
  end

  it "includes system prompt in API output" do
    conversation.add(Chatbot::UserMessage.new(content: "Hi"))
    api_messages = conversation.to_api
    expect(api_messages.first[:role]).to eq("system")
  end
end