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
  #
  # The end state alone cannot tell an atomic promotion from three separate
  # commands that happen to succeed, so the commands the promoter sends are
  # recorded as well: it may not read the due members, push the payload or
  # remove the member with a command of its own. The move has to happen inside
  # the script, where a crash cannot land between the removal and the push.
  def test_reliable_promotion_is_atomic
    jid = enqueue_in(3600, 'a', 'b')
    member, = scheduled_entry(jid)

    refute_nil member, 'perform_in should add an entry to the schedule ZSET'

    # Make the member due without waiting for its schedule time.
    @pool.with { |c| c.call('ZADD', 'schedule', 'XX', (::Time.now.to_f - 1).to_s, member) }

    config = reliable_config

    assert_equal Sidekiq::Scheduled::ReliableEnq, config[:scheduled_enq]

    sent = []
    record_promotion_commands(config, sent) do
      Sidekiq::Scheduled::ReliableEnq.new(config).enqueue_jobs(['schedule'])
    end

    assert_empty sent.select { |command| command.first == 'ZRANGEBYSCORE' },
                 'the promoter must not read the due members with a command of its own'
    assert_empty sent.select { |command| command.first == 'LPUSH' },
                 'the promoter must not push the payload with a command of its own'
    assert_empty sent.select { |command| command.first == 'ZREM' },
                 'the promoter must not remove the member with a command of its own'
    assert sent.any? { |command| %w[EVALSHA EVAL].include?(command.first) },
           'the promotion runs as one Lua script'

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

  # Pro §4: "Default Sidekiq does ZRANGE then ZREM then LPUSH non-atomically —
  # a crash between can lose jobs." The atomic promoter must not lose the job
  # when the push fails: the member stays scheduled, so a later sweep promotes
  # it again instead of the job falling between the two places.
  def test_reliable_promotion_keeps_the_job_when_the_push_fails
    jid = enqueue_in(3600, 'a', 'b')
    member, = scheduled_entry(jid)

    refute_nil member, 'perform_in should add an entry to the schedule ZSET'

    # Make the member due without waiting for its schedule time.
    @pool.with { |c| c.call('ZADD', 'schedule', 'XX', (::Time.now.to_f - 1).to_s, member) }

    # The queue key holds a string, so the push inside the promotion fails
    # with WRONGTYPE — the fault boundary the promise is about.
    @pool.with { |c| c.call('DEL', "queue:#{@queue}") }
    @pool.with { |c| c.call('SET', "queue:#{@queue}", 'not-a-list') }

    config = reliable_config

    assert_raises(RedisClient::CommandError) do
      Sidekiq::Scheduled::ReliableEnq.new(config).enqueue_jobs(['schedule'])
    end

    refute_nil scheduled_entry(jid).first,
               'a failed promotion leaves the job scheduled instead of losing it'
  end

  private

  # A configuration of its own, with the reliable promoter selected.
  def reliable_config
    config = Sidekiq::Config.new
    config.logger = ::Logger.new(IO::NULL)
    config.reliable_scheduler!
    config
  end

  # Points the configuration's pool at a decorator that records every command
  # the promoter sends, so the oracle sees the shape of the promotion and not
  # only its end state. The commands still run against the real server.
  def record_promotion_commands(config, sent)
    recorder = Wurk::Test::RecordingPool.new(config.default_capsule.redis_pool, sent)
    config.default_capsule.define_singleton_method(:redis_pool) { recorder }
    yield
  ensure
    recorder&.disconnect!
  end

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
