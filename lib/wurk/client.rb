# frozen_string_literal: true

module Wurk
  # Enqueue interface. Lua bulk path. Redis-outage local buffer is in
  # Wurk::Client::Buffered (Pro feature parity).
  # Spec: docs/target/sidekiq-free.md §7.
  class Client
    attr_accessor :redis_pool

    def initialize(pool: nil, config: nil, chain: nil)
      @redis_pool = pool
      @config = config
      @chain = chain
    end

    def push(job_hash); end

    def push_bulk(job_hash); end
  end
end
