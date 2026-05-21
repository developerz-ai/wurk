# frozen_string_literal: true

require_relative '../test_helper'

# Top-level so the constant resolves in the forked subprocess.
class RollingRestartIdleWorker
  include Wurk::Job

  # Stamps the current PID into a per-job sentinel key the test can
  # observe to confirm the new slot actually picked up work.
  def perform(redis_url, sentinel_prefix, jid)
    client = RedisClient.config(url: redis_url).new_client
    client.call('SET', "#{sentinel_prefix}:#{jid}", ::Process.pid.to_s)
    client.call('EXPIRE', "#{sentinel_prefix}:#{jid}", 60)
  ensure
    client&.close
  end
end

# SIGUSR1 to the swarm parent → rolling_restart: each slot is replaced
# in turn. After the cycle, every child PID must be new and the swarm
# must still be servicing jobs (no dropped work). Real fork, real Redis.
#
# Not parallelized — forks a supervisor subprocess and waits on it.
class RollingRestartTest < Wurk::Test::UnitCase
  REDIS_URL = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
  POLL_TIMEOUT = 60.0
  POLL_INTERVAL = 0.1
  CHILD_COUNT = 2
  SHUTDOWN_TIMEOUT = 10

  def setup
    super
    @ns = "rrestart-#{::Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @sentinel_prefix = "#{@ns}-sentinel"
    @observer = RedisClient.config(url: REDIS_URL).new_client
  end

  def teardown
    cleanup_observer_keys
    @observer&.close
  ensure
    super
  end

  # rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize
  def test_sigusr1_cycles_each_slot_in_turn
    parent_pid, pipe_read = fork_swarm_supervisor

    begin
      initial_children = read_child_pids(pipe_read)

      assert_equal CHILD_COUNT, initial_children.size,
                   "expected #{CHILD_COUNT} initial children, got #{initial_children.inspect}"

      ::Process.kill('USR1', parent_pid)

      new_children = wait_for_children_to_cycle(parent_pid, initial_children)

      assert_equal CHILD_COUNT, new_children.size,
                   "expected #{CHILD_COUNT} children after cycle, got #{new_children.inspect}"
      refute new_children.intersect?(initial_children),
             "PIDs should be fully replaced, but overlap remained: #{initial_children & new_children}"

      jid = push_followup_job
      stamped_pid = wait_for_sentinel("#{@sentinel_prefix}:#{jid}")

      assert stamped_pid, 'follow-up job never ran after rolling restart'
      assert_includes new_children.map(&:to_s), stamped_pid,
                      "follow-up job ran on #{stamped_pid}, not a post-restart child #{new_children}"
    ensure
      pipe_read&.close
      shutdown_supervisor(parent_pid)
    end
  end
  # rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize

  private

  def fork_swarm_supervisor
    read_io, write_io = ::IO.pipe
    pid = ::Process.fork { run_supervisor_subprocess(read_io, write_io) }
    write_io.close
    [pid, read_io]
  end

  def run_supervisor_subprocess(read_io, write_io)
    read_io.close
    $stdout.reopen(IO::NULL)
    $stderr.reopen(IO::NULL)
    config = build_config
    topology = Wurk::Topology.flat(count: CHILD_COUNT, queues: [@queue_name], concurrency: 1)
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
    config[:timeout] = SHUTDOWN_TIMEOUT
    config
  end

  def read_child_pids(pipe)
    pipe.readline.strip.split(',').map(&:to_i)
  end

  # /proc/<pid>/task/*/children lists every child reaped through this
  # process. We poll until the original PIDs are gone and CHILD_COUNT
  # fresh PIDs are running — that's "cycle complete".
  def wait_for_children_to_cycle(parent_pid, initial_pids)
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      current = live_children_of(parent_pid)
      return current if current.size == CHILD_COUNT && !current.intersect?(initial_pids)

      sleep POLL_INTERVAL
    end
    live_children_of(parent_pid)
  end

  def live_children_of(parent_pid)
    ::Dir["/proc/#{parent_pid}/task/*/children"].flat_map do |path|
      ::File.read(path).split.map(&:to_i)
    end.uniq
  rescue Errno::ENOENT
    []
  end

  def push_followup_job
    config = build_config
    client = Wurk::Client.new(pool: capsule_pool(config), config: config)
    jid = client.push('class' => RollingRestartIdleWorker.name,
                      'args' => [REDIS_URL, @sentinel_prefix, 'placeholder'],
                      'queue' => @queue_name)
    # placeholder arg must equal jid so the worker stamps the right key
    repush_with_correct_jid(client, jid)
    jid
  ensure
    config&.reset_redis_pools!
  end

  # Two-step push avoids racing on jid generation: we push, get the jid,
  # remove that payload, then push the canonical one with the jid baked
  # into args. Cleaner than re-implementing jid generation outside Client.
  def repush_with_correct_jid(client, jid)
    pop_existing(jid)
    client.push('class' => RollingRestartIdleWorker.name,
                'args' => [REDIS_URL, @sentinel_prefix, jid],
                'queue' => @queue_name,
                'jid' => jid)
  end

  def pop_existing(jid)
    deadline = monotonic_now + 1.0
    while monotonic_now < deadline
      raw = @observer.call('LPOP', "queue:#{@queue_name}")
      return unless raw

      parsed = JSON.parse(raw)
      return if parsed['jid'] == jid

      @observer.call('LPUSH', "queue:#{@queue_name}", raw)
      sleep 0.01
    end
  end

  def capsule_pool(config)
    cap = config.default_capsule
    cap.queues = [@queue_name]
    cap.redis_pool
  end

  def wait_for_sentinel(key)
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      val = @observer.call('GET', key)
      return val if val

      sleep POLL_INTERVAL
    end
    nil
  end

  def shutdown_supervisor(pid)
    return unless pid_alive?(pid)

    ::Process.kill('TERM', pid)
    deadline = monotonic_now + SHUTDOWN_TIMEOUT + 5
    while monotonic_now < deadline
      return if ::Process.wait(pid, ::Process::WNOHANG)

      sleep POLL_INTERVAL
    end
    ::Process.kill('KILL', pid) if pid_alive?(pid)
    begin
      ::Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end
  end

  def pid_alive?(pid)
    ::Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def cleanup_observer_keys
    return unless @observer

    cursor = '0'
    loop do
      cursor, keys = @observer.call('SCAN', cursor, 'MATCH', "#{@ns}*", 'COUNT', 100)
      @observer.call('DEL', *keys) unless keys.empty?
      break if cursor == '0'
    end
    @observer.call('DEL', "queue:#{@queue_name}")
  rescue StandardError
    nil
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end
