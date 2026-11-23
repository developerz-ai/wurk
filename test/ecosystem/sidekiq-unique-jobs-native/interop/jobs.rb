# frozen_string_literal: true

# Loaded by every interop process, under either bundle: the gem pod gets the real
# sidekiq-unique-jobs, the native pod Wurk::UniqueJobs. Same classes, same options,
# same middleware setup, as a fleet halfway through a deploy would have.

require 'json'
require 'sidekiq'
require 'sidekiq/api'
require 'sidekiq-unique-jobs'

module Interop
  POD = ENV.fetch('INTEROP_POD')
  EVENTS = 'interop:events'

  module_function

  def native? = defined?(Wurk::UniqueJobs) && SidekiqUniqueJobs.equal?(Wurk::UniqueJobs)

  def check_pod!
    expected = POD == 'native'
    return if native? == expected

    raise "interop: the #{POD} pod loaded #{SidekiqUniqueJobs.name}, which is the wrong implementation"
  end

  def event(run, name, **extra)
    row = { 'run' => run, 'event' => name, 'pod' => POD, 'at' => Process.clock_gettime(Process::CLOCK_REALTIME) }
    Sidekiq.redis { |c| c.call('RPUSH', EVENTS, JSON.generate(row.merge(extra.transform_keys(&:to_s)))) }
  end

  def events(run, name = nil)
    rows = Sidekiq.redis { |c| c.call('LRANGE', EVENTS, 0, -1) }.map { |raw| JSON.parse(raw) }
    rows.select { |row| row['run'] == run && (name.nil? || row['event'] == name) }
  end

  def release(run) = Sidekiq.redis { |c| c.call('SET', "interop:release:#{run}", '1', 'EX', 120) }

  def hold(run)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    until Sidekiq.redis { |c| c.call('GET', "interop:release:#{run}") }
      raise "interop: #{run} was never released" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end
end

Interop.check_pod!

# Held until released; the lock is taken at push and dropped when perform returns.
class InteropUntilExecutedJob
  include Sidekiq::Job

  sidekiq_options lock: :until_executed, on_conflict: :reject, retry: false,
                  lock_args_method: ->(args) { [args[0]] }

  def perform(run, tag)
    Interop.event(run, 'start', tag: tag)
    Interop.hold(run) if tag == 'hold'
    Interop.event(run, 'finish', tag: tag)
  end
end

# No push-time lock; a second copy meeting the running one is rescheduled. Across
# queues so a copy on the gem pod's queue and one on the native pod's collide.
class InteropWhileExecutingJob
  include Sidekiq::Job

  sidekiq_options lock: :while_executing, on_conflict: :reschedule, schedule_in: 1, retry: false,
                  unique_across_queues: true, lock_args_method: :lock_args

  def self.lock_args(args) = [args[0]]

  def perform(run, tag)
    Interop.event(run, 'start', tag: tag)
    Interop.hold(run) if tag == 'first'
    Interop.event(run, 'finish', tag: tag)
  end
end

class InteropUntilAndWhileJob
  include Sidekiq::Job

  sidekiq_options lock: :until_and_while_executing, on_conflict: :reject, retry: false,
                  unique_across_queues: true, lock_args_method: ->(args) { [args[0]] }

  def perform(run, tag)
    Interop.event(run, 'start', tag: tag)
    Interop.hold(run) if tag == 'first'
    Interop.event(run, 'finish', tag: tag)
  end
end

class InteropDyingJob
  include Sidekiq::Job

  # retry: 0 goes straight to the dead set and its death handlers; false would skip both.
  sidekiq_options lock: :until_executed, on_conflict: :log, retry: 0

  def perform(run)
    Interop.event(run, 'attempt')
    raise 'interop: dies on purpose'
  end
end

# Fails once, succeeds on the retry: the lock has to hold across the wait.
class InteropRetryJob
  include Sidekiq::Job

  sidekiq_options lock: :until_executed, on_conflict: :reject, retry: 2, lock_args_method: ->(args) { [args[0]] }
  sidekiq_retry_in { 1 }

  def perform(run, _tag = nil)
    Interop.event(run, 'attempt')
    raise 'interop: first attempt fails' if Interop.events(run, 'attempt').size == 1

    Interop.event(run, 'finish')
  end
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

# Treasury's settings: a 2h default TTL, no lock wait, no lock info.
SidekiqUniqueJobs.configure do |config|
  config.lock_ttl = 7200
  config.lock_timeout = nil
  config.lock_info = false
  config.reaper = :none
end
