# frozen_string_literal: true

require_relative '../test_helper'

# Swarm::Liveness against injected fakes: a hand-cranked clock, a beats table
# the test edits, and a kill log. The real-fork path is covered by
# test/integration/swarm_liveness_test.rb.
class SwarmLivenessTest < Wurk::Test::UnitCase
  parallelize_me!

  TIMEOUT = 60
  KILL_AFTER = 30
  BOOT_GRACE = 30

  def setup
    @now = 0.0
    @beats = {}
    @kills = []
    @probe_error = nil
    @log = StringIO.new
    @liveness = Wurk::Swarm::Liveness.new(Wurk::Swarm::Liveness::Config.new(
                                            beats: lambda { |pids|
                                              raise @probe_error if @probe_error

                                              pids.to_h { |pid| [pid, @beats[pid]] }
                                            },
                                            kill: ->(pid, sig) { @kills << [pid, sig] },
                                            now: -> { @now },
                                            logger: ::Logger.new(@log),
                                            timeout: TIMEOUT, kill_after: KILL_AFTER, boot_grace: BOOT_GRACE,
                                            check_interval: 5
                                          ))
  end

  def test_moving_heartbeat_is_never_judged
    20.times do |i|
      @beats[1] = i.to_s
      advance(10)
    end

    assert_empty @kills
  end

  def test_stale_heartbeat_gets_term_then_kill
    @beats[1] = 'b1'
    advance(0)
    advance(TIMEOUT + 5)

    assert_equal [[1, 'TERM']], @kills
    assert_match(/child 1 heartbeat stale .*sending TERM/, @log.string)

    advance(KILL_AFTER - 1)

    assert_equal [[1, 'TERM']], @kills, 'no KILL before kill_after'

    advance(2)

    assert_equal [[1, 'TERM'], [1, 'KILL']], @kills
    assert_match(/still running .*sending KILL/, @log.string)

    advance(KILL_AFTER * 2)

    assert_equal 2, @kills.size, 'KILL is sent once'

    @liveness.forget(1)

    assert_match(/unresponsive child 1 exited/, @log.string)
    refute @liveness.terminating?(1)
  end

  def test_expired_identity_counts_as_stale_from_the_last_moving_beat
    @beats[1] = 'b1'
    advance(0)
    @beats[1] = nil # TTL expired
    advance(TIMEOUT - 10)

    assert_empty @kills

    advance(20)

    assert_equal [[1, 'TERM']], @kills
  end

  def test_never_beaten_child_gets_the_boot_grace
    advance(0)
    advance(TIMEOUT + BOOT_GRACE - 5)

    assert_empty @kills

    advance(10)

    assert_equal [[1, 'TERM']], @kills
  end

  def test_paused_forgets_progress_and_never_terms
    @beats[1] = 'b1'
    advance(0)
    advance(TIMEOUT * 3, paused: true)

    assert_empty @kills

    advance(5) # first look after the pause re-seeds

    assert_empty @kills

    advance(TIMEOUT + 5)

    assert_equal [[1, 'TERM']], @kills
  end

  def test_kill_escalation_continues_while_paused
    @beats[1] = 'b1'
    advance(0)
    advance(TIMEOUT + 5)
    advance(KILL_AFTER + 1, paused: true)

    assert_equal [[1, 'TERM'], [1, 'KILL']], @kills
  end

  def test_probe_failure_does_not_judge_and_restarts_every_window
    @beats[1] = 'b1'
    advance(0)
    @probe_error = RedisClient::CannotConnectError.new('down')
    advance(TIMEOUT * 2)

    assert_empty @kills
    assert_match(/liveness probe failed/, @log.string)

    @probe_error = nil
    advance(5)

    assert_empty @kills, 'Redis just came back — children get a fresh window'

    advance(TIMEOUT + 5)

    assert_equal [[1, 'TERM']], @kills
  end

  def test_checks_are_rate_limited
    calls = 0
    liveness = Wurk::Swarm::Liveness.new(Wurk::Swarm::Liveness::Config.new(
                                           beats: lambda { |pids|
                                             calls += 1
                                             pids.to_h { |pid| [pid, 'x'] }
                                           },
                                           kill: ->(*) {}, now: -> { @now }, logger: ::Logger.new(IO::NULL),
                                           timeout: TIMEOUT, kill_after: KILL_AFTER, boot_grace: BOOT_GRACE
                                         ))
    10.times do
      liveness.tick([1], paused: false)
      @now += 0.2
    end

    assert_equal 1, calls

    @now += 10
    liveness.tick([], paused: false)

    assert_equal 1, calls, 'an empty fleet is not probed'
  end

  def test_timeout_from
    assert_equal 60, Wurk::Swarm::Liveness.timeout_from(nil)
    assert_nil Wurk::Swarm::Liveness.timeout_from(false)
    assert_nil Wurk::Swarm::Liveness.timeout_from(0)
    assert_in_delta 90.0, Wurk::Swarm::Liveness.timeout_from('90')
    assert_raises(ArgumentError) { Wurk::Swarm::Liveness.timeout_from(5) }
  end

  def test_swarm_builds_no_supervisor_when_disabled
    config = Wurk::Configuration.new
    swarm = Wurk::Swarm.new(topology: Wurk::Topology.flat(count: 1, queues: ['q'], concurrency: 1),
                            config: config, heartbeat_timeout: false)

    assert_nil swarm.instance_variable_get(:@liveness)
  end

  # The swarm-side wiring of `paused:` — quiet and an in-flight restart.
  def test_swarm_pauses_liveness_while_quiet_or_restarting
    swarm = Wurk::Swarm.new(topology: Wurk::Topology.flat(count: 1, queues: ['q'], concurrency: 1),
                            config: Wurk::Configuration.new)
    recorder = Class.new do
      attr_reader :calls

      def initialize = @calls = []
      def tick(pids, paused:) = @calls << [pids, paused]
    end.new
    swarm.instance_variable_set(:@liveness, recorder)
    swarm.instance_variable_get(:@children)[42] = { index: 0 }

    swarm.send(:check_liveness)
    swarm.instance_variable_get(:@restart).enqueue([42])
    swarm.send(:check_liveness)
    swarm.instance_variable_get(:@restart).abort
    swarm.instance_variable_set(:@quieted, true)
    swarm.send(:check_liveness)

    assert_equal [[[42], false], [[42], true], [[42], true]], recorder.calls
  end

  private

  def advance(seconds, paused: false)
    @now += seconds
    @liveness.tick([1], paused: paused)
  end
end
