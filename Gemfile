# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rake", ">= 13.0"
  gem "minitest", ">= 5.20"
  gem "minitest-parallel_fork"
  # Pin to the 0.x line. SimpleCov 1.0 rewrote subprocess handling: the default
  # `at_fork` proc now ignores the name argument and labels every child
  # `(subprocess: #{subprocess_serial})`. Our parallel_fork coverage merge
  # (test/test_helper.rb) passes a per-worker name so each worker writes a
  # distinct resultset; under 1.0 the serial stays 0 for all workers (its only
  # increment lives in the off-by-default Process._fork hook), so they collide
  # on one key, clobber each other, and the merged report collapses far below
  # the 90% gate. cobertura 4.0 requires simplecov ~> 1.0, so it pins with it.
  gem "simplecov", "~> 0.22", require: false
  gem "simplecov-cobertura", "~> 3.2", require: false
  gem "rubocop", require: false
  gem "rubocop-minitest", require: false
  gem "rubocop-rake", require: false
  gem "benchmark-ips"
  gem "memory_profiler"
  gem "pry"
  gem "yard", require: false
end

group :test do
  # CI matrix pins a Rails series via RAILS_VERSION (e.g. "7.2", "8.0") so each
  # leg resolves to that line; locally it floats to the newest supported Rails.
  rails_version = ENV["RAILS_VERSION"]
  gem "rails", rails_version ? "~> #{rails_version}.0" : ">= 7.1"
  gem "sqlite3"
  gem "rack-test"
  # Exercises Wurk::IterableJob::CsvEnumerator. Not a runtime dep — the gem
  # only touches CSV when the host has loaded it (`defined?(::CSV)` guard).
  gem "csv"
end
