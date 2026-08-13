# frozen_string_literal: true

# ---------------------------------------------------------------------------
# Stage-7 lifecycle helpers: retry, manifest loading, progress counters and
# drain queues shared by the stage-7 worker experiments.
#
# Extracted from the worker path while the stage-7 pipeline is validated and
# kept under the stage7 namespace until it graduates to the default boot
# path. Exercised by the stage-7 harness; not wired into the standard boot.
# ---------------------------------------------------------------------------

require 'json'

module Wurk
  # Retry and lifecycle helpers for the stage-7 worker experiments.
  module Stage7Lifecycle
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
