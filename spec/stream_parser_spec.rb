# frozen_string_literal: true

require_relative "../../lib/chatbot/streaming/parser"
require_relative "../../lib/chatbot/streaming/reasoning/extractor"

RSpec.describe Chatbot::Streaming::Parser do
  let(:extractor) { Chatbot::Streaming::Reasoning::Qwen.new }
  let(:parser) { described_class.new(extractor: extractor) }

  it "extracts thinking and answer" do
    parser.feed("Hello ")
    parser.feed("world")
    parser.feed("!")
    parser.flush

    expect(parser.answer).to include("Hello world!")
    expect(parser.thinking).to eq("")
  end

  it "handles empty input" do
    parser.flush
    expect(parser.answer).to eq("")
    expect(parser.thinking).to eq("")
  end

  it "handles qwen reasoning tags" do
    parser.feed("Hello ")
    parser.feed("")
    parser.feed("thinking content")
    parser.feed("")
    parser.feed(" world")
    parser.flush

    expect(parser.thinking).to eq("thinking content")
    expect(parser.answer).to eq("Hello  world")
  end
end