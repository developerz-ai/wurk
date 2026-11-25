# frozen_string_literal: true

require_relative '../test_helper'
require 'fileutils'
require 'socket'
require 'tmpdir'

# A unique job on a Redis at `maxmemory` under `noeviction`. The lock was taken
# at push, so entering it needs no memory: the job must run, as docs/reliability.md
# promises of a full Redis. Filling one is server-wide, so this has its own.
class UniqueJobsMaxmemoryTest < Wurk::Test::UnitCase
  UJ = Wurk::UniqueJobs

  module Jobs
    class Executed
      include Wurk::Job

      sidekiq_options lock: :until_executed, lock_ttl: 600, on_conflict: :log, retry: false
    end

    class Expired
      include Wurk::Job

      sidekiq_options lock: :until_expired, lock_ttl: 600, on_conflict: :log, retry: false
    end
  end

  # What Dragonfly 1.34 answers the same refusal with; it has no allow-oom either.
  DRAGONFLY_OOM = 'ERR Error running script (call to 10d4dedc2ed7fbbe1f54ad6dda662c6b90def492): ' \
                  '@user_script:15: -ERR Out of memory (redis://127.0.0.1:6379/5)'

  def setup
    super
    skip 'needs a redis-server binary' unless system('command -v redis-server > /dev/null 2>&1')

    @dir = Dir.mktmpdir('wurk-oom-unique')
    @port = TCPServer.open('127.0.0.1', 0) { |s| s.addr[1] }
    @server = Process.spawn('redis-server', '--port', @port.to_s, '--bind', '127.0.0.1', '--save', '', '--dir', @dir,
                            '--maxmemory-policy', 'noeviction', out: IO::NULL, err: IO::NULL)
    @direct = RedisClient.config(url: "redis://127.0.0.1:#{@port}/0", timeout: 5).new_client
    wait_for_server
    use_capsule
    UJ.reset!
    @server_chain = Wurk::Middleware::Chain.new(Wurk.configuration)
    @server_chain.add(UJ::Middleware::Server)
  end

  def teardown
    Thread.current[:wurk_capsule] = @outer_capsule if defined?(@outer_capsule)
    UJ.reset!
    @config&.reset_redis_pools!
    @direct&.close
    if @server
      Process.kill('KILL', @server)
      Process.wait(@server)
    end
    FileUtils.rm_rf(@dir) if @dir
  ensure
    super
  end

  [Jobs::Executed, Jobs::Expired].each do |klass|
    name = klass.get_sidekiq_options['lock']

    define_method("test_#{name}_performs_on_a_full_redis") do
      job = locked(klass)
      fill!

      assert_raises(RedisClient::OutOfMemoryError) { @direct.call('SET', 'precondition', 'x') }
      assert perform(job), 'the job was not performed'
    end

    # Dragonfly words it differently, and its refusal reads as a script failure.
    define_method("test_#{name}_performs_on_a_full_dragonfly") do
      job = locked(klass)

      assert(refusing_claims { perform(job) }, 'the job was not performed')
    end
  end

  # Entered by jid, so released and renewed by jid: the run has no mark there, and
  # must not read the one it finds as another run's.
  def test_a_run_that_entered_by_jid_is_the_holder
    job = locked(Jobs::Executed)
    held = UJ::Run.token
    @direct.call('HSET', "#{job['lock_digest']}:LOCKED", job['jid'], held)
    renewed = nil
    refusing_claims { perform(job) { |worker| renewed = UJ.refresh_lock!(worker) } }

    assert renewed, 'refresh_lock! refused the only run'
    assert_empty @direct.call('KEYS', '*:LOCKED'), 'the lock was not released'
  end

  # The fallback asks the same question the mark's script does.
  def test_a_jid_without_the_lock_is_not_let_in_by_a_refusal
    job = locked(Jobs::Executed)
    locked_key = "#{job['lock_digest']}:LOCKED"
    @direct.call('DEL', locked_key)
    @direct.call('HSET', locked_key, 'another-jid', '1764000000.1')

    refute(refusing_claims { perform(job) })
    assert_equal ['another-jid'], @direct.call('HKEYS', locked_key)
  end

  # Any other refusal is not about memory, and says so.
  def test_another_script_failure_is_raised
    job = locked(Jobs::Executed)
    error = RedisClient::CommandError.new('ERR Error running script (call to f_1): @user_script:15: WRONGTYPE')

    assert_raises(UJ::Script::LuaError) { refusing_claims(error) { perform(job) } }
  end

  private

  def use_capsule
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: "redis://127.0.0.1:#{@port}/0" }
    @outer_capsule = Thread.current[:wurk_capsule]
    Thread.current[:wurk_capsule] = @config.default_capsule
  end

  # A pushed job's payload, its lock taken.
  def locked(klass)
    item = UJ::Job.prepare('class' => klass.name, 'queue' => 'default', 'jid' => "oom-#{object_id}", 'args' => [1],
                           **klass.get_sidekiq_options.except('retry'))
    UJ::Locksmith.new(item).lock
    Wurk.load_json(Wurk.dump_json(item))
  end

  # The unlock itself may be refused after the job has run; FinishedJobCleanup
  # owns that, and it is not what is measured here.
  def perform(job)
    ran = false
    worker = Wurk.const_get(job['class']).new
    worker.jid = job['jid']
    begin
      @server_chain.invoke(worker, job, job['queue']) do
        ran = true
        yield worker if block_given?
      end
    rescue RedisClient::OutOfMemoryError
      raise unless ran
    end
    ran
  end

  # Minitest 6 dropped minitest/mock; swap one singleton method and restore it.
  def refusing_claims(error = RedisClient::CommandError.new(DRAGONFLY_OOM))
    loader = Wurk::Lua::Loader
    real = loader.method(:eval_cached)
    loader.define_singleton_method(:eval_cached) do |conn, name, **args|
      raise error if name == :unique_jobs_claim

      real.call(conn, name, **args)
    end
    yield
  ensure
    loader.define_singleton_method(:eval_cached, real)
  end

  def fill!
    used = @direct.call('INFO', 'memory')[/used_memory:(\d+)/, 1].to_i
    @direct.call('CONFIG', 'SET', 'maxmemory', (used * 0.9).to_i)
  end

  def wait_for_server
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 10
    begin
      @direct.call('PING')
    rescue RedisClient::Error
      raise if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
      retry
    end
  end
end
