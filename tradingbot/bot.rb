#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.join(__dir__, "..", "lib")
$LOAD_PATH.unshift File.join(__dir__, "..", "config")

require "bundler/setup"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "time"

require_relative "config"
require_relative "storage"
require_relative "engine"
require_relative "backtest"

module TradingBot
  class CLI
    def self.run
      config_path = File.join(__dir__, "config.yml")
      config = Config.load(config_path)

      mode = parse_args(config)

      case mode
      when :live, :paper
        config.mode = mode.to_s
        engine = Engine.new(config)
        engine.run
      when :backtest
        Backtest.run(config)
      when :optimize
        param_grid = [
          { max_risk_per_trade_pct: 1.0, min_rr_ratio: 2.0 },
          { max_risk_per_trade_pct: 1.5, min_rr_ratio: 2.0 },
          { max_risk_per_trade_pct: 2.0, min_rr_ratio: 2.0 },
          { max_risk_per_trade_pct: 2.0, min_rr_ratio: 2.5 },
          { max_risk_per_trade_pct: 2.0, min_rr_ratio: 3.0 }
        ]
        Backtest.optimize(config, param_grid)
      when :summary
        storage = Storage.new
        summary = storage.summary
        puts "=" * 50
        puts "TradingBot Summary"
        puts "=" * 50
        puts "Total Trades: #{summary[:total_trades]}"
        puts "Open Trades: #{summary[:open_trades]}"
        puts "Closed Trades: #{summary[:closed_trades]}"
        puts "Winners: #{summary[:winners]}"
        puts "Total PnL: $#{summary[:total_pnl]}"
        puts ""
        puts "Recent Trades:"
        storage.recent_trades(limit: 10).each do |t|
          puts "  #{t["entry_time"]} #{t["direction"]} #{t["symbol"]} @ $#{t["entry_price"]} PnL=#{t["pnl"]} #{t["status"]}"
        end
      end
    end

    private

    def self.parse_args(config)
      mode = :paper

      OptionParser.new do |opts|
        opts.banner = "Usage: ruby bot.rb [options]"

        opts.on("--live", "Run in live execution mode (requires CoinDCX credentials)") do
          mode = :live
        end

        opts.on("--paper", "Run in paper trading mode (default)") do
          mode = :paper
        end

        opts.on("--backtest", "Run backtest") do
          mode = :backtest
        end

        opts.on("--optimize", "Run parameter optimization") do
          mode = :optimize
        end

        opts.on("--summary", "Show trade summary") do
          mode = :summary
        end

        opts.on("--config=PATH", "Path to config YAML") do |path|
          config_path = path
        end

        opts.on("--symbols=SYMS", "Comma-separated symbols (overrides config)") do |syms|
          config.symbols = syms.split(",").map(&:strip).map(&:upcase)
        end

        opts.on("--start=DATE", "Backtest start date (YYYY-MM-DD)") do |d|
          config.start_date = d
        end

        opts.on("--end=DATE", "Backtest end date (YYYY-MM-DD)") do |d|
          config.end_date = d
        end

        opts.on("--balance=AMOUNT", Float, "Initial balance for backtest") do |b|
          config.initial_balance = b
        end

        opts.on("--verbose", "Verbose output") do
          config.verbose = true
        end

        opts.on("-h", "--help", "Show help") do
          puts opts
          exit
        end
      end.parse!

      mode
    end
  end
end

TradingBot::CLI.run if __FILE__ == $PROGRAM_NAME
