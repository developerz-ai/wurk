# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'
require 'fileutils'

# Spawns the REAL exe/wurk binary against real Redis to prove that
# `Sidekiq.configure_server` blocks fire in a booted worker (#191). Server mode
# must be entered before the `-r` initializer loads, or the block — and the
# server middleware / error handlers / lifecycle hooks inside it — is silently
# dropped. Also asserts `configure_client` does NOT fire in the server.
class ConfigureServerBootTest < Wurk::Test::UnitCase
  parallelize_me!

  POLL_TIMEOUT = 30.0
  POLL_INTERVAL = 0.1
  BOOT_TIMEOUT = 5

  def setup
    super
    @ns = "cfgsrv-#{::Process.pid}-#{object_id}"
    @server_key = "#{@ns}-server-startup"
    @module_flag_key = "#{@ns}-module-flag"
    @client_key = "#{@ns}-client"
    @boot_file = ::File.join(::Dir.tmpdir, "#{@ns}-boot.rb")
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @observer&.call('DEL', @server_key, @module_flag_key, @client_key)
    @observer&.close
    ::FileUtils.rm_f(@boot_file)
  ensure
    super
  end

  def test_configure_server_block_fires_in_booted_worker
    write_boot_file
    pid = spawn_worker

    begin
      assert wait_for_key(@server_key),
             'configure_server { on(:startup) } never fired in the booted worker'
      assert_equal 'true', @observer.call('GET', @module_flag_key),
                   'Sidekiq.server? must be true inside the booted worker'
      assert_nil @observer.call('GET', @client_key),
                 'configure_client must NOT fire in a server process'
    ensure
      stop(pid)
    end
  end

  private

  # The `-r` initializer: registers a server hook + a client block, both writing
  # to Redis. Only the server hook should run.
  def write_boot_file
    ::File.write(@boot_file, <<~RUBY)
      require 'redis-client'
      url = ENV.fetch('REDIS_URL')

      Wurk.configure_server do |config|
        config.redis = { url: url }
        # Record the module flag at block-run time (deterministic — separate
        # process, no parallel teardown can race it).
        c = RedisClient.config(url: url).new_client
        c.call('SET', #{@module_flag_key.inspect}, Sidekiq.server?.to_s)
        c.call('EXPIRE', #{@module_flag_key.inspect}, 60)
        c.close
        config.on(:startup) do
          c = RedisClient.config(url: url).new_client
          c.call('SET', #{@server_key.inspect}, '1')
          c.call('EXPIRE', #{@server_key.inspect}, 60)
          c.close
        end
      end

      Wurk.configure_client do |_config|
        c = RedisClient.config(url: url).new_client
        c.call('SET', #{@client_key.inspect}, '1')
        c.call('EXPIRE', #{@client_key.inspect}, 60)
        c.close
      end
    RUBY
  end

  def spawn_worker
    exe = ::File.expand_path('../../exe/wurk', __dir__)
    ::Process.spawn(
      { 'REDIS_URL' => Wurk::Test.redis_url },
      'bundle', 'exec', exe,
      '-r', @boot_file, '-q', "#{@ns}-q", '-c', '1', '-e', 'production', '-t', BOOT_TIMEOUT.to_s,
      chdir: ::File.expand_path('../..', __dir__), out: ::IO::NULL, err: ::IO::NULL
    )
  end

  def wait_for_key(key)
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      val = @observer.call('GET', key)
      return val if val

      sleep POLL_INTERVAL
    end
    nil
  end

  def stop(pid)
    return unless pid_alive?(pid)

    ::Process.kill('TERM', pid)
    deadline = monotonic_now + BOOT_TIMEOUT + 5
    while monotonic_now < deadline
      return if ::Process.wait(pid, ::Process::WNOHANG)

      sleep POLL_INTERVAL
    end
    ::Process.kill('KILL', pid)
    ::Process.wait(pid)
  rescue Errno::ECHILD
    nil
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
end
