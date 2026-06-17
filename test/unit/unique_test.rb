# frozen_string_literal: true

require_relative '../test_helper'

class UniqueTest < Wurk::Test::UnitCase
  # NOT parallelize_me! — these tests flip the process-wide
  # `Wurk::Unique.enabled?` flag and install client/server middleware on
  # the global config. Running in parallel would let one test's `enable!`
  # leak into another's "should be a no-op" assertion.

  ENABLE_MUTEX = ::Mutex.new

  def setup
    super
    @suffix = "uniq#{Process.pid}#{object_id}"
    @keys = []
  end

  def teardown
    Wurk.redis do |c|
      @keys.each { |k| c.call('DEL', k) }
    end
    Wurk::Unique.disable!
    Wurk.configuration.client_middleware.remove(Wurk::Unique::ClientMiddleware)
    Wurk.configuration.server_middleware.remove(Wurk::Unique::ServerMiddleware)
    Wurk.configuration.death_handlers.delete(Wurk::Unique::DEATH_HANDLER)
  ensure
    super
  end

  # ---- digest / lock key ----------------------------------------------

  def test_lock_key_is_sha256_with_unique_prefix
    key = Wurk::Unique.lock_key('FooJob', 'default', [1, 2, 3])

    assert_match(/\Aunique:[0-9a-f]{64}\z/, key)
  end

  def test_lock_key_stable_for_same_inputs
    a = Wurk::Unique.lock_key('FooJob', 'default', [1, 2])
    b = Wurk::Unique.lock_key('FooJob', 'default', [1, 2])

    assert_equal a, b
  end

  def test_lock_key_differs_by_class
    a = Wurk::Unique.lock_key('A', 'default', [1])
    b = Wurk::Unique.lock_key('B', 'default', [1])

    refute_equal a, b
  end

  def test_lock_key_differs_by_queue
    a = Wurk::Unique.lock_key('A', 'q1', [1])
    b = Wurk::Unique.lock_key('A', 'q2', [1])

    refute_equal a, b
  end

  def test_lock_key_differs_by_args
    a = Wurk::Unique.lock_key('A', 'q', [1])
    b = Wurk::Unique.lock_key('A', 'q', [2])

    refute_equal a, b
  end

  def test_lock_key_for_uses_default_context
    job = { 'class' => 'FooJob', 'queue' => 'default', 'args' => [42] }

    assert_equal Wurk::Unique.lock_key('FooJob', 'default', [42]),
                 Wurk::Unique.lock_key_for(job)
  end

  def test_lock_key_for_with_nil_class_resolves_to_nil_context
    # resolve_class short-circuits on a nil/empty class name (line 82),
    # so unique_context falls back to the raw [class, queue, args] triple.
    job = { 'class' => nil, 'queue' => 'q', 'args' => [1] }
    expected = "unique:#{Digest::SHA256.hexdigest(JSON.dump([nil, 'q', [1]]))}"

    assert_equal expected, Wurk::Unique.lock_key_for(job)
  end

  def test_lock_key_for_with_empty_class_resolves_to_nil_context
    job = { 'class' => '', 'queue' => 'q', 'args' => [1] }
    expected = "unique:#{Digest::SHA256.hexdigest(JSON.dump(['', 'q', [1]]))}"

    assert_equal expected, Wurk::Unique.lock_key_for(job)
  end

  def test_lock_key_honors_sidekiq_unique_context
    klass = Class.new do
      def self.name = 'CustomContextJob'

      def self.sidekiq_unique_context(job)
        ['CustomContextJob', job['queue'], [job['args'].first]]
      end
    end
    stub_const('CustomContextJob', klass) do
      a = Wurk::Unique.lock_key_for({ 'class' => 'CustomContextJob', 'queue' => 'q', 'args' => [1, 'noise'] })
      b = Wurk::Unique.lock_key_for({ 'class' => 'CustomContextJob', 'queue' => 'q', 'args' => [1, 'other'] })

      assert_equal a, b
    end
  end

  # ---- enable / disable -----------------------------------------------

  def test_disabled_by_default
    refute_predicate Wurk::Unique, :enabled?
    refute_predicate Sidekiq::Enterprise, :unique?
  end

  def test_enable_via_sidekiq_enterprise_sets_predicates
    ENABLE_MUTEX.synchronize do
      Sidekiq::Enterprise.unique!

      assert_predicate Wurk::Unique, :enabled?
      assert_predicate Sidekiq::Enterprise, :unique?
    end
  end

  def test_enable_installs_both_middleware
    ENABLE_MUTEX.synchronize do
      Sidekiq::Enterprise.unique!

      assert Wurk.configuration.client_middleware.exists?(Wurk::Unique::ClientMiddleware)
      assert Wurk.configuration.server_middleware.exists?(Wurk::Unique::ServerMiddleware)
    end
  end

  def test_enable_is_idempotent
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      Wurk::Unique.enable!

      client_count = Wurk.configuration.client_middleware.entries.count { |e| e.klass == Wurk::Unique::ClientMiddleware }
      server_count = Wurk.configuration.server_middleware.entries.count { |e| e.klass == Wurk::Unique::ServerMiddleware }

      assert_equal 1, client_count
      assert_equal 1, server_count
    end
  end

  # ---- coerce_ttl ------------------------------------------------------

  def test_coerce_ttl_passes_through_positive_integer
    assert_equal 60, Wurk::Unique.coerce_ttl(60)
  end

  def test_coerce_ttl_false_means_skip
    assert_nil Wurk::Unique.coerce_ttl(false)
    assert_nil Wurk::Unique.coerce_ttl(nil)
  end

  def test_coerce_ttl_handles_duration_like
    duration = duration_double(600)

    assert_equal 600, Wurk::Unique.coerce_ttl(duration)
  end

  # Regression #253: a real ActiveSupport::Duration overrides `is_a?(Integer)`
  # to return true, so `unique_for: 1.hour` slipped past the Integer fast-path
  # and the raw Duration reached redis-client as the EX arg (TypeError). Must
  # coerce to Integer seconds. The duration_double above can't catch this — it
  # doesn't lie about is_a?(Integer) the way the real class does.
  def test_coerce_ttl_coerces_real_activesupport_duration_to_integer
    require 'active_support/duration'
    duration = ActiveSupport::Duration.build(3600)

    assert_kind_of Integer, duration, 'precondition: AS Duration reports is_a?(Integer)'

    ttl = Wurk::Unique.coerce_ttl(duration)

    assert_instance_of Integer, ttl
    assert_equal 3600, ttl
  end

  def test_coerce_ttl_floors_non_integer_numeric
    # Float is Numeric but not Integer (line 103 then): truncated via to_i.
    assert_equal 60, Wurk::Unique.coerce_ttl(60.9)
  end

  def test_coerce_ttl_rejects_non_numeric_non_duration
    # An object that does not respond to to_i: duration_like? short-circuits
    # to false (line 110 then) and coerce_ttl falls through to nil (line 104 else).
    assert_nil Wurk::Unique.coerce_ttl(Object.new)
  end

  def test_coerce_ttl_rejects_to_i_responder_that_is_not_duration
    # Responds to to_i but is neither Numeric nor Duration-like, so coerce_ttl
    # reaches line 104, finds duration_like? false, and returns nil (line 104 else).
    not_a_duration = Class.new do
      def to_i = 42
      def self.name = 'PlainThing'
    end.new

    assert_nil Wurk::Unique.coerce_ttl(not_a_duration)
  end

  # ---- ClientMiddleware: SETNX --------------------------------------

  def test_client_middleware_skips_when_disabled
    job = { 'class' => 'X', 'queue' => 'q', 'args' => [], 'jid' => 'j1', 'unique_for' => 60 }
    track_key(job)
    ran = invoke_client(job)

    assert ran
    assert_nil(Wurk.redis { |c| c.call('GET', Wurk::Unique.lock_key_for(job)) })
  end

  def test_client_middleware_skips_when_unique_for_missing
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = { 'class' => 'X', 'queue' => 'q', 'args' => [], 'jid' => 'j1' }
      ran = invoke_client(job)

      assert ran
    end
  end

  def test_client_middleware_skips_when_unique_for_false
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = { 'class' => 'X', 'queue' => 'q', 'args' => [], 'jid' => 'j1', 'unique_for' => false }
      ran = invoke_client(job)

      assert ran
    end
  end

  def test_client_middleware_acquires_lock_first_push
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'jid-1', ttl: 60)
      ran = invoke_client(job)
      track_key(job)

      assert ran
      assert_equal('jid-1', Wurk.redis { |c| c.call('GET', Wurk::Unique.lock_key_for(job)) })
    end
  end

  def test_client_middleware_drops_duplicate
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      first = build_job(jid: 'jid-1', ttl: 60)
      second = build_job(jid: 'jid-2', ttl: 60)
      track_key(first)

      assert invoke_client(first)
      refute invoke_client(second)
      assert_equal('jid-1', Wurk.redis { |c| c.call('GET', Wurk::Unique.lock_key_for(first)) })
    end
  end

  def test_client_middleware_logs_holder_on_duplicate
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      io = StringIO.new
      with_logger(::Logger.new(io)) do
        invoke_client(build_job(jid: 'jid-A', ttl: 60))
        track_key(build_job(jid: 'jid-A', ttl: 60))
        invoke_client(build_job(jid: 'jid-B', ttl: 60))
      end

      assert_includes io.string, 'jid-A'
      assert_includes io.string, 'jid=jid-B'
    end
  end

  def test_client_middleware_past_at_uses_base_ttl
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'past-1', ttl: 30)
      job['at'] = ::Time.now.to_f - 120 # delay non-positive (line 168 else)
      ran = invoke_client(job)
      track_key(job)

      assert ran
      ttl = Wurk.redis { |c| c.call('TTL', Wurk::Unique.lock_key_for(job)) }

      assert_operator ttl, :<=, 30
      assert_operator ttl, :>, 0
    end
  end

  def test_client_middleware_duplicate_without_logger_is_silent
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      first = build_job(jid: 'nolog-1', ttl: 60)
      second = build_job(jid: 'nolog-2', ttl: 60)
      track_key(first)

      without_logger do
        assert invoke_client(first)
        refute invoke_client(second) # log_duplicate hits `return unless logger` (line 181 then)
      end

      assert_equal('nolog-1', Wurk.redis { |c| c.call('GET', Wurk::Unique.lock_key_for(first)) })
    end
  end

  def test_client_middleware_ttl_includes_schedule_delay
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'sched-1', ttl: 30)
      job['at'] = ::Time.now.to_f + 120
      ran = invoke_client(job)
      track_key(job)

      assert ran
      ttl = Wurk.redis { |c| c.call('TTL', Wurk::Unique.lock_key_for(job)) }

      assert_operator ttl, :>=, 120
    end
  end

  # ---- ClientMiddleware: own-jid re-push (#205) -----------------------

  def test_client_middleware_own_jid_repush_proceeds
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'repush-1', ttl: 600)
      track_key(job)

      assert invoke_client(job)
      assert invoke_client(job), 'promotion re-push of the lock holder must not be dropped'
      assert_equal('repush-1', Wurk.redis { |c| c.call('GET', Wurk::Unique.lock_key_for(job)) })
    end
  end

  def test_unique_scheduled_job_survives_promotion
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      queue = "promo#{@suffix}"
      jid = Wurk::Client.push('class' => 'PromoJob', 'args' => [1], 'queue' => queue,
                              'unique_for' => 3600, 'at' => ::Time.now.to_f - 1)
      track_key('class' => 'PromoJob', 'queue' => queue, 'args' => [1])

      refute_nil jid
      drain_sorted_set(Wurk::Keys::SCHEDULE)

      assert_equal 1, redis_call('LLEN', "queue:#{queue}")
      assert_equal 0, redis_call('ZCARD', Wurk::Keys::SCHEDULE)
    end
  end

  def test_unique_retry_job_survives_promotion
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      queue = "rpromo#{@suffix}"
      job = build_job(jid: 'retry-promo-1', ttl: 3600, queue: queue)
      seed_locked_retry_entry(job)

      drain_sorted_set(Wurk::Keys::RETRY)

      assert_equal 1, redis_call('LLEN', "queue:#{queue}")
      assert_equal 0, redis_call('ZCARD', Wurk::Keys::RETRY)
    end
  end

  def test_client_middleware_reacquires_when_lock_expires_mid_check
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      # First SET NX loses, GET sees the lock already expired (nil), the
      # retried SET NX wins — the push must proceed, not drop.
      pool = stub_pool(set_results: [nil, 'OK'], get_result: nil)
      job = build_job(jid: 'race-1', ttl: 60)

      assert Wurk::Unique::ClientMiddleware.new.call(nil, job, job['queue'], pool) { true }
    end
  end

  def test_client_middleware_drops_when_reacquire_also_loses
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      # Lock expired before GET but a competitor re-took it before our
      # retried SET NX — duplicate semantics apply.
      pool = stub_pool(set_results: [nil, nil], get_result: nil)
      job = build_job(jid: 'race-2', ttl: 60)

      refute Wurk::Unique::ClientMiddleware.new.call(nil, job, job['queue'], pool) { true }
    end
  end

  # ---- Death handler: lock release on automatic death (#211) ----------

  def test_enable_registers_death_handler_once
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      Wurk::Unique.enable!

      count = Wurk.configuration.death_handlers.count(Wurk::Unique::DEATH_HANDLER)

      assert_equal 1, count
    end
  end

  def test_automatic_death_releases_lock
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'dead-1', ttl: 600)
      track_key(job)

      assert invoke_client(job)
      die_unretryable(job)

      assert_nil redis_call('GET', Wurk::Unique.lock_key_for(job))
    end
  end

  def test_automatic_death_allows_fresh_duplicate
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'dead-a', ttl: 600)
      track_key(job)

      assert invoke_client(job)
      die_unretryable(job)

      assert invoke_client(build_job(jid: 'dead-b', ttl: 600)),
             'a fresh duplicate must enqueue immediately after the holder dies'
    end
  end

  def test_death_handler_retains_foreign_lock
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'dh-cas', ttl: 600)
      key = Wurk::Unique.lock_key_for(job)
      Wurk.redis { |c| c.call('SET', key, 'someone-else', 'EX', 600) }
      track_key(job)

      Wurk::Unique::DEATH_HANDLER.call(job, RuntimeError.new('boom'))

      assert_equal('someone-else', Wurk.redis { |c| c.call('GET', key) })
    end
  end

  def test_death_handler_noop_without_unique_for
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = { 'class' => 'X', 'queue' => 'q', 'args' => [], 'jid' => 'nfu-1' }
      key = Wurk::Unique.lock_key_for(job)
      Wurk.redis { |c| c.call('SET', key, 'nfu-1', 'EX', 60) }
      @keys << key

      Wurk::Unique::DEATH_HANDLER.call(job, RuntimeError.new('boom'))

      assert_equal('nfu-1', redis_call('GET', key))
    end
  end

  def test_death_handler_noop_when_disabled
    job = build_job(jid: 'dh-off', ttl: 600)
    key = Wurk::Unique.lock_key_for(job)
    Wurk.redis { |c| c.call('SET', key, 'dh-off', 'EX', 600) }
    track_key(job)

    Wurk::Unique::DEATH_HANDLER.call(job, RuntimeError.new('boom'))

    assert_equal('dh-off', Wurk.redis { |c| c.call('GET', key) })
  end

  def test_manual_ui_kill_retains_lock
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'kill-1', ttl: 600, queue: "kill#{@suffix}")
      key = seed_locked_retry_entry(job)
      # FLUSHDB only runs per test class, so the DEAD zset can already hold
      # entries from earlier `die_unretryable` tests — assert the delta.
      before = redis_call('ZCARD', Wurk::Keys::DEAD)

      Wurk::RetrySet.new.find_job('kill-1').kill

      assert_equal('kill-1', redis_call('GET', key),
                   'a user-initiated UI kill must keep the unique lock (Ent parity)')
      assert_equal before + 1, redis_call('ZCARD', Wurk::Keys::DEAD)
    end
  end

  # #207 × #211: API kills DO reach death handlers (OSS parity) while the
  # unique lock is still retained — DEATH_HANDLER recognizes the synthesized
  # "Job killed by API" exception and skips the release.
  def test_api_kill_fires_other_death_handlers_but_keeps_lock
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'kill-2', ttl: 600, queue: "kill2#{@suffix}")
      key = seed_locked_retry_entry(job)

      observe_death_handlers do |observed|
        Wurk::RetrySet.new.find_job('kill-2').kill

        assert_includes observed, ['kill-2', Wurk::DeadSet::API_KILL_MESSAGE]
        assert_equal('kill-2', redis_call('GET', key))
      end
    end
  end

  # ---- ServerMiddleware: lock release strategy -----------------------

  def test_server_middleware_no_op_when_disabled
    job = build_job(jid: 'sj-noop', ttl: 30)
    Wurk.redis { |c| c.call('SET', Wurk::Unique.lock_key_for(job), 'owner', 'EX', 30) }
    track_key(job)
    ran = invoke_server(job) { true }

    assert ran
    refute_nil(Wurk.redis { |c| c.call('GET', Wurk::Unique.lock_key_for(job)) })
  end

  def test_server_middleware_until_success_releases_after_success
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'sj-ok', ttl: 30, until_mode: :success)
      Wurk.redis { |c| c.call('SET', Wurk::Unique.lock_key_for(job), 'sj-ok', 'EX', 30) }
      track_key(job)

      assert_equal :done, invoke_server(job) { :done }
      assert_nil(Wurk.redis { |c| c.call('GET', Wurk::Unique.lock_key_for(job)) })
    end
  end

  def test_server_middleware_until_success_retains_on_raise
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'sj-raise', ttl: 30, until_mode: :success)
      Wurk.redis { |c| c.call('SET', Wurk::Unique.lock_key_for(job), 'sj-raise', 'EX', 30) }
      track_key(job)

      assert_raises(RuntimeError) { invoke_server(job) { raise 'boom' } }
      assert_equal('sj-raise', Wurk.redis { |c| c.call('GET', Wurk::Unique.lock_key_for(job)) })
    end
  end

  def test_server_middleware_until_start_releases_before_perform
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'sj-start', ttl: 30, until_mode: :start)
      key = Wurk::Unique.lock_key_for(job)
      Wurk.redis { |c| c.call('SET', key, 'sj-start', 'EX', 30) }
      track_key(job)

      seen_during_perform = nil
      invoke_server(job) { seen_during_perform = Wurk.redis { |c| c.call('GET', key) } }

      assert_nil seen_during_perform
    end
  end

  def test_server_middleware_release_is_cas_protected
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'cas-job', ttl: 30, until_mode: :success)
      key = Wurk::Unique.lock_key_for(job)
      Wurk.redis { |c| c.call('SET', key, 'someone-else', 'EX', 30) }
      track_key(job)
      invoke_server(job) { :ok }

      assert_equal('someone-else', Wurk.redis { |c| c.call('GET', key) })
    end
  end

  def test_server_middleware_invalid_until_defaults_to_success
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'sj-bad', ttl: 30, until_mode: 'garbage')
      Wurk.redis { |c| c.call('SET', Wurk::Unique.lock_key_for(job), 'sj-bad', 'EX', 30) }
      track_key(job)

      invoke_server(job) { :ok }

      assert_nil(Wurk.redis { |c| c.call('GET', Wurk::Unique.lock_key_for(job)) })
    end
  end

  def test_server_middleware_defaults_to_success_when_until_missing
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'sj-default', ttl: 30) # no unique_until → line 222 then
      Wurk.redis { |c| c.call('SET', Wurk::Unique.lock_key_for(job), 'sj-default', 'EX', 30) }
      track_key(job)

      assert_equal :done, invoke_server(job) { :done }
      assert_nil(Wurk.redis { |c| c.call('GET', Wurk::Unique.lock_key_for(job)) })
    end
  end

  def test_server_middleware_release_failure_logs_warning
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'sj-boom', ttl: 30, until_mode: :success)
      io = StringIO.new

      with_logger(::Logger.new(io)) do
        # release rescues the pool failure (line 236) and warns (logger present).
        assert_equal :ok, invoke_server_with_failing_pool(job) { :ok }
      end

      assert_includes io.string, 'Wurk::Unique release failed'
    end
  end

  def test_server_middleware_release_failure_without_logger_is_silent
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'sj-boom2', ttl: 30, until_mode: :success)

      without_logger do
        # rescue runs, `Wurk.logger&.warn` short-circuits (line 236 logger-nil side).
        assert_equal :ok, invoke_server_with_failing_pool(job) { :ok }
      end
    end
  end

  # ---- locked? introspection ------------------------------------------

  def test_locked_returns_jid_when_present
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      job = build_job(jid: 'holder', ttl: 60)
      key = Wurk::Unique.lock_key_for(job)
      Wurk.redis { |c| c.call('SET', key, 'holder', 'EX', 60) }
      track_key(job)

      assert_equal 'holder', Sidekiq::Enterprise::Unique.locked?(job['queue'], job['class'], job['args'])
    end
  end

  def test_locked_returns_nil_when_absent
    assert_nil Sidekiq::Enterprise::Unique.locked?('default', 'NeverEnqueued', [])
  end

  def test_locked_two_arg_form_uses_default_queue
    ENABLE_MUTEX.synchronize do
      Wurk::Unique.enable!
      default_queue = Wurk.default_job_options['queue']
      job = { 'class' => 'TwoArg', 'queue' => default_queue, 'args' => [99] }
      key = Wurk::Unique.lock_key_for(job)
      Wurk.redis { |c| c.call('SET', key, 'who', 'EX', 60) }
      @keys << key

      assert_equal 'who', Wurk::Unique.locked?('TwoArg', [99])
    end
  end

  private

  def build_job(jid:, ttl:, until_mode: nil, klass: "UniqJob#{@suffix}", queue: 'q')
    {
      'class' => klass,
      'queue' => queue,
      'args' => [1, 'x'],
      'jid' => jid,
      'unique_for' => ttl
    }.tap do |h|
      h['unique_until'] = until_mode if until_mode
    end
  end

  def invoke_client(job)
    pool = Wurk.configuration.redis_pool
    Wurk::Unique::ClientMiddleware.new.call(nil, job, job['queue'], pool) { true }
  end

  def invoke_server(job, &)
    mw = Wurk::Unique::ServerMiddleware.new
    mw.config = Wurk.configuration
    mw.call(nil, job, job['queue'], &)
  end

  # Drives the server middleware with a config whose redis_pool raises on
  # checkout, exercising the `release` rescue path without touching Redis.
  def invoke_server_with_failing_pool(job, &)
    failing_pool = Object.new
    def failing_pool.with(*) = raise('pool down')
    config = Struct.new(:redis_pool).new(failing_pool)

    mw = Wurk::Unique::ServerMiddleware.new
    mw.config = config
    mw.call(nil, job, job['queue'], &)
  end

  def track_key(job)
    @keys << Wurk::Unique.lock_key_for(job)
  end

  def redis_call(*args)
    Wurk.redis { |c| c.call(*args) }
  end

  def observe_death_handlers
    observed = []
    handler = ->(job, ex) { observed << [job['jid'], ex.message] }
    Wurk.configuration.death_handlers << handler
    yield observed
  ensure
    Wurk.configuration.death_handlers.delete(handler)
  end

  # Scripted fake connection for racing the SET NX / GET / SET NX sequence
  # deterministically — a real lock expiry between those calls can't be
  # forced against live Redis.
  def stub_pool(set_results:, get_result:)
    conn = Object.new
    conn.define_singleton_method(:call) do |*args|
      args.first == 'SET' ? set_results.shift : get_result
    end
    pool = Object.new
    pool.define_singleton_method(:with) { |&blk| blk.call(conn) }
    pool
  end

  def drain_sorted_set(sset)
    Wurk::Scheduled::Enq.new(Wurk.configuration).enqueue_jobs([sset])
  end

  # Simulate a failed `unique_until: :success` job: the enqueue-time lock is
  # still held by its own jid while the payload waits in `retry`. Returns the
  # lock key (tracked for teardown).
  def seed_locked_retry_entry(job)
    key = Wurk::Unique.lock_key_for(job)
    @keys << key
    Wurk.redis do |c|
      c.call('SET', key, job['jid'], 'EX', 3600)
      c.call('ZADD', Wurk::Keys::RETRY, (::Time.now.to_f - 1).to_s, Wurk.dump_json(job))
    end
    key
  end

  # Drive a no-retry failure through JobRetry#global so the job dies
  # automatically (death handlers fire, as in retries-exhausted).
  def die_unretryable(job)
    job['retry'] = false
    retrier = Wurk::JobRetry.new(Wurk.configuration)
    assert_raises(Wurk::JobRetry::Handled) do
      retrier.global(Wurk.dump_json(job), job['queue']) { raise 'boom' }
    end
  end

  def with_logger(logger)
    prior = Wurk.logger
    Wurk.configuration.logger = logger
    yield
  ensure
    Wurk.configuration.logger = prior
  end

  # Force `Wurk.logger` to return nil. The config memoizes a default logger
  # (`@logger ||= default_logger`), so assigning nil is not enough — we
  # override the accessor on the singleton for the duration of the block.
  def without_logger
    config = Wurk.configuration
    config.singleton_class.send(:define_method, :logger) { nil }
    yield
  ensure
    config.singleton_class.send(:remove_method, :logger)
  end

  def stub_const(name, klass)
    ::Object.const_set(name, klass)
    yield
  ensure
    ::Object.send(:remove_const, name) if ::Object.const_defined?(name)
  end

  # Stand-in for ActiveSupport::Duration so coerce_ttl handles it correctly
  # without pulling in ActiveSupport.
  def duration_double(seconds)
    Class.new do
      def initialize(secs) = @secs = secs
      def to_i = @secs
      def since(_then) = ::Time.now
      def self.name = 'ActiveSupport::Duration'
    end.new(seconds)
  end
end
