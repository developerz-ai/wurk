# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Pins Wurk::Middleware::PoisonPill, driven the way production drives it: an
# orphan on a private list moved by Fetcher::OrphanReclaim, whose script keeps
# the counter, then PoisonPill.recovered! for the notifications.
#   * counter +1 with a 72h TTL at `super_fetch:recovered:<jid>` per orphan
#   * <=3 → requeued, emit `jobs.recovered.fetch`
#   * >3 (the 4th orphaning, as Pro) → dead set, emit `jobs.poison`, fire callbacks
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
    @public_q = Wurk::Keys.queue(@queue)
    @private_list = "#{@public_q}|host|999999|nonce|0"
    @stub_increments = []
    @saved_handlers = Wurk.configuration.death_handlers.dup
    Wurk::Middleware::PoisonPill.reset!
    clean
  end

  def teardown
    @configs&.each(&:reset_redis_pools!)
    Wurk.configuration.death_handlers.replace(@saved_handlers)
    Wurk::Middleware::PoisonPill.reset!
    clean
  ensure
    super
  end

  # --- counter lifecycle -------------------------------------------------

  # Not a chain middleware: its producer is the reaper and its consumer the ACK,
  # so the file lives with the fetcher. The constant keeps the Middleware path
  # Pro initializers name.
  def test_lives_with_the_fetcher_under_its_pro_constant
    path = Wurk::Middleware::PoisonPill.method(:recovered!).source_location.first

    assert_equal File.expand_path('../../lib/wurk/fetcher/poison_pill.rb', __dir__), path
  end

  def test_first_recovery_increments_to_one
    json = payload_json

    assert recover(json)
    assert_equal [json], public_jobs
    assert_equal 1, Wurk::Middleware::PoisonPill.recovery_count(@jid)
  end

  def test_counter_expires_at_72_hours
    recover(payload_json)
    ttl = @pool.with { |c| c.call('TTL', @key) }.to_i

    assert_operator ttl, :<=, Wurk::Middleware::PoisonPill::RECOVERY_TTL
    assert_operator ttl, :>=, Wurk::Middleware::PoisonPill::RECOVERY_TTL - 5
  end

  def test_third_recovery_does_not_yet_poison
    3.times { recover(payload_json) }

    assert_equal 3, Wurk::Middleware::PoisonPill.recovery_count(@jid)
    # jid-scoped: a global ZCARD races other parallel tests / stray dead jobs.
    assert_equal 0, dead_for_jid_count, 'a job below the poison threshold must not be in the dead set'
  end

  def test_fourth_recovery_goes_to_dead_and_never_to_the_queue
    json = payload_json
    3.times { recover(json) }
    @pool.with { |c| c.call('DEL', @public_q) }
    kills = Wurk::Metrics::ProcessCounters.value(:poison_kills)
    recover(json)

    assert_equal kills + 1, Wurk::Metrics::ProcessCounters.value(:poison_kills)
    assert_empty public_jobs
    assert_equal(0, @pool.with { |c| c.call('LLEN', @private_list) })
    assert_equal 1, dead_for_jid_count
  end

  # A payload that has already left the private list (another reaper, an ACK)
  # is not moved, counted or notified twice.
  def test_a_payload_no_longer_on_the_private_list_is_left_alone
    refute Wurk::Fetcher::OrphanReclaim.new(Wurk.configuration).call(@private_list, @public_q, payload_json)
    assert_empty public_jobs
    assert_equal 0, Wurk::Middleware::PoisonPill.recovery_count(@jid)
  end

  # The counter is written in the same step as the move, so it never exists
  # without its TTL (an INCR then EXPIRE pair could be split by a blip).
  def test_the_counter_is_never_left_without_a_ttl
    @pool.with { |c| c.call('SET', @key, '1') }
    recover(payload_json)

    assert_operator @pool.with { |c| c.call('TTL', @key) }, :>, 0
    assert_equal 2, Wurk::Middleware::PoisonPill.recovery_count(@jid)
  end

  def test_clear_resets_counter
    recover(payload_json)
    Wurk::Middleware::PoisonPill.clear!(@jid)

    assert_equal 0, Wurk::Middleware::PoisonPill.recovery_count(@jid)
  end

  # Covers clear!'s early-return guard (nil / empty jid): must be a no-op
  # and must never issue a DEL against a malformed key.
  def test_clear_is_a_noop_for_empty_jid
    assert_nil Wurk::Middleware::PoisonPill.clear!(nil)
    assert_nil Wurk::Middleware::PoisonPill.clear!('')
  end

  # The ACK path's form of clear!: the DEL rides a pipeline the caller already
  # opened (Fetcher::Reliable::UnitOfWork#acknowledge) instead of taking a
  # round trip of its own.
  def test_clear_in_drops_the_counter_from_an_open_pipeline
    recover(payload_json)
    @pool.with { |c| c.pipelined { |pipe| Wurk::Middleware::PoisonPill.clear_in(pipe, @jid) } }

    assert_equal 0, Wurk::Middleware::PoisonPill.recovery_count(@jid)
  end

  # clear_in guards the blank jid itself rather than trusting its caller:
  # counter_key(nil) is the bare KEY_PREFIX, so an unguarded DEL would drop a
  # shared key instead of a per-job one. Queue nothing, and leave a real
  # counter parked under the bare prefix untouched.
  def test_clear_in_is_a_noop_for_empty_jid
    prefix = Wurk::Middleware::PoisonPill.counter_key(nil)
    @pool.with { |c| c.call('SET', prefix, '7') }

    [nil, ''].each do |blank|
      @pool.with { |c| c.pipelined { |pipe| Wurk::Middleware::PoisonPill.clear_in(pipe, blank) } }
    end

    assert_equal('7', @pool.with { |c| c.call('GET', prefix) })
  end

  def test_counter_key_is_the_pro_wire_key
    assert_equal @key, Wurk::Middleware::PoisonPill.counter_key(@jid)
  end

  def test_recovery_count_returns_zero_for_unknown_jid
    assert_equal 0, Wurk::Middleware::PoisonPill.recovery_count(SecureRandom.hex(12))
  end

  def test_recovery_count_handles_empty_input
    assert_equal 0, Wurk::Middleware::PoisonPill.recovery_count(nil)
    assert_equal 0, Wurk::Middleware::PoisonPill.recovery_count('')
  end

  # --- malformed payload --------------------------------------------------

  def test_unparseable_payload_is_requeued_without_state
    assert recover('not-json{{')
    assert_equal ['not-json{{'], public_jobs
    assert_equal :recovered, Wurk::Middleware::PoisonPill.recovered!('not-json{{', nil, count: 0)
  end

  # A JSON value that is not an object has no jid to count.
  def test_non_object_json_is_not_a_job
    assert_nil Wurk::Middleware::PoisonPill.parse('12345')
    assert_nil Wurk::Middleware::PoisonPill.parse('["a"]')
  end

  def test_payload_without_jid_skips_counter
    json = Wurk.dump_json('class' => 'X', 'args' => [])
    4.times { recover(json) }

    assert_equal [json] * 4, public_jobs
  end

  # --- statsd integration -------------------------------------------------

  def test_emits_jobs_recovered_fetch_on_normal_recovery
    metrics = with_statsd_recorder do
      recover(payload_json)
    end

    assert_equal [['jobs.recovered.fetch', ['class:PoisonPillTestJob', "queue:#{@queue}"]]], metrics
  end

  def test_emits_jobs_poison_on_threshold_crossing
    json = payload_json
    metrics = with_statsd_recorder do
      4.times { recover(json) }
    end

    poison = metrics.select { |m| m[0] == 'jobs.poison' }

    assert_equal 1, poison.size
    assert_equal ['class:PoisonPillTestJob', "queue:#{@queue}"], poison.first[1]
  end

  # No class and no queue → tags stays empty → increment called with nil
  # tags (covers the false sides of both `if klass` / `if queue` guards and
  # the empty? branch in emit_recovered_fetch).
  def test_emits_recovered_fetch_with_nil_tags_when_no_class_or_queue
    metrics = with_statsd_recorder do
      Wurk::Middleware::PoisonPill.recovered!(Wurk.dump_json('jid' => @jid), { 'jid' => @jid }, count: 1)
    end

    assert_equal [['jobs.recovered.fetch', nil]], metrics
  end

  # Crossing the threshold with a payload that has a jid but no class, and
  # queue: nil: emit_poison's empty-tags path (nil tags).
  def test_emits_poison_with_nil_tags
    hash = { 'jid' => @jid }
    metrics = with_statsd_recorder do
      Wurk::Middleware::PoisonPill.recovered!(Wurk.dump_json(hash), hash, count: 4)
    end

    poison = metrics.select { |m| m[0] == 'jobs.poison' }

    assert_equal 1, poison.size
    assert_nil poison.first[1]
    assert_equal 1, dead_for_jid_count
  end

  # --- death handlers -----------------------------------------------------

  # A poison kill is a death: Batch::DeathHandler is a death handler, so
  # suppressing the notification would strand every batch owning the job.
  def test_poison_kill_fires_death_handlers_with_the_poisoned_error
    received = []
    Wurk.configuration.death_handlers << ->(job, ex) { received << [job['jid'], ex] }
    json = payload_json
    4.times { recover(json) }

    assert_equal 1, received.size, 'only the kill notifies — sub-threshold recoveries are not deaths'
    jid, ex = received.first

    assert_equal @jid, jid
    assert_instance_of Wurk::Middleware::PoisonPill::Poisoned, ex
    assert_equal 'PoisonPillTestJob was orphaned 4 times without completing', ex.message
    refute_nil ex.backtrace, 'error services expect a backtrace'
  end

  # Falls back to a generic subject when the payload carries no class name.
  def test_poisoned_error_message_without_a_class
    received = []
    Wurk.configuration.death_handlers << ->(_job, ex) { received << ex.message }
    hash = { 'jid' => @jid }
    4.times { recover(Wurk.dump_json(hash)) }

    assert_equal ['job was orphaned 4 times without completing'], received
  end

  # --- callback hooks -----------------------------------------------------

  # One test pinning the entire callback contract — splitting would
  # obscure the pill-hash shape vs. fire-count constraint.
  def test_on_poison_fires_with_pill_hash
    pill = nil
    Wurk::Middleware::PoisonPill.on_poison { |p| pill = p }
    json = payload_json
    4.times { recover(json) }

    refute_nil pill
    assert_equal @jid, pill[:jid]
    assert_equal 'PoisonPillTestJob', pill[:klass]
    assert_equal @queue, pill[:queue]
    assert_equal 4, pill[:count]
  end

  def test_on_poison_swallows_callback_errors
    Wurk::Middleware::PoisonPill.on_poison { |_| raise 'boom' }
    json = payload_json

    assert_silent do
      4.times { recover(json) }
    end
  end

  def test_on_poison_requires_block
    assert_raises(ArgumentError) { Wurk::Middleware::PoisonPill.on_poison }
  end

  # Re-running an initializer that hands back the same stored Proc each time
  # (Rails code reloading, a re-required file) must not accumulate duplicate
  # closures — each registration retains its own binding, so unbounded
  # re-registration is an unbounded retention leak.
  def test_on_poison_dedups_by_callback_identity
    calls = 0
    callback = proc { calls += 1 }
    3.times { Wurk::Middleware::PoisonPill.on_poison(&callback) }
    json = payload_json
    4.times { recover(json) }

    assert_equal 1, calls, 'the same Proc registered repeatedly must fire once per poison, not N times'
  end

  # A fresh block literal per call is a distinct callable and must still
  # register separately (dedup is by identity, not by "already registered
  # something").
  def test_on_poison_does_not_dedup_distinct_blocks
    calls = 0
    2.times { Wurk::Middleware::PoisonPill.on_poison { calls += 1 } }
    json = payload_json
    4.times { recover(json) }

    assert_equal 2, calls
  end

  def test_on_poison_returns_removable_registration
    calls = 0
    registration = Wurk::Middleware::PoisonPill.on_poison { calls += 1 }
    registration.remove!
    json = payload_json
    4.times { recover(json) }

    assert_equal 0, calls, 'a removed registration must not fire'
  end

  # --- super_fetch! recovery callback (Pro §3.1: |jobstr, pill|) -----------

  def test_super_fetch_callback_fires_with_job_string_and_nil_pill_on_recovery
    recorded = []
    cfg = recovery_config { |jobstr, pill| recorded << [jobstr, pill] }
    json = payload_json

    recover(json, config: cfg)

    assert_equal [[json, nil]], recorded, 'a non-poison recovery passes the raw jobstr and pill=nil'
  end

  # Even a payload that can't be parsed is still a recovery — the block fires
  # once with the raw string and no pill (the `unless job` branch in recovered!).
  def test_super_fetch_callback_fires_for_unparseable_payload
    recorded = []
    cfg = recovery_config { |jobstr, pill| recorded << [jobstr, pill] }

    recover('not-json{{', config: cfg)

    assert_equal [['not-json{{', nil]], recorded
  end

  def test_super_fetch_callback_receives_pill_on_poison_kill
    recorded = []
    cfg = recovery_config { |jobstr, pill| recorded << [jobstr, pill] }
    json = payload_json
    4.times { recover(json, config: cfg) }

    assert_equal 4, recorded.size, 'the block fires once per recovery'
    assert(recorded[0..2].all? { |_, pill| pill.nil? }, 'sub-threshold recoveries carry no pill')

    jobstr, pill = recorded.last

    assert_equal json, jobstr
    assert_equal @jid, pill.jid
    assert_equal 'PoisonPillTestJob', pill.klass
    assert_equal 4, pill.count
    assert_equal @queue, pill.queue
  end

  # The two-arg super_fetch block and the legacy on_poison Hash callback are
  # independent registries; both must fire on a poison kill.
  def test_super_fetch_and_on_poison_both_fire_on_poison
    super_pill = nil
    on_poison_hash = nil
    cfg = recovery_config { |_jobstr, pill| super_pill = pill }
    Wurk::Middleware::PoisonPill.on_poison { |h| on_poison_hash = h }
    json = payload_json

    4.times { recover(json, config: cfg) }

    assert_equal @jid, super_pill&.jid, 'super_fetch block saw the pill'
    assert_equal @jid, on_poison_hash&.[](:jid), 'legacy on_poison Hash still fires'
  end

  def test_super_fetch_callback_errors_are_swallowed
    cfg = recovery_config { |_jobstr, _pill| raise 'boom' }

    assert_silent do
      recover(payload_json, config: cfg)
    end
  end

  # A blank jid is a plain recovery — no counter bump, never poison — and still
  # fires the block once with pill=nil.
  def test_super_fetch_callback_treats_blank_jid_as_plain_recovery
    recorded = []
    cfg = recovery_config { |_jobstr, pill| recorded << pill }

    4.times { recover(Wurk.dump_json('jid' => '', 'class' => 'X'), config: cfg) }

    assert_equal [nil] * 4, recorded
  end

  private

  # A throwaway config carrying only the recovery block + a NULL logger, so a
  # swallowed callback error reports silently, on the suite's Redis.
  def recovery_config(&)
    cfg = Wurk::Configuration.new
    cfg.logger = ::Logger.new(IO::NULL)
    cfg.super_fetch!(&)
    (@configs ||= []) << cfg
    cfg
  end

  # One orphaning: the payload lands on a private list and is reclaimed.
  def recover(payload, config: Wurk.configuration)
    @pool.with { |c| c.call('RPUSH', @private_list, payload) }
    Wurk::Fetcher::OrphanReclaim.new(config).call(@private_list, @public_q, payload)
  end

  def public_jobs
    @pool.with { |c| c.call('LRANGE', @public_q, 0, -1) }
  end

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
      c.call('DEL', @key, @public_q, @private_list)
      members = c.call('ZRANGE', Wurk::Keys::DEAD, 0, -1)
      mine = members.select { |m| m.include?(@jid) }
      mine.each { |m| c.call('ZREM', Wurk::Keys::DEAD, m) }
    end
  end
end
