# frozen_string_literal: true

require 'securerandom'
require 'socket'

module Wurk
  # Leader election via Redis SET NX + TTL refresh. Used by Cron and any
  # other once-per-cluster work. Best-effort (not Raft): a partitioned
  # leader can briefly co-exist with a new one until the TTL expires —
  # downstream callers must idempotency-guard their once-per-cluster
  # writes (Cron does this implicitly via per-tick fire marks).
  #
  # Spec: docs/target/sidekiq-ent.md §6. The fencing-token + lifecycle
  # event surface (`config.on(:leader)`, `Component#leader?`) lands in
  # the dedicated Leader task; this class implements the minimum
  # `acquire`/`release`/`leader?` API that Cron's tick loop requires.
  class Leader
    DEFAULT_TTL = 30
    OPT_OUT_ENV = 'WURK_LEADER'

    attr_reader :key, :ttl

    def initialize(key:, ttl: DEFAULT_TTL, pool: nil, owner: nil)
      @key = key
      @ttl = ttl
      @pool = pool
      @owner = owner || build_owner_id
      @held = false
    end

    # SET key owner NX EX ttl. If the key already holds our owner string
    # (rare — same process re-entering the loop), refresh the TTL via
    # EXPIRE so leadership doesn't lapse. Opt-out env `WURK_LEADER=false`
    # makes acquire a no-op and `leader?` permanently false; useful for
    # hot-standby pools.
    def acquire
      if ENV[OPT_OUT_ENV].to_s.downcase == 'false'
        @held = false
        return false
      end

      redis do |c|
        result = c.call('SET', @key, @owner, 'NX', 'EX', @ttl)
        if result == 'OK'
          @held = true
          return true
        end

        if c.call('GET', @key) == @owner
          c.call('EXPIRE', @key, @ttl)
          @held = true
          return true
        end

        @held = false
        false
      end
    end

    # CAS delete: only DEL if we still own the key, otherwise a stale
    # release would yank leadership from whichever follower took over.
    def release
      redis do |c|
        c.call('DEL', @key) if c.call('GET', @key) == @owner
      end
      @held = false
      nil
    end

    def leader?
      @held
    end

    def owner
      @owner.dup
    end

    private

    def redis(&)
      if @pool
        @pool.with(&)
      else
        Wurk.redis(&)
      end
    end

    def build_owner_id
      host = ::Socket.gethostname
      "#{::Process.pid}@#{host}:#{::SecureRandom.hex(4)}"
    rescue StandardError
      "#{::Process.pid}@localhost:#{::SecureRandom.hex(4)}"
    end
  end
end
