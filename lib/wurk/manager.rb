# frozen_string_literal: true

module Wurk
  # Lives inside each forked child. Owns the thread pool, lifecycle,
  # and the heartbeat. Spawns N Processor threads, supervises them,
  # handles graceful drain on SIGTERM relayed from the swarm parent.
  class Manager
    def initialize(concurrency:, queues:); end
    def start; end
    def stop(timeout:); end
  end
end
