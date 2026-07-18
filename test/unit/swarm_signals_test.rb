# frozen_string_literal: true

require_relative '../test_helper'

# Self-pipe signal handling of Wurk::Swarm, driven fork-free. fork_child hands
# back fake PIDs and shutdown/relay are captured, so the trap → pipe → drain
# dispatch is asserted without real processes or poisoning the runner's signal
# handlers. The real-signal proof lives in the integration layer.
class SwarmSignalsTest < Wurk::Test::UnitCase
  parallelize_me!

  # Fork-free swarm that records the drain-side effects instead of touching
  # real children.
  class SignalSpySwarm < Wurk::Swarm
    attr_reader :shutdown_calls, :relayed

    def initialize(**kwargs)
      super
      @shutdown_calls = 0
      @relayed = []
      @fake_pid = 9000
    end

    def shutdown(**)
      @shutdown_calls += 1
    end

    private

    def fork_child(_slot, _idx)
      @fake_pid += 1
    end

    def relay_signal(sig)
      @relayed << sig
    end
  end

  def setup
    super
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
  end

  # --- drain dispatch (injected pipe, no real traps) ---------------------

  def test_drain_signals_is_a_noop_without_a_pipe
    swarm = booted

    swarm.send(:drain_signals) # @signal_read is nil in the install_signals:false path

    assert_equal 0, swarm.shutdown_calls
  end

  def test_read_pending_signal_returns_nil_when_pipe_empty
    swarm = booted
    inject_pipe(swarm)

    assert_nil swarm.send(:read_pending_signal)
  end

  def test_term_signal_drains
    swarm = booted
    feed(swarm, 'TERM')

    swarm.send(:drain_signals)

    assert_equal 1, swarm.shutdown_calls
  end

  def test_tstp_signal_relays_quiet
    swarm = booted
    feed(swarm, 'TSTP')

    swarm.send(:drain_signals)

    assert_equal ['TSTP'], swarm.relayed
  end

  def test_usr1_signal_enqueues_a_rolling_restart
    swarm = booted
    feed(swarm, 'USR1')

    swarm.send(:drain_signals)

    refute_predicate swarm.instance_variable_get(:@restart), :idle?
  end

  def test_drain_processes_every_buffered_signal_in_one_tick
    swarm = booted
    feed(swarm, 'TSTP', 'TSTP', 'TERM')

    swarm.send(:drain_signals)

    assert_equal %w[TSTP TSTP], swarm.relayed
    assert_equal 1, swarm.shutdown_calls
  end

  # --- real trap install (restores the runner's handlers) ----------------

  def test_install_signal_handlers_wires_the_self_pipe_trap
    with_saved_traps(%w[TERM INT TSTP USR1]) do
      swarm = booted # fake children so a rolling restart has a slot to queue
      swarm.send(:install_signal_handlers)

      assert swarm.instance_variable_get(:@signal_read), 'a read end must be opened'

      ::Process.kill('USR1', ::Process.pid) # trapped → writes to the pipe, does not terminate
      swarm.instance_variable_get(:@signal_read).wait_readable(1)
      swarm.send(:drain_signals)

      refute_predicate swarm.instance_variable_get(:@restart), :idle?,
                       'the trapped USR1 must reach the rolling-restart machine'
    end
  end

  private

  def topology
    Wurk::Topology.flat(count: 1, queues: ['default'], concurrency: 1)
  end

  def booted
    swarm = SignalSpySwarm.new(topology: topology, config: @config)
    swarm.boot(install_signals: false)
    swarm
  end

  def inject_pipe(swarm)
    r, w = ::IO.pipe
    swarm.instance_variable_set(:@signal_read, r)
    swarm.instance_variable_set(:@signal_write, w)
    [r, w]
  end

  def feed(swarm, *signals)
    _r, w = inject_pipe(swarm)
    signals.each { |s| w.puts(s) }
  end

  # Snapshots and restores the process's disposition for `signals` so a test
  # that installs real traps can't leak them into the rest of the run.
  def with_saved_traps(signals)
    saved = signals.to_h { |s| [s, ::Signal.trap(s, 'DEFAULT')] }
    yield
  ensure
    saved&.each { |s, h| ::Signal.trap(s, h || 'DEFAULT') }
  end
end
