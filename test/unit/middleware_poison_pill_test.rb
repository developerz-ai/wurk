# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Pins Wurk::Middleware::PoisonPill:
#   * INCR + EXPIRE 72h at `super_fetch:recovered:<jid>` per orphan
#   * <3 → return :recovered, emit `jobs.recovered.fetch`
#   * ≥3 → kill into dead set, emit `jobs.poison`, fire callbacks
#
# Spec: docs/target/sidekiq-pro.md §3.2.
class MiddlewarePoisonPillTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns       = "#{Process.pid}-#{object_id}"
    @jid      = SecureRandom.hex(12)
    @queue    = "ppq-#{@ns}"
    @pool     = Wurk.configuration.redis_pool
    @key      = "super_fetch:recovered:#{@jid}"
    @stub_increments = []
    Wurk::Middleware::PoisonPill.reset!
    clean
  end

  def teardown
    Wurk::Middleware::PoisonPill.reset!
    clean
  ensure
    super
  end

  # --- counter lifecycle -------------------------------------------------

  def test_first_recovery_increments_to_one
    result = Wurk::Middleware::PoisonPill.track!(payload_json, queue: @queue)

    assert_equal :recovered, result
    assert_equal 1, Wurk::Middleware::PoisonPill.recovery_count(@jid)
  end

  def test_counter_expires_at_72_hours
    Wurk::Middleware::PoisonPill.track!(payload_json, queue: @queue)
    ttl = @pool.with { |c| c.call('TTL', @key) }.to_i

    assert_operator ttl, :<=, Wurk::Middleware::PoisonPill::RECOVERY_TTL
    assert_operator ttl, :>=, Wurk::Middleware::PoisonPill::RECOVERY_TTL - 5
  end

  def test_second_recovery_does_not_yet_poison
    2.times { Wurk::Middleware::PoisonPill.track!(payload_json, queue: @queue) }

    assert_equal 2, Wurk::Middleware::PoisonPill.recovery_count(@jid)
    # jid-scoped: a global ZCARD races other parallel tests / stray dead jobs.
    assert_equal 0, dead_for_jid_count, 'a job below the poison threshold must not be in the dead set'
  end

  def test_third_recovery_returns_poison_and_writes_to_dead
    json = payload_json
    2.times { Wurk::Middleware::PoisonPill.track!(json, queue: @queue) }
    result = Wurk::Middleware::PoisonPill.track!(json, queue: @queue)

    assert_equal :poison, result
    assert_equal 1, dead_for_jid_count
  end

  def test_clear_resets_counter
    Wurk::Middleware::PoisonPill.track!(payload_json, queue: @queue)
    Wurk::Middleware::PoisonPill.clear!(@jid)

    assert_equal 0, Wurk::Middleware::PoisonPill.recovery_count(@jid)
  end

  def test_recovery_count_returns_zero_for_unknown_jid
    assert_equal 0, Wurk::Middleware::PoisonPill.recovery_count(SecureRandom.hex(12))
  end

  def test_recovery_count_handles_empty_input
    assert_equal 0, Wurk::Middleware::PoisonPill.recovery_count(nil)
    assert_equal 0, Wurk::Middleware::PoisonPill.recovery_count('')
  end

  # --- malformed payload --------------------------------------------------

  def test_unparseable_payload_returns_recovered_without_state
    assert_equal :recovered, Wurk::Middleware::PoisonPill.track!('not-json{{')
  end

  def test_payload_without_jid_skips_counter
    json = Wurk.dump_json('class' => 'X', 'args' => [])

    assert_equal :recovered, Wurk::Middleware::PoisonPill.track!(json, queue: @queue)
  end

  def test_accepts_pre_parsed_hash
    Wurk::Middleware::PoisonPill.track!({ 'jid' => @jid, 'class' => 'X' }, queue: @queue)

    assert_equal 1, Wurk::Middleware::PoisonPill.recovery_count(@jid)
  end

  # --- statsd integration -------------------------------------------------

  def test_emits_jobs_recovered_fetch_on_normal_recovery
    metrics = with_statsd_recorder do
      Wurk::Middleware::PoisonPill.track!(payload_json, queue: @queue)
    end

    assert_equal [['jobs.recovered.fetch', ['class:PoisonPillTestJob', "queue:#{@queue}"]]], metrics
  end

  def test_emits_jobs_poison_on_threshold_crossing
    json = payload_json
    metrics = with_statsd_recorder do
      3.times { Wurk::Middleware::PoisonPill.track!(json, queue: @queue) }
    end

    poison = metrics.select { |m| m[0] == 'jobs.poison' }

    assert_equal 1, poison.size
    assert_equal ['class:PoisonPillTestJob', "queue:#{@queue}"], poison.first[1]
  end

  # --- callback hooks -----------------------------------------------------

  # rubocop:disable Minitest/MultipleAssertions
  # One test pinning the entire callback contract — splitting would
  # obscure the pill-hash shape vs. fire-count constraint.
  def test_on_poison_fires_with_pill_hash
    pill = nil
    Wurk::Middleware::PoisonPill.on_poison { |p| pill = p }
    json = payload_json
    3.times { Wurk::Middleware::PoisonPill.track!(json, queue: @queue) }

    refute_nil pill
    assert_equal @jid, pill[:jid]
    assert_equal 'PoisonPillTestJob', pill[:klass]
    assert_equal @queue, pill[:queue]
    assert_equal 3, pill[:count]
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_on_poison_swallows_callback_errors
    Wurk::Middleware::PoisonPill.on_poison { |_| raise 'boom' }
    json = payload_json

    assert_silent do
      3.times { Wurk::Middleware::PoisonPill.track!(json, queue: @queue) }
    end
  end

  def test_on_poison_requires_block
    assert_raises(ArgumentError) { Wurk::Middleware::PoisonPill.on_poison }
  end

  private

  def payload_json(extra = {})
    Wurk.dump_json({
      'class' => 'PoisonPillTestJob',
      'args' => [],
      'queue' => @queue,
      'jid' => @jid,
      'enqueued_at' => Time.now.to_f
    }.merge(extra))
  end

  # `Wurk::Metrics::Statsd.increment` is a process-global singleton method —
  # serialize against every other test class that rewrites it (metrics_statsd,
  # client_buffered, middleware_expiry).
  def with_statsd_recorder
    Wurk::Test::STATSD_MUTEX.synchronize do
      calls = []
      real = Wurk::Metrics::Statsd.method(:increment)
      Wurk::Metrics::Statsd.singleton_class.send(:define_method, :increment) do |metric, tags: nil, **_|
        calls << [metric, tags]
        nil
      end
      begin
        yield
        calls
      ensure
        Wurk::Metrics::Statsd.singleton_class.send(:define_method, :increment, real)
      end
    end
  end

  def dead_for_jid_count
    @pool.with do |c|
      members = c.call('ZRANGE', Wurk::Keys::DEAD, 0, -1)
      members.count { |m| m.include?(@jid) }
    end
  end

  def clean
    @pool.with do |c|
      c.call('DEL', @key)
      members = c.call('ZRANGE', Wurk::Keys::DEAD, 0, -1)
      mine = members.select { |m| m.include?(@jid) }
      mine.each { |m| c.call('ZREM', Wurk::Keys::DEAD, m) }
    end
  end
end
