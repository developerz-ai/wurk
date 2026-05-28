# frozen_string_literal: true

require_relative '../test_helper'

class CronTest < Wurk::Test::UnitCase
  parallelize_me!

  REDIS_URL = ENV['REDIS_URL'] || 'redis://localhost:6379/0'

  # Workers used by ConfigTester resolution checks. Bodies stay empty —
  # the test only needs the constant to resolve, not actual perform logic.
  class FooWorker # rubocop:disable Lint/EmptyClass
  end

  class BarWorker # rubocop:disable Lint/EmptyClass
  end

  def setup
    super
    @suffix = "cron#{Process.pid}#{object_id}"
    @lids = []
  end

  def teardown
    @lids.each { |lid| Wurk::Cron.unregister(lid) }
  ensure
    super
  end

  # ---- Parser: fields ---------------------------------------------------

  def test_parser_rejects_wrong_field_count
    assert_raises(ArgumentError) { Wurk::Cron::Parser.new('* * * *') }
    assert_raises(ArgumentError) { Wurk::Cron::Parser.new('* * * * * *') }
  end

  def test_parser_rejects_non_string
    assert_raises(ArgumentError) { Wurk::Cron::Parser.new(nil) }
    assert_raises(ArgumentError) { Wurk::Cron::Parser.new(123) }
  end

  def test_parser_expands_wildcard_minute
    p = Wurk::Cron::Parser.new('* * * * *')

    assert_equal 60, p.fields[0].size
  end

  def test_parser_step_every_five_minutes
    p = Wurk::Cron::Parser.new('*/5 * * * *')

    assert_equal Set.new([0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55]), p.fields[0]
  end

  def test_parser_list_values
    p = Wurk::Cron::Parser.new('0,15,30,45 * * * *')

    assert_equal Set.new([0, 15, 30, 45]), p.fields[0]
  end

  def test_parser_range
    p = Wurk::Cron::Parser.new('* 9-17 * * *')

    assert_equal Set.new(9..17), p.fields[1]
  end

  def test_parser_range_with_step
    p = Wurk::Cron::Parser.new('* 8-18/2 * * *')

    assert_equal Set.new([8, 10, 12, 14, 16, 18]), p.fields[1]
  end

  def test_parser_dow_7_normalized_to_0
    p = Wurk::Cron::Parser.new('0 0 * * 7')

    assert_includes p.fields[4], 0
    refute_includes p.fields[4], 7
  end

  def test_parser_rejects_out_of_range_minute
    assert_raises(ArgumentError) { Wurk::Cron::Parser.new('60 * * * *') }
  end

  def test_parser_rejects_out_of_range_hour
    assert_raises(ArgumentError) { Wurk::Cron::Parser.new('* 24 * * *') }
  end

  def test_parser_rejects_out_of_range_dom
    assert_raises(ArgumentError) { Wurk::Cron::Parser.new('* * 32 * *') }
  end

  def test_parser_rejects_out_of_range_month
    assert_raises(ArgumentError) { Wurk::Cron::Parser.new('* * * 13 *') }
  end

  def test_parser_rejects_out_of_range_dow
    assert_raises(ArgumentError) { Wurk::Cron::Parser.new('* * * * 8') }
  end

  def test_parser_rejects_reversed_range
    assert_raises(ArgumentError) { Wurk::Cron::Parser.new('10-5 * * * *') }
  end

  def test_parser_rejects_zero_step
    assert_raises(ArgumentError) { Wurk::Cron::Parser.new('*/0 * * * *') }
  end

  def test_parser_alias_hourly
    assert_equal '0 * * * *', Wurk::Cron::Parser.new('@hourly').expression
  end

  def test_parser_alias_daily
    assert_equal '0 0 * * *', Wurk::Cron::Parser.new('@daily').expression
  end

  def test_parser_alias_weekly
    assert_equal '0 0 * * 0', Wurk::Cron::Parser.new('@weekly').expression
  end

  def test_parser_alias_monthly
    assert_equal '0 0 1 * *', Wurk::Cron::Parser.new('@monthly').expression
  end

  def test_parser_alias_yearly
    assert_equal '0 0 1 1 *', Wurk::Cron::Parser.new('@yearly').expression
  end

  # ---- Parser: next_fire_at --------------------------------------------

  def test_next_fire_at_every_minute
    p = Wurk::Cron::Parser.new('* * * * *')
    now = ::Time.utc(2026, 1, 1, 12, 0, 30).to_i
    nxt = p.next_fire_at(now)

    assert_equal ::Time.utc(2026, 1, 1, 12, 1, 0).to_i, nxt
  end

  def test_next_fire_at_every_five_minutes
    p = Wurk::Cron::Parser.new('*/5 * * * *')
    now = ::Time.utc(2026, 1, 1, 12, 2, 0).to_i
    nxt = p.next_fire_at(now)

    assert_equal ::Time.utc(2026, 1, 1, 12, 5, 0).to_i, nxt
  end

  def test_next_fire_at_daily_at_4am
    p = Wurk::Cron::Parser.new('0 4 * * *')
    now = ::Time.utc(2026, 1, 1, 5, 0, 0).to_i
    nxt = p.next_fire_at(now)

    assert_equal ::Time.utc(2026, 1, 2, 4, 0, 0).to_i, nxt
  end

  def test_next_fire_at_strictly_after_from
    p = Wurk::Cron::Parser.new('* * * * *')
    boundary = ::Time.utc(2026, 1, 1, 12, 0, 0).to_i
    nxt = p.next_fire_at(boundary)

    assert_operator nxt, :>, boundary
    assert_equal boundary + 60, nxt
  end

  def test_next_fire_at_weekly_sunday_midnight
    p = Wurk::Cron::Parser.new('0 0 * * 0')
    # 2026-01-04 is a Sunday.
    monday = ::Time.utc(2026, 1, 5, 12, 0, 0).to_i
    nxt = p.next_fire_at(monday)

    assert_equal 0, ::Time.at(nxt).utc.wday
  end

  def test_next_fire_at_dow_seven_matches_sunday
    p = Wurk::Cron::Parser.new('0 0 * * 7')
    monday = ::Time.utc(2026, 1, 5, 12, 0, 0).to_i
    nxt = p.next_fire_at(monday)

    assert_equal 0, ::Time.at(nxt).utc.wday
  end

  # ---- Loop -------------------------------------------------------------

  def test_loop_lid_stable_for_same_inputs
    a = Wurk::Cron::Loop.new(schedule: '* * * * *', klass: 'A', options: { 'queue' => 'low' })
    b = Wurk::Cron::Loop.new(schedule: '* * * * *', klass: 'A', options: { 'queue' => 'low' })

    assert_equal a.lid, b.lid
    assert_equal 16, a.lid.length
  end

  def test_loop_lid_differs_for_different_inputs
    a = Wurk::Cron::Loop.new(schedule: '* * * * *', klass: 'A')
    b = Wurk::Cron::Loop.new(schedule: '* * * * *', klass: 'B')

    refute_equal a.lid, b.lid
  end

  def test_loop_rejects_invalid_cron
    assert_raises(ArgumentError) { Wurk::Cron::Loop.new(schedule: 'bogus', klass: 'A') }
  end

  def test_loop_rejects_empty_klass
    assert_raises(ArgumentError) { Wurk::Cron::Loop.new(schedule: '* * * * *', klass: '') }
  end

  def test_loop_to_redis_hash_carries_schedule_and_klass
    lp = Wurk::Cron::Loop.new(schedule: '* * * * *', klass: 'A')
    h = lp.to_redis_hash

    assert_equal '* * * * *', h['schedule']
    assert_equal 'A', h['klass']
  end

  def test_loop_to_redis_hash_json_options_round_trip
    lp = Wurk::Cron::Loop.new(schedule: '* * * * *', klass: 'A', options: { queue: 'low', args: [1, 2] })
    parsed = JSON.parse(lp.to_redis_hash['options'])

    assert_equal({ 'queue' => 'low', 'args' => [1, 2] }, parsed)
  end

  def test_loop_paused_flag_round_trips
    lp = Wurk::Cron::Loop.new(schedule: '* * * * *', klass: 'A', options: { 'paused' => '1' })

    assert_predicate lp, :paused?
  end

  # ---- Manager registration + Redis -----------------------------------

  def test_register_adds_lid_to_periodic_set
    lp = register_for_persist_test
    membership = Wurk.redis { |c| c.call('SISMEMBER', Wurk::Cron::PERIODIC_KEY, lp.lid) }

    assert_equal 1, membership
  end

  def test_register_writes_schedule_to_loop_hash
    lp = register_for_persist_test

    assert_equal '*/5 * * * *', loop_hash(lp.lid)['schedule']
  end

  def test_register_writes_klass_to_loop_hash
    lp = register_for_persist_test

    assert_equal 'CronTest::FooWorker', loop_hash(lp.lid)['klass']
  end

  def test_register_idempotent_for_same_inputs
    mgr = Wurk::Cron::Manager.new
    a = mgr.register('*/5 * * * *', 'CronTest::FooWorker')
    b = mgr.register('*/5 * * * *', 'CronTest::FooWorker')
    @lids << a.lid
    membership = Wurk.redis { |c| c.call('SISMEMBER', Wurk::Cron::PERIODIC_KEY, a.lid) }

    assert_equal a.lid, b.lid
    assert_equal 1, membership
  end

  def test_manager_tz_default_applies_to_subsequent_registers
    mgr = Wurk::Cron::Manager.new
    mgr.tz = 'America/Chicago'
    lp = mgr.register('0 4 * * *', 'CronTest::FooWorker')
    @lids << lp.lid

    assert_equal 'America/Chicago', lp.tz
  end

  def test_manager_per_call_tz_overrides_default
    mgr = Wurk::Cron::Manager.new
    mgr.tz = 'America/Chicago'
    lp = mgr.register('0 4 * * *', 'CronTest::FooWorker', tz: 'Asia/Tokyo')
    @lids << lp.lid

    assert_equal 'Asia/Tokyo', lp.tz
  end

  def test_register_accepts_constant_klass
    mgr = Wurk::Cron::Manager.new
    lp = mgr.register('* * * * *', CronTest::FooWorker)
    @lids << lp.lid

    assert_equal 'CronTest::FooWorker', lp.klass
  end

  # ---- Top-level register(name, cron, klass, args) --------------------

  def test_module_register_carries_schedule_and_klass
    lp = Wurk::Cron.register('nightly', '0 4 * * *', 'CronTest::BarWorker', ['nightly'], queue: 'low')
    @lids << lp.lid

    assert_equal ['0 4 * * *', 'CronTest::BarWorker'], [lp.schedule, lp.klass]
  end

  def test_module_register_carries_args_and_queue
    lp = Wurk::Cron.register('nightly', '0 4 * * *', 'CronTest::BarWorker', ['nightly'], queue: 'low')
    @lids << lp.lid

    assert_equal [['nightly'], 'low'], [lp.args, lp.queue]
  end

  # ---- LoopSet --------------------------------------------------------

  def test_loop_set_each_yields_registered_loops
    mgr = Wurk::Cron::Manager.new
    a = mgr.register('* * * * *', "CronTest::FooWorker#{@suffix}A")
    b = mgr.register('0 * * * *', "CronTest::FooWorker#{@suffix}B")
    @lids << a.lid << b.lid

    set = Wurk::Cron::LoopSet.new
    found = set.to_a.map(&:lid)

    assert_includes found, a.lid
    assert_includes found, b.lid
  end

  def test_loop_set_size_matches_registered_count
    mgr = Wurk::Cron::Manager.new
    lp = mgr.register('* * * * *', "CronTest::Sized#{@suffix}")
    @lids << lp.lid

    assert_operator Wurk::Cron::LoopSet.new.size, :>=, 1
  end

  def test_loop_set_fetch_returns_loop_for_known_lid
    mgr = Wurk::Cron::Manager.new
    lp = mgr.register('* * * * *', "CronTest::Fetch#{@suffix}", queue: 'high')
    @lids << lp.lid

    found = Wurk::Cron::LoopSet.new.fetch(lp.lid)

    refute_nil found
    assert_equal lp.lid, found.lid
    assert_equal 'high', found.queue
  end

  def test_loop_set_fetch_returns_nil_for_unknown_lid
    assert_nil Wurk::Cron::LoopSet.new.fetch('deadbeef00000000')
  end

  # ---- ConfigTester ---------------------------------------------------

  def test_config_tester_verifies_valid_block
    block = ->(mgr) { mgr.register('* * * * *', 'CronTest::FooWorker') }
    loops = Wurk::Cron::ConfigTester.new.verify(&block)
    @lids.concat(loops.map(&:lid))

    assert_equal 1, loops.size
  end

  def test_config_tester_raises_on_missing_class
    block = ->(mgr) { mgr.register('* * * * *', 'NoSuchWorker123') }
    err = assert_raises(ArgumentError) { Wurk::Cron::ConfigTester.new.verify(&block) }

    assert_match(/NoSuchWorker123/, err.message)
  end

  def test_config_tester_raises_on_invalid_cron
    block = ->(mgr) { mgr.register('bogus expr', 'CronTest::FooWorker') }
    assert_raises(ArgumentError) { Wurk::Cron::ConfigTester.new.verify(&block) }
  end

  def test_config_tester_requires_block
    assert_raises(ArgumentError) { Wurk::Cron::ConfigTester.new.verify }
  end

  # ---- Poller leader-driven enqueue -----------------------------------

  def test_poller_does_not_enqueue_when_not_leader
    mgr = Wurk::Cron::Manager.new
    queue = "cron-q-#{@suffix}"
    lp = mgr.register('* * * * *', "CronTest::Pollee#{@suffix}", queue: queue)
    @lids << lp.lid

    poller = Wurk::Cron::Poller.new(Wurk.configuration)
    # Not the cluster leader → never enqueues.
    poller.define_singleton_method(:leader?) { false }

    poller.tick

    len = Wurk.redis { |c| c.call('LLEN', "queue:#{queue}") }
    cleanup_queue(queue)

    assert_equal 0, len
  end

  def test_poller_enqueues_payload_when_leader
    job = enqueue_via_leader_tick(klass: "CronTest::Pollee#{@suffix}", queue: "cron-q-#{@suffix}", args: [1, 2])

    assert_equal "CronTest::Pollee#{@suffix}", job['class']
  end

  def test_poller_enqueues_args_when_leader
    job = enqueue_via_leader_tick(klass: "CronTest::PolleeArgs#{@suffix}", queue: "cron-qa-#{@suffix}", args: [1, 2])

    assert_equal [1, 2], job['args']
  end

  def test_poller_enqueues_queue_when_leader
    queue = "cron-qq-#{@suffix}"
    job = enqueue_via_leader_tick(klass: "CronTest::PolleeQ#{@suffix}", queue: queue, args: [])

    assert_equal queue, job['queue']
  end

  def test_poller_skips_paused_loops
    mgr = Wurk::Cron::Manager.new
    queue = "cron-q-paused-#{@suffix}"
    lp = mgr.register('* * * * *', "CronTest::Paused#{@suffix}", queue: queue, paused: '1')
    @lids << lp.lid

    poller = Wurk::Cron::Poller.new(Wurk.configuration)
    poller.define_singleton_method(:leader?) { true }

    poller.tick

    len = Wurk.redis { |c| c.call('LLEN', "queue:#{queue}") }
    cleanup_queue(queue)

    assert_equal 0, len
  end

  def test_poller_records_history_entry_on_fire
    history = history_after_leader_tick

    assert_equal 1, history.size
  end

  def test_poller_history_entry_carries_ts_and_jid
    history = history_after_leader_tick
    ts, jid = JSON.parse(history.first)

    assert ts.is_a?(Integer) && jid.is_a?(String) && !jid.empty?
  end

  # ---- Configuration#periodic -----------------------------------------

  def test_configure_server_periodic_block_yields_manager
    cfg = Wurk::Configuration.new
    mgr_seen = nil
    cfg.periodic { |mgr| mgr_seen = mgr }

    assert_kind_of Wurk::Cron::Manager, mgr_seen
  end

  def test_configure_periodic_returns_manager_without_block
    cfg = Wurk::Configuration.new

    assert_kind_of Wurk::Cron::Manager, cfg.periodic
  end

  # ---- Sidekiq aliases ------------------------------------------------

  def test_aliased_under_sidekiq_namespace
    assert_same Wurk::Cron, Sidekiq::Cron
    assert_same Wurk::Cron, Sidekiq::Periodic
  end

  def test_constants_match_spec_keys
    assert_equal 'periodic', Wurk::Cron::PERIODIC_KEY
    assert_equal 'loops:', Wurk::Cron::LOOP_PREFIX
  end

  private

  def cleanup_queue(queue)
    Wurk.redis do |c|
      c.call('DEL', "queue:#{queue}")
      c.call('SREM', 'queues', queue)
    end
  end

  def register_for_persist_test
    mgr = Wurk::Cron::Manager.new
    lp = mgr.register('*/5 * * * *', 'CronTest::FooWorker', queue: 'low')
    @lids << lp.lid
    lp
  end

  def loop_hash(lid)
    h = Wurk.redis { |c| c.call('HGETALL', "#{Wurk::Cron::LOOP_PREFIX}#{lid}") }
    h.is_a?(Array) ? h.each_slice(2).to_h : h
  end

  def build_leader_poller
    poller = Wurk::Cron::Poller.new(Wurk.configuration)
    # Pretend this process holds the cluster lock.
    poller.define_singleton_method(:leader?) { true }
    poller
  end

  def enqueue_via_leader_tick(klass:, queue:, args:)
    mgr = Wurk::Cron::Manager.new
    lp = mgr.register('* * * * *', klass, queue: queue, args: args)
    @lids << lp.lid
    build_leader_poller.tick
    raw = Wurk.redis { |c| c.call('RPOP', "queue:#{queue}") }
    cleanup_queue(queue)
    raise 'no job enqueued' if raw.nil?

    JSON.parse(raw)
  end

  def history_after_leader_tick
    mgr = Wurk::Cron::Manager.new
    queue = "cron-q-hist-#{@suffix}"
    lp = mgr.register('* * * * *', "CronTest::Hist#{@suffix}", queue: queue)
    @lids << lp.lid
    build_leader_poller.tick
    history = Wurk.redis { |c| c.call('LRANGE', "#{Wurk::Cron::HISTORY_PREFIX}#{lp.lid}", 0, -1) }
    cleanup_queue(queue)
    history
  end
end
