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
end

group :test do
  gem "rails", ">= 7.1"
  gem "sqlite3"
  gem "rack-test"
end
