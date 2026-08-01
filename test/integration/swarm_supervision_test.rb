# frozen_string_literal: true

require_relative '../test_helper'

# Real forks, real Redis, real signals. Proves the three behaviors #101's
# swarm-supervision slice added that the unit-level fake-fork suites
# (swarm_backoff_test.rb, swarm_restart_test.rb, swarm_orphan_guard_test.rb)
# can't: (1) the supervise loop truly never blocks the process on a crash-loop
# backoff or an in-flight restart, (2) a replacement that dies before
# heartbeating leaves the old child alone and gets retried, (3) an orphaned
# child really does self-terminate. NEVER mock Redis here.
class SwarmSupervisionTest < Wurk::Test::UnitCase
  parallelize_me!

  POLL_TIMEOUT = 20.0
  POLL_INTERVAL = 0.1
  SHUTDOWN_TIMEOUT = 5

  def setup
    super
    @ns = "swarmsup-#{::Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: Wurk::Test.redis_url }
    @config[:timeout] = SHUTDOWN_TIMEOUT
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @observer&.call('DEL', "#{@ns}-crash-log", "queue:#{@queue_name}", private_queue_key(@queue_name))
    @observer&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  # --- crash-loop backoff, in-process (no real signal needed) ------------

  # A slot whose child crashes at boot must respawn on a growing schedule
  # (1s -> 2s -> 4s ...) and the supervise loop must still honor a shutdown
  # instantly even while a slot's respawn is armed for the future — the old
  # bug slept the respawn delay inline on the supervise thread.
  def test_crash_loop_backoff_grows_and_term_drains_while_pending
    key = "#{@ns}-crash-log"
    install_crash_on_startup(key)
    swarm = Wurk::Swarm.new(topology: topology_n(1), config: @config, shutdown_timeout: SHUTDOWN_TIMEOUT)
    supervisor = nil

    begin
      swarm.boot(install_signals: false)
      supervisor = Thread.new { swarm.supervise }

      assert_growing_backoff(key)
      assert_drains_promptly_while_backoff_pending(swarm)
    ensure
      # A failed assertion must not leave the crash-loop respawning forever;
      # shutdown is idempotent so the happy path's drain isn't double-counted.
      begin
        swarm.shutdown(timeout: SHUTDOWN_TIMEOUT)
      rescue StandardError
        nil
      end
      stop_supervisor_thread(supervisor, 10)
    end
  end

  # --- rolling restart: replacement dies before heartbeat -----------------

  # Killing the replacement while it's still awaiting heartbeat must NOT take
  # the old (still-healthy) child down with it, and the slot must be retried
  # (a fresh replacement spawned) once the restart's own backoff elapses.
  def test_kill_replacement_mid_restart_keeps_old_child_and_retries_slot
    swarm = Wurk::Swarm.new(topology: topology_n(1), config: @config, shutdown_timeout: SHUTDOWN_TIMEOUT)
    supervisor = nil

    begin
      original = swarm.boot(install_signals: false).first
      supervisor = Thread.new { swarm.supervise }

      swarm.rolling_restart
      replacement = kill_the_replacement(swarm, original)

      assert_old_child_survives(swarm, original)

      retried = wait_for_new_child(swarm, exclude: [original, replacement])

      assert retried, 'the slot must be retried with a fresh replacement after backoff'
    ensure
      begin
        swarm.shutdown(timeout: SHUTDOWN_TIMEOUT)
      rescue StandardError
        nil
      end
      stop_supervisor_thread(supervisor, 10)
    end
  end

  # --- rolling restart: TERM lands mid-flight ------------------------------

  # A real SIGTERM arriving while a replacement is up but the old child hasn't
  # been TERMed yet must abort the restart machine and fall through to an
  # ordinary drain of everything alive — not wait out the restart's own
  # (up to 30s) heartbeat deadline.
  def test_term_mid_restart_aborts_to_drain
    parent_pid, pipe_read = fork_swarm_supervisor(count: 2)

    begin
      initial_children = read_child_pids(pipe_read)

      assert_equal 2, initial_children.size

      ::Process.kill('USR1', parent_pid)

      assert extra_child_appeared?(parent_pid, initial_children.size),
             'rolling restart never reached a mid-flight state (replacement never appeared)'

      assert_term_aborts_the_restart(parent_pid)
    ensure
      pipe_read&.close
      shutdown_supervisor_if_alive(parent_pid)
    end
  end

  # --- orphan self-termination ---------------------------------------------

  # SIGKILL'ing the supervisor must not leave the children fetching forever:
  # each one self-terminates (PR_SET_PDEATHSIG on Linux, the portable getppid
  # watchdog everywhere) within its watchdog window.
  def test_sigkill_parent_orphans_self_terminate
    parent_pid, pipe_read = fork_swarm_supervisor(count: 1)
    child_pid = nil

    begin
      child_pid = read_child_pids(pipe_read).first

      assert pid_alive?(child_pid), 'child should be alive before its parent is killed'

      ::Process.kill('KILL', parent_pid)
      reap(parent_pid)

      watchdog_timeout = Wurk::Swarm::OrphanGuard::WATCHDOG_INTERVAL + 10
      terminated = wait_until_dead(child_pid, watchdog_timeout)

      assert terminated,
             "orphaned child #{child_pid} was still alive #{watchdog_timeout}s after its parent was SIGKILL'd"
    ensure
      pipe_read&.close
      # An early assertion failure (before the parent is KILL'd) would otherwise
      # leave the parent supervisor alive; it's a no-op once already reaped.
      shutdown_supervisor_if_alive(parent_pid)
      ::Process.kill('KILL', child_pid) if child_pid && pid_alive?(child_pid)
    end
  end

  private

  def topology_n(count)
    Wurk::Topology.flat(count: count, queues: [@queue_name], concurrency: 1)
  end

  def assert_growing_backoff(key)
    timestamps = wait_for_crash_count(key, 3)

    assert timestamps, "expected >=3 crash timestamps, saw #{@observer.call('LRANGE', key, 0, -1).inspect}"

    intervals = timestamps.each_cons(2).map { |a, b| b - a }

    assert_operator intervals[1], :>=, intervals[0] * 1.5,
                    "respawn backoff must grow across crashes: #{intervals.inspect}"
  end

  def assert_drains_promptly_while_backoff_pending(swarm)
    drain_started = monotonic_now
    swarm.shutdown(timeout: SHUTDOWN_TIMEOUT)
    drain_elapsed = monotonic_now - drain_started

    assert_operator drain_elapsed, :<, 1.0,
                    "shutdown must not block on a pending crash-loop backoff, took #{drain_elapsed}s"
  end

  def kill_the_replacement(swarm, original)
    replacement = wait_for_new_child(swarm, exclude: [original])

    assert replacement, 'replacement child was never spawned for the restart'

    ::Process.kill('KILL', replacement)
    sleep POLL_INTERVAL * 3 # let the reaper observe the death before asserting survival
    replacement
  end

  def assert_old_child_survives(swarm, original)
    assert pid_alive?(original), 'old child must survive a replacement that dies before heartbeat'
    assert_includes swarm.children.keys, original, 'old child must still be tracked by the swarm'
  end

  def assert_term_aborts_the_restart(parent_pid)
    drain_started = monotonic_now
    ::Process.kill('TERM', parent_pid)
    exited = wait_for_process_exit(parent_pid, SHUTDOWN_TIMEOUT + 5)
    drain_elapsed = monotonic_now - drain_started

    assert exited, "supervisor never exited after TERM mid-restart (waited #{SHUTDOWN_TIMEOUT + 5}s)"
    assert_operator drain_elapsed, :<, SHUTDOWN_TIMEOUT + 5,
                    "TERM mid-restart must abort to an ordinary drain, took #{drain_elapsed}s"
    assert_empty live_children_of(parent_pid), 'no descendant should survive a TERM mid-restart'
  end

  # Every child crashes immediately at :startup (before it ever fetches), so
  # the parent's per-slot backoff is observed without a genuine job/queue
  # scenario. `exit!` bypasses at_exit/ensure unwinding, the same as a real
  # segfault or OOM-kill would.
  def install_crash_on_startup(key)
    redis_url = Wurk::Test.redis_url
    @config.on(:startup) do
      client = RedisClient.config(url: redis_url).new_client
      client.call('RPUSH', key, ::Process.clock_gettime(::Process::CLOCK_MONOTONIC).to_s)
      client.call('EXPIRE', key, 60)
      client.close
      exit!(1)
    end
  end

  def wait_for_crash_count(key, count)
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      raw = @observer.call('LRANGE', key, 0, -1)
      return raw.map(&:to_f) if raw.size >= count

      sleep POLL_INTERVAL
    end
    nil
  end

  def wait_for_new_child(swarm, exclude:)
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      found = swarm.children.keys.find { |pid| !exclude.include?(pid) }
      return found if found

      sleep POLL_INTERVAL
    end
    nil
  end

  # --- subprocess supervisor plumbing (real SIGTERM/SIGKILL delivery) ------

  def fork_swarm_supervisor(count:)
    read_io, write_io = ::IO.pipe
    pid = ::Process.fork { run_supervisor_subprocess(read_io, write_io, count) }
    write_io.close
    [pid, read_io]
  end

  def run_supervisor_subprocess(read_io, write_io, count)
    read_io.close
    $stdout.reopen(IO::NULL)
    $stderr.reopen(IO::NULL)
    config = build_config
    topology = Wurk::Topology.flat(count: count, queues: [@queue_name], concurrency: 1)
    swarm = Wurk::Swarm.new(topology: topology, config: config, shutdown_timeout: SHUTDOWN_TIMEOUT)
    swarm.boot(install_signals: true)
    write_io.puts(swarm.children.keys.join(','))
    write_io.close
    swarm.supervise
    exit 0
  end

  def build_config
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config.redis = { url: Wurk::Test.redis_url }
    config[:timeout] = SHUTDOWN_TIMEOUT
    config
  end

  def read_child_pids(pipe)
    pipe.readline.strip.split(',').map(&:to_i)
  end

  def extra_child_appeared?(parent_pid, initial_count)
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      return true if live_children_of(parent_pid).size > initial_count

      sleep POLL_INTERVAL
    end
    false
  end

  def wait_for_process_exit(pid, timeout)
    deadline = monotonic_now + timeout
    while monotonic_now < deadline
      return true if ::Process.wait(pid, ::Process::WNOHANG)

      sleep POLL_INTERVAL
    end
    false
  rescue Errno::ECHILD
    true
  end

  def live_children_of(parent_pid)
    ::Dir["/proc/#{parent_pid}/task/*/children"].flat_map do |path|
      ::File.read(path).split.map(&:to_i)
    end.uniq
  rescue Errno::ENOENT
    []
  end

  def shutdown_supervisor_if_alive(pid)
    return unless pid_alive?(pid)

    ::Process.kill('TERM', pid)
    deadline = monotonic_now + SHUTDOWN_TIMEOUT + 5
    while monotonic_now < deadline
      return if ::Process.wait(pid, ::Process::WNOHANG)

      sleep POLL_INTERVAL
    end
    ::Process.kill('KILL', pid) if pid_alive?(pid)
    reap(pid)
  end

  def reap(pid)
    ::Process.wait(pid)
  rescue Errno::ECHILD
    nil
  end

  def wait_until_dead(pid, timeout) # rubocop:disable Naming/PredicateMethod
    deadline = monotonic_now + timeout
    while monotonic_now < deadline
      return true unless pid_alive?(pid)

      sleep POLL_INTERVAL
    end
    !pid_alive?(pid)
  end

  def pid_alive?(pid)
    ::Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end

  def private_queue_key(queue_name)
    Wurk::Fetcher::Reliable.private_queue_name("queue:#{queue_name}")
  end
end
