# frozen_string_literal: true

# The soak's worker app: `wurkswarm -r bench/soak/app.rb`, and required by the
# producer for the job classes. SOAK_APP=dummy boots test/dummy first so the
# children carry a real Rails app's heap, not just Wurk's.
require File.expand_path('../../test/dummy/config/environment', __dir__) if ENV['SOAK_APP'] == 'dummy'
require 'wurk'
require_relative 'ledger'

module WurkSoak
  QUEUE = 'soak'

  def self.ledger? = ENV.key?('SOAK_LEDGER')

  def self.limiter
    @limiter ||= Wurk::Limiter.concurrent('soak', Integer(ENV.fetch('SOAK_LIMIT', '3')),
                                          wait_timeout: 1, lock_timeout: 30, backoff: ->(*) { 1 })
  end

  # Innermost server middleware: `run` before perform, `done` once perform
  # returned. A raise (retry, limiter reschedule, iterable interruption) writes
  # no `done`. SOAK_LOSSY=N swallows about 1 in N jobs without running them, so
  # they are ACKed and gone: the ledger must call those lost (the harness
  # self-test, plan 102/09 T1).
  class LedgerMiddleware
    def initialize
      @lossy = Integer(ENV.fetch('SOAK_LOSSY', '0'))
    end

    def call(_worker, job, _queue)
      kind = KINDS[job['class']]
      return yield unless kind && WurkSoak.ledger?

      jid = job['jid']
      return Ledger.record('drop', jid, kind) if @lossy.positive? && rand(@lossy).zero?

      Ledger.record('run', jid, kind)
      yield
      Ledger.record('done', jid, kind)
    end
  end

  # Batch :success bodies. A child records its parent so the verdict can check
  # child-before-parent ordering.
  class Callbacks
    def on_success(status, _options)
      Ledger.record('cb', status.bid, 'success', status.parent_bid || '-') if WurkSoak.ledger?
    end
  end

  module Work
    def perform(millis, *)
      sleep(millis / 1000.0) if millis.positive?
    end
  end

  class PlainJob
    include Sidekiq::Job
    include Work

    sidekiq_options queue: QUEUE
  end

  class ScheduledJob
    include Sidekiq::Job
    include Work

    sidekiq_options queue: QUEUE
  end

  class TrackedJob
    include Sidekiq::Job
    include Work

    sidekiq_options queue: QUEUE, track: true
  end

  class BatchJob
    include Sidekiq::Job
    include Work

    sidekiq_options queue: QUEUE
  end

  class CronJob
    include Sidekiq::Job
    include Work

    sidekiq_options queue: QUEUE
  end

  # args: [millis, key] — the key is what the lock dedupes on.
  class UniqueJob
    include Sidekiq::Job
    include Work

    sidekiq_options queue: QUEUE, unique_for: 600
  end

  # Fails its first attempt, then succeeds from the retry set.
  class RetryJob
    include Sidekiq::Job

    sidekiq_options queue: QUEUE, retry: 5
    sidekiq_retry_in { 1 }

    class Flake < StandardError; end

    def perform(millis)
      first = Wurk.redis { |c| c.call('SET', "soak-retry:#{jid}", '1', 'NX', 'EX', 3600) }
      raise Flake, 'first attempt fails on purpose' if first

      sleep(millis / 1000.0) if millis.positive?
    end
  end

  class LimitedJob
    include Sidekiq::Job

    sidekiq_options queue: QUEUE

    def perform(millis)
      WurkSoak.limiter.within_limit { sleep(millis / 1000.0) }
    end
  end

  # args: [items, millis per item]
  class IterableJob
    include Sidekiq::Job
    include Wurk::IterableJob

    sidekiq_options queue: QUEUE

    def build_enumerator(items, _millis, cursor:) = array_enumerator(Array.new(items) { |i| i }, cursor: cursor)

    def each_iteration(_item, _items, millis)
      sleep(millis / 1000.0)
    end
  end

  KINDS = {
    PlainJob => 'plain', ScheduledJob => 'scheduled', RetryJob => 'retry', UniqueJob => 'unique',
    LimitedJob => 'limited', IterableJob => 'iterable', BatchJob => 'batch', CronJob => 'cron',
    TrackedJob => 'tracked'
  }.transform_keys(&:name).freeze
end

Sidekiq::Enterprise.unique!

Wurk.configure_server do |config|
  config.server_middleware { |chain| chain.add WurkSoak::LedgerMiddleware }
  if ENV['SOAK_CRON'] == '1'
    config.periodic { |mgr| mgr.register('* * * * *', 'WurkSoak::CronJob', queue: WurkSoak::QUEUE, args: [0]) }
  end
end
