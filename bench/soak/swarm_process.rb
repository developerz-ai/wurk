# frozen_string_literal: true

require 'rbconfig'
require_relative 'sampler'

module WurkSoak
  # One `exe/wurkswarm` parent, spawned the way an operator runs it: its own
  # process, signals for control, children found through /proc. Restartable,
  # because the chaos loop SIGKILLs the parent too.
  class SwarmProcess
    ROOT = File.expand_path('../..', __dir__)
    EXE = File.join(ROOT, 'exe', 'wurkswarm')
    QUEUE_NAME = 'soak'

    attr_reader :pid

    def initialize(env:, log:, require_path:, concurrency:, timeout: 25)
      @env = env
      @log = log
      @argv = ['-r', require_path, '-q', QUEUE_NAME, '-c', concurrency.to_s, '-t', timeout.to_s]
      @pid = nil
    end

    def start
      ruby = [RbConfig.ruby, *('-rbundler/setup' if defined?(::Bundler))]
      # The suite's COVERAGE would make every child write a resultset.
      @pid = ::Process.spawn(@env.merge('COVERAGE' => nil), *ruby, EXE, *@argv,
                             chdir: ROOT, %i[out err] => [@log, 'a'])
      self
    end

    def children = @pid ? Sampler.children(@pid) : []

    def signal(sig)
      ::Process.kill(sig, @pid) if @pid
    rescue Errno::ESRCH
      nil
    end

    # True once the parent has exited (and is reaped).
    def exited?
      return true unless @pid

      !::Process.wait(@pid, ::Process::WNOHANG).nil?
    rescue Errno::ECHILD
      true
    end

    # Graceful drain, then KILL whatever is left of the process tree.
    def stop(timeout: 60)
      return unless @pid

      kids = children
      signal(:TERM)
      deadline = monotonic + timeout
      sleep 0.1 until exited? || monotonic > deadline
      kill_tree(kids)
      @pid = nil
    end

    # SIGKILL the parent only. Its children drain on their own (pdeathsig →
    # SIGTERM, lib/wurk/swarm/orphan_guard.rb). Returns the old children.
    def kill9_parent
      kids = children
      signal(:KILL)
      sleep 0.05 until exited?
      @pid = nil
      kids
    end

    private

    def kill_tree(kids)
      signal(:KILL) unless exited?
      kids.each do |k|
        ::Process.kill(:KILL, k)
      rescue Errno::ESRCH
        nil
      end
    end

    def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end
