# frozen_string_literal: true

require_relative '../test_helper'
require 'logger'

# Parity test for scheduled enqueue — Sidekiq's `perform_in` / `perform_at`
# DSL and the `schedule` ZSET shape that sidekiq-cron, sidekiq-scheduler, and
# the upstream suite depend on. The matching promotion side (Scheduled::Enq
# popping due entries) is exercised in test/unit/scheduled_poller_test.rb and
# end-to-end in test/integration/scheduled_promotion_test.rb.
#
# Spec: docs/target/sidekiq-free.md §16 and docs/target/sidekiq-pro.md §4 (the
# reliable promoter moves a due member onto its queue in one atomic Lua pass).
# When this file diverges from upstream Sidekiq's behavior, Wurk is wrong
# unless the divergence is documented there.
class ScheduledParityTest < Wurk::Test::UnitCase
  parallelize_me!

  class ScheduledParityJob
    include Sidekiq::Worker

    def perform(*); end
  end

  def setup
    super
    @ns = "schedparity-#{Process.pid}-#{object_id}"
    @queue = "#{@ns}-q"
    @jids = []
    @pool = Wurk.configuration.redis_pool
  end

  # Remove only our own members — the `schedule` ZSET is a shared global key,
  # so a blanket DEL would clobber other parallel tests' scheduled jobs.
  def teardown
    prune_mine('schedule')
    @pool.with do |c|
      c.call('DEL', "queue:#{@queue}")
      c.call('SREM', 'queues', @queue)
    end
  ensure
    super
  end

  # §1.2: the `schedule` sorted set scores its members with the unix epoch
  # float seconds of the moment the job is due. `perform_in(100)` puts the job
  # 100 seconds from now on the set.
  def test_perform_in_adds_to_schedule_set_with_future_score
    now = ::Process.clock_gettime(::Process::CLOCK_REALTIME)
    jid = enqueue_in(100, 'a', 'b')

    member, score = scheduled_entry(jid)

    refute_nil member, 'perform_in should add an entry to the schedule ZSET'
    assert_in_delta now + 100, score, 5.0, 'score should be ~now + interval'
    assert_kind_of Float, score, 'the schedule score is unix epoch float seconds'
    assert_operator score, :>, now, 'the score is in the future'
  end

  def test_perform_at_uses_the_absolute_timestamp
    at = ::Time.now + 3600
    jid = ScheduledParityJob.set('queue' => @queue).perform_at(at, 'x')
    @jids << jid

    _member, score = scheduled_entry(jid)

    assert_in_delta at.to_f, score, 0.001, 'perform_at score should equal the given timestamp'
  end

  # §7.1: a scheduled payload's `at` is moved into the sorted set's score
  # and dropped from the member (`hash.except("enqueued_at", "at")`); the
  # member keeps the job's core fields.
  def test_scheduled_member_omits_at_and_keeps_core_fields
    jid = enqueue_in(100, 1, 2)

    member, = scheduled_entry(jid)
    payload = Wurk.load_json(member)

    refute payload.key?('at'), "'at' is encoded as the ZSET score, never stored in the member"
    refute payload.key?('enqueued_at'), "'enqueued_at' is dropped from a scheduled payload"
    assert_equal 'ScheduledParityTest::ScheduledParityJob', payload['class']
    assert_equal [1, 2], payload['args']
    assert_equal @queue, payload['queue']
    assert_equal jid, payload['jid']
    assert_kind_of Integer, payload['created_at'], 'the member keeps the creation time'
  end

  def test_perform_in_with_past_time_enqueues_immediately
    jid = enqueue_in(-100, 'now')

    assert_nil scheduled_entry(jid).first,
               'a past schedule time must not land in the schedule ZSET'
    assert_equal 1, @pool.with { |c| c.call('LLEN', "queue:#{@queue}") },
                 'a past schedule time enqueues to the live queue immediately'
  end

  # Pro §4: the reliable promoter moves a due `schedule` member onto its queue
  # in ONE atomic Lua pass (ZRANGEBYSCORE + LPUSH + ZREM), so the job is never
  # in both places and never in neither.
  def test_reliable_promotion_is_atomic
    jid = enqueue_in(3600, 'a', 'b')
    member, = scheduled_entry(jid)

    refute_nil member, 'perform_in should add an entry to the schedule ZSET'

    # Make the member due without waiting for its schedule time.
    @pool.with { |c| c.call('ZADD', 'schedule', 'XX', (::Time.now.to_f - 1).to_s, member) }

    config = Sidekiq::Config.new
    config.logger = ::Logger.new(IO::NULL)
    config.reliable_scheduler!

    assert_equal Sidekiq::Scheduled::ReliableEnq, config[:scheduled_enq]

    Sidekiq::Scheduled::ReliableEnq.new(config).enqueue_jobs(['schedule'])

    promoted = @pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }

    assert_equal 1, promoted.size, 'the due member landed on its queue'
    payload = Wurk.load_json(promoted.first)
    scheduled = Wurk.load_json(member)

    assert_equal scheduled.except('enqueued_at'), payload.except('enqueued_at'),
                 'the payload crossed the promotion unchanged'
    assert payload.key?('enqueued_at'), 'the promoter stamps the arrival time'
    assert_equal jid, payload['jid']
    assert_equal @queue, payload['queue']

    still_scheduled = @pool.with { |c| c.call('ZSCORE', 'schedule', member) }

    assert_nil still_scheduled, 'the member left the schedule set'
  end

  private

  def enqueue_in(interval, *)
    jid = ScheduledParityJob.set('queue' => @queue).perform_in(interval, *)
    @jids << jid
    jid
  end

  # Scans the shared `schedule` ZSET for the member carrying our jid. Returns
  # [member_json, score_float] or [nil, nil]. Filtering by jid keeps us
  # immune to other parallel tests' entries in the same ZSET.
  def scheduled_entry(jid)
    each_scheduled('schedule') do |member, score|
      return [member, score] if Wurk.load_json(member)['jid'] == jid
    end
    [nil, nil]
  end

  def prune_mine(key)
    mine = []
    each_scheduled(key) { |member, _score| mine << member if @jids.include?(Wurk.load_json(member)['jid']) }
    @pool.with { |c| mine.each { |member| c.call('ZREM', key, member) } } unless mine.empty?
  end

  # ZRANGE … WITHSCORES returns [[member, score], …] pairs via redis-client;
  # yield each as a [member, Float] pair.
  def each_scheduled(key)
    pairs = @pool.with { |c| c.call('ZRANGE', key, '0', '-1', 'WITHSCORES') }
    pairs.each { |member, score| yield member, score.to_f }
  end
end
