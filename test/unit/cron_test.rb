# frozen_string_literal: true

require_relative '../test_helper'
require 'tzinfo'
require 'active_job'
require 'active_job/queue_adapters/wurk_adapter'

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

  # Resolvable constant for the ConfigTester pruning checks.
  class PruneWorker # rubocop:disable Lint/EmptyClass
  end

  def setup
    super
    @suffix = "cron#{Process.pid}#{object_id}"
    @lids = []
    @configs = []
  end

  def teardown
    @lids.each { |lid| Wurk::Cron.unregister(lid) }
    @configs.each(&:reset_redis_pools!)
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

    assert_equal persist_klass, loop_hash(lp.lid)['klass']
  end

  def test_register_idempotent_for_same_inputs
    mgr = Wurk::Cron::Manager.new
    klass = "CronTest::Idem#{@suffix}"
    a = mgr.register('*/5 * * * *', klass)
    b = mgr.register('*/5 * * * *', klass)
    @lids << a.lid
    membership = Wurk.redis { |c| c.call('SISMEMBER', Wurk::Cron::PERIODIC_KEY, a.lid) }

    assert_equal a.lid, b.lid
    assert_equal 1, membership
  end

  def test_manager_tz_default_applies_to_subsequent_registers
    mgr = Wurk::Cron::Manager.new
    mgr.tz = 'America/Chicago'
    lp = mgr.register('0 4 * * *', "CronTest::TzDefault#{@suffix}")
    @lids << lp.lid

    assert_equal 'America/Chicago', lp.tz
  end

  def test_manager_per_call_tz_overrides_default
    mgr = Wurk::Cron::Manager.new
    mgr.tz = 'America/Chicago'
    lp = mgr.register('0 4 * * *', "CronTest::TzOverride#{@suffix}", tz: 'Asia/Tokyo')
    @lids << lp.lid

    assert_equal 'Asia/Tokyo', lp.tz
  end

  def test_register_accepts_constant_klass
    mgr = Wurk::Cron::Manager.new
    lp = mgr.register('* * * * *', CronTest::FooWorker)
    @lids << lp.lid

    assert_equal 'CronTest::FooWorker', lp.klass
  end

  # ---- Superseded-loop pruning ----------------------------------------

  def test_register_prunes_superseded_loop_for_same_class
    klass = "CronTest::Edited#{@suffix}"
    old = Wurk::Cron::Manager.new.register('0 4 * * *', klass)
    fresh = Wurk::Cron::Manager.new.register('0 5 * * *', klass)
    @lids << old.lid << fresh.lid
    lids = Wurk::Cron::LoopSet.new.map(&:lid)

    refute_includes lids, old.lid, 'the pre-edit loop must not keep firing'
    assert_includes lids, fresh.lid
  end

  def test_pruned_loop_hash_and_history_are_deleted
    klass = "CronTest::EditedKeys#{@suffix}"
    old = Wurk::Cron::Manager.new.register('0 4 * * *', klass)
    @lids << old.lid
    seed_history(old.lid)
    @lids << Wurk::Cron::Manager.new.register('0 5 * * *', klass).lid

    assert_empty loop_hash(old.lid)
    assert_empty history_entries(old.lid)
  end

  # The registry is fleet-wide: a process registering only part of it (or an
  # app that registers nothing at all) must not wipe another process's loops.
  def test_register_of_a_subset_leaves_other_classes_alone
    kept = Wurk::Cron::Manager.new.register('0 4 * * *', "CronTest::SubsetKept#{@suffix}")
    other = Wurk::Cron::Manager.new.register('0 6 * * *', "CronTest::SubsetOther#{@suffix}")
    @lids << kept.lid << other.lid
    lids = Wurk::Cron::LoopSet.new.map(&:lid)

    assert_includes lids, kept.lid
    assert_includes lids, other.lid
  end

  def test_manager_that_registers_nothing_prunes_nothing
    lp = Wurk::Cron::Manager.new.register('0 4 * * *', "CronTest::ClientOnly#{@suffix}")
    @lids << lp.lid

    Wurk::Cron::Manager.new # a client-only process: config.periodic never called

    assert_includes Wurk::Cron::LoopSet.new.map(&:lid), lp.lid
  end

  # Two schedules for one class in a single block: the second register must
  # survive the first one's prune (and re-registering the whole set is a no-op).
  def test_register_keeps_every_loop_declared_for_the_same_class
    klass = "CronTest::Twice#{@suffix}"
    first_boot = register_pair(klass)
    second_boot = register_pair(klass)
    @lids.concat(first_boot)

    assert_equal first_boot, second_boot, 'the same block must produce the same lids on every boot'
    assert_equal first_boot.sort, (Wurk::Cron::LoopSet.new.map(&:lid) & first_boot).sort
  end

  def test_config_tester_does_not_prune_live_loops
    live = Wurk::Cron::Manager.new.register('7 3 * * *', 'CronTest::PruneWorker')
    @lids << live.lid
    block = ->(mgr) { mgr.register('9 3 * * *', 'CronTest::PruneWorker') }
    @lids.concat(Wurk::Cron::ConfigTester.new.verify(&block).map(&:lid))

    assert_includes Wurk::Cron::LoopSet.new.map(&:lid), live.lid
  end

  # ---- Pause survives re-registration ---------------------------------

  def test_runtime_pause_survives_re_registration
    klass = "CronTest::Paused#{@suffix}"
    lp = Wurk::Cron::Manager.new.register('0 4 * * *', klass)
    @lids << lp.lid
    Wurk::Web::Enterprise::Periodic.pause(lp.lid)

    Wurk::Cron::Manager.new.register('0 4 * * *', klass)

    assert_equal '1', loop_hash(lp.lid)['paused']
    assert_predicate Wurk::Cron::LoopSet.new.fetch(lp.lid), :paused?
  end

  def test_runtime_unpause_survives_re_registration_of_a_paused_loop
    klass = "CronTest::Unpaused#{@suffix}"
    lp = Wurk::Cron::Manager.new.register('0 4 * * *', klass, paused: true)
    @lids << lp.lid
    Wurk::Web::Enterprise::Periodic.unpause(lp.lid)

    Wurk::Cron::Manager.new.register('0 4 * * *', klass, paused: true)

    assert_equal '0', loop_hash(lp.lid)['paused']
  end

  def test_paused_option_is_the_initial_state_at_first_registration
    lp = Wurk::Cron::Manager.new.register('0 4 * * *', "CronTest::BornPaused#{@suffix}", paused: true)
    @lids << lp.lid

    assert_equal '1', loop_hash(lp.lid)['paused']
  end

  def test_register_defaults_to_unpaused
    lp = Wurk::Cron::Manager.new.register('0 4 * * *', "CronTest::BornRunning#{@suffix}")
    @lids << lp.lid

    assert_equal '0', loop_hash(lp.lid)['paused']
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

  # A cron loop targeting an ActiveJob class must enqueue through the AJ wrapper
  # (perform_later → Sidekiq::ActiveJob::Wrapper), NOT as a bare worker — a raw
  # `client.push('class' => AJClass)` would make the processor call
  # `AJClass.new.perform` and skip all of ActiveJob. sidekiq-cron parity.
  def test_poller_enqueues_active_job_via_wrapper_when_leader
    queue = "cron-aj-#{@suffix}"
    klass = build_cron_active_job(queue)
    job = enqueue_via_leader_tick(klass: klass.name, queue: queue, args: [])

    assert_equal 'Sidekiq::ActiveJob::Wrapper', job['class'],
                 'ActiveJob cron target must enqueue through the AJ wrapper, not as a bare worker'
    assert_equal klass.name, job['wrapped']
  ensure
    Object.send(:remove_const, klass.name.to_sym) if klass.respond_to?(:name) && klass.name
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

  # ---- Fire-mark CAS ---------------------------------------------------
  #
  # `leader?` is a cached read, so two processes can both believe they lead
  # for seconds after a handover and both reach the same due loop. The CAS on
  # `nf` — not the leader gate — is what keeps a slot to a single fire.

  def test_racing_pollers_fire_a_due_slot_exactly_once
    queue = "cron-race-#{@suffix}"
    lp = register_loop("CronTest::Race#{@suffix}", queue: queue)
    pollers = Array.new(3) { build_leader_poller }
    rounds = 8
    claims = 0

    rounds.times do
      arm_due_mark(lp.lid)
      claims += race_enqueue(pollers, lp).compact.size
    end
    len = queue_len(queue)
    cleanup_queue(queue)

    assert_equal rounds, claims, 'exactly one racing poller may claim each due slot'
    assert_equal rounds, len, 'a claimed slot must enqueue exactly one job'
  end

  def test_enqueue_if_due_loses_the_slot_once_the_mark_moved
    queue = "cron-cas-#{@suffix}"
    lp = register_loop("CronTest::Cas#{@suffix}", queue: queue)
    poller = build_leader_poller
    arm_due_mark(lp.lid)

    first = poller.send(:enqueue_if_due, lp)
    arm_due_mark(lp.lid)
    poller.define_singleton_method(:claim_fire?) { |*| false }
    second = poller.send(:enqueue_if_due, lp)
    len = queue_len(queue)
    cleanup_queue(queue)

    refute_nil first
    assert_nil second, 'losing the CAS must return without enqueuing'
    assert_equal 1, len
  end

  # The exhausted-schedule case: the winner cleared `nf`, so a loser arriving
  # with the same slot sees no mark at all. `lf` is what tells it the slot is
  # already spent.
  def test_claim_fire_refuses_a_slot_already_covered_by_lf
    lp = register_loop("CronTest::Spent#{@suffix}", queue: "cron-sp-#{@suffix}")
    poller = Wurk::Cron::Poller.new(Wurk.configuration)
    slot = ::Time.now.to_i - 30
    seed_mark(lp.lid, 'lf', slot + 1)

    refute poller.send(:claim_fire?, lp, slot.to_s, ::Time.now.to_i, nil),
           'a slot the loop already fired must not be re-claimable after `nf` is cleared'
  end

  def test_claim_fire_bootstraps_an_unmarked_loop_then_rejects_the_replay
    lp = register_loop("CronTest::Boot#{@suffix}", queue: "cron-bt-#{@suffix}")
    poller = Wurk::Cron::Poller.new(Wurk.configuration)
    now = ::Time.now.to_i

    assert poller.send(:claim_fire?, lp, now.to_s, now, now + 60),
           'a loop with no marks yet must be claimable'
    refute poller.send(:claim_fire?, lp, now.to_s, now, now + 60),
           'the mark moved — a second claim on the same slot must lose'
  end

  def test_claim_fire_writes_marks_byte_identically_to_the_ruby_path
    lp = register_loop("CronTest::Bytes#{@suffix}", queue: "cron-by-#{@suffix}")
    poller = Wurk::Cron::Poller.new(Wurk.configuration)
    now = ::Time.now.to_i

    poller.send(:claim_fire?, lp, now.to_s, now, now + 60)

    assert_equal [now.to_s, (now + 60).to_s], marks(lp.lid), 'lf/nf stay decimal-epoch strings'
  end

  def test_claim_fire_clears_nf_when_there_is_no_future_occurrence
    lp = register_loop("CronTest::Last#{@suffix}", queue: "cron-la-#{@suffix}")
    poller = Wurk::Cron::Poller.new(Wurk.configuration)
    now = ::Time.now.to_i
    seed_mark(lp.lid, 'nf', now)

    poller.send(:claim_fire?, lp, now.to_s, now, nil)

    assert_nil marks(lp.lid)[1], 'a nil future must HDEL nf, never write ""'
  end

  # Ent periodic is best-effort about a miss, never about a duplicate: the mark
  # advances before the push, so a failed push drops this occurrence instead of
  # leaving the next tick to fire it a second time.
  def test_enqueue_if_due_advances_the_mark_before_the_push
    lp = register_loop("CronTest::Lost#{@suffix}", queue: "cron-lo-#{@suffix}")
    arm_due_mark(lp.lid)
    poller = poller_whose_push_fails(StringIO.new)

    assert_raises(IOError) { poller.send(:enqueue_if_due, lp) }
    assert_operator marks(lp.lid)[1].to_i, :>, ::Time.now.to_i,
                    'the mark must advance before the push, not after'
  end

  def test_enqueue_if_due_logs_the_occurrence_lost_to_a_failed_push
    io = StringIO.new
    lp = register_loop("CronTest::LostLog#{@suffix}", queue: "cron-ll-#{@suffix}")
    arm_due_mark(lp.lid)
    poller = poller_whose_push_fails(io)

    assert_raises(IOError) { poller.send(:enqueue_if_due, lp) }
    assert_match(/fire lost/, io.string)
  end

  # The manual `Cron.fire!` path deliberately bypasses the CAS: an operator
  # asking for a run contends with no schedule slot.
  def test_manual_fire_enqueues_with_the_next_mark_far_in_the_future
    queue = "cron-manual-#{@suffix}"
    lp = register_loop("CronTest::Manual#{@suffix}", queue: queue)
    seed_mark(lp.lid, 'nf', ::Time.now.to_i + 86_400)

    jid = Wurk::Cron::Poller.new(Wurk.configuration).fire(lp)
    cleanup_queue(queue)

    refute_nil jid, 'a manual fire must not be gated by the schedule'
    assert_operator marks(lp.lid)[0].to_i, :>, 0, 'a manual fire still advances lf'
  end

  def test_manual_fire_records_a_history_entry
    queue = "cron-manhist-#{@suffix}"
    lp = register_loop("CronTest::ManHist#{@suffix}", queue: queue)

    Wurk::Cron::Poller.new(Wurk.configuration).fire(lp)
    history = history_entries(lp.lid)
    cleanup_queue(queue)

    assert_equal 1, history.size
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
    one_am = fires.count { |f| lc = nyt.utc_to_local(Time.at(f).utc); lc.hour == 1 && lc.min.zero? }

    assert_equal 2, one_am, 'hourly 0 * * * * must fire in both fold 01:00 hours, not skip one'
  end

  def test_dst_fall_back_hourly_nonzero_minute_keeps_both_fold_hours
    # Guards the discriminator: "hourly" means the hour field is a wildcard, NOT
    # "minute == 0". 15 * * * * must also keep both repeated fall-back hours.
    nyt = tz('America/New_York')
    fires = simulate_fires('15 * * * *', nyt, Time.utc(2026, 11, 1, 4, 0), Time.utc(2026, 11, 1, 7, 0))
    one_fifteen = fires.count { |f| lc = nyt.utc_to_local(Time.at(f).utc); lc.hour == 1 && lc.min == 15 }

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
    assert_same Wurk::Cron, Sidekiq::Periodic
  end

  # #204: `Sidekiq::Cron` belongs to the third-party sidekiq-cron gem — real
  # Sidekiq never defines it. Wurk must leave the namespace free so the gem's
  # own classes (Poller, Job) can load against wurk without colliding.
  def test_sidekiq_cron_namespace_left_free_for_the_ecosystem_gem
    refute Sidekiq.const_defined?(:Cron, false),
           'Sidekiq::Cron must stay undefined — it is sidekiq-cron the gem, not Sidekiq surface'
  end

  def test_constants_match_spec_keys
    assert_equal 'periodic', Wurk::Cron::PERIODIC_KEY
    assert_equal 'loops:', Wurk::Cron::LOOP_PREFIX
  end

  # ---- Parser branch coverage: match_components? / match_day? ----------

  # 112 then: month field restricted and the candidate month does not match,
  # so match_components? short-circuits to false before reaching match_day?.
  def test_match_returns_false_when_month_does_not_match
    # Fires only in June; January wall-clock must not match.
    p = Wurk::Cron::Parser.new('0 0 1 6 *')

    refute p.match?(::Time.utc(2026, 1, 1, 0, 0, 0)), 'January must not match a June-only month field'
    assert p.match?(::Time.utc(2026, 6, 1, 0, 0, 0)), 'June 1 00:00 must match'
  end

  # 123 then: both dom AND dow restricted → the "Friday the 13th" OR rule. The
  # slot matches when EITHER the day-of-month OR the day-of-week matches.
  def test_match_day_ors_dom_and_dow_when_both_restricted
    # day-of-month 13 OR Friday(5). 2026-02-13 is a Friday (both true);
    # 2026-03-13 is a Friday (dow true, dom true again) — use distinct dates.
    p = Wurk::Cron::Parser.new('0 0 13 * 5')

    # 2026-11-13 is a Friday → both halves true.
    assert p.match?(::Time.utc(2026, 11, 13, 0, 0, 0)), 'the 13th that is also Friday matches'
    # 2026-11-06 is a Friday but not the 13th → dow true, dom false → OR matches.
    assert p.match?(::Time.utc(2026, 11, 6, 0, 0, 0)), 'a Friday that is not the 13th still matches via OR'
    # 2026-11-13 covered; pick a 13th that is NOT Friday: 2026-01-13 is a Tuesday.
    assert p.match?(::Time.utc(2026, 1, 13, 0, 0, 0)), 'the 13th that is not Friday still matches via OR'
    # Neither the 13th nor a Friday → no match.
    refute p.match?(::Time.utc(2026, 1, 14, 0, 0, 0)), 'non-13th non-Friday must not match'
  end

  # 124 then: only dom restricted (dow wild) → dom must match.
  def test_match_day_uses_dom_only_when_dow_wild
    p = Wurk::Cron::Parser.new('0 0 15 * *')

    assert p.match?(::Time.utc(2026, 1, 15, 0, 0, 0)), 'the 15th matches a dom-only schedule'
    refute p.match?(::Time.utc(2026, 1, 16, 0, 0, 0)), 'the 16th must not match a dom-15 schedule'
  end

  # ---- Parser branch coverage: local_time tz dispatch ------------------

  # A minimal AS::TimeZone-like double: responds to #at (not a String), so
  # local_time takes the 198-then `tz.at(epoch)` branch.
  class AtTZ
    def initialize(offset_hours) = @offset = offset_hours * 3600
    def at(epoch) = ::Time.at(epoch + @offset).utc
  end

  # An object that responds to #identifier but NOT #name and NOT #at, so
  # tz_name takes the 319-then `identifier` branch and local_time takes the
  # 199 `utc_to_local` branch.
  class IdentifierTZ
    def initialize(name) = @name = name
    def identifier = @name
    def utc_to_local(time) = time
  end

  # 198 then: tz responds to #at → local_time returns tz.at(epoch).
  def test_local_time_uses_at_for_as_timezone_like
    p = Wurk::Cron::Parser.new('* * * * *')
    # AtTZ(+1h): 00:30 UTC becomes local 01:30 → matches an "01:30" slot.
    p_slot = Wurk::Cron::Parser.new('30 1 * * *')

    assert p.match?(::Time.utc(2026, 1, 1, 0, 30, 0), AtTZ.new(1))
    assert p_slot.match?(::Time.utc(2026, 1, 1, 0, 30, 0), AtTZ.new(1)),
           '00:30 UTC shifted +1h must match local 01:30'
  end

  # 199 (utc_to_local path) + then via TZInfo, exercised through match?.
  def test_local_time_uses_utc_to_local_for_tzinfo
    p = Wurk::Cron::Parser.new('30 1 * * *')
    # America/New_York is UTC-5 in January → 06:30 UTC == 01:30 EST.
    assert p.match?(::Time.utc(2026, 1, 1, 6, 30, 0), tz('America/New_York'))
  end

  # 199 else: tz is a String → neither #at (it IS a String) nor #utc_to_local,
  # so local_time resolves it through TZInfo (#210 replaced the old ENV['TZ']
  # tzset(3) override, which was process-global and thread-unsafe). A String
  # must now produce the exact same wall clock as the equivalent TZInfo object.
  def test_local_time_string_tz_resolves_via_tzinfo
    p = Wurk::Cron::Parser.new('* * * * *')
    epoch = ::Time.utc(2026, 1, 1, 6, 30, 0).to_i

    assert_equal p.local_components(epoch, tz('America/New_York')),
                 p.local_components(epoch, 'America/New_York'),
                 'String tz must resolve to the same wall clock as the TZInfo object'
  end

  def test_string_tz_matches_dst_local_time
    # America/New_York is UTC-4 in July (EDT): 05:30 UTC == 01:30 local.
    p = Wurk::Cron::Parser.new('30 1 * * *')

    assert p.match?(::Time.utc(2026, 7, 1, 5, 30, 0), 'America/New_York')
    refute p.match?(::Time.utc(2026, 7, 1, 6, 30, 0), 'America/New_York'),
           'EST offset must not match during EDT — String tz must be DST-aware'
  end

  # #210 regression: evaluating a String tz must never write ENV['TZ'] — ENV
  # is process-global, so any write leaks the loop's zone into every other
  # thread. A sampling watcher thread is a probabilistic tripwire (the old
  # set/restore window was microseconds wide), so instead intercept ENV.[]=
  # itself for the duration of a minute-walk: deterministic both ways. The
  # walk crosses a leap-day boundary (~40k minutes), which flapped ENV ~80k
  # times under the old tzset(3) path.
  def test_string_tz_evaluation_never_writes_env_tz
    before = ENV.fetch('TZ', :unset)
    writes = []
    original = ENV.method(:[]=)
    ENV.singleton_class.send(:define_method, :[]=) do |k, v|
      writes << k
      original.call(k, v)
    end
    begin
      Wurk::Cron::Parser.new('0 12 29 2 *').next_fire_at(::Time.utc(2028, 2, 1).to_i, 'Pacific/Auckland')
    ensure
      ENV.singleton_class.send(:define_method, :[]=, original)
    end

    refute_includes writes, 'TZ', 'cron tz evaluation must never write the process-global ENV[TZ]'
    assert_equal before, ENV.fetch('TZ', :unset), 'ENV[TZ] must be untouched after evaluation'
  end

  def test_unknown_string_tz_falls_back_to_utc_with_warning
    p = Wurk::Cron::Parser.new('* * * * *')
    epoch = ::Time.utc(2026, 1, 1, 6, 30, 0).to_i

    assert_equal p.local_components(epoch, nil),
                 p.local_components(epoch, 'Not/AZone'),
                 'unresolvable tz must degrade to UTC, not raise'
  end

  def test_resolve_zone_caches_per_name
    assert_same Wurk::Cron::Parser.resolve_zone('Asia/Tokyo'),
                Wurk::Cron::Parser.resolve_zone('Asia/Tokyo')
  end

  # ---- Loop#last_fired_at branch coverage ------------------------------

  # 268 else: history head IS an Array but element 0 is non-Numeric → nil.
  def test_last_fired_at_nil_when_tuple_head_not_numeric
    lp = register_loop("CronTest::LastNonNum#{@suffix}", queue: "cron-lnn-#{@suffix}")
    Wurk.redis { |c| c.call('LPUSH', "#{Wurk::Cron::HISTORY_PREFIX}#{lp.lid}", JSON.dump(['not-a-number', 'jid-x'])) }

    assert_nil lp.last_fired_at, 'a non-Numeric timestamp in the tuple head must read as nil'
  ensure
    Wurk.redis { |c| c.call('DEL', "#{Wurk::Cron::HISTORY_PREFIX}#{lp.lid}") }
  end

  # ---- Loop#tz_name branch coverage ------------------------------------

  # 318 then: tz responds to #name (TZInfo::Timezone) → tz_name returns #name,
  # observed through the persisted 'tz' hash field.
  def test_tz_name_uses_name_for_tzinfo
    lp = Wurk::Cron::Loop.new(schedule: '* * * * *', klass: 'CronTest::FooWorker', tz: tz('Asia/Tokyo'))

    assert_equal 'Asia/Tokyo', lp.to_redis_hash['tz']
  end

  # 319 then: tz responds to #identifier but NOT #name → identifier branch.
  def test_tz_name_uses_identifier_when_no_name
    lp = Wurk::Cron::Loop.new(schedule: '* * * * *', klass: 'CronTest::FooWorker', tz: IdentifierTZ.new('Etc/UTC'))

    assert_equal 'Etc/UTC', lp.to_redis_hash['tz']
  end

  # ---- Loop.from_redis branch coverage ---------------------------------

  # 325 then: from_redis receives an Array (RESP2 HGETALL shape) → pairs it up.
  # 328 else: 'tz' is non-empty → preserved (not coerced to nil).
  def test_from_redis_array_shape_with_tz
    arr = ['schedule', '0 4 * * *', 'klass', 'CronTest::FooWorker', 'options', '{}', 'tz', 'Asia/Tokyo', 'paused', '0']
    lp = Wurk::Cron::Loop.from_redis('deadbeefcafef00d', arr)

    assert_equal '0 4 * * *', lp.schedule
    assert_equal 'Asia/Tokyo', lp.tz
  end

  # 326 else: no 'options' field present → opts defaults to {}.
  def test_from_redis_defaults_options_to_empty_hash
    lp = Wurk::Cron::Loop.from_redis('feedface00000000',
                                     { 'schedule' => '0 4 * * *', 'klass' => 'CronTest::FooWorker' })

    assert_equal 'default', lp.queue, 'absent options hash must yield the default queue'
    assert_empty lp.args
  end

  # ---- LoopSet branch coverage -----------------------------------------

  # 377 then: each called without a block returns an Enumerator.
  def test_loop_set_each_without_block_returns_enumerator
    assert_kind_of Enumerator, Wurk::Cron::LoopSet.new.each
  end

  # 383 then: a lid is in the periodic SET but its loops:{lid} HASH is gone
  # (empty) → each skips it instead of yielding a half-built Loop.
  def test_loop_set_each_skips_lid_with_missing_hash
    orphan = "orphan#{@suffix}deadbeef"[0, 16]
    Wurk.redis { |c| c.call('SADD', Wurk::Cron::PERIODIC_KEY, orphan) }

    lids = Wurk::Cron::LoopSet.new.to_a.map(&:lid)

    refute_includes lids, orphan, 'a SET member with no backing hash must be skipped'
  ensure
    Wurk.redis { |c| c.call('SREM', Wurk::Cron::PERIODIC_KEY, orphan) }
  end

  # NOTE: LoopSet#fetch lines 398/399 (`h.is_a?(Array)` → each_slice / empty
  # re-check) are unreachable here: this pool speaks RESP3, so HGETALL always
  # returns a Hash, never an Array. Exercising them would require mocking Redis,
  # which the integration/parity rules forbid. The equivalent Array shape IS
  # covered for Loop.from_redis (test_from_redis_array_shape_with_tz), which
  # accepts a raw Array directly.

  # ---- Poller branch coverage ------------------------------------------

  # start spawns the tick thread; with a tiny tick interval and a non-leader
  # gate the loop body runs at least once. terminate joins, so the thread is
  # already dead by the time it returns — no post-hoc join needed.
  def test_poller_start_runs_tick_loop_then_terminates
    cfg = Wurk::Configuration.new
    cfg[:cron_tick_interval] = 0.01
    poller = Wurk::Cron::Poller.new(cfg)
    ticks = Queue.new
    poller.define_singleton_method(:leader?) { false }
    poller.define_singleton_method(:tick) { ticks << :t }

    thread = poller.start
    first = ticks.pop(timeout: 5) # waits until the loop body executes tick at least once

    poller.terminate

    refute_predicate thread, :alive?, 'terminate must join the poller thread'
    assert_nil poller.instance_variable_get(:@thread)
    assert_equal :t, first
  end

  # A cleared @thread would be pointless if the timer stayed terminated —
  # start has to re-arm it, not spawn a thread that exits immediately.
  def test_poller_start_after_terminate_ticks_again
    cfg = Wurk::Configuration.new
    cfg[:cron_tick_interval] = 0.01
    poller = Wurk::Cron::Poller.new(cfg)
    ticks = Queue.new
    poller.define_singleton_method(:leader?) { false }
    poller.define_singleton_method(:tick) { ticks << :t }

    poller.start
    ticks.pop(timeout: 5)
    poller.terminate
    poller.start

    assert_equal :t, ticks.pop(timeout: 5), 'start after terminate must resume ticking'
  ensure
    poller&.terminate
  end

  # The flip side of re-arming: a tick wedged past JOIN_TIMEOUT (Thread#join
  # returns nil) must keep @thread set, so the next #start returns it instead
  # of resetting the shared timer under it and double-enqueuing every loop.
  def test_poller_terminate_keeps_a_thread_that_outlives_the_join
    cfg = Wurk::Configuration.new
    cfg[:cron_tick_interval] = 0.01
    poller = Wurk::Cron::Poller.new(cfg)
    poller.define_singleton_method(:leader?) { false }

    thread = poller.start
    thread.define_singleton_method(:join) { |_timeout = nil| nil }
    poller.terminate

    assert_same thread, poller.instance_variable_get(:@thread), 'a wedged thread must stay tracked'
    assert_same thread, poller.start, 'start must not spawn a second thread alongside it'
  ensure
    poller&.instance_variable_set(:@thread, nil)
    thread&.kill
  end

  # 497 then: a loop whose next fire is in the future → enqueue_if_due returns
  # early without enqueuing. We register a daily-4am loop and pre-seed its 'nf'
  # mark far in the future, then a leader tick must enqueue nothing.
  def test_enqueue_if_due_skips_when_next_fire_in_future
    mgr = Wurk::Cron::Manager.new
    queue = "cron-future-#{@suffix}"
    lp = mgr.register('0 4 * * *', "CronTest::Future#{@suffix}", queue: queue)
    @lids << lp.lid
    future = ::Time.now.to_i + 86_400
    Wurk.redis { |c| c.call('HSET', "#{Wurk::Cron::LOOP_PREFIX}#{lp.lid}", 'nf', future.to_s) }

    build_leader_poller.tick
    len = Wurk.redis { |c| c.call('LLEN', "queue:#{queue}") }
    cleanup_queue(queue)

    assert_equal 0, len, 'a loop whose next fire is in the future must not enqueue'
  end

  # 526 else: drift beyond MISSED_TICK_THRESHOLD → warn_missed_tick logs. We
  # capture the logger output and assert the missed-tick warning is emitted.
  def test_warn_missed_tick_logs_when_drift_exceeds_threshold
    cfg = Wurk::Configuration.new
    io = StringIO.new
    cfg.logger = Logger.new(io)
    poller = Wurk::Cron::Poller.new(cfg)
    lp = Wurk::Cron::Loop.new(schedule: '0 4 * * *', klass: 'CronTest::Missed')
    now = ::Time.now.to_i
    expected = now - (Wurk::Cron::MISSED_TICK_THRESHOLD + 60)

    poller.send(:warn_missed_tick, lp, expected, now)

    assert_match(/missed tick/, io.string)
  end

  def test_warn_missed_tick_silent_within_threshold
    cfg = Wurk::Configuration.new
    io = StringIO.new
    cfg.logger = Logger.new(io)
    poller = Wurk::Cron::Poller.new(cfg)
    lp = Wurk::Cron::Loop.new(schedule: '0 4 * * *', klass: 'CronTest::OnTime')
    now = ::Time.now.to_i

    poller.send(:warn_missed_tick, lp, now, now)

    refute_match(/missed tick/, io.string)
  end

  # 548 else: 'nf' is present and non-empty → read_fire_marks returns its
  # integer value, not nil.
  def test_read_fire_marks_returns_nf_when_present
    lp = register_loop("CronTest::Marks#{@suffix}", queue: "cron-mk-#{@suffix}")
    Wurk.redis do |c|
      c.call('HSET', "#{Wurk::Cron::LOOP_PREFIX}#{lp.lid}", 'lf', '111', 'nf', '222')
    end
    poller = Wurk::Cron::Poller.new(Wurk.configuration)

    prev_fire, next_fire = poller.send(:read_fire_marks, lp.lid)

    assert_equal 111, prev_fire
    assert_equal 222, next_fire
  end

  # ---- Module-level register / lid branch coverage ---------------------

  # 572 else: options is not a Hash → lid coerces to {} before hashing.
  def test_lid_coerces_non_hash_options
    a = Wurk::Cron.lid('* * * * *', 'A', nil)
    b = Wurk::Cron.lid('* * * * *', 'A', {})

    assert_equal b, a, 'a non-Hash options arg must hash identically to an empty Hash'
    assert_equal 16, a.length
  end

  # 582 else: name is nil → no :label key merged into options.
  def test_module_register_without_name_omits_label
    lp = Wurk::Cron.register(nil, '0 4 * * *', 'CronTest::BarWorker', [1])
    @lids << lp.lid

    refute_includes lp.options.keys, 'label', 'a nil name must not add a label option'
    assert_equal [1], lp.args
  end

  # --- public Sidekiq::CronParser surface (#201) ------------------------

  def test_sidekiq_cron_parser_aliases_the_in_tree_parser
    assert_same Wurk::Cron::Parser, Sidekiq::CronParser
  end

  def test_cron_parser_next_returns_the_next_fire_time
    nxt = Sidekiq::CronParser.new('0 4 * * *').next(Time.utc(2026, 6, 10, 1, 0, 0))

    assert_equal Time.utc(2026, 6, 10, 4, 0, 0), nxt.utc
  end

  def test_cron_parser_next_honors_aliases
    nxt = Sidekiq::CronParser.new('@daily').next(Time.utc(2026, 6, 10, 1, 0, 0))

    assert_equal Time.utc(2026, 6, 11, 0, 0, 0), nxt.utc
  end

  # 0 9 * * * in Asia/Tokyo (UTC+9) = 09:00 JST = 00:00 UTC; the 06-10 instant
  # (00:00 UTC) is before `from` (01:00 UTC), so the next is 06-11 00:00 UTC.
  def test_cron_parser_next_is_timezone_aware
    nxt = Sidekiq::CronParser.new('0 9 * * *').next(Time.utc(2026, 6, 10, 1, 0, 0), tz('Asia/Tokyo'))

    assert_equal Time.utc(2026, 6, 11, 0, 0, 0), nxt.utc
  end

  def test_cron_parser_next_defaults_to_now_and_returns_a_future_time
    nxt = Sidekiq::CronParser.new('* * * * *').next

    assert_operator nxt, :>, Time.now - 1
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

  # Registration now prunes superseded loops for the class it registers, so a
  # test must own its class name or it deletes a concurrent test's loop.
  def register_for_persist_test
    mgr = Wurk::Cron::Manager.new
    lp = mgr.register('*/5 * * * *', persist_klass, queue: 'low')
    @lids << lp.lid
    lp
  end

  def persist_klass
    "CronTest::Persist#{@suffix}"
  end

  def register_pair(klass)
    mgr = Wurk::Cron::Manager.new
    [mgr.register('0 4 * * *', klass).lid, mgr.register('0 16 * * *', klass).lid]
  end

  def seed_history(lid)
    Wurk.redis { |c| c.call('LPUSH', "#{Wurk::Cron::HISTORY_PREFIX}#{lid}", '[1,"jid"]') }
  end

  def history_entries(lid)
    Wurk.redis { |c| c.call('LRANGE', "#{Wurk::Cron::HISTORY_PREFIX}#{lid}", 0, -1) }
  end

  def loop_hash(lid)
    h = Wurk.redis { |c| c.call('HGETALL', "#{Wurk::Cron::LOOP_PREFIX}#{lid}") }
    h.is_a?(Array) ? h.each_slice(2).to_h : h
  end

  def loop_key(lid)
    "#{Wurk::Cron::LOOP_PREFIX}#{lid}"
  end

  def seed_mark(lid, field, value)
    Wurk.redis { |c| c.call('HSET', loop_key(lid), field, value.to_s) }
  end

  def marks(lid)
    Wurk.redis { |c| c.call('HMGET', loop_key(lid), 'lf', 'nf') }
  end

  # An `nf` one second in the past makes the loop due right now whatever its
  # schedule, so a tick has to go through the CAS to fire it.
  def arm_due_mark(lid)
    seed_mark(lid, 'nf', ::Time.now.to_i - 1)
  end

  def queue_len(queue)
    Wurk.redis { |c| c.call('LLEN', "queue:#{queue}") }
  end

  # Poller on a throwaway Configuration — it inherits the worker's REDIS_URL,
  # so it still reads and writes this test's DB — logging to `io`, whose push
  # always fails.
  def poller_whose_push_fails(io)
    cfg = Wurk::Configuration.new
    cfg.logger = Logger.new(io)
    @configs << cfg
    poller = Wurk::Cron::Poller.new(cfg)
    poller.define_singleton_method(:enqueue!) { |_| raise IOError, 'redis down' }
    poller
  end

  # Releases every poller onto the same loop at once — a barrier, so the CAS
  # is what separates them rather than thread start-up skew.
  def race_enqueue(pollers, loop_obj)
    gate = Queue.new
    threads = pollers.map do |p|
      Thread.new do
        gate.pop
        p.send(:enqueue_if_due, loop_obj)
      end
    end
    pollers.size.times { gate << :go }
    threads.map(&:value)
  end

  def build_leader_poller
    poller = Wurk::Cron::Poller.new(Wurk.configuration)
    # Pretend this process holds the cluster lock.
    poller.define_singleton_method(:leader?) { true }
    poller
  end

  # Named ActiveJob subclass wired to the wurk adapter. AJ serialization needs
  # a real (non-anonymous) constant, so const_set a unique name; the test's
  # ensure-block removes it.
  def build_cron_active_job(queue)
    klass = Class.new(::ActiveJob::Base) do
      def perform(*); end
    end
    klass.queue_as(queue)
    klass.queue_adapter = :wurk
    name = "CronAJ_#{Process.pid}_#{object_id}_#{rand(1 << 32)}"
    Object.const_set(name, klass)
    klass
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
