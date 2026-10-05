# frozen_string_literal: true

require_relative '../test_helper'

# ChildBoot#reconnect_after_fork runs inside forked swarm children; the real
# fork path is proven end-to-end by swarm_boot_test. Here we drive its Redis
# side in-process (no fork) against real Redis so the post-fork liveness check
# + Lua cache warm-up is exercised directly. `send` reaches the private
# reconnect because there is no public entry that runs it without the launcher.
class ChildBootTest < Wurk::Test::UnitCase
  parallelize_me!

  # A server whose script cache holds only `cached` SHAs. The real cache is
  # server-global and shared by every parallel worker, so a cold one can't be
  # staged against real Redis without a SCRIPT FLUSH racing the other tests.
  # Counts round trips — one per pipeline, one per direct call.
  class ScriptCacheConn
    attr_reader :round_trips, :loaded

    def initialize(cached)
      @cached = cached
      @round_trips = 0
      @loaded = []
    end

    def call(*args)
      @round_trips += 1
      raise ArgumentError, "unexpected #{args.inspect}" unless args.first(2) == %w[SCRIPT EXISTS]

      args.drop(2).map { |sha| @cached.include?(sha) ? 1 : 0 }
    end

    def pipelined
      @round_trips += 1
      yield self.class::Pipe.new(@loaded)
    end

    Pipe = Struct.new(:loaded) do
      def call(*args) = loaded << args
    end
  end

  # Hands the same connection to every checkout. Swallows RedisPool#with's
  # `idempotent:` keyword — retry behavior is that class's business, not this
  # test's.
  class StubPool
    def initialize(conn)
      @conn = conn
    end

    def with(**) = yield(@conn)
    def disconnect! = nil
  end

  # Records the launcher calls the signal dispatcher makes.
  class FakeLauncher
    attr_reader :events

    def initialize
      @events = []
    end

    def stop
      @events << :stop
    end

    def quiet
      @events << :quiet
    end

    def dump_threads
      @events << :dump_threads
    end
  end

  def setup
    super
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: Wurk::Test.redis_url }
    @boot = Wurk::Swarm::ChildBoot.new(@config, nil, 0)
  end

  def teardown
    @config&.reset_redis_pools!
  ensure
    super
  end

  # --- self-pipe signal dispatch -----------------------------------------

  def test_parent_pid_defaults_to_live_parent
    assert_equal ::Process.ppid, @boot.instance_variable_get(:@parent_pid)
  end

  def test_dispatch_signals_stops_on_term
    launcher = drive_dispatch('TERM')

    assert_equal [:stop], launcher.events
  end

  def test_dispatch_signals_quiets_on_tstp_then_stops
    launcher = drive_dispatch('TSTP', 'TERM')

    assert_equal %i[quiet stop], launcher.events
  end

  def test_dispatch_signals_reopens_logs_on_usr2_then_stops
    # USR2 → reopen_logs (best-effort); TERM ends the loop. The IO::NULL logger
    # reopen is a harmless no-op — we only assert the dispatch reached TERM.
    launcher = drive_dispatch('USR2', 'TERM')

    assert_equal [:stop], launcher.events
  end

  def test_dispatch_signals_dumps_threads_on_ttin_then_stops
    launcher = drive_dispatch('TTIN', 'TERM')

    assert_equal %i[dump_threads stop], launcher.events
  end

  # K16, in a real fork: a quiet relayed into the boot window (reconnect,
  # `:fork` / `:startup` hooks — before install_signal_handlers) used to hit
  # TSTP's default disposition and SUSPEND the child. It must be held and
  # replayed as a quiet once the handlers are in.
  def test_tstp_in_the_boot_window_quiets_instead_of_suspending
    read, write = ::IO.pipe
    pid = ::Process.fork do
      read.close
      write.write(quiet_after_boot_window_tstp ? 'quiet' : 'not-quiet')
      exit!(0)
    end
    write.close
    _, status = ::Process.waitpid2(pid, ::Process::WUNTRACED)
    if status.stopped?
      ::Process.kill('KILL', pid)
      ::Process.waitpid(pid)

      flunk 'a TSTP in the boot window suspended the child'
    end

    assert_equal 'quiet', read.read
  ensure
    read&.close
  end

  def test_install_signal_handlers_wires_self_pipe_dispatch
    with_saved_traps(%w[TERM INT TSTP USR2 TTIN]) do
      launcher = FakeLauncher.new
      @boot.send(:install_signal_handlers, launcher)

      ::Process.kill('TSTP', ::Process.pid)
      wait_until { launcher.events.include?(:quiet) }
      ::Process.kill('TERM', ::Process.pid)
      @boot.instance_variable_get(:@dispatcher).join(2)

      assert_equal %i[quiet stop], launcher.events
    end
  end

  # Reconnect drops the inherited pools, PINGs through a fresh one, and (with
  # ActiveRecord absent in the unit env) returns cleanly — so a live connection
  # exists afterwards where the inherited one was closed.
  def test_reconnect_after_fork_leaves_a_working_pool
    @boot.send(:reconnect_after_fork)

    pong = @config.redis { |c| c.call('PING') }

    assert_equal 'PONG', pong
  end

  # A6: the dogstatsd client is memoized at the class level, so a forked
  # child that skipped this reset would share the parent's UDP socket and
  # thread-locals instead of building its own after fork.
  def test_reconnect_after_fork_resets_the_statsd_client
    Wurk::Metrics::Statsd.instance_variable_set(:@client, :parent_client)

    @boot.send(:reconnect_after_fork)

    assert_nil Wurk::Metrics::Statsd.client
  ensure
    Wurk::Metrics::Statsd.reset!
  end

  def test_validate_redis_leaves_every_lua_script_cached
    @boot.send(:validate_redis!)

    present = @config.redis { |c| c.call('SCRIPT', 'EXISTS', *Wurk::Lua::SHAS.values) }

    assert_equal [1] * Wurk::Lua::SHAS.size, present
  end

  # Against a warm server cache — every child after a fleet's first, every
  # boot after the first against a server — the child's whole Redis validation
  # is ONE round trip carrying SHAs only: no script source rides the
  # boot-critical path.
  #
  # #101 boot-audit: hoisting the upload into the parent was measured and
  # REJECTED — see Swarm#boot. Children reconnect in parallel; the parent's
  # upload would have been serial, ahead of every fork.
  def test_validate_redis_against_a_warm_cache_sends_one_script_exists
    @config.redis { |c| Wurk::Lua::Loader.script_load_all(c) }

    sent = record_capsule_commands { @boot.send(:validate_redis!) }

    assert_equal [['SCRIPT', 'EXISTS', *Wurk::Lua::SHAS.values]], sent
  end

  def test_validate_redis_against_a_cold_cache_uploads_only_what_is_missing
    cached = Wurk::Lua::SHAS.values.each_slice(2).map(&:first)
    conn = ScriptCacheConn.new(cached)
    @config.default_capsule.instance_variable_get(:@pools)[:main] = StubPool.new(conn)

    @boot.send(:validate_redis!)

    missing = Wurk::Lua::SCRIPTS.values.reject { |src| cached.include?(Digest::SHA1.hexdigest(src)) }

    assert_equal 2, conn.round_trips
    assert_equal(missing.map { |src| ['SCRIPT', 'LOAD', src] }, conn.loaded)
  ensure
    @config.reset_redis_pools!
  end

  # #101 boot-audit: `reconnect_active_record` must not itself pay a DB
  # handshake on the child's boot-critical path — `establish_connection`
  # only records the spec; AR opens the real socket lazily on first checkout.
  # Pin that here (not just eyeball it) so a future AR upgrade that changes
  # this can't silently put a DB round trip ahead of `:startup`. Requires
  # `active_record` + `sqlite3` directly (unit env doesn't load them) rather
  # than stubbing, per "never mock" — this is real AR, just an in-memory DB.
  def test_reconnect_active_record_does_not_eagerly_open_a_connection
    require 'active_record'
    require 'sqlite3'
    ::ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    ::ActiveRecord::Base.connection_handler.clear_active_connections!

    @boot.send(:reconnect_active_record)

    assert_equal 0, ::ActiveRecord::Base.connection_pool.stat[:connections]
  ensure
    ::ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(::ActiveRecord::Base)
  end

  private

  # Swaps the default capsule's main pool for a command-recording decorator.
  # Restored (and the real pool dropped) on the way out so the next checkout
  # rebuilds normally.
  def record_capsule_commands
    sent = []
    capsule = @config.default_capsule
    capsule.instance_variable_get(:@pools)[:main] = Wurk::Test::RecordingPool.new(capsule.redis_pool, sent)
    yield
    sent
  ensure
    @config.reset_redis_pools!
  end

  # Drives dispatch_signals synchronously against an injected pipe. Every call
  # must end in TERM so the dispatch loop breaks instead of blocking.
  def drive_dispatch(*signals)
    r, w = ::IO.pipe
    @boot.instance_variable_set(:@signal_read, r)
    signals.each { |s| w.puts(s) }
    launcher = FakeLauncher.new
    @boot.send(:dispatch_signals, launcher)
    launcher
  ensure
    r&.close
    w&.close
  end

  # Runs in the forked child: TSTP after the inherited traps are reset but
  # before the real handlers exist, then the handlers go in.
  def quiet_after_boot_window_tstp
    @boot.send(:reset_inherited_signals)
    ::Process.kill('TSTP', ::Process.pid)
    # The trap runs on the main thread at its next interrupt check; wait for
    # its write rather than guessing how long that takes.
    wait_until { @boot.instance_variable_get(:@pending_tstp) }
    launcher = FakeLauncher.new
    @boot.send(:install_signal_handlers, launcher)
    wait_until { launcher.events.include?(:quiet) }
  end

  def with_saved_traps(signals)
    saved = signals.to_h { |s| [s, ::Signal.trap(s, 'DEFAULT')] }
    yield
  ensure
    saved&.each { |s, h| ::Signal.trap(s, h || 'DEFAULT') }
  end

  def wait_until(timeout = 2)
    deadline = ::Time.now + timeout
    sleep 0.02 until yield || ::Time.now > deadline
    yield
  end
end
