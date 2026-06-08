# frozen_string_literal: true

require 'securerandom'
require_relative 'client'
require_relative 'job_util'

module Wurk
  # Opt-in enqueue client that holds each `push` until the surrounding
  # ActiveRecord transaction commits, so a job never references a row a
  # rollback erased — the canonical "enqueue after commit" pattern.
  #
  # Enable globally with `Wurk.transactional_push!` (aliased
  # `Sidekiq.transactional_push!`), which sets `default_job_options
  # ["client_class"]`; the worker DSL then builds this client instead of the
  # plain `Wurk::Client`.
  #
  # The jid is pre-allocated and returned synchronously so the caller can
  # reference it inside the transaction; the actual Redis write runs in an
  # after-commit hook. `push_bulk` is intentionally NOT deferred — it matches
  # Sidekiq, whose batching/scheduling machinery can't ride the commit hook.
  #
  # Spec: docs/target/sidekiq-free.md §8.
  class TransactionAwareClient
    def initialize(pool: nil, config: nil)
      @redis_client = Wurk::Client.new(pool: pool, config: config)
    end

    # True inside a `Batch#jobs` block. The batch counts jobs at push time, so
    # deferring would desync its totals — push immediately instead.
    def batching?
      !Thread.current[Wurk::Batch::THREAD_KEY].nil?
    end

    # @return [String] the pre-allocated jid (returned before the deferred push runs).
    def push(item)
      item['jid'] ||= SecureRandom.hex(12)

      if batching?
        @redis_client.push(item)
      else
        register_after_commit { @redis_client.push(item) }
      end

      item['jid']
    end

    # Bulk enqueue is never transactional (Sidekiq parity) — straight to Redis.
    def push_bulk(items)
      @redis_client.push_bulk(items)
    end

    private

    # Routes the push to the host's after-commit hook. AR 7.2+ exposes
    # `ActiveRecord.after_all_transactions_commit`, which runs the block now
    # when there's no open transaction and after commit when there is — so the
    # "not in a transaction" and "ActiveRecord absent" cases both degrade to an
    # immediate push, exactly the graceful no-op the spec calls for.
    def register_after_commit(&)
      if defined?(::ActiveRecord) && ::ActiveRecord.respond_to?(:after_all_transactions_commit)
        ::ActiveRecord.after_all_transactions_commit(&)
      elsif defined?(::AfterCommitEverywhere)
        ::AfterCommitEverywhere.after_commit(&)
      else
        yield
      end
    end
  end

  # The class-level `client_class` option carries a Class object, so it must
  # never reach the wire. Append it to the transient list the canonical way the
  # comment in JobUtil anticipates, rather than baking it into the base literal.
  JobUtil::TRANSIENT_ATTRIBUTES << 'client_class' unless JobUtil::TRANSIENT_ATTRIBUTES.include?('client_class')
end
