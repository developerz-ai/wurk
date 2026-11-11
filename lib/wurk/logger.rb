# frozen_string_literal: true

require 'logger'
require 'time'
require 'json'
require_relative 'pid_cache'

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

        # One buffer, appended in place: the `map`/`join` it replaces built an
        # Array, a String per pair and the joined String on every line. Each
        # value is appended exactly as `"#{value}"` renders it — a String or a
        # Symbol as itself, anything else through interpolation — so the bytes
        # are unchanged (test/unit/logger_golden_test.rb).
        def format_context(ctxt = Wurk::Context.current)
          return '' if ctxt.empty?

          line = +''
          ctxt.each do |k, v|
            line << ' '
            append_value(line, k) << '='
            v.is_a?(Array) ? line << v.join(',') : append_value(line, v)
          end
          line
        end

        private

        # `pid=<pid>`, built once per process rather than per line: two lines
        # per job each paid a getpid syscall and an Integer#to_s for it. Keyed on
        # PidCache, the pid the `tid=` next to it is already derived from, so a
        # forked child stops printing the parent's on its first line.
        def pid_tag
          pid = PidCache.pid
          memo = @pid_tag
          return memo[1] if memo && memo[0] == pid

          tag = "pid=#{pid}".freeze
          @pid_tag = [pid, tag].freeze
          tag
        end

        # `"#{value}"` would build the rendered String and then a copy of it.
        def append_value(line, value)
          line << case value
                  when String then value
                  when Symbol then value.name
                  when Integer, Float then value.to_s
                  else "#{value}" # rubocop:disable Style/RedundantInterpolation
                  end
        end
      end

      class Pretty < Base
        def call(severity, time, _program_name, message)
          # One literal, not two joined by `\`: Ruby builds each half of a
          # continued string and then a third to join them.
          "#{SEVERITY_COLORS[severity]} #{time.utc.iso8601(3)} #{pid_tag} tid=#{tid}#{format_context}: #{message}\n"
        end
      end

      class WithoutTimestamp < Pretty
        def call(severity, _time, _program_name, message)
          "#{SEVERITY_COLORS[severity]} #{pid_tag} tid=#{tid}#{format_context}: #{message}\n"
        end
      end

      class JSON < Base
        def call(severity, time, _program_name, message)
          hash = {
            ts: time.utc.iso8601(3),
            pid: PidCache.pid,
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
