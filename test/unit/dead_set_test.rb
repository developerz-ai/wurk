# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# DeadSet-specific behaviors: trim (two-axis), kill (notify_failure default,
# death-handler firing). Generic JobSet behaviors covered in job_set_test.rb.
#
# Parallel safety: every test operates on a per-instance ZSET named
# "dead-<pid>-<object_id>" instead of the global `dead` key. Trim limits ride
# in via kwargs so we don't have to mutate `Wurk.configuration` (which is
# process-global and races across threads).
class DeadSetTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns      = "#{Process.pid}-#{object_id}"
    @dead    = "dead-#{@ns}"
    @pool    = Wurk.configuration.redis_pool
    @saved_handlers = Wurk.configuration.death_handlers.dup
  end

  def teardown
    @pool.with { |c| c.call('UNLINK', @dead) }
    Wurk.configuration.death_handlers.replace(@saved_handlers)
  ensure
    super
  end

  # --- name --------------------------------------------------------------

  def test_default_name_is_dead
    assert_equal 'dead', Wurk::DeadSet.new.name
  end

  def test_accepts_custom_name
    assert_equal @dead, Wurk::DeadSet.new(@dead).name
  end

  # --- kill --------------------------------------------------------------

  def test_kill_zadds_payload_with_current_score
    payload = Wurk.dump_json(base_item)
    before = ::Process.clock_gettime(::Process::CLOCK_REALTIME)

    dead_set.kill(payload, notify_failure: false)

    score = @pool.with { |c| c.call('ZSCORE', @dead, payload) }

    refute_nil score
    assert_operator score.to_f, :>=, before
  end

  def test_kill_fires_death_handlers_when_notify
    received = []
    Wurk.configuration.death_handlers << ->(job, ex) { received << [job['jid'], ex] }
    jid = "dh-#{@ns}"
    kill_payload(base_item('jid' => jid))

    assert_equal 1, received.size
    assert_equal jid, received.first.first
    assert_kind_of RuntimeError, received.first.last
  end

  def test_kill_skips_death_handlers_when_notify_false
    received = []
    Wurk.configuration.death_handlers << ->(_job, _ex) { received << :called }
    payload = Wurk.dump_json(base_item)

    dead_set.kill(payload, notify_failure: false)

    assert_empty received
  end

  def test_kill_uses_provided_exception
    received_ex = nil
    Wurk.configuration.death_handlers << ->(_job, ex) { received_ex = ex }
    custom = ArgumentError.new('boom')
    payload = Wurk.dump_json(base_item)

    dead_set.kill(payload, notify_failure: true, ex: custom)

    assert_same custom, received_ex
  end

  def test_kill_swallows_death_handler_errors
    Wurk.configuration.death_handlers << ->(_job, _ex) { raise 'handler boom' }
    payload = Wurk.dump_json(base_item)

    dead_set.kill(payload, notify_failure: true)

    refute_nil(@pool.with { |c| c.call('ZSCORE', @dead, payload) })
  end

  # --- trim --------------------------------------------------------------

  def test_trim_caps_to_dead_max_jobs
    payloads = seed_dead((0...5).map { |i| [i.to_f, "tm-#{@ns}-#{i}"] })
    dead_set.trim(max_jobs: 2, timeout: 60_000)
    survivors = payloads.count { |p| @pool.with { |c| c.call('ZSCORE', @dead, p) } }

    assert_operator survivors, :<=, 2
  end

  def test_trim_evicts_expired_by_score
    now = ::Process.clock_gettime(::Process::CLOCK_REALTIME)
    expired, fresh = seed_dead([[now - 600, "ex-#{@ns}"], [now, "fr-#{@ns}"]])
    dead_set.trim(max_jobs: 1_000_000, timeout: 60)

    assert_nil(@pool.with { |c| c.call('ZSCORE', @dead, expired) })
    refute_nil(@pool.with { |c| c.call('ZSCORE', @dead, fresh) })
  end

  def test_kill_with_trim_false_skips_trim # rubocop:disable Metrics/AbcSize
    # Seed enough entries that max_jobs:1 would normally trim everything.
    seed_dead((0...5).map { |i| [i.to_f, "skip-seed-#{@ns}-#{i}"] })
    skip_opts = { notify_failure: false, trim: false, max_jobs: 1, timeout: 60_000 }
    payload1 = kill_payload(base_item('jid' => "nt1-#{@ns}"), **skip_opts)
    payload2 = kill_payload(base_item('jid' => "nt2-#{@ns}"), **skip_opts)

    refute_nil(@pool.with { |c| c.call('ZSCORE', @dead, payload1) })
    refute_nil(@pool.with { |c| c.call('ZSCORE', @dead, payload2) })
    # The seeded entries should also survive — trim was skipped.
    assert_operator @pool.with { |c| c.call('ZCARD', @dead) }, :>=, 7
  end

  private

  def dead_set
    Wurk::DeadSet.new(@dead)
  end

  def seed_dead(rows)
    rows.map do |score, jid|
      payload = Wurk.dump_json(base_item('jid' => jid))
      @pool.with { |c| c.call('ZADD', @dead, score, payload) }
      payload
    end
  end

  def kill_payload(item, **opts)
    payload = Wurk.dump_json(item)
    dead_set.kill(payload, opts)
    payload
  end

  def base_item(extra = {})
    {
      'class' => 'DeadSetTestJob',
      'args' => [],
      'queue' => 'default',
      'jid' => SecureRandom.hex(12),
      'created_at' => Time.now.to_f
    }.merge(extra)
  end
end
