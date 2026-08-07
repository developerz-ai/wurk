# frozen_string_literal: true

require_relative '../test_helper'

# ChildBoot#reconnect_after_fork runs inside forked swarm children; the real
# fork path is proven end-to-end by swarm_boot_test. Here we drive its Redis
# side in-process (no fork) against real Redis so the post-fork PING + eager
# pipelined script-load logic is exercised directly. `send` reaches the private
# reconnect because there is no public entry that runs it without the launcher.
class ChildBootTest < Wurk::Test::UnitCase
  parallelize_me!

  # Counts round trips — one per pipeline, one per direct call — and nothing
  # else; a `PING` plus a separate pipelined upload sends the same commands and
  # returns the same replies, so only the count can tell the one-trip form from
  # the two-trip one. What is actually sent is asserted against real Redis.
  class RoundTripCountingConn
    attr_reader :round_trips

    def initialize
      @round_trips = 0
    end

    def call(*_args)
      @round_trips += 1
      nil
    end

    def pipelined
      @round_trips += 1
      yield Pipe.new
      []
    end

    # Buffered commands cost nothing on their own — the enclosing pipeline is
    # the round trip.
    class Pipe
      def call(*_args) = nil
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

  def test_install_signal_handlers_wires_self_pipe_dispatch
    with_saved_traps(%w[TERM INT TSTP USR2]) do
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

  def test_validate_redis_pings_the_fresh_pool
    assert_equal 'PONG', @boot.send(:validate_redis!).first
  end

  # The child's whole Redis validation is ONE round trip: the liveness PING and
  # the eager Lua upload ride in the same pipeline. `SCRIPT EXISTS` can't catch
  # a regression here — every parallel worker shares one server-global script
  # cache — so assert on what the child actually sends, and on the single batch
  # of replies that comes back (two round trips can't produce one).
  #
  # #101 boot-audit: hoisting the upload into the parent (children PING only)
  # was measured and REJECTED — see Swarm#boot. Children reconnect in parallel;
  # the parent's upload would have been serial, ahead of every fork.
  def test_validate_redis_uploads_every_lua_script_in_the_ping_round_trip
    replies = nil
    sent = record_capsule_commands { replies = @boot.send(:validate_redis!) }

    assert_equal %w[PING], sent.first
    assert_equal Wurk::Lua::SCRIPTS.size + 1, sent.size, 'nothing else may ride the boot-critical round trip'
    assert_equal ['PONG', *Wurk::Lua::SHAS.values], replies,
                 'the PING reply and every uploaded SHA must come back together'
  end

  # The saving itself: the child's whole Redis validation costs ONE round trip.
  # A separate `PING` ahead of the upload sends the same commands and returns
  # the same replies, so the test above cannot see the difference — this can.
  def test_validate_redis_costs_a_single_round_trip
    conn = RoundTripCountingConn.new
    capsule = @config.default_capsule
    capsule.instance_variable_set(:@redis_pool, StubPool.new(conn))

    @boot.send(:validate_redis!)

    assert_equal 1, conn.round_trips
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
    capsule.instance_variable_set(:@redis_pool, Wurk::Test::RecordingPool.new(capsule.redis_pool, sent))
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
