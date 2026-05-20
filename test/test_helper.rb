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

require "minitest/autorun"
require "minitest/parallel_fork" rescue nil

require_relative "support/redis_namespace"

module Wurk
  module Test
    # Base class for non-engine tests.
    class UnitCase < ::Minitest::Test
      include RedisNamespace

      def self.parallelize_me!
        # Hook for Minitest's parallel runner.
      end
    end
  end
end
