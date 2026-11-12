# frozen_string_literal: true

# The client half of mixed_fleet_test.rb, run under either bundle: with
# BUNDLE_GEMFILE=bench/vs_sidekiq/Gemfile `require 'sidekiq'` is the real gem,
# with the repo Gemfile it is Wurk's drop-in shim. Prints one JSON line.
#
#   client.rb push <queue>:<count>:<kind>[:<delay_seconds>] ...   ledgers each jid
#   client.rb inspect <queue>                                       reads back through the API

require 'json'
require 'sidekiq'
require 'sidekiq/api'
require_relative 'job'

def version = MIXED_FLEET_ENGINE == 'wurk' ? Wurk::VERSION : Sidekiq::VERSION

def push(*specs)
  jids = specs.flat_map do |spec|
    queue, count, kind, delay = spec.split(':')
    Array.new(Integer(count)) do
      job = MixedFleetJob.set(queue: queue)
      jid = delay ? job.perform_in(Float(delay), kind) : job.perform_async(kind)
      WurkSoak::Ledger.record('push', jid, kind, MIXED_FLEET_ENGINE)
      jid
    end
  end
  { jids: jids }
end

def record_times(record)
  { created_at: record.created_at.to_f, enqueued_at: record.enqueued_at&.to_f,
    raw_created_at: record.item['created_at'], raw_enqueued_at: record.item['enqueued_at'] }
end

def inspect_queue(name)
  queue = Sidekiq::Queue.new(name)
  scheduled = Sidekiq::ScheduledSet.new.select { |entry| entry.queue == name }
  { size: queue.size, latency: queue.latency,
    jobs: queue.map { |record| record_times(record) },
    scheduled: scheduled.map { |entry| record_times(entry).merge(at: entry.at.to_f) } }
end

command, *args = ARGV
result = case command
         when 'push' then push(*args)
         when 'inspect' then inspect_queue(*args)
         else abort "usage: #{$PROGRAM_NAME} push|inspect ..."
         end
puts JSON.generate(result.merge(engine: MIXED_FLEET_ENGINE, version: version))
