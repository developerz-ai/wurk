# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rake", ">= 13.0"
  gem "minitest", ">= 5.20"
  gem "minitest-parallel_fork"
  gem "simplecov", require: false
  gem "simplecov-cobertura", require: false
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
