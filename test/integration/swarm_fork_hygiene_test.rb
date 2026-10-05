# frozen_string_literal: true

require_relative '../test_helper'

# Boot step 3 on EVERY fork, proven with real forks and real Redis (K17).
# A respawn happens long after boot, in a parent that has reopened sockets —
# the railtie's parent is a live web process whose enqueues reopen the capsule
# and web pools. Whatever the parent holds at the instant of fork, the child
# inherits; connection_pool's own fork hook then closes those copies in the
# child, which over `rediss://` sends close_notify on the PARENT's live TLS
# session. So the property is parent-side: at every fork, none of the sockets
# the parent opened may still be open. NEVER mock Redis here.
class SwarmForkHygieneTest < Wurk::Test::UnitCase
  include SwarmTeardown

  parallelize_me!

  POLL_TIMEOUT = 30.0
  SHUTDOWN_TIMEOUT = 5

  def setup
    super
    skip 'needs /proc' unless ::File.directory?('/proc/self/fd')
    @ns = "forkhyg-#{::Process.pid}-#{object_id}"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: Wurk::Test.redis_url }
    @config[:timeout] = SHUTDOWN_TIMEOUT
  end

  def teardown
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_a_respawn_fork_carries_none_of_the_parents_redis_sockets
    swarm = Wurk::Swarm.new(topology: Wurk::Topology.flat(count: 1, queues: ["#{@ns}-q"], concurrency: 1),
                            config: @config, shutdown_timeout: SHUTDOWN_TIMEOUT)
    supervisor = nil
    at_fork = []
    with_fork_recording(at_fork) do
      first = swarm.boot(install_signals: false).first
      supervisor = Thread.new { swarm.supervise }
      parent_opened = sockets_opened_by { reopen_parent_pools }

      refute_empty parent_opened, 'precondition: the parent must hold live Redis sockets before the respawn'

      ::Process.kill('KILL', first)

      assert wait_until { at_fork.size >= 2 }, 'the slot was never respawned'
      assert_empty at_fork[1] & parent_opened, 'the respawn fork carried a Redis socket the parent had open'
    ensure
      swarm.shutdown(timeout: SHUTDOWN_TIMEOUT)
      stop_supervisor_thread(supervisor, 10)
    end
  end

  private

  def socket_inodes
    ::Dir.children('/proc/self/fd').filter_map do |fd|
      target = ::File.readlink("/proc/self/fd/#{fd}")
      target if target.start_with?('socket:')
    rescue SystemCallError
      nil
    end
  end

  # What a web parent does between forks: enqueue (capsule pool) and serve the
  # dashboard (web pool).
  def reopen_parent_pools
    @config.redis_pool.with { |c| c.call('PING') }
    @config.web_redis_pool.with { |c| c.call('PING') }
  end

  def sockets_opened_by
    before = socket_inodes
    yield
    socket_inodes - before
  end

  # Snapshots the parent's open sockets at the instant of each real fork.
  # Test classes get their own worker process and run serially inside it, so
  # nothing else forks while this is installed.
  def with_fork_recording(log)
    sc = ::Process.singleton_class
    original = ::Process.method(:fork)
    parent = ::Process.pid
    probe = method(:socket_inodes)
    sc.define_method(:fork) do |*args, &blk|
      log << probe.call if ::Process.pid == parent
      original.call(*args, &blk)
    end
    yield
  ensure
    sc.define_method(:fork) { |*a, &b| original.call(*a, &b) }
  end

  def wait_until
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + POLL_TIMEOUT
    until yield
      return false if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
    true
  end
end
