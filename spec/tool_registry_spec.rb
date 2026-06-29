# frozen_string_literal: true

require_relative "../../lib/chatbot/tools/registry"
require_relative "../../lib/chatbot/tools/calculator"

RSpec.describe Chatbot::ToolRegistry do
  let(:registry) { described_class.new }

  before do
    registry.register(Chatbot::Tools::Calculator)
  end

  it "lists registered tools" do
    expect(registry.names).to include("calculate")
  end

  it "returns schema for Ollama" do
    schema = registry.schema
    expect(schema.first[:type]).to eq("function")
    expect(schema.first[:function][:name]).to eq("calculate")
  end

  it "executes a registered tool" do
    result = registry.execute("calculate", { "expression" => "1 + 1" })
    expect(result).to eq({ result: 2 })
  end

  it "returns error for unknown tools" do
    result = registry.execute("unknown", {})
    expect(result[:error]).to include("Unknown tool")
  end
end