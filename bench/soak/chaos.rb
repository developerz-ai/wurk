# frozen_string_literal: true

require_relative 'ledger'
require_relative 'sampler'

module WurkSoak
  # One fault every `interval` seconds, picked at random from `ops`, each
  # written to the ledger before it lands so the verdict can attribute what it
  # causes. Ops:
  #
  #   kill9         SIGKILL the oldest child (mid-perform + deferred-ACK windows)
  #   term          SIGTERM one child: its graceful drain, then a respawn
  #   usr1          rolling restart of the whole swarm
  #   parent_kill9  SIGKILL the parent; children drain on pdeathsig, a new
  #                 parent is started at once (an orchestrator restart)
  #   redis_restart SIGKILL redis-server, boot it again from its AOF
  #   pause         CLIENT PAUSE ALL for `pause_ms`
  #
  # The oldest child is the kill target because a child that dies young starts
  # its slot's crash streak, and a streak on every slot exits the swarm
  # (lib/wurk/swarm/crash_watch.rb) — that would test the chaos rate, not Wurk.
  class Chaos
    OPS = %w[kill9 term usr1 parent_kill9 redis_restart pause].freeze

    def initialize(swarm:, redis:, ops:, interval:, pause_ms: 3000, rng: Random.new)
      unknown = ops - OPS
      raise ArgumentError, "unknown chaos op(s) #{unknown.join(', ')}; known: #{OPS.join(', ')}" if unknown.any?

      @swarm = swarm
      @redis = redis
      @ops = ops
      @interval = interval
      @pause_ms = pause_ms
      @rng = rng
      @stop = false
    end

    def run
      return if @ops.empty?

      until @stop
        sleep_until_next
        break if @stop

        public_send(@ops.sample(random: @rng))
      end
    end

    def stop! = (@stop = true)

    def kill9
      pid = oldest_child or return
      Ledger.record('chaos', pid, 'kill9', format('age=%.0f', Sampler.age(pid).to_f))
      ::Process.kill(:KILL, pid)
    rescue Errno::ESRCH
      nil
    end

    def term
      pid = oldest_child or return
      Ledger.record('chaos', pid, 'term')
      ::Process.kill(:TERM, pid)
    rescue Errno::ESRCH
      nil
    end

    def usr1
      Ledger.record('chaos', @swarm.pid, 'usr1')
      @swarm.signal(:USR1)
    end

    def parent_kill9
      Ledger.record('chaos', @swarm.pid, 'parent_kill9')
      @swarm.kill9_parent
      @swarm.start
    end

    def redis_restart
      Ledger.record('chaos', @redis.port, 'redis_restart')
      Ledger.record('outage_start')
      down = @redis.kill9_and_restart
      Ledger.record('outage_end', '-', '-', format('%.2f', down))
    end

    def pause
      Ledger.record('chaos', @redis.port, 'pause', @pause_ms)
      Ledger.record('outage_start')
      c = @redis.client
      c.call('CLIENT', 'PAUSE', @pause_ms, 'ALL')
      sleep(@pause_ms / 1000.0)
      Ledger.record('outage_end')
    ensure
      c&.close
    end

    private

    def oldest_child
      @swarm.children.filter_map { |pid| (age = Sampler.age(pid)) && [age, pid] }.max&.last
    end

    def sleep_until_next
      deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + @interval
      sleep 0.2 until @stop || ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) >= deadline
    end
  end
end
