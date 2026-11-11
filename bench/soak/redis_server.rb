# frozen_string_literal: true

require 'fileutils'
require 'socket'
require 'redis-client'

module WurkSoak
  # A redis-server this harness starts, owns and kills: a free 127.0.0.1 port,
  # its own --dir, never the shared :6379. Chaos kills and restarts it, so it
  # cannot be anyone else's server (CLAUDE.md "Never": DB 0, FLUSHALL).
  #
  # `aof: true` (the soak) runs AOF with `appendfsync always`: a SIGKILL then
  # loses no acknowledged write, so a job missing after a restart is Wurk's
  # loss, not the documented "Redis itself lost it" one (docs/reliability.md,
  # "The guarantee"). `aof: false` (bench/rss_soak.rb) persists nothing.
  class RedisServer
    BOOT_TIMEOUT = 30.0

    attr_reader :port, :dir

    def initialize(dir:, aof: true, binary: ENV.fetch('SOAK_REDIS_SERVER', 'redis-server'))
      @dir = dir
      @aof = aof
      @binary = binary
      @port = free_port
      @pid = nil
    end

    def url(database = 1) = "redis://127.0.0.1:#{@port}/#{database}"

    def start
      FileUtils.mkdir_p(@dir)
      @pid = ::Process.spawn(@binary, '--port', @port.to_s, '--bind', '127.0.0.1', '--dir', @dir,
                             '--save', '', *persistence,
                             '--logfile', File.join(@dir, 'redis.log'), %i[out err] => File::NULL)
      wait_ready
      self
    end

    # SIGKILL, then boot again on the same port and dir so it reloads the AOF.
    # Returns the seconds Redis was unreachable.
    def kill9_and_restart
      t0 = monotonic
      kill(:KILL)
      start
      monotonic - t0
    end

    def stop
      kill(:TERM)
    end

    def alive? = !@pid.nil?

    def client = RedisClient.config(url: url, timeout: 5).new_client

    private

    def persistence = @aof ? %w[--appendonly yes --appendfsync always] : %w[--appendonly no]

    def kill(sig)
      return unless @pid

      ::Process.kill(sig, @pid)
      ::Process.wait(@pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    ensure
      @pid = nil
    end

    def wait_ready
      deadline = monotonic + BOOT_TIMEOUT
      until monotonic > deadline
        return if loaded?

        sleep 0.05
      end
      raise "redis-server on :#{@port} not ready within #{BOOT_TIMEOUT}s (see #{@dir}/redis.log)"
    end

    # PING answers while the AOF is still loading; INFO's `loading:0` is ready.
    def loaded?
      c = RedisClient.config(url: url, timeout: 1).new_client
      c.call('INFO', 'persistence').include?('loading:0')
    rescue RedisClient::Error
      false
    ensure
      c&.close
    end

    def free_port
      server = TCPServer.new('127.0.0.1', 0)
      server.addr[1]
    ensure
      server&.close
    end

    def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end
