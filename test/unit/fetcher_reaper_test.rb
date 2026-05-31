# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Drives Wurk::Fetcher::Reaper against real Redis. Each test owns a unique
# public queue + simulated private lists keyed to a dead/alive pid, so
# parallel runs never collide. The periodic thread is never started here —
# tests call the unguarded `reclaim!` for determinism; the locked `reap`
# and the loop lifecycle get their own focused cases.
#
# Spec: docs/target/sidekiq-pro.md §3.2.
class FetcherReaperTest < Wurk::Test::UnitCase
  parallelize_me!

  DEAD_PID = 999_999 # never a running pid in CI/dev

  def setup # rubocop:disable Metrics/AbcSize -- linear fixture wiring, no branching
    super
    @ns           = "reaper-#{Process.pid}-#{object_id}"
    @queue_name   = "#{@ns}-q"
    @public_queue = Wurk::Keys.queue(@queue_name)
    @config       = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @capsule = @config.default_capsule
    @capsule.queues = [@queue_name]
    @pool         = @capsule.redis_pool
    @host         = ENV['DYNO'] || Socket.gethostname
    # Salt every default jid so the global, 72h-TTL PoisonPill counter at
    # `super_fetch:recovered:<jid>` can't accumulate across runs and tip an
    # otherwise-recoverable job over the poison threshold.
    @salt         = SecureRandom.hex(8)
    @reaper       = Wurk::Fetcher::Reaper.new(@config, interval: 1, lock_key: "#{Wurk::Fetcher::Reaper::LOCK_KEY}:#{@ns}")
    Wurk::Middleware::PoisonPill.reset!
  end

  def teardown
    Wurk::Middleware::PoisonPill.reset!
    @pool.with do |c|
      keys = c.call('KEYS', "#{@public_queue}*")
      c.call('DEL', *keys) unless keys.empty?
      c.call('DEL', "#{Wurk::Fetcher::Reaper::LOCK_KEY}:#{@ns}")
    end
    cleanup_dead_set
    cleanup_recovery_counters
    @config.reset_redis_pools!
  ensure
    super
  end

  # --- orphan reclamation ------------------------------------------------

  def test_reclaims_orphaned_private_list_back_to_public_queue
    seed_private_list(DEAD_PID, %w[a b c])

    reclaimed = @reaper.reclaim!

    assert_equal 3, reclaimed
    assert_equal 0, llen(private_list(DEAD_PID)), 'private list should be drained'
    assert_equal 3, llen(@public_queue), 'jobs should be back on the public queue'
  end

  def test_reclaimed_jobs_land_on_the_public_tail_for_prompt_rerun
    # A job already waiting at the head; reclaimed jobs must sit behind it on
    # the tail (RIGHT) so they are fetched next, matching #bulk_requeue.
    @pool.with { |c| c.call('LPUSH', @public_queue, payload('existing')) }
    seed_private_list(DEAD_PID, %w[recovered])

    @reaper.reclaim!

    # Fetch order is RIGHT (tail); the reclaimed job must be the tail element.
    assert_equal payload('recovered'), lindex(@public_queue, -1)
  end

  def test_does_not_reclaim_a_live_owners_private_list
    seed_private_list(Process.pid, %w[live]) # this very process is alive

    reclaimed = @reaper.reclaim!

    assert_equal 0, reclaimed
    assert_equal 1, llen(private_list(Process.pid)), 'a live owner keeps its in-flight jobs'
    assert_equal 0, llen(@public_queue)
  end

  def test_empty_when_no_private_lists_exist
    assert_equal 0, @reaper.reclaim!
  end

  def test_only_scans_served_queues
    other = Wurk::Keys.queue("#{@ns}-unserved")
    other_priv = "#{other}|#{@host}|#{DEAD_PID}|0"
    @pool.with { |c| c.call('RPUSH', other_priv, payload('x')) }

    reclaimed = @reaper.reclaim!

    assert_equal 0, reclaimed, 'queues this process does not serve are left untouched'
    assert_equal 1, llen(other_priv)
  ensure
    @pool.with { |c| c.call('DEL', other_priv) }
  end

  # --- poison-pill cap ---------------------------------------------------

  # rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions
  def test_recovery_past_threshold_kills_to_dead_set_instead_of_requeue
    jid = SecureRandom.hex(12)
    job = payload('poison', jid: jid)
    # Two prior recoveries on record; this reclaim is the 3rd → poison.
    Wurk.redis { |c| c.call('SET', recovery_key(jid), '2') }
    @pool.with { |c| c.call('RPUSH', private_list(DEAD_PID), job) }

    reclaimed = @reaper.reclaim!

    assert_equal 1, reclaimed
    assert_equal 0, llen(@public_queue), 'a poison job must not be re-queued'
    assert_equal 0, llen(private_list(DEAD_PID)), 'and must be drained from the private list'
    assert_includes dead_payloads, job, 'poison job belongs in the dead set'
  ensure
    Wurk.redis { |c| c.call('DEL', recovery_key(jid)) }
  end
  # rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions

  def test_under_threshold_recovery_requeues_and_bumps_counter
    jid = SecureRandom.hex(12)
    @pool.with { |c| c.call('RPUSH', private_list(DEAD_PID), payload('ok', jid: jid)) }

    @reaper.reclaim!

    assert_equal 1, llen(@public_queue)
    assert_equal 1, Wurk::Middleware::PoisonPill.recovery_count(jid)
  ensure
    Wurk.redis { |c| c.call('DEL', recovery_key(jid)) }
  end

  # --- liveness: cross-host ----------------------------------------------

  def test_cross_host_owner_with_live_heartbeat_is_skipped
    other_host = 'other-host.example'
    register_process(other_host, DEAD_PID, info: true)
    seed_private_list(DEAD_PID, %w[remote], host: other_host)

    reclaimed = @reaper.reclaim!

    assert_equal 0, reclaimed, 'a beating cross-host owner keeps its jobs'
  ensure
    unregister_process(other_host, DEAD_PID)
  end

  def test_cross_host_owner_without_info_hash_is_reclaimed
    other_host = 'other-host.example'
    register_process(other_host, DEAD_PID, info: false) # SET member, expired hash
    seed_private_list(DEAD_PID, %w[remote], host: other_host)

    reclaimed = @reaper.reclaim!

    assert_equal 1, reclaimed, 'a SET member whose heartbeat lapsed is dead'
  ensure
    unregister_process(other_host, DEAD_PID)
  end

  # --- key parsing -------------------------------------------------------

  def test_ignores_malformed_private_list_keys
    @pool.with do |c|
      c.call('RPUSH', "#{@public_queue}|#{@host}|notapid|0", payload('bad'))
      c.call('RPUSH', "#{@public_queue}|#{@host}|#{DEAD_PID}|notanidx", payload('bad2'))
    end

    assert_equal 0, @reaper.reclaim!, 'non-numeric pid/idx suffixes are not reclaimable'
  end

  # --- cluster lock ------------------------------------------------------

  def test_reap_is_a_noop_when_the_lock_is_held_elsewhere
    seed_private_list(DEAD_PID, %w[a])
    @pool.with { |c| c.call('SET', "#{Wurk::Fetcher::Reaper::LOCK_KEY}:#{@ns}", 'other', 'EX', 30) }

    assert_equal 0, @reaper.reap, 'a process that loses the lock does not sweep'
    assert_equal 1, llen(private_list(DEAD_PID))
  end

  def test_reap_sweeps_when_the_lock_is_free
    seed_private_list(DEAD_PID, %w[a b])

    assert_equal 2, @reaper.reap
  end

  # --- thread lifecycle --------------------------------------------------

  def test_start_is_idempotent_and_stop_joins # rubocop:disable Minitest/MultipleAssertions
    refute_predicate @reaper, :running?
    first = @reaper.start
    second = @reaper.start

    assert_same first, second, 'start must not spawn a second thread'
    assert_predicate @reaper, :running?

    @reaper.stop

    refute_predicate @reaper, :running?
  end

  private

  def seed_private_list(pid, tokens, host: @host)
    key = "#{@public_queue}|#{host}|#{pid}|0"
    @pool.with { |c| tokens.each { |t| c.call('RPUSH', key, payload(t)) } }
    key
  end

  def private_list(pid, host: @host)
    "#{@public_queue}|#{host}|#{pid}|0"
  end

  def payload(token, jid: nil)
    Wurk.dump_json('class' => 'ReaperTestJob', 'args' => [token],
                   'queue' => @queue_name, 'jid' => jid || "#{@salt}:#{token}")
  end

  def recovery_key(jid)
    "#{Wurk::Middleware::PoisonPill::KEY_PREFIX}#{jid}"
  end

  def register_process(host, pid, info:)
    identity = "#{host}:#{pid}:#{SecureRandom.hex(6)}"
    @registered ||= {}
    @registered[[host, pid]] = identity
    Wurk.redis do |c|
      c.call('SADD', Wurk::Keys::PROCESSES, identity)
      c.call('HSET', identity, 'info', '{}') if info
    end
  end

  def unregister_process(host, pid)
    identity = @registered&.delete([host, pid])
    return unless identity

    Wurk.redis do |c|
      c.call('SREM', Wurk::Keys::PROCESSES, identity)
      c.call('DEL', identity)
    end
  end

  def dead_payloads
    Wurk.redis { |c| c.call('ZRANGE', Wurk::Keys::DEAD, 0, -1) }
  end

  def cleanup_dead_set
    Wurk.redis do |c|
      mine = c.call('ZRANGE', Wurk::Keys::DEAD, 0, -1).select { |m| m.include?(@queue_name) }
      c.call('ZREM', Wurk::Keys::DEAD, *mine) unless mine.empty?
    end
  end

  def cleanup_recovery_counters
    Wurk.redis do |c|
      keys = c.call('KEYS', "#{Wurk::Middleware::PoisonPill::KEY_PREFIX}#{@salt}:*")
      c.call('DEL', *keys) unless keys.empty?
    end
  end

  def llen(key)
    @pool.with { |c| c.call('LLEN', key) }
  end

  def lindex(key, idx)
    @pool.with { |c| c.call('LINDEX', key, idx) }
  end
end
