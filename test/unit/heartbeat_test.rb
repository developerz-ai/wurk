# frozen_string_literal: true

require_relative '../test_helper'

# Drives Wurk::Heartbeat against real Redis. Each test owns a unique
# identity so parallel runs can't collide on the global `processes` SET
# or per-identity HASH/LIST keys.
class HeartbeatTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns = "hb-#{Process.pid}-#{object_id}"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    cap = @config.default_capsule
    cap.queues = ['default']
    cap.concurrency = 3
    @config[:tag] = @ns
    @pool = cap.redis_pool
    @identity = "host-#{@ns}:1234:#{object_id.to_s(16)}"
    @cleanup_keys = [@identity, "#{@identity}:work", "#{@identity}-signals"]
  end

  def teardown
    @pool.with do |c|
      c.call('SREM', Wurk::Keys::PROCESSES, @identity)
      @cleanup_keys.each { |k| c.call('UNLINK', k) }
    end
  ensure
    super
  end

  # --- shape ----------------------------------------------------------

  def test_constants
    assert_equal 10, Wurk::Heartbeat::BEAT_PAUSE
    assert_equal 60, Wurk::Heartbeat::TTL_SECONDS
  end

  def test_includes_component
    assert_includes Wurk::Heartbeat.ancestors, Wurk::Component
  end

  # --- beat! writes -----------------------------------------------------

  def test_beat_adds_identity_to_processes_set
    hb = build_heartbeat

    hb.beat!
    member = @pool.with { |c| c.call('SISMEMBER', Wurk::Keys::PROCESSES, @identity) }

    assert_equal 1, member
  end

  def test_beat_sets_ttl_on_identity_hash
    hb = build_heartbeat

    hb.beat!
    ttl = @pool.with { |c| c.call('TTL', @identity).to_i }

    assert_operator ttl, :>, 0
    assert_operator ttl, :<=, Wurk::Heartbeat::TTL_SECONDS
  end

  def test_beat_writes_info_version_and_identity
    hb = build_heartbeat

    hb.beat!
    info = read_info

    assert_equal Wurk::VERSION, info['version']
    assert_equal @identity, info['identity']
  end

  # Additive host facts ride the info JSON so the dashboard can group the
  # Busy page by machine. cpu_model may legitimately be nil on exotic
  # platforms; cores and total memory must be positive on any CI box.
  def test_beat_writes_host_hardware_facts
    hb = build_heartbeat

    hb.beat!
    info = read_info

    assert_operator info['cores'], :>, 0
    assert_operator info['memory_total_kb'], :>, 0
    assert_kind_of String, info['cpu_model'] if info['cpu_model']
  end

  def test_host_facts_are_memoized_per_instance
    hb = build_heartbeat

    first = hb.send(:host_facts)

    assert_same first, hb.send(:host_facts)
  end

  # Etc raises NotImplementedError (a ScriptError, not StandardError) on
  # platforms without sysconf — a heartbeat must degrade to nil, never die.
  # Injected seam instead of patching ::Etc: parallelize_me! runs the other
  # host-facts tests concurrently in this process.
  def test_cores_is_nil_when_etc_raises
    hb = build_heartbeat
    raising_etc = Object.new
    raising_etc.define_singleton_method(:nprocessors) { raise NotImplementedError }

    assert_nil hb.send(:cores, raising_etc)
  end

  # Regression: File.foreach(path).find { } never closes the underlying
  # File — the Enumerator (and its FD) is abandoned until GC finalizes it.
  # cpu_model/memory_total_kb must read via File.open with a block so the
  # FD closes deterministically on return, not on the next GC pass.
  # Minitest 6 dropped minitest/mock; a singleton override on the ::File
  # class object is the stub.
  def test_cpu_model_does_not_use_file_foreach
    skip 'no /proc/cpuinfo on this platform' unless ::File.exist?('/proc/cpuinfo')

    hb = build_heartbeat
    with_file_foreach_disabled do
      result = hb.send(:cpu_model)

      assert_kind_of String, result if result
    end
  end

  def test_memory_total_kb_does_not_use_file_foreach
    skip 'no /proc/meminfo on this platform' unless ::File.exist?('/proc/meminfo')

    hb = build_heartbeat
    with_file_foreach_disabled do
      result = hb.send(:memory_total_kb)

      assert_operator result, :>, 0
    end
  end

  def test_beat_writes_info_tag_and_embedded_default
    hb = build_heartbeat

    hb.beat!
    info = read_info

    assert_equal @ns, info['tag']
    refute info['embedded']
  end

  def test_beat_writes_embedded_flag_when_set
    hb = build_heartbeat(embedded: true)

    hb.beat!
    info = read_info

    assert info['embedded']
  end

  def test_beat_writes_beat_fields
    hb = build_heartbeat

    hb.beat!
    fields = read_beat_fields

    assert_equal '3', fields[0]     # concurrency (cap.concurrency=3)
    assert_equal '0', fields[1]     # busy (WORK_STATE empty)
    assert_equal 'false', fields[3] # quiet (default callable)
  end

  def test_beat_writes_quiet_true_when_callable_returns_true
    flag = true
    hb = build_heartbeat(quiet: -> { flag })

    hb.beat!
    fields = read_beat_fields

    assert_equal 'true', fields[3]
  end

  # --- :heartbeat / :beat events ---------------------------------------

  def test_beat_fires_heartbeat_event_only_on_first_beat
    fires = 0
    @config.on(:heartbeat) { fires += 1 }
    hb = build_heartbeat

    hb.beat!
    hb.beat!

    assert_equal 1, fires
  end

  def test_beat_fires_beat_event_every_call
    fires = 0
    @config.on(:beat) { fires += 1 }
    hb = build_heartbeat

    hb.beat!
    hb.beat!
    hb.beat!

    assert_equal 3, fires
  end

  def test_beat_rearms_first_heartbeat_after_redis_error
    hb = build_heartbeat

    hb.beat!

    refute hb.instance_variable_get(:@first_heartbeat),
           'first beat must clear @first_heartbeat'

    hb.define_singleton_method(:redis) { |&_blk| raise 'down' }
    hb.beat!

    assert hb.instance_variable_get(:@first_heartbeat),
           '@first_heartbeat must be re-armed when beat raises'
  end

  def test_beat_refires_heartbeat_on_recovery_with_fresh_hook
    fires = 0
    hb = build_heartbeat

    @config.on(:heartbeat) { fires += 1 }
    hb.beat!  # fires :heartbeat, oneshot clears the bucket

    hb.define_singleton_method(:redis) { |&_blk| raise 'down' }
    hb.beat!  # raises → @first_heartbeat re-armed
    hb.singleton_class.send(:remove_method, :redis)

    @config.on(:heartbeat) { fires += 1 }
    hb.beat!  # recovers → :heartbeat fires again

    assert_equal 2, fires
  end

  def test_beat_returns_nil_on_redis_error
    hb = build_heartbeat
    hb.define_singleton_method(:redis) { |&_blk| raise 'down' }

    assert_nil hb.beat!
  end

  # --- work hash mirror ------------------------------------------------

  def test_beat_unlinks_work_hash_when_no_in_flight
    Wurk::Processor::WORK_STATE.clear
    @pool.with { |c| c.call('HSET', "#{@identity}:work", 'stale-tid', '{}') }
    hb = build_heartbeat

    hb.beat!
    exists = @pool.with { |c| c.call('EXISTS', "#{@identity}:work") }

    assert_equal 0, exists
  end

  def test_beat_repopulates_work_hash_from_work_state
    tid = "hb-tid-#{object_id}"
    Wurk::Processor::WORK_STATE.set(tid, queue: 'q', payload: 'p', run_at: 1)
    hb = build_heartbeat

    begin
      hb.beat!
      hash = work_hash

      assert_includes hash.keys, tid
    ensure
      Wurk::Processor::WORK_STATE.delete(tid)
    end
  end

  def test_beat_sets_ttl_on_work_hash_when_populated
    tid = "hb-tid-ttl-#{object_id}"
    Wurk::Processor::WORK_STATE.set(tid, queue: 'q', payload: 'p', run_at: 1)
    hb = build_heartbeat

    begin
      hb.beat!
      ttl = @pool.with { |c| c.call('TTL', "#{@identity}:work").to_i }

      assert_operator ttl, :>, 0
      assert_operator ttl, :<=, Wurk::Heartbeat::TTL_SECONDS
    ensure
      Wurk::Processor::WORK_STATE.delete(tid)
    end
  end

  # --- signal drain ----------------------------------------------------

  def test_beat_drains_signal_list_and_returns_signals
    sig_key = "#{@identity}-signals"
    @pool.with do |c|
      c.call('LPUSH', sig_key, 'TERM')
      c.call('LPUSH', sig_key, 'TSTP')
    end
    hb = build_heartbeat

    sigs = hb.beat!
    remaining = @pool.with { |c| c.call('LLEN', sig_key) }

    assert_equal 0, remaining.to_i
    assert_equal %w[TSTP TERM], sigs
  end

  def test_beat_returns_empty_array_when_no_signals
    hb = build_heartbeat

    sigs = hb.beat!

    assert_equal [], sigs
  end

  # The drain is a second checkout that runs only after the identity write
  # returns, so a failed beat leaves every queued signal in Redis for the next
  # one. Popping first would swallow a dashboard TERM into the beat! rescue.
  def test_failed_identity_write_leaves_signals_queued
    sig_key = "#{@identity}-signals"
    @pool.with { |c| c.call('LPUSH', sig_key, 'TERM') }
    hb = build_heartbeat

    # Minitest 6 dropped minitest/mock; a singleton override is the stub.
    hb.define_singleton_method(:write_beat) { |*| raise 'beat write failed' }

    sigs = hb.beat!
    remaining = @pool.with { |c| c.call('LLEN', sig_key) }

    assert_nil sigs
    assert_equal 1, remaining.to_i
  end

  # --- stop! -----------------------------------------------------------

  def test_stop_removes_identity_from_processes_set
    hb = build_heartbeat
    hb.beat!

    hb.stop!
    member = @pool.with { |c| c.call('SISMEMBER', Wurk::Keys::PROCESSES, @identity) }

    assert_equal 0, member
  end

  def test_stop_unlinks_identity_and_work_hashes
    hb = build_heartbeat
    hb.beat!
    @pool.with { |c| c.call('HSET', "#{@identity}:work", 't', '{}') }

    hb.stop!
    exists_id, exists_work = @pool.with do |c|
      [c.call('EXISTS', @identity), c.call('EXISTS', "#{@identity}:work")]
    end

    assert_equal 0, exists_id
    assert_equal 0, exists_work
  end

  def test_stop_is_safe_when_redis_raises
    hb = build_heartbeat
    hb.define_singleton_method(:redis) { |&_blk| raise 'down' }

    assert_nil hb.stop!
  end

  # --- statsd queue-size emission --------------------------------------

  # emit_queue_sizes early-returns when the config exposes no queues (the
  # `queues.empty?` then-branch). With a live statsd client wired but zero
  # queues, the beat must still succeed and emit only the `busy` gauge — no
  # `queue.size` LLEN pipeline. Holds STATSD_MUTEX because Statsd.@client is
  # a process-global other suites also rewrite.
  def test_beat_skips_queue_sizes_when_no_queues_configured
    Wurk::Test::STATSD_MUTEX.synchronize do
      recorder = []
      fake_client = build_statsd_client(recorder)
      hb = build_heartbeat
      # A capsule that exposes no queues ⇒ flat_map(&:queues).uniq is empty ⇒
      # emit_queue_sizes returns early. queues= rejects [], so set @queues
      # directly to model the empty-queue edge the guard exists for.
      @config.capsules.each_value { |cap| cap.instance_variable_set(:@queues, []) }

      Wurk::Metrics::Statsd.instance_variable_set(:@client, fake_client)
      begin
        refute_nil hb.beat!
      ensure
        Wurk::Metrics::Statsd.reset!
      end

      assert_includes recorder.map { |m| m[1] }, 'sidekiq.busy'
      refute_includes recorder.map { |m| m[1] }, 'sidekiq.queue.size'
    end
  end

  # --- memory_usage_kb ps fallback -------------------------------------

  # On a host without /proc/self/statm (macOS/BSD), memory_usage_kb takes the
  # `ps` else-branch. We force that branch by stubbing ::File.exist? for the
  # statm path only; everything else delegates to the real implementation.
  def test_beat_uses_ps_fallback_when_proc_statm_absent
    original = ::File.method(:exist?)
    ::File.singleton_class.send(:define_method, :exist?) do |path|
      path == '/proc/self/statm' ? false : original.call(path)
    end
    hb = build_heartbeat

    begin
      refute_nil hb.beat!
      rss = read_beat_fields[4] # 'rss'

      refute_nil rss
      assert_match(/\A\d+\z/, rss)
    ensure
      ::File.singleton_class.send(:define_method, :exist?, original)
    end
  end

  private

  def build_statsd_client(recorder)
    client = Object.new
    client.define_singleton_method(:gauge) { |metric, value, **opts| recorder << [:gauge, metric, value, opts] }
    client.define_singleton_method(:increment) { |metric, **opts| recorder << [:increment, metric, opts] }
    client
  end

  def build_heartbeat(embedded: false, quiet: nil)
    Wurk::Heartbeat.new(
      identity: @identity,
      config: @config,
      started_at: Time.now.to_f,
      embedded: embedded,
      quiet: quiet
    )
  end

  def read_info
    Wurk.load_json(@pool.with { |c| c.call('HGET', @identity, 'info') })
  end

  def with_file_foreach_disabled
    original = ::File.method(:foreach)
    ::File.define_singleton_method(:foreach) { |*| raise 'must not use File.foreach — abandons the FD until GC' }
    yield
  ensure
    ::File.define_singleton_method(:foreach, original)
  end

  def read_beat_fields
    @pool.with { |c| c.call('HMGET', @identity, 'concurrency', 'busy', 'beat', 'quiet', 'rss', 'rtt_us') }
  end

  def work_hash
    raw = @pool.with { |c| c.call('HGETALL', "#{@identity}:work") }
    raw.is_a?(Hash) ? raw : Hash[*raw]
  end
end
