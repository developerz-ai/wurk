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

  # A host subprocess exits with a status only the host could care about; each
  # round gives the supervise loop several ticks to steal it.
  HOST_SUBPROCESS_ROUNDS = 3
  HOST_SUBPROCESS_STATUS = 7
  STRAGGLER_LIFETIME = 300

  def setup
    super
    @ns = "swarmsup-#{::Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new($stderr)
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

  # --- what the waits below depend on -------------------------------------

  # A host that is merely SLOW must not end a wait. Progress arrives BETWEEN
  # polls — from the passage of (fake) time, never from the probe — and the run
  # outlasts several idle budgets in total, which a single total deadline could
  # not survive. That difference is this file's whole history on the platform's
  # coding boxes: the assertions above are about supervision, and a total budget
  # made every one of them a bet on how fast the host forks and boots a Ruby
  # child (developerz-ai/developerz.ai#4386).
  #
  # No threads and no real sleeping: the clock is a local, so the case proves the
  # arithmetic rather than racing the scheduler it is about.
  def test_a_wait_follows_progress_rather_than_elapsed_time
    idle = 1.0
    now = 0.0
    ticks = 0
    found = wait_while_progressing(
      progress: -> { ticks },
      idle_timeout: idle,
      clock: -> { now },
      # One poll costs three quarters of an idle budget, and the thing being
      # waited on moves once per poll.
      nap: lambda { |_|
        now += idle * 0.75
        ticks += 1
      }
    ) { ticks >= 8 ? ticks : nil }

    assert_equal 8, found, 'a wait must survive a host too slow to finish inside one idle budget'
    assert_operator now, :>, idle * 4,
                    'this case is only a test if it outlasts the budget it is meant to survive'
  end

  # And a supervisor that has genuinely STOPPED still fails the wait, within one
  # idle budget of its last move — the property a total deadline also had, and
  # the reason the replacement is not simply a bigger number.
  def test_a_wait_gives_up_on_a_supervisor_that_stopped_moving
    idle = 1.0
    now = 0.0
    polls = 0
    found = wait_while_progressing(
      progress: -> { 0 },
      idle_timeout: idle,
      clock: -> { now },
      nap: lambda { |_|
        now += idle * 0.25
        polls += 1
      }
    ) { nil }

    assert_nil found, 'a stalled supervisor must fail the wait'
    assert_operator polls, :<=, 4, 'and must fail within one idle budget of its last move'
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

  # --- fork safety: an exiting child must not drain the fleet ---------------

  # A Rails host registers `at_exit { swarm.shutdown }` (rails_boot.rb) and
  # every forked child inherits it, so ChildBoot's `exit` runs a full drain
  # inside the child — where `@children` lists that child's SIBLINGS. Unguarded
  # it TERMs them, then stalls the entire shutdown timeout on PIDs it can never
  # reap, then SIGKILLs whatever survived. Forking the supervisor reproduces
  # that inherited object graph exactly. No supervise thread needed — the drain
  # under test runs entirely inside the fork.
  def test_shutdown_from_a_forked_child_leaves_the_fleet_alone
    swarm = Wurk::Swarm.new(topology: topology_n(2), config: @config, shutdown_timeout: SHUTDOWN_TIMEOUT)

    begin
      children = swarm.boot(install_signals: false)
      elapsed = time_drain_in_a_fork(swarm)

      assert_operator elapsed, :<, SHUTDOWN_TIMEOUT,
                      "a non-owner drain must return at once, took #{elapsed.round(1)}s"
      children.each do |pid|
        assert pid_alive?(pid), "sibling #{pid} was killed by a forked child's inherited shutdown"
      end
    ensure
      begin
        swarm.shutdown(timeout: SHUTDOWN_TIMEOUT)
      rescue StandardError
        nil
      end
    end
  end

  # --- at_exit drain request ------------------------------------------------

  # A Rails host's `at_exit` (rails_boot) can't drain the fleet itself: it runs
  # on the host's main thread while the supervise thread walks the same child
  # table. It raises a flag instead — the supervise loop must observe it on its
  # next tick, drain the real children, and return.
  def test_requested_shutdown_is_drained_by_the_supervise_thread
    swarm = Wurk::Swarm.new(topology: topology_n(1), config: @config, shutdown_timeout: SHUTDOWN_TIMEOUT)
    supervisor = nil

    begin
      children = swarm.boot(install_signals: false)
      supervisor = Thread.new { swarm.supervise }

      swarm.request_shutdown

      assert_request_drained(swarm, supervisor, children)
    ensure
      begin
        swarm.shutdown(timeout: SHUTDOWN_TIMEOUT)
      rescue StandardError
        nil
      end
      stop_supervisor_thread(supervisor, 10)
    end
  end

  # --- reaping ownership ----------------------------------------------------

  # Embedded (`RailsBoot.boot_swarm`) the supervise loop ticks on a background
  # thread of the host's own process, so a wildcard `wait2(-1)` there consumes
  # the exit status of ANY child — a Puma worker, a `system`/`Open3`
  # subprocess — and the host's own `Process.wait` then fails with ECHILD.
  # Forking a stranger child while the loop ticks reproduces exactly that.
  def test_supervise_leaves_the_hosts_own_subprocesses_to_the_host
    swarm = Wurk::Swarm.new(topology: topology_n(1), config: @config, shutdown_timeout: SHUTDOWN_TIMEOUT)
    supervisor = nil

    begin
      swarm.boot(install_signals: false)
      supervisor = Thread.new { swarm.supervise }

      assert_host_subprocesses_survive_the_supervisor
    ensure
      begin
        swarm.shutdown(timeout: SHUTDOWN_TIMEOUT)
      rescue StandardError
        nil
      end
      stop_supervisor_thread(supervisor, 10)
    end
  end

  # SIGKILL only schedules the teardown; the pid stays a zombie until someone
  # waits on it, and `hard_kill_stragglers` is the last reap the swarm will ever
  # do — `shutdown` has already left the supervise loop behind. Standalone the
  # exiting process hands its zombies to init; embedded, the host lives on and
  # keeps one per straggler for the rest of its life.
  def test_hard_kill_stragglers_reaps_the_pids_it_killed
    swarm = Wurk::Swarm.new(topology: topology_n(1), config: @config, shutdown_timeout: SHUTDOWN_TIMEOUT)
    straggler = ::Process.fork { sleep STRAGGLER_LIFETIME }
    register_straggler(swarm, straggler)

    swarm.send(:hard_kill_stragglers)

    assert_empty swarm.children
    assert_fully_reaped(straggler)
  ensure
    ::Process.kill('KILL', straggler) if straggler && pid_alive?(straggler)
    reap(straggler) if straggler
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

    # Each interval is the slot's respawn delay (1 s, then 2 s — Backoff has no
    # jitter) PLUS one fork + boot, and the boot is the noise: on a loaded CI
    # runner it ran ~1 s, so [2.07, 2.94] failed a `>= 1.5x` ratio while the
    # schedule underneath had doubled exactly (2026-09-03). Assert the two
    # facts the schedule guarantees: the second interval cannot be shorter than
    # the second delay, and it grew by the delay's own step, less half a step
    # of boot jitter.
    assert_operator intervals[1], :>=, Wurk::Swarm::RESPAWN_BACKOFF * 2,
                    "second respawn must wait the doubled delay: #{intervals.inspect}"
    assert_operator intervals[1] - intervals[0], :>=, Wurk::Swarm::RESPAWN_BACKOFF * 0.5,
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

  def assert_request_drained(swarm, supervisor, children)
    assert supervisor.join(SHUTDOWN_TIMEOUT + 5), 'supervise must return once it observes the drain request'
    assert_empty swarm.children, 'the supervise thread must have drained the fleet'
    assert(children.all? { |pid| wait_until_dead(pid, 5) }, "children #{children.inspect} survived the drain")
  end

  # Children the swarm never forked: the test owns them, and only the test may
  # reap them. `exit!` skips this suite's at_exit hooks, the same as a real
  # child gets.
  def assert_host_subprocesses_survive_the_supervisor
    HOST_SUBPROCESS_ROUNDS.times do
      pid = ::Process.fork { exit!(HOST_SUBPROCESS_STATUS) }
      sleep Wurk::Swarm::SUPERVISE_TICK * 3
      status = reap_host_subprocess(pid)

      assert status, "the supervisor reaped the host's subprocess #{pid} (ECHILD)"
      assert_equal HOST_SUBPROCESS_STATUS, status.exitstatus
    end
  end

  def reap_host_subprocess(pid)
    _, status = ::Process.wait2(pid)
    status
  rescue Errno::ECHILD
    nil
  end

  # A straggler exactly as the drain leaves one behind: tracked, about to be
  # SIGKILLed, and no supervise loop left to wait on it. A real fleet can't
  # produce one on demand — its children drain well inside the deadline.
  def register_straggler(swarm, pid)
    swarm.instance_variable_set(:@owner_pid, ::Process.pid)
    swarm.instance_variable_get(:@children)[pid] =
      { slot: topology_n(1).assignments.first, index: 0, spawned_at: monotonic_now }
  end

  # ECHILD is the unambiguous proof: not merely dead — waited on. A zombie still
  # answers `wait2` (with a status) and still answers `kill(0)`.
  def assert_fully_reaped(pid)
    outcome = begin
      ::Process.wait2(pid, ::Process::WNOHANG)
    rescue Errno::ECHILD
      :reaped
    end

    assert_equal :reaped, outcome, "straggler #{pid} was left behind: #{outcome.inspect}"
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

  # Poll until the block answers, giving up only once the supervisor has made NO
  # OBSERVABLE PROGRESS for POLL_TIMEOUT — `progress` returns a snapshot, and the
  # deadline resets every time that snapshot changes.
  #
  # WHY NOT A TOTAL DEADLINE, WHICH IS WHAT THIS WAS. One fixed 20 s budget for
  # the whole wait makes every assertion downstream a bet on how fast THIS HOST
  # forks and boots a Ruby child. On a quiet machine the crash loop below logs
  # three crashes in about 4 s; on a loaded runner a single fork + boot can eat
  # the budget on its own, and the test then fails with an EMPTY crash log —
  # nothing broken, the host was busy. Measured, not supposed: this file is the
  # top cause of a red baseline on the platform's coding boxes — 83 refusals
  # across 9 tasks in four days, every one on a 4-core 1.8 GHz box that also runs
  # agents, while `bin/check` on the same SHA is green on a quiet machine
  # (developerz-ai/developerz.ai#4386, and the class in #522).
  #
  # Progress is what the supervisor actually promises; elapsed wall-clock is what
  # the host happens to be doing. So a slow host makes this poll LONGER and never
  # changes its verdict, while a supervisor that has genuinely stopped moving
  # still fails within POLL_TIMEOUT of its last move.
  # `clock` and `nap` are the host, injected ONLY by the two cases that test this
  # helper's own deadline arithmetic. Every other caller takes the real pair. A
  # test of a timing rule that depends on the scheduler to produce its timing is
  # the very class of flake this file is fixing, and a real mover thread can be
  # descheduled past the idle budget it is meant to beat.
  def wait_while_progressing(progress:, idle_timeout: POLL_TIMEOUT, interval: POLL_INTERVAL,
                             clock: method(:monotonic_now), nap: method(:sleep))
    seen = progress.call
    deadline = clock.call + idle_timeout
    loop do
      found = yield
      return found if found

      now = progress.call
      if now != seen
        seen = now
        deadline = clock.call + idle_timeout
      end
      return nil if clock.call >= deadline

      nap.call(interval)
    end
  end

  # Progress is the crash log growing: each entry is one child that booted, ran
  # the startup hook and died, which is exactly the loop being waited on.
  def wait_for_crash_count(key, count)
    wait_while_progressing(progress: -> { @observer.call('LLEN', key).to_i }) do
      raw = @observer.call('LRANGE', key, 0, -1)
      raw.size >= count ? raw.map(&:to_f) : nil
    end
  end

  # Progress is the child set changing at all — a fork or a reap. A slot being
  # retried shows up as a pid this wait has not excluded, so the first churn ends
  # the wait rather than extending it.
  def wait_for_new_child(swarm, exclude:)
    wait_while_progressing(progress: -> { swarm.children.keys.sort }) do
      swarm.children.keys.find { |pid| !exclude.include?(pid) }
    end
  end

  # `exit!` so the drainer skips this suite's at_exit hooks (Minitest reporting,
  # SimpleCov) — the same abrupt teardown a real child gets.
  def time_drain_in_a_fork(swarm)
    started = monotonic_now
    pid = ::Process.fork do
      swarm.shutdown(timeout: SHUTDOWN_TIMEOUT)
      exit!(0)
    end
    ::Process.wait(pid)
    monotonic_now - started
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
