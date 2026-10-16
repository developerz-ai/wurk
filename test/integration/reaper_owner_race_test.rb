# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# K5 (plan 101/02): the reaper's liveness snapshot is taken before a SCAN that
# can run a long time, and a booting process claims jobs a moment before its
# first heartbeat lands. An owner that starts beating after the snapshot must
# keep its private list — draining it re-runs a job that is still running.
#
# Real Redis, no mocks: the only seam is the snapshot itself, wrapped so the
# owner's heartbeat lands between the snapshot and the drain, exactly where a
# slow SCAN puts it. Boot reclaim (Launcher#boot_reclaim) runs this same
# lock-free #reclaim!.
class ReaperOwnerRaceTest < Wurk::Test::UnitCase
  parallelize_me!

  DEAD_PID = 999_999 # never a running pid in CI/dev

  def setup
    super
    @ns       = "reaprace-#{Process.pid}-#{object_id}"
    @queue    = "#{@ns}-q"
    @public_q = Wurk::Keys.queue(@queue)
    @config   = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.default_capsule.queues = [@queue]
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
    @identity = nil
  end

  def teardown
    keys = @observer.call('KEYS', "#{@public_q}*")
    @observer.call('DEL', *keys) unless keys.empty?
    if @identity
      @observer.call('SREM', Wurk::Keys::PROCESSES, @identity)
      @observer.call('DEL', @identity)
    end
    @observer&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_an_owner_that_beats_after_the_snapshot_keeps_its_list
    nonce = SecureRandom.hex(6)
    priv = seed_private_list('remote-host.example', nonce)
    reaper = beat_after_snapshot(grace: 0) { register('remote-host.example', nonce) }

    assert_equal 0, reaper.reclaim!, 'owner beat before the drain — its in-flight job stays put'
    assert_equal 1, @observer.call('LLEN', priv)
    assert_equal 0, @observer.call('LLEN', @public_q), 'nothing re-queued, so nothing runs twice'
  end

  def test_the_full_sweep_rechecks_too
    nonce = SecureRandom.hex(6)
    priv = seed_private_list('remote-host.example', nonce)
    reaper = beat_after_snapshot(grace: 0) { register('remote-host.example', nonce) }

    assert_equal 0, reaper.reclaim_full!
    assert_equal 1, @observer.call('LLEN', priv)
  end

  # Control: with no heartbeat ever, the same list is an orphan and comes back.
  def test_an_owner_that_never_beats_is_still_reclaimed
    priv = seed_private_list('remote-host.example', SecureRandom.hex(6))
    reaper = beat_after_snapshot(grace: 0) { nil }

    assert_equal 1, reaper.reclaim!
    assert_equal 0, @observer.call('LLEN', priv)
    assert_equal 1, @observer.call('LLEN', @public_q)
  end

  # The boot race without any snapshot trick: the owner has claimed but not yet
  # beaten at all, and the default grace keeps its freshly-touched list safe.
  def test_a_claim_ahead_of_the_first_heartbeat_survives_the_default_grace
    priv = seed_private_list('booting-host.example', SecureRandom.hex(6))
    reaper = Wurk::Fetcher::Reaper.new(@config, lock_key: "rr:#{@ns}", full_lock_key: "rrf:#{@ns}")

    assert_equal 0, reaper.reclaim!
    assert_equal 1, @observer.call('LLEN', priv)
  end

  # The per-identity `settled_orphan?` re-check is the gate that spares an
  # in-flight job whose owner beats in the seam between the liveness snapshot
  # and the SCAN. Stubbing the re-check to ignore the fresh info hash lets the
  # stale snapshot's verdict stand — and the live owner's list is drained,
  # proving the safety was the only thing protecting the job.
  def test_disabling_the_per_identity_recheck_lets_the_stale_snapshot_reclaim
    nonce = SecureRandom.hex(6)
    priv = seed_private_list('remote-host.example', nonce)
    reaper = beat_after_snapshot(grace: 0) { register('remote-host.example', nonce) }
    # settled_orphan? is private; the singleton override replaces it on this
    # reaper, and `orphaned?` reaches it via implicit-self method lookup.
    reaper.define_singleton_method(:settled_orphan?) { |*_args| true }

    assert_equal 1, reaper.reclaim!,
                 'without the re-check the stale snapshot reclaims the live owner'
    assert_equal 0, @observer.call('LLEN', priv), 'private list drained by the stale snapshot'
    assert_equal 1, @observer.call('LLEN', @public_q), 'in-flight job re-queued — would run twice'
  end

  private

  # A Reaper whose liveness snapshot runs the block right after it is taken —
  # the moment a long SCAN leaves open.
  def beat_after_snapshot(grace:, &after)
    reaper = Wurk::Fetcher::Reaper.new(@config, lock_key: "rr:#{@ns}", full_lock_key: "rrf:#{@ns}", grace: grace)
    snapshot = reaper.method(:live_owners)
    reaper.define_singleton_method(:live_owners) do
      owners = snapshot.call
      after.call
      owners
    end
    reaper
  end

  def seed_private_list(host, nonce)
    key = "#{@public_q}|#{host}|#{DEAD_PID}|#{nonce}|0"
    @observer.call('RPUSH', key, Wurk.dump_json('class' => 'NoOp', 'args' => [], 'queue' => @queue,
                                                'jid' => "#{@ns}-#{nonce}"))
    key
  end

  def register(host, nonce)
    @identity = "#{host}:#{DEAD_PID}:#{nonce}"
    @observer.call('SADD', Wurk::Keys::PROCESSES, @identity)
    @observer.call('HSET', @identity, 'info', '{}')
  end
end
