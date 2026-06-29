# frozen_string_literal: true

require_relative "../../lib/chatbot/tools/calculator"

RSpec.describe Chatbot::Tools::Calculator do
  let(:calculator) { described_class.new }

  it "evaluates simple arithmetic" do
    expect(calculator.execute({ "expression" => "2 + 3" }))
      .to eq({ result: 5 })
  end

  it "respects operator precedence" do
    expect(calculator.execute({ "expression" => "2 + 3 * 4" }))
      .to eq({ result: 14 })
  end

  it "handles right-associative exponentiation" do
    expect(calculator.execute({ "expression" => "2 ** 3 ** 2" }))
      .to eq({ result: 512 })
  end

  it "handles unary minus" do
    expect(calculator.execute({ "expression" => "-5 + 2" }))
      .to eq({ result: -3 })
  end

  it "handles unary minus with multiplication" do
    expect(calculator.execute({ "expression" => "3 * -2" }))
      .to eq({ result: -6 })
  end

  it "handles parentheses" do
    expect(calculator.execute({ "expression" => "(10 - 2) / 4" }))
      .to eq({ result: 2 })
  end

  it "handles decimals" do
    expect(calculator.execute({ "expression" => "2.5 * 4" }))
      .to eq({ result: 10.0 })
  end

  it "rejects division by zero" do
    expect(calculator.execute({ "expression" => "1 / 0" }))
      .to eq({ error: "Division by zero" })
  end

  it "rejects invalid characters" do
    expect(calculator.execute({ "expression" => "2 + abc" }))
      .to eq({ error: "Empty or invalid expression" })
  end

  it "rejects malformed expressions" do
    expect(calculator.execute({ "expression" => "2 +" }))
      .to eq({ error: "Unexpected tokens remaining" })
  end
end