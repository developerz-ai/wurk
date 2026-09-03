# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :development, :test do
  gem 'minitest', '>= 5.20'
  gem 'minitest-parallel_fork'
  gem 'rake', '>= 13.0'
  # Pin to the 0.x line. SimpleCov 1.0 rewrote subprocess handling: the default
  # `at_fork` proc now ignores the name argument and labels every child
  # `(subprocess: #{subprocess_serial})`. Our parallel_fork coverage merge
  # (test/test_helper.rb) passes a per-worker name so each worker writes a
  # distinct resultset; under 1.0 the serial stays 0 for all workers (its only
  # increment lives in the off-by-default Process._fork hook), so they collide
  # on one key, clobber each other, and the merged report collapses far below
  # the 90% gate. cobertura 4.0 requires simplecov ~> 1.0, so it pins with it.
  gem 'rubocop', require: false
  gem 'rubocop-minitest', require: false
  gem 'rubocop-rake', require: false
  gem 'simplecov', '~> 0.22', require: false
  gem 'simplecov-cobertura', '~> 3.2', require: false
  gem 'benchmark-ips'
  gem 'memory_profiler'
  gem 'pry'
  # Development-only, and deliberately never a gemspec runtime dependency:
  # `lib/wurk/sentry.rb` guards every call site on `defined?(::Sentry)`, so the
  # integration is inert without it. Present here so SentrySdkSurfaceTest can
  # assert the real SDK objects still respond to the methods Wurk calls.
  gem 'sentry-ruby', require: false
  gem 'yard', require: false
end

group :test do
  # CI pins a Rails series via RAILS_VERSION ("8.1"); locally it floats to the
  # newest supported Rails.
  rails_version = ENV.fetch('RAILS_VERSION', nil)
  gem 'rack-test'
  gem 'rails', rails_version ? "~> #{rails_version}.0" : '>= 7.1'
  gem 'sqlite3'
  # Exercises Wurk::IterableJob::CsvEnumerator. Not a runtime dep — the gem
  # only touches CSV when the host has loaded it (`defined?(::CSV)` guard).
  gem 'csv'
end

group :development do
  # Drives `bin/profile`, which samples the real fetch+execute and enqueue paths
  # against a real Redis. Pillar 3 is "measured", and the benchmarks say *that*
  # something regressed while this says *where*. Not a gemspec dependency and
  # never required by lib/.
  gem 'stackprof', require: false
end
