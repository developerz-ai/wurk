# frozen_string_literal: true

# Lock behaviour only a real worker can show: a conflict rescheduled through the
# scheduler, a lock held across a retry, a lock released by a death. Uses the
# option values production apps run (no lock wait, a long TTL). The fake-testing
# boot mode is left out on purpose: a reschedule or retry pushed from a worker in
# that mode lands in the fake queue.

require 'securerandom'
require 'sidekiq'
require 'sidekiq/api'
require 'sidekiq-unique-jobs'
require_relative '../boot_check_support'

module LockScenarioSupport
  module_function

  def event(scenario, run, name, **extra)
    BootCheck.record({ 'scenario' => scenario, 'run' => run, 'event' => name,
                       'at' => Process.clock_gettime(Process::CLOCK_REALTIME) }.merge(extra.transform_keys(&:to_s)))
  end

  def events(scenario, run, name = nil)
    BootCheck.rows.select do |row|
      row['scenario'] == scenario && row['run'] == run && (name.nil? || row['event'] == name)
    end
  end

  def release(run) = Sidekiq.redis { |c| c.call('SET', "scenario:release:#{run}", '1', 'EX', 120) }
  def released?(run) = Sidekiq.redis { |c| c.call('GET', "scenario:release:#{run}") }

  def hold(run)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    sleep 0.02 until released?(run) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    raise "scenario #{run} was never released" unless released?(run)
  end

  def attempt(run) = Sidekiq.redis { |c| c.call('INCR', "scenario:attempt:#{run}") }
end

class RescheduleScenarioJob
  include Sidekiq::Job

  sidekiq_options queue: 'default', retry: false, lock: :while_executing, on_conflict: :reschedule,
                  schedule_in: 1, lock_args_method: ->(args) { [args[0]] }

  def perform(run, tag)
    LockScenarioSupport.event('reschedule', run, 'start', tag: tag)
    LockScenarioSupport.hold(run) if tag == 'first'
    LockScenarioSupport.event('reschedule', run, 'finish', tag: tag)
  end
end

class ProcLockArgsScenarioJob
  include Sidekiq::Job

  sidekiq_options queue: 'default', retry: false, lock: :until_executed, on_conflict: :log,
                  lock_args_method: ->(args) { [args[0]] }

  def perform(run, tag)
    LockScenarioSupport.hold(run)
    LockScenarioSupport.event('lock_args_proc', run, 'ran', tag: tag)
  end
end

class SymbolLockArgsScenarioJob
  include Sidekiq::Job

  sidekiq_options queue: 'default', retry: false, lock: :until_executed, on_conflict: :log,
                  lock_args_method: :lock_args

  def self.lock_args(args) = [args[0]]

  def perform(run, tag)
    LockScenarioSupport.hold(run)
    LockScenarioSupport.event('lock_args_symbol', run, 'ran', tag: tag)
  end
end

class RetryScenarioJob
  include Sidekiq::Job

  sidekiq_options queue: 'default', retry: 2, lock: :until_and_while_executing, on_conflict: :reject,
                  lock_args_method: ->(args) { [args[0]] }
  sidekiq_retry_in { 3 }

  def perform(run, tag = 'original')
    number = LockScenarioSupport.attempt(run)
    LockScenarioSupport.event('retry', run, 'attempt', number: number, tag: tag, jid: jid)
    raise 'first attempt fails' if number == 1

    LockScenarioSupport.hold(run) if tag == 'original'
    LockScenarioSupport.event('retry', run, 'finish', tag: tag)
  end
end

class ExhaustedScenarioJob
  include Sidekiq::Job

  sidekiq_options queue: 'default', retry: 1, lock: :until_and_while_executing, on_conflict: :reject,
                  lock_args_method: ->(args) { [args[0]] }
  sidekiq_retry_in { 1 }

  def perform(run)
    LockScenarioSupport.event('exhausted', run, 'attempt')
    raise 'always fails'
  end
end

# The gem's unlock losing Redis once, after `perform` returned.
module FailFirstUnlock
  FAILED = Set.new
  LOCK = Mutex.new

  def unlock(conn = nil)
    # until_and_while_executing also unlocks before `perform`; only its :RUN
    # unlock comes after.
    after_perform = item['lock'].to_s == 'until_executed' || item['lock_digest'].end_with?(':RUN')
    first = item['class'].start_with?('UnlockFailure') && after_perform &&
            LOCK.synchronize { FAILED.add?(item['jid']) }
    raise RedisClient::CannotConnectError, 'injected: Redis gone during unlock' if first

    super
  end
end
SidekiqUniqueJobs::Locksmith.prepend(FailFirstUnlock)

class UnlockFailureUntilExecutedJob
  include Sidekiq::Job

  sidekiq_options queue: 'default', retry: 3, lock: :until_executed, on_conflict: :reject,
                  lock_args_method: ->(args) { [args[0]] }

  def perform(run) = LockScenarioSupport.event('unlock_failure', run, 'ran')
end

class UnlockFailureUntilAndWhileJob
  include Sidekiq::Job

  sidekiq_options queue: 'default', retry: false, lock: :until_and_while_executing, on_conflict: :reject,
                  lock_args_method: ->(args) { [args[0]] }

  def perform(run) = LockScenarioSupport.event('unlock_failure', run, 'ran')
end

Sidekiq.configure_client do |config|
  config.client_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Client }
end

Sidekiq.configure_server do |config|
  config.average_scheduled_poll_interval = 1
  config.client_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Client }
  config.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
  SidekiqUniqueJobs::Server.configure(config)
end

SidekiqUniqueJobs.configure do |config|
  config.lock_timeout = nil
  config.lock_ttl = 7200
  config.reaper = :none
end

module LockScenarios
  module_function

  def run_all
    reschedule
    lock_args('lock_args_proc', ProcLockArgsScenarioJob)
    lock_args('lock_args_symbol', SymbolLockArgsScenarioJob)
    retry_holds_the_lock
    exhausted_releases_the_lock
    unlock_failure_runs_once(UnlockFailureUntilExecutedJob)
    unlock_failure_runs_once(UnlockFailureUntilAndWhileJob)
    reaper_keeps_a_private_list_job
  end

  # The second job meets the running first one, goes back through the schedule
  # and runs once the first is done. Never at the same time, and never dropped.
  def reschedule
    run = fresh_run
    RescheduleScenarioJob.perform_async(run, 'first')
    wait('first job running') { started?('reschedule', run, 'first') }
    RescheduleScenarioJob.perform_async(run, 'second')
    wait('second job rescheduled') { Sidekiq::ScheduledSet.new.any? { |job| job.args == [run, 'second'] } }
    check(!started?('reschedule', run, 'second'), 'the conflicting job ran beside the holder')

    LockScenarioSupport.release(run)
    wait('second job finished') { finished('reschedule', run).include?('second') }
    first_end = LockScenarioSupport.events('reschedule', run, 'finish').find { |row| row['tag'] == 'first' }['at']
    second_start = LockScenarioSupport.events('reschedule', run, 'start').find { |row| row['tag'] == 'second' }['at']
    check(second_start >= first_end, 'the rescheduled job overlapped the holder')
    check(LockScenarioSupport.events('reschedule', run, 'start').size == 2, 'a job ran more than once')
    locks_gone
  end

  # The lock covers only the arguments lock_args_method returns.
  def lock_args(scenario, job)
    run = fresh_run
    other = fresh_run
    check(job.perform_async(run, 'a'), "#{scenario}: first push refused")
    check(job.perform_async(run, 'b').nil?, "#{scenario}: same lock args, different ignored arg, was accepted")
    check(job.perform_async(other, 'a'), "#{scenario}: different lock args were refused")
    LockScenarioSupport.release(run)
    LockScenarioSupport.release(other)
    wait("#{scenario}: both ran") { ran?(scenario, run) && ran?(scenario, other) }
    locks_gone
    check(job.perform_async(run, 'c'), "#{scenario}: lock not released after the job ran")
    wait("#{scenario}: third ran") { LockScenarioSupport.events(scenario, run, 'ran').size == 2 }
    check(LockScenarioSupport.events(scenario, run, 'ran').map { |row| row['tag'] } == %w[a c],
          "#{scenario}: wrong jobs ran")
    locks_gone
  end

  # A failed job takes its lock back for the wait in the retry set, keeps its
  # jid, and leaves nothing behind once it succeeds.
  def retry_holds_the_lock
    run = fresh_run
    jid = RetryScenarioJob.perform_async(run)
    check(jid, 'retry: first push refused')
    wait('retry: job in the retry set') { Sidekiq::RetrySet.new.any? { |job| job.jid == jid } }
    check(RetryScenarioJob.perform_async(run, 'duplicate').nil?, 'retry: duplicate accepted during the retry wait')

    wait('retry: second attempt') { LockScenarioSupport.events('retry', run, 'attempt').size == 2 }
    jids = LockScenarioSupport.events('retry', run, 'attempt').map { |row| row['jid'] }.uniq
    check(jids == [jid], "retry: the retry ran under another jid: #{jids}")

    # The until lock is off while it executes, so this push is accepted, and the
    # runtime lock must stop it at the worker.
    duplicate = RetryScenarioJob.perform_async(run, 'during-execution')
    check(duplicate, 'retry: push during execution refused')
    wait('retry: duplicate rejected to the dead set') { Sidekiq::DeadSet.new.any? { |job| job.jid == duplicate } }
    check(LockScenarioSupport.events('retry', run, 'attempt').size == 2, 'retry: duplicate executed beside the holder')

    LockScenarioSupport.release(run)
    wait('retry: finished') { LockScenarioSupport.events('retry', run, 'finish').size == 1 }
    locks_gone
  end

  def exhausted_releases_the_lock
    run = fresh_run
    jid = ExhaustedScenarioJob.perform_async(run)
    wait('exhausted: job in the dead set') { Sidekiq::DeadSet.new.any? { |job| job.jid == jid } }
    check(LockScenarioSupport.events('exhausted', run, 'attempt').size == 2, 'exhausted: wrong attempt count')
    locks_gone
    check(ExhaustedScenarioJob.perform_async(run), 'exhausted: lock survived the death')
    wait('exhausted: retried push ran') { LockScenarioSupport.events('exhausted', run, 'attempt').size >= 3 }
  end

  # Redis failing in the unlock after `perform`: the job is not run again, and
  # its lock is gone, so the next push of the same arguments is accepted.
  def unlock_failure_runs_once(job)
    run = fresh_run
    check(job.perform_async(run), "#{job}: first push refused")
    wait("#{job}: ran") { LockScenarioSupport.events('unlock_failure', run, 'ran').size == 1 }
    locks_gone
    sleep 2.5
    check(LockScenarioSupport.events('unlock_failure', run, 'ran').size == 1,
          "#{job}: ran again after the unlock failed")
    check(Sidekiq::RetrySet.new.none? { |entry| entry.args == [run] }, "#{job}: went to the retry set")
    check(job.perform_async(run), "#{job}: lock survived the failed unlock")
    wait("#{job}: next push ran") { LockScenarioSupport.events('unlock_failure', run, 'ran').size == 2 }
    locks_gone
  end

  # A worker was killed: its heartbeat is gone and its job sits in a private
  # list. The gem's reaper reads only public queues and live workers, so without
  # Wurk's guard it deletes the lock and a duplicate runs beside the recovery.
  def reaper_keeps_a_private_list_job
    Wurk::UniqueJobsCompat.install
    run = fresh_run
    jid = 'a' * 24
    digest = "uniquejobs:scenario#{run}"
    list = "queue:#{run}|dead-host|999999|0123456789ab|0"
    payload = JSON.generate('class' => 'RetryScenarioJob', 'jid' => jid, 'args' => [run], 'lock_digest' => digest)
    aged = Time.now.to_f - SidekiqUniqueJobs.config.reaper_timeout - 60
    Sidekiq.redis do |conn|
      conn.call('LPUSH', list, payload)
      conn.call('ZADD', SidekiqUniqueJobs::DIGESTS, aged, digest)
    end
    reaper = Sidekiq.redis { |conn| SidekiqUniqueJobs::Orphans::RubyReaper.new(conn) }

    check(reaper.belongs_to_job?(digest), 'reaper: a job in a dead worker\'s private list read as lockless')
    Sidekiq.redis { |conn| conn.call('DEL', list) }
    check(!reaper.belongs_to_job?(digest), 'reaper: a lock with no job left is no longer an orphan')
    Sidekiq.redis { |conn| conn.call('ZREM', SidekiqUniqueJobs::DIGESTS, digest) }
  end

  def fresh_run = SecureRandom.hex(6)

  def started?(scenario, run, tag)
    LockScenarioSupport.events(scenario, run, 'start').any? { |row| row['tag'] == tag }
  end

  def finished(scenario, run) = LockScenarioSupport.events(scenario, run, 'finish').map { |row| row['tag'] }
  def ran?(scenario, run) = LockScenarioSupport.events(scenario, run, 'ran').any?

  def locks_gone
    wait('every lock released') { SidekiqUniqueJobs::Digests.new.entries(pattern: '*').empty? }
  end

  def check(condition, message)
    raise "lock scenario failed: #{message}" unless condition
  end

  def wait(what, seconds: 30)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      raise "lock scenario timed out waiting for: #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end
end

if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  results = BootCheck::MODES.slice('sidekiq', 'wurkswarm, preload on').map do |label, (command, env)|
    BootCheck.run_mode(__FILE__, 'sidekiq-unique-jobs lock scenarios', label, command, env) do
      next false unless Sidekiq::ProcessSet.new.size.positive?

      LockScenarios.run_all
      true
    end
  end
  exit 1 unless results.all?

  puts 'sidekiq-unique-jobs lock scenarios: passed'
end
