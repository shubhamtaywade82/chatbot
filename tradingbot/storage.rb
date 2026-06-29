require "sqlite3"
require "json"
require "fileutils"

module TradingBot
  class Storage
    DB_PATH = File.join(__dir__, "trading_bot.db")

    def initialize(path = DB_PATH)
      @db = SQLite3::Database.new(path)
      @db.results_as_hash = true
      migrate
    end

    def migrate
      @db.execute_batch(<<~SQL)
        CREATE TABLE IF NOT EXISTS trades (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          symbol TEXT NOT NULL,
          direction TEXT NOT NULL CHECK(direction IN ('LONG','SHORT')),
          entry_price REAL NOT NULL,
          exit_price REAL,
          quantity REAL NOT NULL,
          stop_loss REAL NOT NULL,
          take_profit_1 REAL,
          take_profit_2 REAL,
          take_profit_3 REAL,
          status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','closed','cancelled')),
          pnl REAL,
          pnl_pct REAL,
          rr_ratio REAL,
          fees REAL DEFAULT 0,
          entry_reason TEXT,
          exit_reason TEXT,
          entry_time TEXT NOT NULL DEFAULT (datetime('now')),
          exit_time TEXT,
          strategy TEXT DEFAULT 'smc',
          model_name TEXT,
          metadata TEXT,
          backtest_id TEXT
        );

        CREATE TABLE IF NOT EXISTS signals (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          symbol TEXT NOT NULL,
          direction TEXT NOT NULL,
          confidence REAL,
          entry_price REAL,
          stop_loss REAL,
          take_profit_1 REAL,
          take_profit_2 REAL,
          take_profit_3 REAL,
          rr_ratio REAL,
          reason TEXT,
          raw_response TEXT,
          event_type TEXT,
          model_name TEXT,
          created_at TEXT NOT NULL DEFAULT (datetime('now')),
          acted BOOLEAN DEFAULT 0,
          trade_id INTEGER REFERENCES trades(id)
        );

        CREATE TABLE IF NOT EXISTS events (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          symbol TEXT NOT NULL,
          event_type TEXT NOT NULL,
          timeframe TEXT,
          price REAL,
          description TEXT,
          created_at TEXT NOT NULL DEFAULT (datetime('now')),
          analyzed BOOLEAN DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS backtest_runs (
          id TEXT PRIMARY KEY,
          config TEXT,
          started_at TEXT NOT NULL DEFAULT (datetime('now')),
          finished_at TEXT,
          total_trades INTEGER DEFAULT 0,
          win_rate REAL,
          total_pnl REAL,
          max_drawdown REAL,
          sharpe_ratio REAL,
          profit_factor REAL
        );

        CREATE TABLE IF NOT EXISTS bot_state (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
      SQL

      @db.execute("ALTER TABLE signals ADD COLUMN raw_response TEXT") rescue nil

      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS llm_responses (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          symbol TEXT,
          event_type TEXT,
          prompt TEXT,
          response TEXT NOT NULL,
          parsed_action TEXT,
          model_name TEXT,
          duration_ms INTEGER,
          created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
      SQL
    end

    def log_llm_response(symbol:, event_type:, prompt:, response:, parsed_action:, duration_ms:)
      @db.execute(<<~SQL, [symbol, event_type, prompt, response, parsed_action, nil, duration_ms])
        INSERT INTO llm_responses (symbol, event_type, prompt, response, parsed_action, model_name, duration_ms)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      SQL
    end

    def log_signal(signal)
      @db.execute(<<~SQL, signal)
        INSERT INTO signals (symbol, direction, confidence, entry_price, stop_loss,
                             take_profit_1, take_profit_2, take_profit_3,
                             rr_ratio, reason, raw_response, event_type, model_name)
        VALUES (:symbol, :direction, :confidence, :entry_price, :stop_loss,
                :take_profit_1, :take_profit_2, :take_profit_3,
                :rr_ratio, :reason, :raw_response, :event_type, :model_name)
      SQL
      @db.last_insert_row_id
    end

    def open_trade(trade)
      @db.execute(<<~SQL, trade)
        INSERT INTO trades (symbol, direction, entry_price, quantity, stop_loss,
                            take_profit_1, take_profit_2, take_profit_3,
                            entry_reason, strategy, model_name, entry_time, metadata)
        VALUES (:symbol, :direction, :entry_price, :quantity, :stop_loss,
                :take_profit_1, :take_profit_2, :take_profit_3,
                :entry_reason, :strategy, :model_name, datetime('now'), :metadata)
      SQL
      @db.last_insert_row_id
    end

    def close_trade(id, exit_price:, pnl:, pnl_pct:, rr_ratio:, exit_reason:, fees: 0)
      params = { id: id, exit_price: exit_price, pnl: pnl, pnl_pct: pnl_pct,
                 rr_ratio: rr_ratio, exit_reason: exit_reason, fees: fees, status: "closed" }
      @db.execute(<<~SQL, params)
        UPDATE trades SET exit_price = :exit_price, pnl = :pnl, pnl_pct = :pnl_pct,
                          rr_ratio = :rr_ratio, exit_reason = :exit_reason,
                          fees = :fees, status = :status,
                          exit_time = datetime('now')
        WHERE id = :id
      SQL
    end

    def cancel_trade(id, reason: "cancelled")
      @db.execute("UPDATE trades SET status = 'cancelled', exit_reason = ? WHERE id = ?",
                  [reason, id])
    end

    def open_trades(symbol: nil)
      query = "SELECT * FROM trades WHERE status = 'open'"
      query += " AND symbol = ?" if symbol
      rows = symbol ? @db.execute(query, [symbol]) : @db.execute(query)
      rows
    end

    def recent_trades(limit: 20)
      @db.execute("SELECT * FROM trades ORDER BY entry_time DESC LIMIT ?", [limit])
    end

    def recent_signals(limit: 20)
      @db.execute("SELECT * FROM signals ORDER BY created_at DESC LIMIT ?", [limit])
    end

    def recent_llm_responses(limit: 20)
      @db.execute("SELECT * FROM llm_responses ORDER BY created_at DESC LIMIT ?", [limit])
    end

    def log_event(symbol:, event_type:, timeframe: nil, price: nil, description:)
      @db.execute(<<~SQL, [symbol, event_type, timeframe, price, description])
        INSERT INTO events (symbol, event_type, timeframe, price, description)
        VALUES (?, ?, ?, ?, ?)
      SQL
    end

    def unanalyzed_events(symbol: nil)
      query = "SELECT * FROM events WHERE analyzed = 0"
      params = []
      if symbol
        query += " AND symbol = ?"
        params << symbol
      end
      query += " ORDER BY created_at ASC"
      rows = @db.execute(query, params)
      rows
    end

    def mark_events_analyzed(event_ids)
      return if event_ids.empty?
      placeholders = event_ids.map { "?" }.join(",")
      @db.execute("UPDATE events SET analyzed = 1 WHERE id IN (#{placeholders})", event_ids)
    end

    def set_state(key, value)
      @db.execute("INSERT OR REPLACE INTO bot_state (key, value) VALUES (?, ?)", [key, value.to_s])
    end

    def get_state(key)
      row = @db.execute("SELECT value FROM bot_state WHERE key = ?", [key]).first
      row&.dig("value")
    end

    def create_backtest(id, config)
      @db.execute("INSERT INTO backtest_runs (id, config) VALUES (?, ?)",
                  [id, JSON.generate(config)])
    end

    def finish_backtest(id, stats)
      @db.execute(<<~SQL, stats.merge(id: id))
        UPDATE backtest_runs SET finished_at = datetime('now'),
          total_trades = :total_trades, win_rate = :win_rate, total_pnl = :total_pnl,
          max_drawdown = :max_drawdown, sharpe_ratio = :sharpe_ratio,
          profit_factor = :profit_factor
        WHERE id = :id
      SQL
    end

    def summary
      trades = @db.execute("SELECT COUNT(*) as c FROM trades").first["c"]
      open = @db.execute("SELECT COUNT(*) as c FROM trades WHERE status = 'open'").first["c"]
      closed = @db.execute("SELECT COUNT(*) as c FROM trades WHERE status = 'closed'").first["c"]
      winners = @db.execute("SELECT COUNT(*) as c FROM trades WHERE status = 'closed' AND pnl > 0").first["c"]
      total_pnl = @db.execute("SELECT COALESCE(SUM(pnl), 0) as s FROM trades WHERE status = 'closed'").first["s"]
      llm_calls = @db.execute("SELECT COUNT(*) as c FROM llm_responses").first["c"]
      { total_trades: trades, open_trades: open, closed_trades: closed,
        winners: winners, total_pnl: total_pnl.round(2), llm_calls: llm_calls }
    end
  end
end
