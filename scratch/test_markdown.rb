# frozen_string_literal: true

require_relative "../lib/chatbot/terminal_markdown"

markdown_sample = <<~MD
  # 📊 BTCUSDT Market Analysis
  
  Some standard text with **bold** words, *italic* annotations, and `inline code`.
  
  ## 🔍 Key Levels & Structure
  
  - 🟢 **Bullish OB:** $58,358.77 - $59,456.0 [MITIGATED]
  - 🔴 Bearish OBs: All INVALIDATED
  
  > [!IMPORTANT]
  > Ranging market with no clear direction.
  
  | Setup | Direction | Entry | Stop-Loss | TP-1 | TP-2 | TP-3 |
  |---|---|---|---|---|---|---|
  | PB-7 Sweep | Long | 71.65 | 70.30 | 73.00 | 74.36 | 75.71 |
MD

puts "=== RENDERING MARKDOWN ==="
markdown_sample.each_line do |line|
  puts Chatbot::TerminalMarkdown.render_line(line.chomp)
end
puts "=========================="
