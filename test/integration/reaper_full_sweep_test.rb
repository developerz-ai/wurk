# frozen_string_literal: true

require_relative '../test_helper'

# Real fork + real `kill -9` integration for the reaper's full-keyspace sweep
# (#108 acceptance #4). A job is genuinely BLMOVE'd into a private list owned by
# a forked child, under a queue the reaper's config does NOT serve; the child is
# killed; and the *full* sweep — not the scoped per-queue one — must re-queue it.
#
# NEVER mock Redis. Spec: docs/target/sidekiq-pro.md §3.2.
class ReaperFullSweepTest < Wurk::Test::UnitCase
  parallelize_me!

  DEAD_PID = 999_999 # never a running pid in CI/dev

  def setup
    super
    @ns        = "reapfull-#{Process.pid}-#{object_id}"
    @orphan_q  = Wurk::Keys.queue("#{@ns}-orphan") # deliberately NOT served below
    @config    = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.default_capsule.queues = ["#{@ns}-served"]
    @observer  = RedisClient.config(url: Wurk::Test.redis_url).new_client
    @reaper    = Wurk::Fetcher::Reaper.new(@config, lock_key: "rf:#{@ns}", full_lock_key: "rff:#{@ns}")
    @child_pid = nil
  end

  def teardown
    kill_child
    @observer&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  # rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize
  def test_full_sweep_reclaims_a_killed_owners_orphan_in_an_unserved_queue
    @observer.call('RPUSH', @orphan_q, payload('job-1'))
    @child_pid = fork_fetcher(@orphan_q)

    priv = wait_for_private_list(@orphan_q)

    assert priv, 'child must BLMOVE the job into its private list'
    assert_equal 1, @observer.call('LLEN', priv)
    assert_equal 0, @observer.call('LLEN', @orphan_q), 'job is in-flight, off the public queue'

    kill_child # kill -9 + reap, so the OS reports the owner pid as dead

    assert_equal 0, @reaper.reclaim!, 'scoped sweep ignores an unserved queue'
    assert_equal 1, @reaper.reclaim_full!, 'full sweep recovers the killed owner orphan'
    assert_equal 0, @observer.call('LLEN', priv), 'private list drained'
    assert_equal 1, @observer.call('LLEN', @orphan_q), 'job re-queued onto its public queue'
  end
  # rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize

  # Migration window: a private list written before the PROCESS_NONCE upgrade
  # (`<host>|<pid>|<idx>`, no nonce segment) must stay reclaimable by the full
  # sweep. No fork needed here — the owner pid is simply gone, exactly like a
  # pre-upgrade process that crashed and was never replaced under that pid.
  # rubocop:disable Minitest/MultipleAssertions
  def test_full_sweep_reclaims_a_legacy_pre_nonce_orphan_in_an_unserved_queue
    legacy_priv = "#{@orphan_q}|#{Socket.gethostname}|#{DEAD_PID}|0"
    @observer.call('RPUSH', legacy_priv, payload('job-legacy'))

    assert_equal 0, @reaper.reclaim!, 'scoped sweep ignores an unserved queue'
    assert_equal 1, @reaper.reclaim_full!, 'full sweep recovers the pre-nonce orphan'
    assert_equal 0, @observer.call('LLEN', legacy_priv), 'private list drained'
    assert_equal 1, @observer.call('LLEN', @orphan_q), 'job re-queued onto its public queue'
  end
  # rubocop:enable Minitest/MultipleAssertions

  private

  def payload(jid)
    Wurk.dump_json('class' => 'NoOp', 'args' => [], 'queue' => "#{@ns}-orphan", 'jid' => jid)
  end

  # Forks a child that does a genuine reliable-fetch BLMOVE (same command + key
  # the fetcher uses) into its own pid-keyed private list, then parks until killed.
  def fork_fetcher(public_q)
    fork do
      @observer.close # never share the parent's socket across a fork
      child = RedisClient.config(url: Wurk::Test.redis_url).new_client
      priv = Wurk::Fetcher::Reliable.private_queue_name(public_q)
      child.blocking_call(5, 'BLMOVE', public_q, priv, 'RIGHT', 'LEFT', 2)
      sleep 60
    ensure
      child&.close
    end
  end

  def wait_for_private_list(public_q)
    deadline = monotonic + 10
    while monotonic < deadline
      keys = @observer.call('KEYS', "#{public_q}|*")
      return keys.first unless keys.empty?

      sleep 0.05
    end
    nil
  end

  def kill_child
    return unless @child_pid

    ::Process.kill('KILL', @child_pid)
    ::Process.wait(@child_pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    @child_pid = nil
  end

  def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
end
