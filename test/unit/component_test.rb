# frozen_string_literal: true

require_relative '../test_helper'

class ComponentTest < Wurk::Test::UnitCase
  parallelize_me!

  # Hostname env tests mutate ENV['DYNO'], which is process-global.
  # Serialize them when the parallel runner is active.
  ENV_MUTEX = Mutex.new

  Host = Struct.new(:config) do
    include Wurk::Component
  end

  def setup
    super
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @host = Host.new(@config)
  end

  # --- clocks ----------------------------------------------------------

  def test_real_ms_returns_integer_epoch_ms
    now = @host.real_ms

    assert_kind_of Integer, now
    assert_operator now, :>, 1_700_000_000_000 # post-2023 sanity
  end

  def test_mono_ms_is_monotonic
    a = @host.mono_ms
    sleep 0.002
    b = @host.mono_ms

    assert_kind_of Integer, a
    assert_operator b, :>=, a
  end

  # --- identity --------------------------------------------------------

  def test_tid_is_base36_string
    assert_match(/\A[0-9a-z]+\z/, @host.tid)
  end

  def test_tid_differs_between_threads
    main = @host.tid
    other = Thread.new { @host.tid }.value

    refute_equal main, other
  end

  def test_hostname_prefers_dyno_env
    ENV_MUTEX.synchronize do
      saved = ENV.fetch('DYNO', nil)
      ENV['DYNO'] = 'web.42'

      assert_equal 'web.42', @host.hostname
    ensure
      saved.nil? ? ENV.delete('DYNO') : ENV['DYNO'] = saved
    end
  end

  def test_hostname_falls_back_to_socket
    ENV_MUTEX.synchronize do
      saved = ENV.delete('DYNO')

      assert_equal Socket.gethostname, @host.hostname
    ensure
      ENV['DYNO'] = saved if saved
    end
  end

  def test_process_nonce_is_12_hex
    assert_match(/\A[0-9a-f]{12}\z/, @host.process_nonce)
  end

  # --- leader? opt-out (#122) ------------------------------------------

  def test_leader_predicate_false_under_wurk_leader_opt_out
    ENV_MUTEX.synchronize do
      saved = ENV.fetch('WURK_LEADER', nil)
      ENV['WURK_LEADER'] = 'false'

      refute_predicate @host, :leader?
    ensure
      saved.nil? ? ENV.delete('WURK_LEADER') : ENV['WURK_LEADER'] = saved
    end
  end

  def test_leader_predicate_false_under_sidekiq_leader_opt_out
    ENV_MUTEX.synchronize do
      saved = ENV.fetch('SIDEKIQ_LEADER', nil)
      ENV['SIDEKIQ_LEADER'] = 'false'

      refute_predicate @host, :leader?
    ensure
      saved.nil? ? ENV.delete('SIDEKIQ_LEADER') : ENV['SIDEKIQ_LEADER'] = saved
    end
  end

  def test_process_nonce_stable_within_process
    assert_equal @host.process_nonce, @host.process_nonce
  end

  def test_process_nonce_shared_across_instances
    other = Host.new(@config)

    assert_equal @host.process_nonce, other.process_nonce
  end

  def test_identity_format
    expected = "#{@host.hostname}:#{Process.pid}:#{@host.process_nonce}"

    assert_equal expected, @host.identity
  end

  def test_default_tag_uses_pwd_basename
    assert_equal File.basename(Dir.pwd), @host.default_tag
  end

  def test_default_tag_accepts_explicit_dir
    assert_equal 'foo', @host.default_tag('/tmp/bar/foo')
  end

  # --- delegates ------------------------------------------------------

  def test_logger_delegates_to_config
    assert_same @config.logger, @host.logger
  end

  def test_handle_exception_delegates_to_config
    seen = []
    @config.error_handlers << ->(ex, ctx, _cfg) { seen << [ex.message, ctx] }

    @host.handle_exception(StandardError.new('boom'), { jid: '1' })

    assert_equal [['boom', { jid: '1' }]], seen
  end

  # --- watchdog -------------------------------------------------------

  def test_watchdog_returns_block_value
    assert_equal 42, @host.watchdog('label') { 42 }
  end

  def test_watchdog_reraises_after_reporting
    seen = []
    @config.error_handlers << ->(ex, _ctx, _cfg) { seen << ex.message }

    assert_raises(RuntimeError) { @host.watchdog('thing') { raise 'kaboom' } }
    assert_equal ['kaboom'], seen
  end

  def test_watchdog_passes_label_as_context
    seen = []
    @config.error_handlers << ->(_ex, ctx, _cfg) { seen << ctx }

    assert_raises(RuntimeError) { @host.watchdog('component-x') { raise 'x' } }
    assert_equal [{ context: 'component-x' }], seen
  end

  # --- safe_thread ----------------------------------------------------

  def test_safe_thread_runs_block
    q = Queue.new
    t = @host.safe_thread('runner') { q << :ran }
    t.join

    assert_equal :ran, q.pop
  end

  def test_safe_thread_sets_thread_name
    q = Queue.new
    t = @host.safe_thread('the-name') { q << Thread.current.name }
    t.join

    assert_equal 'the-name', q.pop
  end

  def test_safe_thread_default_priority
    q = Queue.new
    t = @host.safe_thread('p') { q << Thread.current.priority }
    t.join

    assert_equal Wurk::Component::DEFAULT_THREAD_PRIORITY, q.pop
  end

  def test_safe_thread_honors_explicit_priority
    q = Queue.new
    t = @host.safe_thread('p', priority: -3) { q << Thread.current.priority }
    t.join

    assert_equal(-3, q.pop)
  end

  def test_safe_thread_reports_errors
    io = StringIO.new
    @config.logger = ::Logger.new(io)

    t = @host.safe_thread('boom') { raise 'thread boom' }
    begin
      t.join
    rescue StandardError
      # watchdog reraises; the thread dies as expected
    end

    assert_match(/thread boom/, io.string)
  end

  # --- fire_event -----------------------------------------------------

  def test_fire_event_invokes_in_order
    fired = []
    @config.on(:startup) { fired << :a }
    @config.on(:startup) { fired << :b }

    @host.fire_event(:startup)

    assert_equal %i[a b], fired
  end

  def test_fire_event_reverse_runs_lifo
    fired = []
    @config.on(:shutdown) { fired << :first }
    @config.on(:shutdown) { fired << :second }

    @host.fire_event(:shutdown, reverse: true)

    assert_equal %i[second first], fired
  end

  def test_fire_event_oneshot_clears_after_dispatch
    n = 0
    @config.on(:startup) { n += 1 }

    @host.fire_event(:startup)
    @host.fire_event(:startup)

    assert_equal 1, n
  end

  def test_fire_event_oneshot_false_preserves_bucket
    n = 0
    @config.on(:beat) { n += 1 }

    @host.fire_event(:beat, oneshot: false)
    @host.fire_event(:beat, oneshot: false)

    assert_equal 2, n
  end

  def test_fire_event_continues_after_handler_error
    fired = []
    @config.on(:startup) { raise 'first' }
    @config.on(:startup) { fired << :second }

    @host.fire_event(:startup)

    assert_equal [:second], fired
  end

  def test_fire_event_reraise_propagates
    @config.on(:startup) { raise 'fatal' }

    assert_raises(RuntimeError) { @host.fire_event(:startup, reraise: true) }
  end

  def test_fire_event_empty_bucket_noops
    @host.fire_event(:heartbeat) # no callbacks registered
  end
end
