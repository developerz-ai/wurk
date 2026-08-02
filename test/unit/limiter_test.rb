# frozen_string_literal: true

require_relative '../test_helper'

class LimiterTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @suffix = "ltest#{Process.pid}#{object_id}"
    @pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, timeout: 2, name: 'ltop')
    @pool.with { |c| Wurk::Lua::Loader.script_load_all(c) }
    Wurk::Limiter.reset_config!
    Wurk::Limiter.config.redis = @pool
  end

  def teardown
    # Scope cleanup to this test's @suffix so parallel limiter tests don't
    # wipe each other's state mid-run (failure mode: another test's
    # `within_limit` sees an empty counter because we DEL'd its key).
    @pool.with do |c|
      cursor = '0'
      loop do
        cursor, keys = c.call('SCAN', cursor, 'MATCH', "*#{@suffix}*", 'COUNT', 500)
        c.call('DEL', *keys) unless keys.empty?
        break if cursor == '0'
      end
      cursor = '0'
      loop do
        cursor, names = c.call('SSCAN', Wurk::Limiter::LIST_KEY, cursor, 'MATCH', "*#{@suffix}*", 'COUNT', 500)
        c.call('SREM', Wurk::Limiter::LIST_KEY, *names) unless names.empty?
        break if cursor == '0'
      end
    end
    @pool.disconnect!
    Wurk::Limiter.reset_config!
  ensure
    super
  end

  # ----- constructors dispatch to per-type classes ----------------------

  def test_concurrent_returns_concurrent_instance
    l = Wurk::Limiter.concurrent("cc-#{@suffix}", 1)

    assert_instance_of Wurk::Limiter::Concurrent, l
    assert_equal :concurrent, l.type
    assert_equal "cc-#{@suffix}", l.name
  end

  def test_bucket_returns_bucket_instance
    l = Wurk::Limiter.bucket("bk-#{@suffix}", 1, :minute)

    assert_instance_of Wurk::Limiter::Bucket, l
    assert_equal :bucket, l.type
  end

  def test_window_returns_window_instance
    l = Wurk::Limiter.window("wn-#{@suffix}", 1, :minute)

    assert_instance_of Wurk::Limiter::Window, l
    assert_equal :window, l.type
  end

  def test_leaky_returns_leaky_instance
    l = Wurk::Limiter.leaky("lk-#{@suffix}", 1, 1)

    assert_instance_of Wurk::Limiter::Leaky, l
    assert_equal :leaky, l.type
  end

  def test_points_returns_points_instance
    l = Wurk::Limiter.points("pt-#{@suffix}", 100, 10)

    assert_instance_of Wurk::Limiter::Points, l
    assert_equal :points, l.type
  end

  def test_unlimited_ignores_arguments_and_yields_unconditionally
    l = Wurk::Limiter.unlimited('whatever', 9999, foo: :bar)

    assert_instance_of Wurk::Limiter::Unlimited, l
    assert_equal :unlimited, l.type

    ran = false
    l.within_limit { ran = true }

    assert ran
  end

  # Drop-in contract: Points::Handle calls `refund` on the limiter via
  # `points_used`. Unlimited must answer that as a no-op or it raises
  # NoMethodError the moment a worker swaps to `Wurk::Limiter.unlimited`.
  def test_unlimited_handles_points_used_callback
    l = Wurk::Limiter.unlimited
    captured = nil
    l.within_limit(estimate: 50) { |h| captured = h.points_used(10) }

    assert_in_delta(0.0, captured)
  end

  # ----- OverLimit shape ------------------------------------------------

  def test_over_limit_exposes_limiter_and_job
    l = Wurk::Limiter.concurrent("ovr-#{@suffix}", 1, wait_timeout: 0)
    job = { 'jid' => 'abc', 'class' => 'X', 'args' => [], 'queue' => 'default' }
    exc = Wurk::Limiter::OverLimit.new(l, job)

    assert_equal l, exc.limiter
    assert_equal job, exc.job
    assert_kind_of StandardError, exc
  end

  # ----- name validation ------------------------------------------------

  def test_constructor_rejects_invalid_name
    assert_raises(ArgumentError) { Wurk::Limiter.concurrent('bad name with spaces', 1) }
  end

  def test_constructor_rejects_ttl_under_24h
    assert_raises(ArgumentError) { Wurk::Limiter.concurrent("ttl-#{@suffix}", 1, ttl: 60) }
  end

  # ----- registration in lmtr-list -------------------------------------

  def test_constructor_registers_in_lmtr_list_and_metadata_hash
    name = "reg-#{@suffix}"
    Wurk::Limiter.concurrent(name, 5)

    @pool.with do |c|
      assert_equal 1, c.call('SISMEMBER', Wurk::Limiter::LIST_KEY, name)
      type = c.call('HGET', "lmtr:#{name}", 'type')

      assert_equal 'concurrent', type
    end
  end

  # A limiter whose metadata ttl lapsed — and whose name the Web sweep then
  # dropped — has to come back on its next construction. The registration gate
  # keys off the metadata write, so re-creating the HASH re-adds the membership.
  def test_constructor_reregisters_after_metadata_expiry
    name = "rereg-#{@suffix}"
    Wurk::Limiter.concurrent(name, 5)
    @pool.with do |c|
      c.call('DEL', "lmtr:#{name}")
      c.call('SREM', Wurk::Limiter::LIST_KEY, name)
    end

    Wurk::Limiter.concurrent(name, 5)

    @pool.with do |c|
      assert_equal 1, c.call('SISMEMBER', Wurk::Limiter::LIST_KEY, name)
      assert_equal 1, c.call('EXISTS', "lmtr:#{name}")
    end
  end

  # Re-registering an already-registered limiter skips the SET write: with the
  # interpolated names the spec blesses, construction runs once per job against
  # a set that can hold millions of members. Only the Web sweep removes a name,
  # and it re-checks the metadata atomically — so "metadata live, membership
  # gone" is not a state Wurk itself can reach.
  def test_repeat_construction_skips_the_list_write
    name = "regskip-#{@suffix}"
    Wurk::Limiter.concurrent(name, 5)
    @pool.with { |c| c.call('SREM', Wurk::Limiter::LIST_KEY, name) }

    Wurk::Limiter.concurrent(name, 5)

    @pool.with { |c| assert_equal 0, c.call('SISMEMBER', Wurk::Limiter::LIST_KEY, name) }
  end

  # The ttl refresh is not part of that gate: an actively-used limiter must
  # never let its metadata lapse under it (and take its membership with it).
  def test_repeat_construction_refreshes_metadata_ttl
    name = "regttl-#{@suffix}"
    Wurk::Limiter.concurrent(name, 5)
    @pool.with { |c| c.call('EXPIRE', "lmtr:#{name}", 100) }

    Wurk::Limiter.concurrent(name, 5)

    assert_operator @pool.with { |c| c.call('TTL', "lmtr:#{name}").to_i }, :>, 100
  end

  # ----- delete + reset cleanup ----------------------------------------

  def test_delete_removes_state_keys_and_list_membership
    name = "del-#{@suffix}"
    l = Wurk::Limiter.concurrent(name, 1)
    l.within_limit {} # creates state
    l.delete
    @pool.with do |c|
      assert_equal 0, c.call('SISMEMBER', Wurk::Limiter::LIST_KEY, name)
      assert_equal 0, c.call('EXISTS', "lmtr:#{name}")
      assert_equal 0, c.call('EXISTS', "lmtr-cs:#{name}")
    end
  end

  # Regression: the dashboard's Reset DEL'd a bare `lmtr-b:<name>` key, but a
  # bucket's counter lives at `lmtr-b:<name>:<epoch>` — so Reset reported
  # success and left the limiter exhausted.
  def test_web_reset_clears_bucket_epoch_counter
    name = "bkweb-#{@suffix}"
    l = Wurk::Limiter.bucket(name, 5, :minute)
    l.within_limit {} # consumes one of the period's 5

    assert_equal 1, l.size

    Wurk::Web::Enterprise::Limits.reset(name)

    assert_equal 0, l.size
    @pool.with { |c| assert_empty c.call('KEYS', "lmtr-b:#{name}:*") }
  end

  # ----- configure --------------------------------------------------

  def test_configure_sets_backoff
    Wurk::Limiter.configure { |c| c.backoff = ->(_l, _j, _e) { 42 } }

    assert_equal 42, Wurk::Limiter.config.backoff.call(nil, {}, nil)
  end

  def test_configure_errors_array_can_be_extended
    Wurk::Limiter.config.errors << ArgumentError

    assert_includes Wurk::Limiter.config.errors, ArgumentError
  end

  # ----- fingerprint is SHA256 -----------------------------------------

  def test_fingerprint_is_sha256_hex
    l = Wurk::Limiter.concurrent("fp-#{@suffix}", 1)

    assert_match(/\A[0-9a-f]{64}\z/, l.fingerprint)
  end

  # serializable_options renders a Proc option as the literal '<proc>'
  # (base.rb line 100 when) and stringifies other shapes via `else v.to_s`
  # (base.rb line 102 else). The factory signatures are fixed, so we build a
  # Base subclass directly to thread through arbitrary option shapes.
  def test_serializable_options_renders_proc_and_stringifies_other_values
    name = "fpp-#{@suffix}"
    l = Wurk::Limiter::Bucket.new(name, count: 1, interval: :minute, ttl: 86_400,
                                        on_full: -> { :nope }, tags: %i[a b])
    meta = @pool.with { |c| JSON.parse(c.call('HGET', "lmtr:#{name}", 'options')) }

    assert_equal '<proc>', meta['on_full']
    assert_equal %i[a b].to_s, meta['tags']
    assert_match(/\A[0-9a-f]{64}\z/, l.fingerprint)
  end

  # ----- uniform status (#16) ------------------------------------------

  def test_status_uniform_shape_for_every_type
    limiters = {
      concurrent: Wurk::Limiter.concurrent("sc-#{@suffix}", 3),
      bucket: Wurk::Limiter.bucket("sb-#{@suffix}", 10, :minute),
      window: Wurk::Limiter.window("sw-#{@suffix}", 5, :hour),
      leaky: Wurk::Limiter.leaky("sl-#{@suffix}", 4, 2),
      points: Wurk::Limiter.points("sp-#{@suffix}", 100, 10),
      unlimited: Wurk::Limiter.unlimited
    }
    limiters.each do |type, l|
      s = l.status

      %i[used limit reset_at available?].each { |k| assert s.key?(k), "#{type} status missing #{k}" }
    end
  end

  def test_bucket_status_tracks_usage_and_reset_boundary # rubocop:disable Minitest/MultipleAssertions
    l = Wurk::Limiter.bucket("sbu-#{@suffix}", 3, :minute, wait_timeout: 0)
    2.times { l.within_limit { nil } }
    s = l.status

    assert_equal 2, s[:used]
    assert_equal 3, s[:limit]
    assert s[:available?]
    assert_operator s[:reset_at], :>, ::Time.now.to_f, 'reset_at is the next cardinal boundary'
  end

  def test_bucket_status_unavailable_when_full
    l = Wurk::Limiter.bucket("sbf-#{@suffix}", 2, :minute, wait_timeout: 0)
    2.times { l.within_limit { nil } }

    refute l.status[:available?], 'a saturated bucket reports unavailable'
  end

  def test_concurrent_status_merges_uniform_and_metrics
    l = Wurk::Limiter.concurrent("scm-#{@suffix}", 2)
    l.within_limit { nil }
    s = l.status

    assert_equal 2, s[:limit]
    assert s.key?(:available?)
    assert s.key?('immediate'), 'concurrent status keeps its metric counters'
  end

  def test_points_status_reflects_consumption
    l = Wurk::Limiter.points("spc-#{@suffix}", 100, 0)
    l.within_limit(estimate: 30) { |_h| nil }
    s = l.status

    assert_in_delta 30, s[:used], 1.0
    assert_in_delta(100.0, s[:limit])
  end

  # ----- server middleware reschedule path -----------------------------

  # A reschedule raises Wurk::Limiter::Rescheduled (a JobRetry::Skip) so the
  # run is neither success nor failure — the outer Batch onion skips both acks
  # and the Processor acks the UoW with no retry record. The push to `schedule`
  # happens before the raise. (#18)
  def test_server_middleware_reschedules_on_over_limit # rubocop:disable Metrics/AbcSize
    l = Wurk::Limiter.bucket("mw-#{@suffix}", 1, :minute, wait_timeout: 0, reschedule: 5)
    jid = "mwj#{@suffix}"
    job = { 'class' => 'NoopWorker', 'args' => [1], 'queue' => 'default', 'jid' => jid }
    mw = Wurk::Limiter::ServerMiddleware.new
    mw.config = Wurk.configuration

    begin
      assert_raises(Wurk::Limiter::Rescheduled) do
        mw.call(nil, job, 'default') { raise Wurk::Limiter::OverLimit.new(l, job) }
      end

      assert_equal 1, job['overrated']
      # Scheduled push lands in the global `schedule` ZSET with score = at.
      scored = Wurk.redis { |c| c.call('ZRANGE', 'schedule', 0, -1) }

      assert(scored.any? { |payload| payload.include?(jid) }, "schedule missing jid: #{scored.inspect}")
    ensure
      Wurk.redis do |c|
        c.call('ZRANGE', 'schedule', 0, -1).each { |p| c.call('ZREM', 'schedule', p) if p.include?(jid) }
      end
    end
  end

  # #16 poison brake: once `overrated` reaches the reschedule cap the job is
  # rate-limit-poison — instead of re-raising into the 25× retry pipeline,
  # the middleware drops it straight into the dead set tagged `rate_limited`.
  def test_server_middleware_routes_to_dead_after_reschedule_cap # rubocop:disable Minitest/MultipleAssertions,Metrics/AbcSize
    l = Wurk::Limiter.bucket("cap-#{@suffix}", 1, :minute, wait_timeout: 0, reschedule: 2)
    jid = "capj#{@suffix}"
    job = { 'class' => 'NoopWorker', 'args' => [], 'queue' => 'default', 'jid' => jid, 'overrated' => 1 }
    mw = Wurk::Limiter::ServerMiddleware.new
    mw.config = Wurk.configuration

    # No re-raise: the brake ACKs by returning normally.
    mw.call(nil, job, 'default') { raise Wurk::Limiter::OverLimit.new(l, job) }

    assert_equal 2, job['overrated']
    dead = Wurk.redis { |c| c.call('ZRANGE', Wurk::Keys::DEAD, 0, -1) }.find { |p| p.include?(jid) }

    refute_nil dead, 'job should be dead-lettered once the reschedule cap is hit'
    record = JSON.parse(dead)

    assert_equal 'Wurk::Limiter::OverLimit', record['error_class']
    assert_includes record['error_message'], Wurk::Limiter::ServerMiddleware::DEAD_REASON
  ensure
    Wurk.redis do |c|
      c.call('ZRANGE', Wurk::Keys::DEAD, 0, -1).each { |p| c.call('ZREM', Wurk::Keys::DEAD, p) if p.include?(jid) }
    end
  end

  # reschedule: 0 disables limiter rescheduling entirely (§1.2) — OverLimit
  # then re-raises into the normal retry/dead pipeline, no poison brake.
  def test_server_middleware_reraises_when_reschedule_disabled
    l = Wurk::Limiter.bucket("nz-#{@suffix}", 1, :minute, wait_timeout: 0, reschedule: 0)
    job = { 'class' => 'NoopWorker', 'args' => [], 'queue' => 'default', 'jid' => "nzj#{@suffix}" }
    mw = Wurk::Limiter::ServerMiddleware.new
    mw.config = Wurk.configuration

    assert_raises(Wurk::Limiter::OverLimit) do
      mw.call(nil, job, 'default') { raise Wurk::Limiter::OverLimit.new(l, job) }
    end
  end

  # An unrelated error (not OverLimit, not in config.errors) sails through
  # untouched — the `raise unless over_limit?(e)` re-raise side.
  def test_server_middleware_reraises_unrelated_error
    job = { 'class' => 'NoopWorker', 'args' => [], 'queue' => 'default', 'jid' => "unr#{@suffix}" }
    mw = Wurk::Limiter::ServerMiddleware.new
    mw.config = Wurk.configuration

    err = assert_raises(RuntimeError) do
      mw.call(nil, job, 'default') { raise 'boom' }
    end

    assert_equal 'boom', err.message
    refute job.key?('overrated'), 'unrelated error must not be treated as over-limit'
  end

  # A registered custom error that exposes neither #limiter nor #job= drives
  # the else sides of `respond_to?(:limiter)` / `respond_to?(:job=)` plus the
  # nil-limiter `reschedule_cap` short-circuit (default cap, reschedule path).
  def test_server_middleware_handles_plain_registered_error # rubocop:disable Metrics/AbcSize
    custom = Class.new(StandardError)
    Wurk::Limiter.config.errors << custom
    job = { 'class' => 'NoopWorker', 'args' => [], 'queue' => 'default', 'jid' => "pln#{@suffix}" }
    mw = Wurk::Limiter::ServerMiddleware.new
    mw.config = Wurk.configuration

    begin
      assert_raises(Wurk::Limiter::Rescheduled) do
        mw.call(nil, job, 'default') { raise custom, 'throttled' }
      end

      assert_equal 1, job['overrated'], 'plain registered error still counts as over-limit'
      scored = Wurk.redis { |c| c.call('ZRANGE', 'schedule', 0, -1) }

      assert(scored.any? { |p| p.include?("pln#{@suffix}") }, 'rescheduled with default cap')
    ensure
      Wurk.redis do |c|
        c.call('ZRANGE', 'schedule', 0, -1).each { |p| c.call('ZREM', 'schedule', p) if p.include?("pln#{@suffix}") }
      end
    end
  end

  # A limiter type with no `:reschedule` option (concurrent) → reschedule_cap
  # hits the `cap.nil? ? DEFAULT_RESCHEDULE` then-side via the default.
  def test_server_middleware_uses_default_cap_when_limiter_has_no_reschedule_option # rubocop:disable Minitest/MultipleAssertions,Metrics/AbcSize
    l = Wurk::Limiter.concurrent("nocap-#{@suffix}", 1, wait_timeout: 0)

    refute l.options.key?(:reschedule), 'concurrent limiter carries no reschedule option'
    job = { 'class' => 'NoopWorker', 'args' => [], 'queue' => 'default', 'jid' => "ncj#{@suffix}" }
    mw = Wurk::Limiter::ServerMiddleware.new
    mw.config = Wurk.configuration

    begin
      assert_raises(Wurk::Limiter::Rescheduled) do
        mw.call(nil, job, 'default') { raise Wurk::Limiter::OverLimit.new(l, job) }
      end

      assert_equal 1, job['overrated']
      scored = Wurk.redis { |c| c.call('ZRANGE', 'schedule', 0, -1) }

      assert(scored.any? { |p| p.include?("ncj#{@suffix}") }, 'rescheduled under default cap')
    ensure
      Wurk.redis do |c|
        c.call('ZRANGE', 'schedule', 0, -1).each { |p| c.call('ZREM', 'schedule', p) if p.include?("ncj#{@suffix}") }
      end
    end
  end

  # The whole reschedule mechanism depends on Batch being OUTER of Limiter in
  # the server chain (`add` appends; entry 0 is outermost). If Limiter were
  # outer, a Rescheduled would unwind before Batch saw it and the batch onion
  # would never learn the job didn't run. Guard the invariant. (#18)
  def test_batch_middleware_is_registered_outer_of_limiter
    klasses = Wurk.configuration.server_middleware.map(&:klass)
    batch_i = klasses.index(Wurk::Batch::ServerMiddleware)
    limiter_i = klasses.index(Wurk::Limiter::ServerMiddleware)

    refute_nil batch_i, 'Batch::ServerMiddleware must be registered'
    refute_nil limiter_i, 'Limiter::ServerMiddleware must be registered'
    assert_operator batch_i, :<, limiter_i, 'Batch must be OUTER (registered before) Limiter'
  end

  # ----- DEFAULT_BACKOFF non-Hash job branch ---------------------------

  # The backoff proc guards `job.is_a?(Hash)`; a non-Hash job exercises the
  # else side (overrated defaults to 0 → delay is just rand(300)+1).
  def test_default_backoff_with_non_hash_job
    delay = Wurk::Limiter::DEFAULT_BACKOFF.call(nil, nil, nil)

    assert_operator delay, :>=, 1
    assert_operator delay, :<=, 300
  end

  # ----- Config#pool dispatch ------------------------------------------

  # `redis = { url: }` lazily materializes a RedisPool — the `when Hash` arm.
  def test_config_pool_builds_pool_from_hash
    Wurk::Limiter.reset_config!
    Wurk::Limiter.config.redis = { url: Wurk::Test.redis_url, size: 1, timeout: 1 }
    pool = Wurk::Limiter.config.pool

    assert_instance_of Wurk::RedisPool, pool
    pool.with { |c| assert_equal 'PONG', c.call('PING') }
  ensure
    pool&.disconnect!
  end

  # An unsupported redis value (neither Hash nor RedisPool) → the else raise.
  def test_config_pool_rejects_unsupported_redis_value
    Wurk::Limiter.reset_config!
    Wurk::Limiter.config.redis = 'redis://nope'

    assert_raises(ArgumentError) { Wurk::Limiter.config.pool }
  end

  # ----- build (dashboard reconstruction) ------------------------------

  # `type == 'unlimited'` short-circuits to an Unlimited stub (then-side).
  def test_build_returns_unlimited_for_unlimited_type
    assert_instance_of Wurk::Limiter::Unlimited, Wurk::Limiter.build('whatever', 'unlimited', {})
  end

  # An unknown type has no class mapping → `return nil unless klass_name`.
  def test_build_returns_nil_for_unknown_type
    assert_nil Wurk::Limiter.build("bad-#{@suffix}", 'gibberish', {})
  end

  # JSON round-trip stores `interval` as a string; coerce_build_options +
  # interval_seconds must re-symbolize it (line 210 then / line 236 then).
  def test_build_coerces_stringified_interval
    l = Wurk::Limiter.build("rebuilt-#{@suffix}", 'bucket',
                            { 'count' => 3, 'interval' => 'minute' }, register: false)

    assert_instance_of Wurk::Limiter::Bucket, l
    assert_equal :minute, l.options[:interval]
  end

  # ----- interval_seconds guard ----------------------------------------

  # A non-Symbol / non-Integer interval falls to the else raise.
  def test_interval_seconds_rejects_non_symbol_non_integer
    assert_raises(ArgumentError) { Wurk::Limiter.interval_seconds(1.5, allow_integer: true) }
  end

  # A string that names a known unit is re-symbolized then resolved (line 210).
  def test_interval_seconds_accepts_known_string_unit
    assert_equal 60, Wurk::Limiter.interval_seconds('minute', allow_integer: false)
  end

  # ----- first_score: protocol-agnostic ZRANGE WITHSCORES parsing -------
  # Pure-function unit test (no Redis): covers both wire shapes and empty. The
  # integration paths only ever hit the RESP3 nested form, so the flat branch
  # would otherwise go unexercised.

  def test_first_score_reads_resp3_nested_pair
    assert_in_delta 12.5, Wurk::Limiter.first_score([['member', '12.5']]), 0.0001
  end

  def test_first_score_reads_resp2_flat_pair
    assert_in_delta 12.5, Wurk::Limiter.first_score(['member', '12.5']), 0.0001
  end

  def test_first_score_nil_when_empty
    assert_nil Wurk::Limiter.first_score([])
  end
end
