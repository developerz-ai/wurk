# frozen_string_literal: true

# Loaded with `-r` into the Ruby subprocesses that tests spawn under COVERAGE=1
# (see Wurk::Test::SUBPROCESS_COVERAGE). Code those probes exercise — the
# `require "sidekiq/…"` shims above all, which a fresh process is the only
# honest way to test — otherwise reads as 0% once `track_files` counts every lib
# file. Each subprocess stores its own resultset entry; the suite's final merge
# picks it up. No formatter and no minimum: a probe's stdout is its assertion
# channel and its exit status is what the test checks.
begin
  require 'simplecov'
rescue LoadError
  return
end

SimpleCov.command_name "subprocess-#{Process.pid}"
SimpleCov.root File.expand_path('../..', __dir__)
# Each probe writes its own resultset under coverage/subprocess/<pid>/, never
# the shared one: ~100 probes rewriting coverage/.resultset.json raced the
# worker processes, and one probe killed mid-write left a truncated file that
# the next writer read as {} — wiping a worker's entry and sinking the gate
# below 90%. test_helper imports these into the shared resultset once, after
# every worker has exited.
SimpleCov.coverage_dir "coverage/subprocess/#{Process.pid}"
SimpleCov.start do
  enable_coverage :branch
  primary_coverage :line
  add_filter '/test/'
  add_filter '/bench/'
  # Store this process's entry only; merging every entry is the parent's job,
  # and doing it in each of ~100 probes quadruples their runtime.
  use_merging false
  at_exit { SimpleCov::ResultMerger.store_result(SimpleCov.result) }
end
