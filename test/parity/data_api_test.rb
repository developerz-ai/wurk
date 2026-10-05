# frozen_string_literal: true

require_relative '../test_helper'
require 'date'
require 'zlib'
require 'base64'

# Parity oracle for the Data API (`require "sidekiq/api"`): the read/manipulate
# surface dashboards, ops scripts and third-party gems drive against Redis.
#
# Spec: docs/target/sidekiq-free.md §1 (key schema the API reads), §2.3
# (timestamps: Integer epoch ms, Float epoch seconds for the old format),
# §19.1 Stats / Stats::History, §19.2 Queue, §19.3 JobRecord, §19.4
# SortedEntry, §19.5 SortedSet / JobSet / Scheduled-Retry-DeadSet, §19.6
# ProcessSet / Process, §19.7 WorkSet / Work, §31 gotchas 8, 13, 14, 16, 17;
# docs/target/sidekiq-pro.md §6 (Queue#pause! / #unpause! / #paused?) and
# §11 (Queue#delete_job / #delete_by_class).
#
# Every fixture is written straight to Redis in the shape the spec pins, so
# the API is read against the wire format rather than against Wurk's writers.
class DataApiParityTest < Wurk::Test::UnitCase
  parallelize_me!

  WRAPPER = 'Sidekiq::ActiveJob::Wrapper'

  def setup
    super
    @n = 0
  end

  # --- Stats (§19.1) -------------------------------------------------------------

  def test_stats_reads_counters_set_sizes_and_slow_aggregates
    redis('SET', 'stat:processed', '10')
    redis('SET', 'stat:failed', '3')
    2.times { |i| redis('ZADD', 'schedule', now + i, dump(job)) }
    redis('ZADD', 'retry', now, dump(job))
    4.times { |i| redis('ZADD', 'dead', now + i, dump(job)) }
    add_process('h:1:aaa', busy: 2)
    add_process('h:2:bbb', busy: 3)
    3.times { enqueue('qa', job) }
    enqueue('qb', job)

    stats = Sidekiq::Stats.new

    assert_equal 10, stats.processed
    assert_equal 3, stats.failed
    assert_equal 2, stats.scheduled_size
    assert_equal 1, stats.retry_size
    assert_equal 4, stats.dead_size
    assert_equal 2, stats.processes_size
    assert_equal 4, stats.enqueued
    assert_equal 5, stats.workers_size
  end

  def test_stats_on_an_empty_redis_are_zero
    stats = Sidekiq::Stats.new

    assert_equal 0, stats.processed
    assert_equal 0, stats.failed
    assert_equal 0, stats.enqueued
    assert_equal 0, stats.workers_size
    assert_in_delta(0.0, stats.default_queue_latency)
    assert_kind_of Float, stats.default_queue_latency
  end

  def test_default_queue_latency_reads_the_oldest_default_job_in_ms
    enqueue('default', job('enqueued_at' => now_ms - 5_000))
    enqueue('default', job('enqueued_at' => now_ms))

    assert_in_delta 5.0, Sidekiq::Stats.new.default_queue_latency, 1.0
  end

  def test_default_queue_latency_accepts_old_float_seconds
    enqueue('default', job('enqueued_at' => now - 10.0))

    assert_in_delta 10.0, Sidekiq::Stats.new.default_queue_latency, 1.0
  end

  def test_stats_queues_is_sizes_sorted_largest_first
    enqueue('small', job)
    3.times { enqueue('big', job) }
    redis('SADD', 'queues', 'empty')

    queues = Sidekiq::Stats.new.queues

    assert_equal({ 'big' => 3, 'small' => 1, 'empty' => 0 }, queues)
    assert_equal %w[big small empty], queues.keys
  end

  def test_stats_queue_summaries
    enqueue('lat', job('enqueued_at' => now_ms - 3_000))
    enqueue('lat', job)
    redis('SADD', 'paused', 'lat')
    redis('SADD', 'queues', 'idle')

    lat, idle = Sidekiq::Stats.new.queue_summaries

    assert_equal ['lat', 2, true], [lat.name, lat.size, lat.paused?]
    assert_in_delta 3.0, lat.latency, 1.0
    assert_equal ['idle', 0, false], [idle.name, idle.size, idle.paused?]
    assert_in_delta(0.0, idle.latency)
  end

  def test_stats_reset_zeroes_all_or_the_named_counters
    redis('SET', 'stat:processed', '7')
    redis('SET', 'stat:failed', '2')

    Sidekiq::Stats.new.reset('failed')

    assert_equal %w[7 0], [redis('GET', 'stat:processed'), redis('GET', 'stat:failed')]

    Sidekiq::Stats.new.reset

    assert_equal %w[0 0], [redis('GET', 'stat:processed'), redis('GET', 'stat:failed')]
  end

  def test_stats_history_reads_daily_counters_newest_first
    today = Time.now.utc.to_date
    redis('SET', "stat:processed:#{day(today)}", '5')
    redis('SET', "stat:processed:#{day(today - 1)}", '2')
    redis('SET', "stat:failed:#{day(today - 2)}", '1')

    history = Sidekiq::Stats::History.new(3)

    assert_equal({ day(today) => 5, day(today - 1) => 2, day(today - 2) => 0 }, history.processed)
    assert_equal [day(today), day(today - 1), day(today - 2)], history.processed.keys
    assert_equal({ day(today) => 0, day(today - 1) => 0, day(today - 2) => 1 }, history.failed)
  end

  def test_stats_history_honours_start_date_and_bounds
    start = Date.new(2026, 1, 10)
    redis('SET', 'stat:processed:2026-01-09', '4')

    assert_equal({ '2026-01-10' => 0, '2026-01-09' => 4 }, Sidekiq::Stats::History.new(2, start).processed)
    assert_raises(ArgumentError) { Sidekiq::Stats::History.new(0) }
    assert_raises(ArgumentError) { Sidekiq::Stats::History.new((5 * 365) + 1) }
  end

  # --- Queue (§19.2, Pro §6 / §11) ----------------------------------------------

  def test_queue_all_is_every_known_queue_sorted
    redis('SADD', 'queues', 'zeta', 'alpha', 'mid')

    all = Sidekiq::Queue.all

    assert_equal %w[alpha mid zeta], all.map(&:name)
    assert(all.all?(Sidekiq::Queue))
  end

  def test_queue_identity_and_size
    q = Sidekiq::Queue.new('things')
    2.times { enqueue('things', job) }

    assert_equal 'things', q.name
    assert_equal 'things', q.id
    assert_equal 2, q.size
    assert_equal 'default', Sidekiq::Queue.new.name
    assert_equal({ name: 'things' }, q.as_json)
  end

  def test_queue_latency_uses_the_oldest_job
    enqueue('lq', job('enqueued_at' => now_ms - 4_000))
    enqueue('lq', job('enqueued_at' => now_ms))

    assert_in_delta 4.0, Sidekiq::Queue.new('lq').latency, 1.0
    assert_in_delta(0.0, Sidekiq::Queue.new('nope').latency)
  end

  def test_queue_latency_falls_back_to_created_at_and_old_float_format
    enqueue('cq', job('created_at' => now_ms - 2_000).except('enqueued_at'))

    assert_in_delta 2.0, Sidekiq::Queue.new('cq').latency, 1.0

    enqueue('fq', job('enqueued_at' => now - 6.0))

    assert_in_delta 6.0, Sidekiq::Queue.new('fq').latency, 1.0
  end

  def test_queue_each_yields_job_records_newest_first
    jobs = Array.new(3) { |i| job('args' => [i]) }
    jobs.each { |j| enqueue('eq', j) }

    records = Sidekiq::Queue.new('eq').to_a

    assert(records.all?(Sidekiq::JobRecord))
    assert_equal [[2], [1], [0]], records.map(&:args)
    assert_equal ['eq'], records.map(&:queue).uniq
  end

  def test_queue_each_survives_deleting_every_job_while_iterating
    120.times { |i| enqueue('big', job('args' => [i])) }
    seen = 0

    Sidekiq::Queue.new('big').each do |record|
      seen += 1
      record.delete
    end

    assert_equal 120, seen
    assert_equal 0, Sidekiq::Queue.new('big').size
  end

  def test_queue_find_job
    target = job
    enqueue('fj', job)
    enqueue('fj', target)

    found = Sidekiq::Queue.new('fj').find_job(target['jid'])

    assert_equal target['jid'], found.jid
    assert_nil Sidekiq::Queue.new('fj').find_job('0' * 24)
  end

  def test_queue_clear_unlinks_the_list_and_forgets_the_queue
    enqueue('cl', job)
    enqueue('keep', job)

    assert Sidekiq::Queue.new('cl').clear

    assert_equal 0, redis('EXISTS', 'queue:cl')
    assert_equal ['keep'], redis('SMEMBERS', 'queues')
  end

  def test_queue_pause_and_unpause_use_the_paused_set
    q = Sidekiq::Queue.new('pq')

    refute_predicate q, :paused?
    assert q.pause!
    assert_predicate q, :paused?
    assert_equal ['pq'], redis('SMEMBERS', 'paused')
    refute q.pause!, 'pausing an already paused queue reports false'
    assert q.unpause!
    refute_predicate q, :paused?
    refute q.unpause!
  end

  def test_queue_delete_job_by_jid
    keep = job
    gone = job
    enqueue('dj', keep)
    enqueue('dj', gone)

    assert Sidekiq::Queue.new('dj').delete_job(gone['jid'])
    assert_equal [keep['jid']], Sidekiq::Queue.new('dj').map(&:jid)
  end

  # Pro returns the deleted payload, or nil on a miss, so `if q.delete_job(jid)`
  # branches on whether anything was removed.
  def test_queue_delete_job_miss_is_falsy
    gone = job
    enqueue('dj', gone)

    assert_equal dump(gone), Sidekiq::Queue.new('dj').delete_job(gone['jid'])
    assert_nil Sidekiq::Queue.new('dj').delete_job('0' * 24)
  end

  def test_queue_delete_by_class
    3.times { enqueue('dc', job('class' => 'Doomed')) }
    enqueue('dc', job('class' => 'Survivor'))

    assert_equal 3, Sidekiq::Queue.new('dc').delete_by_class('Doomed')
    assert_equal ['Survivor'], Sidekiq::Queue.new('dc').map(&:klass)
  end

  # --- JobRecord (§19.3, §2.3) ---------------------------------------------------

  def test_job_record_accessors
    created = now_ms - 1_234
    raw = dump(job('class' => 'Foo', 'args' => [1, 'a'], 'bid' => 'b1', 'tags' => %w[x],
                   'created_at' => created, 'enqueued_at' => created + 1,
                   'failed_at' => created + 2, 'retried_at' => created + 3, 'queue' => 'jr'))
    record = Sidekiq::JobRecord.new(raw)

    assert_equal 'Foo', record.klass
    assert_equal [1, 'a'], record.args
    assert_equal 'b1', record.bid
    assert_equal %w[x], record.tags
    assert_equal 'jr', record.queue
    assert_equal raw, record.value
    assert_equal 'Foo', record['class']
    assert_equal created, (record.created_at.to_r * 1000).to_i, 'Integer timestamps are epoch milliseconds'
    assert_equal created + 1, (record.enqueued_at.to_r * 1000).to_i
    assert_equal created + 2, (record.failed_at.to_r * 1000).to_i
    assert_equal created + 3, (record.retried_at.to_r * 1000).to_i
    assert_in_delta 1.2, record.latency, 1.0
  end

  def test_job_record_old_float_timestamps_and_absent_fields
    record = Sidekiq::JobRecord.new(dump(job('enqueued_at' => 1_600_000_000.5).except('created_at')))

    assert_in_delta 1_600_000_000.5, record.enqueued_at.to_f, 0.001
    assert_in_delta 1_600_000_000.5, record.created_at.to_f, 0.001, 'created_at falls back to enqueued_at'
    assert_nil record.failed_at
    assert_nil record.retried_at
    assert_equal [], Sidekiq::JobRecord.new(dump(job)).tags
  end

  def test_job_record_queue_name_override_and_delete
    raw = dump(job('queue' => 'ignored'))
    redis('LPUSH', 'queue:real', raw)
    record = Sidekiq::JobRecord.new(raw, 'real')

    assert_equal 'real', record.queue
    assert record.delete
    assert_equal 0, redis('LLEN', 'queue:real')
    refute record.delete, 'deleting a job that is gone reports false'
  end

  def test_job_record_tolerates_invalid_json
    record = Sidekiq::JobRecord.new('{not json')

    assert_equal ['{not json'], record.args
    assert_nil record.klass
    assert_nil record.jid
  end

  def test_job_record_decodes_compressed_backtrace
    lines = ['app.rb:1', 'app.rb:2']
    encoded = Base64.strict_encode64(Zlib::Deflate.deflate(Wurk.dump_json(lines)))

    assert_equal lines, Sidekiq::JobRecord.new(dump(job('error_backtrace' => encoded))).error_backtrace
    assert_nil Sidekiq::JobRecord.new(dump(job)).error_backtrace
  end

  def test_display_class_and_args_unwrap_active_job
    args = [{ 'job_class' => 'SignupJob', 'arguments' => [
      1, { '_aj_globalid' => 'gid://app/User/9' }, { 'a' => 1, '_aj_symbol_keys' => ['a'] }
    ] }]
    record = Sidekiq::JobRecord.new(dump(job('class' => WRAPPER, 'wrapped' => 'SignupJob', 'args' => args)))

    assert_equal WRAPPER, record.klass
    assert_equal 'SignupJob', record.display_class
    assert_equal [1, 'gid://app/User/9', { 'a' => 1 }], record.display_args
  end

  def test_display_class_and_args_unwrap_action_mailer
    args = [{ 'job_class' => 'ActionMailer::MailDeliveryJob', 'arguments' => [
      'UserMailer', 'welcome', 'deliver_now', { 'params' => { 'u' => 1 }, 'args' => [2] }
    ] }]
    record = Sidekiq::JobRecord.new(dump(job('class' => WRAPPER, 'wrapped' => 'ActionMailer::MailDeliveryJob',
                                             'args' => args)))

    assert_equal 'UserMailer#welcome', record.display_class
    assert_equal [{ 'u' => 1 }, [2]], record.display_args
  end

  def test_display_class_override
    assert_equal 'Shown', Sidekiq::JobRecord.new(dump(job('display_class' => 'Shown'))).display_class
  end

  def test_encrypted_last_arg_is_masked_in_display_args
    assert_equal [1, '[encrypted data]'],
                 Sidekiq::JobRecord.new(dump(job('args' => [1, 'c2VjcmV0'], 'encrypt' => true))).display_args
  end

  # --- SortedSet / JobSet (§19.4, §19.5) ----------------------------------------

  def test_job_sets_map_to_their_keys
    assert_equal 'schedule', Sidekiq::ScheduledSet.new.name
    assert_equal 'retry', Sidekiq::RetrySet.new.name
    assert_equal 'dead', Sidekiq::DeadSet.new.name
  end

  def test_sorted_set_size_each_and_order
    jobs = [100, 300, 200].map { |offset| [now + offset, job] }
    jobs.each { |score, j| redis('ZADD', 'retry', score, dump(j)) }

    set = Sidekiq::RetrySet.new
    entries = set.to_a

    assert_equal 3, set.size
    assert(entries.all?(Sidekiq::SortedEntry))
    assert_equal jobs.map(&:first).sort.reverse, entries.map(&:score), 'each walks highest score first'
  end

  def test_sorted_set_each_pages_past_fifty
    120.times { |i| redis('ZADD', 'schedule', now + i, dump(job('args' => [i]))) }

    assert_equal 120, Sidekiq::ScheduledSet.new.map(&:jid).uniq.size
  end

  def test_sorted_entry_fields
    at = now + 60.5
    j = job('error_class' => 'RuntimeError')
    redis('ZADD', 'retry', at, dump(j))

    entry = Sidekiq::RetrySet.new.first

    assert_in_delta at, entry.score, 0.001
    assert_kind_of Float, entry.score
    assert_in_delta at, entry.at.to_f, 0.001
    assert_predicate entry.at, :utc?
    score_part, jid_part = entry.id.split('|')

    assert_equal j['jid'], jid_part
    assert_in_delta at, Float(score_part), 0.001
    assert_predicate entry, :error?
    refute_predicate Sidekiq::SortedEntry.new(Sidekiq::RetrySet.new, at, dump(job)), :error?
    assert_equal 'retry', entry.parent.name
  end

  def test_scan_matches_substrings_and_returns_an_enumerator_without_a_block
    redis('ZADD', 'dead', now, dump(job('class' => 'CustomerJob')))
    redis('ZADD', 'dead', now, dump(job('class' => 'OtherJob')))

    set = Sidekiq::DeadSet.new

    assert_equal ['CustomerJob'], set.scan('Customer').map(&:klass)
    assert_kind_of Enumerator, set.scan('Customer')
    assert_equal 2, set.scan('*Job*').count, 'a pattern with * is passed through as-is'
    found = []
    set.scan('Other') { |e| found << e.klass }

    assert_equal ['OtherJob'], found
  end

  def test_find_job
    target = job
    redis('ZADD', 'schedule', now + 5, dump(job))
    redis('ZADD', 'schedule', now + 9, dump(target))

    assert_equal target['jid'], Sidekiq::ScheduledSet.new.find_job(target['jid']).jid
    assert_nil Sidekiq::ScheduledSet.new.find_job('0' * 24)
  end

  def test_fetch_by_score_range_and_jid
    s1 = now + 10
    s2 = now + 20
    a = job
    b = job
    c = job
    redis('ZADD', 'schedule', s1, dump(a))
    redis('ZADD', 'schedule', s1, dump(b))
    redis('ZADD', 'schedule', s2, dump(c))
    set = Sidekiq::ScheduledSet.new

    assert_equal [a, b].map { |x| x['jid'] }.sort, set.fetch(s1).map(&:jid).sort
    assert_equal [b['jid']], set.fetch(s1, b['jid']).map(&:jid)
    assert_equal 3, set.fetch(s1..s2).size
    assert_empty set.fetch(now + 99)
  end

  def test_schedule_adds_with_float_score
    at = Time.now + 30
    j = job
    Sidekiq::ScheduledSet.new.schedule(at, j)

    member, score = redis('ZRANGE', 'schedule', 0, -1, 'WITHSCORES').first

    assert_equal j, Wurk.load_json(member)
    assert_in_delta at.to_f, score.to_f, 0.001
  end

  def test_clear
    redis('ZADD', 'retry', now, dump(job))

    assert Sidekiq::RetrySet.new.clear
    assert_equal 0, redis('EXISTS', 'retry')
  end

  def test_entry_delete_and_delete_by_jid
    a = job
    b = job
    redis('ZADD', 'schedule', now + 1, dump(a))
    redis('ZADD', 'schedule', now + 2, dump(b))
    set = Sidekiq::ScheduledSet.new

    set.find_job(a['jid']).delete

    assert_equal [b['jid']], set.map(&:jid)

    entry = set.first
    set.delete(entry.score, b['jid'])

    assert_equal 0, set.size
  end

  def test_reschedule_moves_the_score
    j = job
    redis('ZADD', 'schedule', now + 100, dump(j))
    target = Time.now + 5_000

    Sidekiq::ScheduledSet.new.first.reschedule(target)

    _member, score = redis('ZRANGE', 'schedule', 0, -1, 'WITHSCORES').first

    assert_equal 1, redis('ZCARD', 'schedule')
    assert_in_delta target.to_f, score.to_f, 0.01
  end

  def test_add_to_queue_moves_a_scheduled_job_into_its_queue
    j = job('queue' => 'atq')
    redis('ZADD', 'schedule', now + 100, dump(j))

    Sidekiq::ScheduledSet.new.first.add_to_queue

    assert_equal 0, redis('ZCARD', 'schedule')
    queued = Wurk.load_json(redis('LINDEX', 'queue:atq', 0))

    assert_equal j['jid'], queued['jid']
    assert_kind_of Integer, queued['enqueued_at']
    assert_equal 1, redis('SISMEMBER', 'queues', 'atq')
  end

  def test_retry_enqueues_and_does_not_count_against_the_retry_limit
    j = job('queue' => 'rq', 'retry_count' => 3, 'error_class' => 'E')
    redis('ZADD', 'retry', now + 100, dump(j))

    Sidekiq::RetrySet.new.first.retry

    assert_equal 0, redis('ZCARD', 'retry')
    queued = Wurk.load_json(redis('LINDEX', 'queue:rq', 0))

    assert_equal j['jid'], queued['jid']
    assert_equal 2, queued['retry_count']
  end

  def test_retry_with_score_collision_takes_only_the_matching_job
    score = now + 100
    a = job('queue' => 'col')
    b = job('queue' => 'col')
    redis('ZADD', 'retry', score, dump(a))
    redis('ZADD', 'retry', score, dump(b))

    Sidekiq::RetrySet.new.find_job(a['jid']).retry

    assert_equal([a['jid']], redis('LRANGE', 'queue:col', 0, -1).map { |x| Wurk.load_json(x)['jid'] })
    assert_equal [b['jid']], Sidekiq::RetrySet.new.map(&:jid), 'the sibling with the same score stays'
  end

  def test_kill_moves_an_entry_to_the_dead_set
    j = job
    redis('ZADD', 'retry', now + 100, dump(j))

    Sidekiq::RetrySet.new.first.kill

    assert_equal 0, redis('ZCARD', 'retry')
    member, score = redis('ZRANGE', 'dead', 0, -1, 'WITHSCORES').first

    assert_equal j['jid'], Wurk.load_json(member)['jid']
    assert_in_delta now, score.to_f, 5.0
  end

  def test_pop_each_yields_lowest_score_first_and_empties_the_set
    [30, 10, 20].each { |o| redis('ZADD', 'schedule', now + o, dump(job('args' => [o]))) }
    seen = []

    Sidekiq::ScheduledSet.new.pop_each { |data, score| seen << [Wurk.load_json(data)['args'].first, score.to_f] }

    assert_equal [10, 20, 30], seen.map(&:first)
    assert_equal 0, redis('ZCARD', 'schedule')
  end

  def test_retry_all
    2.times { |i| redis('ZADD', 'retry', now + i, dump(job('queue' => 'ra', 'retry_count' => 1))) }

    Sidekiq::RetrySet.new.retry_all

    assert_equal 0, redis('ZCARD', 'retry')
    assert_equal([0, 0], redis('LRANGE', 'queue:ra', 0, -1).map { |x| Wurk.load_json(x)['retry_count'] })
  end

  def test_kill_all_moves_everything_without_notifying_by_default
    3.times { |i| redis('ZADD', 'retry', now + i, dump(job)) }
    calls = with_death_handler { Sidekiq::RetrySet.new.kill_all }

    assert_equal 0, redis('ZCARD', 'retry')
    assert_equal 3, redis('ZCARD', 'dead')
    assert_empty calls
  end

  # --- DeadSet (§19.5, §31 gotcha 8) --------------------------------------------

  def test_dead_set_kill_adds_now_and_notifies_death_handlers
    j = job
    calls = with_death_handler { assert Sidekiq::DeadSet.new.kill(dump(j)) }

    member, score = redis('ZRANGE', 'dead', 0, -1, 'WITHSCORES').first

    assert_equal j, Wurk.load_json(member)
    assert_in_delta now, score.to_f, 5.0
    assert_equal 1, calls.size
    job_hash, ex = calls.first

    assert_equal j['jid'], job_hash['jid']
    assert_kind_of RuntimeError, ex
    assert_equal 'Job killed by API', ex.message
  end

  def test_dead_set_kill_options
    custom = ArgumentError.new('custom')
    calls = with_death_handler do
      Sidekiq::DeadSet.new.kill(dump(job), notify_failure: false)
      Sidekiq::DeadSet.new.kill(dump(job), ex: custom)
    end

    assert_equal 1, calls.size, 'notify_failure: false skips the death handlers'
    assert_same custom, calls.first.last
    assert_equal 2, redis('ZCARD', 'dead')
  end

  def test_dead_set_trim_by_max_jobs_matches_zremrangebyrank_0_minus_max
    with_config(dead_max_jobs: 3) do
      5.times { |i| redis('ZADD', 'dead', now - 100 + i, dump(job('args' => [i]))) }

      Sidekiq::DeadSet.new.trim

      # ZREMRANGEBYRANK dead 0 -3 removes ranks 0..(size-3), keeping max - 1.
      assert_equal [[4], [3]], Sidekiq::DeadSet.new.map(&:args)
    end
  end

  def test_dead_set_trim_by_age
    with_config(dead_timeout_in_seconds: 60) do
      redis('ZADD', 'dead', now - 120, dump(job('args' => ['old'])))
      redis('ZADD', 'dead', now - 10, dump(job('args' => ['fresh'])))

      Sidekiq::DeadSet.new.trim

      assert_equal [['fresh']], Sidekiq::DeadSet.new.map(&:args)
    end
  end

  def test_dead_set_kill_trims_unless_told_not_to
    with_config(dead_max_jobs: 2) do
      3.times { |i| redis('ZADD', 'dead', now - 100 + i, dump(job)) }
      Sidekiq::DeadSet.new.kill(dump(job), notify_failure: false, trim: false)

      assert_equal 4, redis('ZCARD', 'dead')

      Sidekiq::DeadSet.new.kill(dump(job), notify_failure: false)

      assert_equal 1, redis('ZCARD', 'dead')
    end
  end

  # --- ProcessSet / Process (§19.6, §1.4, §31 gotcha 17) ------------------------

  def test_process_set_each_merges_heartbeat_fields_sorted_by_identity
    add_process('b-host:2:bbb', busy: 1, concurrency: 10, rss: 2048, quiet: 'true')
    add_process('a-host:1:aaa', busy: 0, concurrency: 5, rss: 1024)

    procs = Sidekiq::ProcessSet.new(false).to_a

    assert_equal %w[a-host:1:aaa b-host:2:bbb], procs.map(&:identity)
    b = procs.last

    assert_equal 10, b['concurrency']
    assert_equal 1, b['busy']
    assert_kind_of Float, b['beat']
    assert_equal 'true', b['quiet']
    assert_equal 2048, b['rss']
    assert_equal 250, b['rtt_us']
    assert_equal 'b-host', b['hostname']
    assert_equal 2, b['pid']
    assert_predicate b, :stopping?
    refute_predicate procs.first, :stopping?
  end

  def test_process_set_skips_identities_without_a_heartbeat
    add_process('live:1:aaa')
    redis('SADD', 'processes', 'gone:2:bbb')

    set = Sidekiq::ProcessSet.new(false)

    assert_equal ['live:1:aaa'], set.map(&:identity)
    assert_equal 2, set.size, 'size is SCARD and is not pruned'
  end

  def test_process_set_cleanup_prunes_dead_identities_once_a_minute
    add_process('live:1:aaa')
    redis('SADD', 'processes', 'gone:2:bbb')

    assert_equal 1, Sidekiq::ProcessSet.new(false).cleanup
    assert_equal ['live:1:aaa'], redis('SMEMBERS', 'processes')
    ttl = redis('TTL', 'process_cleanup')

    assert_operator ttl, :>, 0
    assert_operator ttl, :<=, 60

    redis('SADD', 'processes', 'gone:3:ccc')

    assert_equal 0, Sidekiq::ProcessSet.new(false).cleanup, 'rate-limited by process_cleanup NX EX 60'
  end

  def test_process_set_new_cleans_up_by_default
    redis('SADD', 'processes', 'gone:2:bbb')
    Sidekiq::ProcessSet.new

    assert_equal 0, redis('SCARD', 'processes')
  end

  def test_process_set_lookup_by_identity
    add_process('h:1:aaa', busy: 4)
    redis('SADD', 'processes', 'gone:2:bbb')
    redis('HSET', 'unregistered:3:ccc', 'info', '{}')

    assert_equal 4, Sidekiq::ProcessSet['h:1:aaa']['busy']
    assert_nil Sidekiq::ProcessSet['gone:2:bbb']
    assert_nil Sidekiq::ProcessSet['unregistered:3:ccc'], 'must be a processes member'
  end

  def test_process_set_totals_and_leader
    add_process('h:1:aaa', concurrency: 5, rss: 100)
    add_process('h:2:bbb', concurrency: 7, rss: 50)
    set = Sidekiq::ProcessSet.new(false)

    assert_equal 12, set.total_concurrency
    assert_equal 150, set.total_rss_in_kb
    assert_equal 150, set.total_rss
    assert_equal '', set.leader

    redis('SET', 'dear-leader', 'h:2:bbb')

    assert_equal 'h:2:bbb', Sidekiq::ProcessSet.new(false).leader
    assert_predicate Sidekiq::ProcessSet['h:2:bbb'], :leader?
    refute_predicate Sidekiq::ProcessSet['h:1:aaa'], :leader?
  end

  def test_process_attributes
    add_process('h:1:aaa', capsules: { 'default' => { 'concurrency' => 5, 'mode' => 'weighted',
                                                      'weights' => { 'critical' => 2, 'low' => 1 } } })
    process = Sidekiq::ProcessSet['h:1:aaa']

    assert_equal 'h:1:aaa', process.identity
    assert_equal 'h:1:aaa', process.id
    assert_equal 'myapp', process.tag
    assert_equal %w[l1], process.labels
    assert_equal '8.1.6', process.version
    refute_predicate process, :embedded?
    assert_equal %w[critical low], process.queues
    assert_equal({ 'critical' => 2, 'low' => 1 }, process.weights)
    assert_equal 'weighted', process.capsules['default']['mode']
  end

  def test_process_signals_are_lpushed_with_a_60s_ttl
    add_process('h:1:aaa')
    process = Sidekiq::ProcessSet['h:1:aaa']

    process.quiet!
    process.stop!
    process.dump_threads

    assert_equal %w[TTIN TERM TSTP], redis('LRANGE', 'h:1:aaa-signals', 0, -1)
    ttl = redis('TTL', 'h:1:aaa-signals')

    assert_operator ttl, :>, 0
    assert_operator ttl, :<=, 60
  end

  def test_embedded_process_refuses_quiet_and_stop
    add_process('h:1:aaa', embedded: true)
    process = Sidekiq::ProcessSet['h:1:aaa']

    assert_predicate process, :embedded?
    assert_raises(RuntimeError) { process.quiet! }
    assert_raises(RuntimeError) { process.stop! }
    assert_equal 0, redis('EXISTS', 'h:1:aaa-signals')
  end

  # --- WorkSet / Work (§19.7, §31 gotcha 13) ------------------------------------

  def test_work_set_each_yields_running_work_oldest_first
    early = job('class' => 'Early', 'queue' => 'wq')
    late = job('class' => 'Late', 'queue' => 'wq')
    add_process('h:1:aaa', busy: 2)
    add_process('h:2:bbb', busy: 1)
    add_work('h:1:aaa', 'tid-late', late, run_at: Time.now.to_i - 10)
    add_work('h:2:bbb', 'tid-early', early, run_at: Time.now.to_i - 100)
    redis('HSET', 'h:2:bbb:work', 'tid-idle', '')

    rows = Sidekiq::WorkSet.new.to_a

    assert_equal([%w[h:2:bbb tid-early], %w[h:1:aaa tid-late]], rows.map { |pid, tid, _| [pid, tid] })
    work = rows.first.last

    assert_equal 'h:2:bbb', work.process_id
    assert_equal 'tid-early', work.thread_id
    assert_equal 'wq', work.queue
    assert_kind_of Time, work.run_at
    assert_equal early['jid'], work.job.jid
    assert_equal 'Early', work.job.klass
    assert_equal dump(early), work.payload
  end

  def test_work_set_size_sums_busy_and_find_work
    target = job
    add_process('h:1:aaa', busy: 2)
    add_process('h:2:bbb', busy: 3)
    add_work('h:1:aaa', 't1', target)

    set = Sidekiq::WorkSet.new

    assert_equal 5, set.size, 'size is the heartbeat busy sum, not the work-hash count'
    assert_equal target['jid'], set.find_work(target['jid']).job.jid
    assert_equal target['jid'], set.find_work_by_jid(target['jid']).job.jid
    assert_nil set.find_work('0' * 24)
    assert_same Sidekiq::WorkSet, Sidekiq::Workers
  end

  def test_work_set_is_empty_without_processes
    assert_equal 0, Sidekiq::WorkSet.new.size
    assert_empty Sidekiq::WorkSet.new.to_a
  end

  private

  def redis(*cmd)
    Wurk.redis { |c| c.call(*cmd) }
  end

  def now = Time.now.to_f
  def now_ms = ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
  def day(date) = date.strftime('%Y-%m-%d')
  def dump(hash) = Wurk.dump_json(hash)

  def job(overrides = {})
    @n += 1
    { 'class' => 'ApiJob', 'args' => [@n], 'queue' => 'default', 'retry' => true,
      'jid' => format('%024x', (object_id << 16) + @n), 'created_at' => now_ms,
      'enqueued_at' => now_ms }.merge(overrides)
  end

  def enqueue(queue, hash)
    redis('SADD', 'queues', queue)
    redis('LPUSH', "queue:#{queue}", dump(hash))
  end

  def add_process(identity, busy: 0, concurrency: 5, rss: 0, quiet: 'false', capsules: nil, embedded: false)
    host, pid, = identity.split(':')
    info = { 'hostname' => host, 'started_at' => now, 'pid' => pid.to_i, 'tag' => 'myapp',
             'concurrency' => concurrency, 'labels' => %w[l1], 'identity' => identity, 'version' => '8.1.6',
             'embedded' => embedded,
             'capsules' => capsules || { 'default' => { 'concurrency' => concurrency, 'mode' => 'strict',
                                                        'weights' => { 'default' => 0 } } } }
    redis('SADD', 'processes', identity)
    redis('HSET', identity, 'info', dump(info), 'concurrency', concurrency.to_s, 'busy', busy.to_s,
          'beat', now.to_s, 'quiet', quiet, 'rss', rss.to_s, 'rtt_us', '250')
    redis('EXPIRE', identity, 60)
  end

  def add_work(identity, tid, payload, run_at: Time.now.to_i)
    redis('HSET', "#{identity}:work", tid, dump({ 'queue' => payload['queue'], 'payload' => dump(payload),
                                                  'run_at' => run_at }))
  end

  def with_death_handler
    calls = []
    handler = ->(job, ex) { calls << [job, ex] }
    handlers = Sidekiq.default_configuration.death_handlers
    handlers << handler
    yield
    calls
  ensure
    handlers.delete(handler)
  end

  def with_config(**overrides)
    config = Sidekiq.default_configuration
    saved = overrides.keys.to_h { |k| [k, config[k]] }
    overrides.each { |k, v| config[k] = v }
    yield
  ensure
    saved&.each { |k, v| config[k] = v }
  end
end
