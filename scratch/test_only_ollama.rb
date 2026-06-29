# frozen_string_literal: true

require "bundler/setup"
require "ollama_client"
require "json"

config = Ollama::Config.new
config.base_url = "http://localhost:11434"
config.timeout = 120

client = Ollama::Client.new(config: config)

system_prompt = "You are a helpful assistant. Reply with a short JSON like {\"status\": \"ok\"}."
user_message = "Hello, are you there?"

puts "Sending direct chat request to Ollama..."
start_time = Time.now
begin
  resp = client.chat(
    model: "qwen3.5:4b",
    messages: [
      { role: "system", content: system_prompt },
      { role: "user", content: user_message }
    ],
    options: { temperature: 0.2 }
  )
  duration = Time.now - start_time
  puts "Completed in #{duration.round(2)}s"
  puts "Response class: #{resp.class}"
  if resp.respond_to?(:message)
    puts "Message: #{resp.message.content}"
  else
    puts "Resp keys/inspect: #{resp.inspect}"
  end
rescue => e
  puts "Failed with error: #{e.class} - #{e.message}"
  puts e.backtrace.join("\n")
end
