# frozen_string_literal: true

require_relative '../test_helper'

# The native orphan reaper: a lock goes only when no job anywhere still carries
# its digest, the run is bounded, and one process in a mixed fleet runs it.
class UniqueJobsReaperTest < Wurk::Test::UnitCase
  def setup
    super
    Wurk::UniqueJobs.reset!
    Wurk::UniqueJobs.config.reaper_timeout = 10
    @old = Time.now.to_f - 3600
  end

  def teardown
    Wurk::UniqueJobs::Orphans::Manager.stop
    Wurk::UniqueJobs.reset!
  ensure
    super
  end

  def lock(digest, score: @old, jid: SecureRandom.hex(12))
    Wurk.redis do |c|
      c.call('SET', digest, jid)
      c.call('HSET', "#{digest}:LOCKED", jid, score)
      c.call('ZADD', 'uniquejobs:digests', score, digest)
    end
  end

  def payload(digest, created_at: (@old * 1000).to_i)
    Wurk.dump_json('class' => 'X', 'jid' => SecureRandom.hex(12), 'args' => [], 'lock_digest' => digest,
                   'created_at' => created_at)
  end

  def digests = Wurk.redis { |c| c.call('ZRANGE', 'uniquejobs:digests', 0, -1) }
  def reap = Wurk::UniqueJobs::Orphans::Reaper.call

  def test_reaps_a_lock_no_job_holds
    lock('uniquejobs:orphan')

    assert_equal 1, reap
    assert_empty digests
    assert_empty(Wurk.redis { |c| c.call('KEYS', 'uniquejobs:orphan*') })
  end

  def test_keeps_a_lock_younger_than_the_timeout
    lock('uniquejobs:fresh', score: Time.now.to_f)

    assert_equal 0, reap
    assert_equal ['uniquejobs:fresh'], digests
  end

  def test_keeps_every_lock_a_job_still_carries
    %w[queued scheduled retrying private running].each { |name| lock("uniquejobs:#{name}") }
    Wurk.redis do |c|
      c.call('SADD', 'queues', 'default')
      c.call('LPUSH', 'queue:default', payload('uniquejobs:queued'))
      c.call('ZADD', 'schedule', Time.now.to_f + 60, payload('uniquejobs:scheduled'))
      c.call('ZADD', 'retry', Time.now.to_f + 60, payload('uniquejobs:retrying'))
      # A dead worker's private list: in no public queue until it is reclaimed.
      c.call('LPUSH', 'queue:default|dead-host|999999|0123456789ab|0', payload('uniquejobs:private'))
      c.call('SADD', 'processes', 'host:1:abc')
      work = { 'queue' => 'default', 'payload' => payload('uniquejobs:running:RUN'), 'run_at' => @old }
      c.call('HSET', 'host:1:abc:work', 'tid', Wurk.dump_json(work))
    end
    lock('uniquejobs:gone')

    assert_equal 1, reap
    assert_equal %w[uniquejobs:private uniquejobs:queued uniquejobs:retrying uniquejobs:running uniquejobs:scheduled],
                 digests.sort
  end

  # The gem keeps every lock while any job created after the cutoff runs.
  def test_a_recently_created_running_job_keeps_every_lock
    lock('uniquejobs:orphan')
    Wurk.redis do |c|
      c.call('SADD', 'processes', 'host:1:abc')
      work = { 'payload' => payload('uniquejobs:other', created_at: (Time.now.to_f * 1000).to_i), 'run_at' => @old }
      c.call('HSET', 'host:1:abc:work', 'tid', Wurk.dump_json(work))
    end

    assert_equal 0, reap
  end

  def test_an_unreadable_payload_counts_every_string_in_it
    lock('uniquejobs:maybe')
    Wurk.redis do |c|
      c.call('SADD', 'queues', 'default')
      c.call('LPUSH', 'queue:default', '{"lock_digest":"uniquejobs:maybe", truncated')
    end

    assert_equal 0, reap
  end

  def test_expired_until_expired_digests_go_too
    Wurk.redis do |c|
      c.call('ZADD', 'uniquejobs:expiring_digests', @old, 'uniquejobs:expired')
      c.call('ZADD', 'uniquejobs:expiring_digests', Time.now.to_f + 600, 'uniquejobs:live')
      c.call('SET', 'uniquejobs:expired', 'j')
    end

    assert_equal 1, reap
    assert_equal(['uniquejobs:live'], Wurk.redis { |c| c.call('ZRANGE', 'uniquejobs:expiring_digests', 0, -1) })
  end

  def test_a_run_reaps_at_most_reaper_count
    Wurk::UniqueJobs.config.reaper_count = 3
    5.times { |i| lock("uniquejobs:o#{i}") }

    assert_equal 3, reap
    assert_equal 2, digests.size
  end

  # Busy queues: skipped, as the gem skips them.
  def test_skips_the_run_when_the_queues_are_very_full
    lock('uniquejobs:orphan')
    Wurk.redis do |c|
      c.call('SADD', 'queues', 'big')
      c.call('LPUSH', 'queue:big', *Array.new(1_001) { |i| "{\"jid\":\"#{i}\"}" })
    end

    assert_equal 0, reap
  end

  # A schedule and retry set past the bound: skipped too, rather than read
  # whole twice. The bound is lowered here, not filled to 100k.
  def test_skips_the_run_when_the_schedule_and_retry_sets_are_very_full
    reaper = Wurk::UniqueJobs::Orphans::Reaper
    bound = reaper::MAX_SORTED_SET_SIZE
    reaper.send(:remove_const, :MAX_SORTED_SET_SIZE)
    reaper.const_set(:MAX_SORTED_SET_SIZE, 3)
    lock('uniquejobs:orphan')
    Wurk.redis do |c|
      2.times { |i| c.call('ZADD', 'schedule', i, payload("uniquejobs:s#{i}")) }
      2.times { |i| c.call('ZADD', 'retry', i, payload("uniquejobs:r#{i}")) }
    end

    assert_equal 0, reap
    Wurk.redis { |c| c.call('ZREM', 'retry', c.call('ZRANGE', 'retry', 0, 0).first) }

    assert_equal 1, reap
  ensure
    reaper.send(:remove_const, :MAX_SORTED_SET_SIZE)
    reaper.const_set(:MAX_SORTED_SET_SIZE, bound)
  end

  # One reaper per fleet: the key the gem's reaper holds, so a gem pod and a
  # native pod never both reap.
  def test_one_process_holds_the_reaper_key
    manager = Wurk::UniqueJobs::Orphans::Manager
    Wurk.redis { |c| c.call('SET', 'uniquejobs:reaper', Time.now.to_i - 5, 'EX', 600) }
    lock('uniquejobs:orphan')

    assert_equal 0, manager.tick, 'reaped while another process held the key'
    Wurk.redis { |c| c.call('DEL', 'uniquejobs:reaper') }

    assert_equal 1, manager.tick
    assert_operator Wurk.redis { |c| c.call('TTL', 'uniquejobs:reaper') }, :>, 600
  ensure
    manager.instance_variable_set(:@owner, false)
  end

  def test_none_reaper_never_starts
    Wurk::UniqueJobs.config.reaper = :none

    assert_nil Wurk::UniqueJobs::Orphans::Manager.start
  end

  # Hand-off lists a Wurk before 1.23 left without a TTL: a lock never taken
  # is in no digest set, so only this sweep meets them. It gives them the
  # hand-off TTL and touches nothing else: a held lock, a PRIMED list that
  # already expires, and the lock's other keys keep what they had.
  def test_gives_unbounded_primed_lists_a_ttl_and_leaves_live_locks_alone
    lock('uniquejobs:live:RUN', score: Time.now.to_f)
    Wurk.redis do |c|
      c.call('RPUSH', 'uniquejobs:leaked:RUN:PRIMED', 'a-jid')
      c.call('RPUSH', 'uniquejobs:leaked2:PRIMED', '1')
      c.call('RPUSH', 'uniquejobs:handoff:RUN:PRIMED', 'b-jid')
      c.call('PEXPIRE', 'uniquejobs:handoff:RUN:PRIMED', 5_000)
      c.call('HSET', 'uniquejobs:not-a-list:PRIMED', 'f', 'v')
    end
    handoff_before = Wurk.redis { |c| c.call('PTTL', 'uniquejobs:handoff:RUN:PRIMED') }

    reap

    Wurk.redis do |c|
      %w[uniquejobs:leaked:RUN:PRIMED uniquejobs:leaked2:PRIMED].each do |key|
        assert_operator c.call('PTTL', key), :>, 0, key
        assert_operator c.call('PTTL', key), :<=, Wurk::UniqueJobs::Locksmith::PRIMED_TTL_MS
      end
      handoff_after = c.call('PTTL', 'uniquejobs:handoff:RUN:PRIMED')

      assert_operator handoff_after, :<=, handoff_before, 'an expiring hand-off keeps its TTL'
      assert_operator handoff_after, :>, handoff_before - 2_000, 'an expiring hand-off keeps its TTL'
      assert_equal(-1, c.call('PTTL', 'uniquejobs:not-a-list:PRIMED'), 'a key that is not a list is left alone')
      assert_equal(-1, c.call('PTTL', 'uniquejobs:live:RUN'))
      assert_equal(-1, c.call('PTTL', 'uniquejobs:live:RUN:LOCKED'))
      assert_equal ['uniquejobs:live:RUN'], digests
      c.call('DEL', 'uniquejobs:not-a-list:PRIMED')
    end
  end
end
