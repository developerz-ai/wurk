# frozen_string_literal: true

require 'logger'
require 'time'
require 'json'

module Wurk
  # Wurk's stdlib-compatible ::Logger subclass. The point of subclassing
  # (rather than configuring a vanilla ::Logger) is to ship default
  # formatters that read the thread-local Wurk::Context so every line
  # carries jid/bid/tags/elapsed without callers threading the hash through.
  #
  # Formatter selection at boot:
  #   - ENV["DYNO"] set        → Formatters::WithoutTimestamp (Heroku already prefixes)
  #   - otherwise              → Formatters::Pretty
  # Switch to Formatters::JSON manually for log aggregators that want NDJSON.
  #
  # Spec: docs/target/sidekiq-free.md §29.
  class Logger < ::Logger
    module Formatters
      class Base < ::Logger::Formatter
        SEVERITY_COLORS = {
          'DEBUG' => "\e[1;32mDEBUG\e[0m",
          'INFO' => "\e[1;34mINFO \e[0m",
          'WARN' => "\e[1;33mWARN \e[0m",
          'ERROR' => "\e[1;31mERROR\e[0m",
          'FATAL' => "\e[1;35mFATAL\e[0m"
        }.freeze

        def tid
          Wurk::Component.tid
        end

        def format_context(ctxt = Wurk::Context.current)
          return '' if ctxt.empty?

          " #{ctxt.map { |k, v| v.is_a?(Array) ? "#{k}=#{v.join(',')}" : "#{k}=#{v}" }.join(' ')}"
        end
      end

      class Pretty < Base
        def call(severity, time, _program_name, message)
          "#{SEVERITY_COLORS[severity]} #{time.utc.iso8601(3)} pid=#{::Process.pid} " \
            "tid=#{tid}#{format_context}: #{message}\n"
        end
      end

      class WithoutTimestamp < Pretty
        def call(severity, _time, _program_name, message)
          "#{SEVERITY_COLORS[severity]} pid=#{::Process.pid} tid=#{tid}#{format_context}: #{message}\n"
        end
      end

      class JSON < Base
        def call(severity, time, _program_name, message)
          hash = {
            ts: time.utc.iso8601(3),
            pid: ::Process.pid,
            tid: tid,
            lvl: severity,
            msg: message
          }
          ctx = Wurk::Context.current
          hash[:ctx] = ctx unless ctx.empty?
          "#{::JSON.generate(hash)}\n"
        end
      end
    end

    def initialize(*, **)
      super
      self.formatter = default_formatter
    end

    private

    def default_formatter
      ENV['DYNO'] ? Formatters::WithoutTimestamp.new : Formatters::Pretty.new
    end
  end
end
