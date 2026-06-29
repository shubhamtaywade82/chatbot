# frozen_string_literal: true

require "sqlite3"
require_relative "base"

module Chatbot
  module Stores
    class SQLite < Base
      def initialize(path: "./chat_history.db")
        @db = SQLite3::Database.new(path)
        @db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            role TEXT NOT NULL,
            content TEXT,
            metadata TEXT,
            created_at TEXT
          )
        SQL
      end

      def save(messages)
        @db.transaction do
          @db.execute("DELETE FROM messages")
          messages.each do |msg|
            @db.execute(
              "INSERT INTO messages (role, content, metadata, created_at) VALUES (?, ?, ?, ?)",
              [msg.role, msg.content, msg.metadata.to_json, msg.created_at.iso8601]
            )
          end
        end
      end

      def load
        rows = @db.execute("SELECT role, content, metadata, created_at FROM messages ORDER BY id")
        rows.map do |row|
          Message.from_h(
            role: row[0],
            content: row[1],
            metadata: ::JSON.parse(row[2] || "{}", symbolize_names: true),
            created_at: row[3]
          )
        end
      end
    end
  end
end