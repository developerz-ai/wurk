# frozen_string_literal: true

require_relative '../test_helper'
require 'tzinfo'

class CronTest < Wurk::Test::UnitCase
  parallelize_me!


  # Workers used by ConfigTester resolution checks. Bodies stay empty —
  # the test only needs the constant to resolve, not actual perform logic.
  class FooWorker # rubocop:disable Lint/EmptyClass
  end

  class BarWorker # rubocop:disable Lint/EmptyClass
  end

  class DSTWorker # rubocop:disable Lint/EmptyClass
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

  def test_last_fired_at_nil_when_never_fired
    lp = register_loop("CronTest::LastNil#{@suffix}", queue: "cron-ln-#{@suffix}")

    assert_nil lp.last_fired_at
  end

  def test_last_fired_at_returns_newest_timestamp
    lp = register_loop("CronTest::LastTs#{@suffix}", queue: "cron-lt-#{@suffix}")
    Wurk.redis { |c| c.call('LPUSH', "#{Wurk::Cron::HISTORY_PREFIX}#{lp.lid}", JSON.dump([1_700_000_000, 'jid-x'])) }

    assert_equal 1_700_000_000, lp.last_fired_at
  ensure
    Wurk.redis { |c| c.call('DEL', "#{Wurk::Cron::HISTORY_PREFIX}#{lp.lid}") }
  end

  def test_last_fired_at_nil_on_non_tuple_payload
    lp = register_loop("CronTest::LastBad#{@suffix}", queue: "cron-lb-#{@suffix}")
    Wurk.redis { |c| c.call('LPUSH', "#{Wurk::Cron::HISTORY_PREFIX}#{lp.lid}", JSON.dump('not-an-array')) }

    assert_nil lp.last_fired_at
  ensure
    Wurk.redis { |c| c.call('DEL', "#{Wurk::Cron::HISTORY_PREFIX}#{lp.lid}") }
  end

  def test_poller_tick_interval_defaults_to_60
    poller = Wurk::Cron::Poller.new(Wurk.configuration)

    assert_equal 60, poller.instance_variable_get(:@tick_interval)
  end

  def test_poller_tick_interval_reads_config
    cfg = Wurk::Configuration.new
    cfg[:cron_tick_interval] = 0.25

    assert_equal 0.25, Wurk::Cron::Poller.new(cfg).instance_variable_get(:@tick_interval)
  end

  # ---- DST / timezone edge cases (US / EU / AU) -----------------------
  #
  # 2026 transitions (confirmed via TZInfo):
  #   America/New_York  spring 03-08 02:00→03:00   fall 11-01 02:00→01:00
  #   Europe/London     spring 03-29 01:00→02:00   fall 10-25 02:00→01:00
  #   Australia/Sydney  spring 10-04 02:00→03:00   fall 04-05 03:00→02:00
  # TZInfo objects (not IANA strings) so the parser uses #utc_to_local and we
  # don't mutate the process-global ENV['TZ'] under the parallel runner.

  # --- fall-back fold: the once-daily slot must fire exactly once ---

  def test_dst_fall_back_fires_once_new_york
    fires = simulate_fires('30 1 * * *', tz('America/New_York'),
                           Time.utc(2026, 11, 1, 4, 0), Time.utc(2026, 11, 1, 8, 0))

    assert_equal 1, fires.size, 'daily 01:30 must fire once across the US fall-back fold'
  end

  def test_dst_fall_back_fires_once_london
    fires = simulate_fires('30 1 * * *', tz('Europe/London'),
                           Time.utc(2026, 10, 25, 0, 0), Time.utc(2026, 10, 25, 2, 0))

    assert_equal 1, fires.size, 'daily 01:30 must fire once across the EU fall-back fold'
  end

  def test_dst_fall_back_fires_once_sydney
    fires = simulate_fires('30 2 * * *', tz('Australia/Sydney'),
                           Time.utc(2026, 4, 4, 15, 0), Time.utc(2026, 4, 4, 17, 0))

    assert_equal 1, fires.size, 'daily 02:30 must fire once across the AU fall-back fold'
  end

  # --- the parser itself enumerates the fold twice (why the dedup exists) ---

  def test_dst_parser_enumerates_fall_back_fold_twice
    tzobj = tz('America/New_York')
    parser = Wurk::Cron::Parser.new('30 1 * * *')
    first = parser.next_fire_at(Time.utc(2026, 11, 1, 4, 0).to_i, tzobj)
    second = parser.next_fire_at(first, tzobj)

    refute_equal first, second
    assert_equal parser.local_components(first, tzobj), parser.local_components(second, tzobj),
                 'both fold instants share the same local wall-clock — the source of a double-fire'
  end

  def test_dst_next_fire_after_skips_the_fold
    loop_obj = dst_loop('30 1 * * *', tz('America/New_York'))
    first = loop_obj.next_fire_at(Time.utc(2026, 11, 1, 4, 0).to_i)
    fold_dup = loop_obj.next_fire_at(first)

    skipped = loop_obj.next_fire_after(first, first)

    refute_equal fold_dup, skipped, 'next_fire_after must not return the fold duplicate'
    assert_operator skipped, :>, Time.utc(2026, 11, 1, 8, 0).to_i, 'should jump to the next day'
  end

  # --- a frequency loop keeps its real-time cadence across the fold ---

  def test_dst_fall_back_frequency_loop_keeps_cadence
    # */30 across the US fold spans six real half-hours (05:00..07:30 UTC) and
    # must fire all six — the dedup only suppresses an identical wall-clock minute.
    fires = simulate_fires('*/30 * * * *', tz('America/New_York'),
                           Time.utc(2026, 11, 1, 4, 30), Time.utc(2026, 11, 1, 7, 30))

    assert_equal 6, fires.size
  end

  def test_dst_fall_back_hourly_keeps_both_fold_hours
    # An hourly loop must run in BOTH repeated 01:00 fall-back hours (01:00 EDT
    # and 01:00 EST) — the fold dedup is only for fixed daily slots, never for
    # an hourly cadence whose repeated hour is a genuine second run.
    nyt = tz('America/New_York')
    fires = simulate_fires('0 * * * *', nyt, Time.utc(2026, 11, 1, 4, 0), Time.utc(2026, 11, 1, 7, 0))
    one_am = fires.count { |f| lc = nyt.utc_to_local(Time.at(f)); lc.hour == 1 && lc.min.zero? }

    assert_equal 2, one_am, 'hourly 0 * * * * must fire in both fold 01:00 hours, not skip one'
  end

  def test_dst_fall_back_hourly_nonzero_minute_keeps_both_fold_hours
    # Guards the discriminator: "hourly" means the hour field is a wildcard, NOT
    # "minute == 0". 15 * * * * must also keep both repeated fall-back hours.
    nyt = tz('America/New_York')
    fires = simulate_fires('15 * * * *', nyt, Time.utc(2026, 11, 1, 4, 0), Time.utc(2026, 11, 1, 7, 0))
    one_fifteen = fires.count { |f| lc = nyt.utc_to_local(Time.at(f)); lc.hour == 1 && lc.min == 15 }

    assert_equal 2, one_fifteen
  end

  # --- spring-forward gap: the missing slot is skipped to the next valid day ---

  def test_dst_spring_forward_skips_gap_new_york
    nxt = next_local_fire('30 2 * * *', tz('America/New_York'), Time.utc(2026, 3, 8, 5, 0))

    assert_equal [30, 2], nxt[0, 2], 'fires at 02:30…'
    assert_equal 9, nxt[2], '…on 03-09, having skipped the non-existent 03-08 02:30'
  end

  def test_dst_spring_forward_skips_gap_london
    nxt = next_local_fire('30 1 * * *', tz('Europe/London'), Time.utc(2026, 3, 29, 0, 0))

    assert_equal [30, 1], nxt[0, 2]
    assert_equal 30, nxt[2], 'skips the non-existent 03-29 01:30, fires 03-30'
  end

  def test_dst_spring_forward_skips_gap_sydney
    nxt = next_local_fire('30 2 * * *', tz('Australia/Sydney'), Time.utc(2026, 10, 3, 14, 0))

    assert_equal [30, 2], nxt[0, 2]
    assert_equal 5, nxt[2], 'skips the non-existent 10-04 02:30, fires 10-05'
  end

  # ---- Cron.fire! (deterministic test/ops helper) ---------------------

  def test_fire_bang_enqueues_the_loop_job
    queue = "cron-fire-#{@suffix}"
    lp = register_loop("CronTest::FireOne#{@suffix}", queue: queue, schedule: '0 4 * * *')

    Wurk::Cron.fire!(lp.lid)
    raw = Wurk.redis { |c| c.call('RPOP', "queue:#{queue}") }
    cleanup_queue(queue)

    refute_nil raw, 'fire! should enqueue even when the loop is not due'
    assert_equal "CronTest::FireOne#{@suffix}", JSON.parse(raw)['class']
  end

  def test_fire_bang_records_one_history_entry
    lp = register_loop("CronTest::FireHist#{@suffix}", queue: "cron-fh-#{@suffix}")

    Wurk::Cron.fire!(lp.lid)
    len = Wurk.redis { |c| c.call('LLEN', "#{Wurk::Cron::HISTORY_PREFIX}#{lp.lid}") }
    cleanup_queue("cron-fh-#{@suffix}")

    assert_equal 1, len
  end

  def test_fire_bang_returns_jid
    lp = register_loop("CronTest::FireJid#{@suffix}", queue: "cron-fj-#{@suffix}")

    jid = Wurk::Cron.fire!(lp.lid)
    cleanup_queue("cron-fj-#{@suffix}")

    assert jid.is_a?(String) && !jid.empty?
  end

  def test_fire_bang_returns_nil_for_unknown_lid
    assert_nil Wurk::Cron.fire!("no-such-lid-#{@suffix}")
  end

  def test_fire_bang_aliased_under_sidekiq_periodic
    queue = "cron-alias-#{@suffix}"
    lp = register_loop("CronTest::FireAlias#{@suffix}", queue: queue)

    jid = Sidekiq::Periodic.fire!(lp.lid)
    cleanup_queue(queue)

    refute_nil jid
  end

  # ---- nil next-fire marks (no resolvable future occurrence) -----------

  def test_record_fire_clears_nf_when_future_is_nil
    # A loop with no resolvable next fire (e.g. Feb 31) yields next_fire_at => nil.
    # record_fire must NOT persist nf as "" — read_fire_marks would coerce "" to 0
    # and every subsequent tick would treat the loop as immediately due forever.
    poller = Wurk::Cron::Poller.new(Wurk.configuration)
    lp = register_loop("CronTest::NoFuture#{@suffix}", queue: "cron-nf-#{@suffix}")
    key = "#{Wurk::Cron::LOOP_PREFIX}#{lp.lid}"
    Wurk.redis { |c| c.call('HSET', key, 'nf', '9999999999') } # pre-existing mark to clear

    poller.send(:record_fire, lp, 'jid-nofuture', Time.now.to_i, nil)

    raw_nf = Wurk.redis { |c| c.call('HGET', key, 'nf') }
    marks = poller.send(:read_fire_marks, lp.lid)
    cleanup_queue("cron-nf-#{@suffix}")

    assert_nil raw_nf, 'nil future must clear the nf field, not write ""'
    assert_nil marks[1], 'read_fire_marks must read an absent/empty nf as nil, not 0'
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

  def register_loop(klass, queue:, schedule: '* * * * *', **opts)
    mgr = Wurk::Cron::Manager.new
    lp = mgr.register(schedule, klass, queue: queue, **opts)
    @lids << lp.lid
    lp
  end

  def tz(name)
    TZInfo::Timezone.get(name)
  end

  def dst_loop(schedule, tzobj)
    Wurk::Cron::Loop.new(schedule: schedule, klass: 'CronTest::DSTWorker', tz: tzobj)
  end

  # Replays the leader poller's fire-advance (next_fire_after) across
  # [from_utc, to_utc], returning the fired UTC epochs. Bounded so a regression
  # that loops can't hang the suite.
  def simulate_fires(schedule, tzobj, from_utc, to_utc)
    loop_obj = dst_loop(schedule, tzobj)
    fires = []
    slot = loop_obj.next_fire_at(from_utc.to_i)
    500.times do
      break if slot.nil? || slot > to_utc.to_i

      fires << slot
      slot = loop_obj.next_fire_after(slot, slot)
    end
    fires
  end

  # Local [min, hour, day] of the first fire at/after `from_utc`.
  def next_local_fire(schedule, tzobj, from_utc)
    loop_obj = dst_loop(schedule, tzobj)
    nf = loop_obj.next_fire_at(from_utc.to_i)
    refute_nil nf, 'next_fire_at must resolve a future fire across the spring-forward gap'
    loop_obj.local_components(nf)[0, 3]
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
