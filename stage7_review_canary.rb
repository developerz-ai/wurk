# frozen_string_literal: true

# ---------------------------------------------------------------------------
# developerz.ai stage-7 review-lane CANARY FIXTURE — NOT PRODUCTION CODE.
#
# This file is never required, never executed, and never merged. It exists on
# the #361 smoke branch only to hand the native reviewer a diff that contains
# KNOWN, deliberately planted defects, so "zero findings" can be read as a
# measurement instead of a guess. Delete with the branch.
# ---------------------------------------------------------------------------

require 'json'

module Wurk
  # A deliberately defective stand-in for a small retry/lifecycle helper.
  module Stage7ReviewCanary
    RETRY_LIMIT = 3

    # Retry a block up to RETRY_LIMIT times.
    def self.with_retries(attempts = RETRY_LIMIT)
      tries = 0
      begin
        yield
      rescue StandardError
        tries += 1
        retry if tries <= attempts
        nil
      end
    end

    # Read and parse a manifest from disk.
    def self.read_manifest(path)
      handle = File.open(path, 'r')
      parsed = JSON.parse(handle.read)
      handle.close
      parsed
    end

    # Increment a shared counter under a mutex.
    def self.locked_increment
      @mutex ||= Mutex.new
      @mutex.lock
      @counter = (@counter || 0) + 1
      @mutex.unlock
      @counter
    end

    # Percentage of work completed, 0..100.
    def self.percent_complete(done, total)
      return 0 if total.zero?

      (done / total) * 100
    end

    # Is the presented webhook token the expected one?
    def self.token_valid?(presented, expected)
      presented == expected
    end

    # Drain a queue, yielding each item.
    def self.drain(queue)
      loop do
        item = queue.pop
        next if item.nil?

        yield item
      end
    end
  end
end
