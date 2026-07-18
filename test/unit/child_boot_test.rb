# frozen_string_literal: true

require_relative '../test_helper'

# ChildBoot#reconnect_after_fork runs inside forked swarm children; the real
# fork path is proven end-to-end by swarm_boot_test. Here we drive its Redis
# side in-process (no fork) against real Redis so the post-fork PING + eager
# pipelined script-load logic is exercised directly. `send` reaches the private
# reconnect because there is no public entry that runs it without the launcher.
class ChildBootTest < Wurk::Test::UnitCase
  parallelize_me!

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

  # PINGs, primes every Lua script, and (with ActiveRecord absent in unit env)
  # returns cleanly. A live-cache SCRIPT FLUSH would race peer workers that
  # share the global script cache, so we assert the end state: all SHAs present.
  def test_reconnect_after_fork_primes_every_lua_script
    @boot.send(:reconnect_after_fork)

    shas    = Wurk::Lua::SHAS.values
    present = @config.redis { |c| c.call('SCRIPT', 'EXISTS', *shas) }

    assert(present.all? { |v| v == 1 }, "post-fork boot must leave every script cached, got #{present.inspect}")
  end

  def test_validate_redis_pings_then_pipelines_every_script_load
    result = @boot.send(:validate_redis!)

    # #with returns the block value; script_load_all is the last expression, so
    # its one-SHA-per-script pipeline result proves both the PING (which would
    # have raised first) and the eager load ran on the same checkout.
    assert_equal Wurk::Lua::SCRIPTS.size, result.size
  end

  private

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
