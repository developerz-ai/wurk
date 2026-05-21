# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  require "simplecov-cobertura"
  SimpleCov.start do
    enable_coverage :branch
    primary_coverage :branch
    add_filter "/test/"
    add_filter "/bench/"
    minimum_coverage_by_file branch: 0 # raise gate per-class once landed
    minimum_coverage branch: 90
    formatter SimpleCov::Formatter::CoberturaFormatter
  end
end

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "wurk"

# Silence the global configuration's logger so default ERROR_HANDLER doesn't
# spam test output. Per-test logger overrides still work — they assign a
# StringIO/NULL logger on a fresh Wurk::Configuration.
Wurk.configuration.logger = Logger.new(IO::NULL)

require "minitest/autorun"
require "minitest/parallel_fork" rescue nil

require_relative "support/redis_namespace"

module Wurk
  module Test
    # Suite-wide mutex for tests that mutate process-global `Wurk::Metrics::Statsd`
    # singletons (`.options`, the `increment` method itself) or
    # `Wurk.configuration.dogstatsd`. A class-level mutex doesn't serialize
    # across parallel test classes that touch the same globals — this one does.
    # Pair with a `#run` override on each such class.
    STATSD_MUTEX = Mutex.new

    # Base class for non-engine tests.
    class UnitCase < ::Minitest::Test
      include RedisNamespace

      def self.parallelize_me!
        # Hook for Minitest's parallel runner.
      end
    end
  end
end
