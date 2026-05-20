# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# DeadSet-specific behaviors: trim (two-axis), kill (notify_failure default,
# death-handler firing). Generic JobSet behaviors covered in job_set_test.rb.
class DeadSetTest < Wurk::Test::UnitCase
  def setup
    super
    @ns      = "#{Process.pid}-#{object_id}"
    @pool    = Wurk.configuration.redis_pool
    @members = []
    @saved_handlers = Wurk.configuration.death_handlers.dup
    @saved_max = Wurk.configuration[:dead_max_jobs]
    @saved_timeout = Wurk.configuration[:dead_timeout_in_seconds]
  end

  def teardown
    @pool.with do |c|
      @members.each { |m| c.call('ZREM', 'dead', m) }
    end
    Wurk.configuration.death_handlers.replace(@saved_handlers)
    Wurk.configuration[:dead_max_jobs] = @saved_max
    Wurk.configuration[:dead_timeout_in_seconds] = @saved_timeout
  ensure
    super
  end

  # --- name --------------------------------------------------------------

  def test_name_is_dead
    assert_equal 'dead', Wurk::DeadSet.new.name
  end

  # --- kill --------------------------------------------------------------

  def test_kill_zadds_payload_with_current_score
    payload = Wurk.dump_json(base_item)
    before = ::Process.clock_gettime(::Process::CLOCK_REALTIME)

    Wurk::DeadSet.new.kill(payload, notify_failure: false)
    @members << payload

    score = @pool.with { |c| c.call('ZSCORE', 'dead', payload) }

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

    Wurk::DeadSet.new.kill(payload, notify_failure: false)
    @members << payload

    assert_empty received
  end

  def test_kill_uses_provided_exception
    received_ex = nil
    Wurk.configuration.death_handlers << ->(_job, ex) { received_ex = ex }
    custom = ArgumentError.new('boom')
    payload = Wurk.dump_json(base_item)

    Wurk::DeadSet.new.kill(payload, notify_failure: true, ex: custom)
    @members << payload

    assert_same custom, received_ex
  end

  def test_kill_swallows_death_handler_errors
    Wurk.configuration.death_handlers << ->(_job, _ex) { raise 'handler boom' }
    payload = Wurk.dump_json(base_item)

    Wurk::DeadSet.new.kill(payload, notify_failure: true)
    @members << payload

    refute_nil(@pool.with { |c| c.call('ZSCORE', 'dead', payload) })
  end

  # --- trim --------------------------------------------------------------

  def test_trim_caps_to_dead_max_jobs
    configure_limits(max: 2, timeout: 60_000)
    payloads = seed_dead((0...5).map { |i| [i.to_f, "tm-#{@ns}-#{i}"] })
    Wurk::DeadSet.new.trim
    survivors = payloads.count { |p| @pool.with { |c| c.call('ZSCORE', 'dead', p) } }

    assert_operator survivors, :<=, 2
  end

  def test_trim_evicts_expired_by_score
    configure_limits(max: 1_000_000, timeout: 60)
    now = ::Process.clock_gettime(::Process::CLOCK_REALTIME)
    expired, fresh = seed_dead([[now - 600, "ex-#{@ns}"], [now, "fr-#{@ns}"]])
    Wurk::DeadSet.new.trim

    assert_nil(@pool.with { |c| c.call('ZSCORE', 'dead', expired) })
    refute_nil(@pool.with { |c| c.call('ZSCORE', 'dead', fresh) })
  end

  def test_kill_with_trim_false_skips_trim
    configure_limits(max: 1, timeout: 60_000)
    payload1 = kill_payload(base_item('jid' => "nt1-#{@ns}"), notify_failure: false, trim: false)
    payload2 = kill_payload(base_item('jid' => "nt2-#{@ns}"), notify_failure: false, trim: false)

    refute_nil(@pool.with { |c| c.call('ZSCORE', 'dead', payload1) })
    refute_nil(@pool.with { |c| c.call('ZSCORE', 'dead', payload2) })
  end

  private

  def configure_limits(max:, timeout:)
    Wurk.configuration[:dead_max_jobs] = max
    Wurk.configuration[:dead_timeout_in_seconds] = timeout
  end

  def seed_dead(rows)
    rows.map do |score, jid|
      payload = Wurk.dump_json(base_item('jid' => jid))
      @pool.with { |c| c.call('ZADD', 'dead', score, payload) }
      @members << payload
      payload
    end
  end

  def kill_payload(item, **opts)
    payload = Wurk.dump_json(item)
    notify = opts.fetch(:notify_failure, true)
    if opts.key?(:trim)
      Wurk::DeadSet.new.kill(payload, notify_failure: notify, trim: opts[:trim])
    else
      Wurk::DeadSet.new.kill(payload, notify_failure: notify)
    end
    @members << payload
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
