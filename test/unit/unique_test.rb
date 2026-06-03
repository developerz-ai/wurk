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

  def track_key(job)
    @keys << Wurk::Unique.lock_key_for(job)
  end

  def with_logger(logger)
    prior = Wurk.logger
    Wurk.configuration.logger = logger
    yield
  ensure
    Wurk.configuration.logger = prior
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
