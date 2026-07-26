# frozen_string_literal: true

module Wurk
  module Sentry
    # Builds the per-job Sentry scope: transaction name, tags, and the `wurk`
    # context block. Split out from {Middleware} so the *shape* of what Sentry
    # sees can change without touching the capture policy.
    module JobContext
      CONTEXT_KEY = :wurk

      # Sentry groups issues by transaction name, and sentry-sidekiq names its
      # transactions `Sidekiq/<JobClass>`. Mirroring that shape as
      # `Wurk/<JobClass>` keeps a migrating app's issue list legible: the same
      # job reads the same way before and after the swap, and the only diff is
      # the prefix — so history stays searchable instead of fragmenting into
      # unnamed transactions.
      TRANSACTION_PREFIX = 'Wurk/'

      module_function

      def apply(scope, job, queue)
        scope.clear_breadcrumbs
        scope.set_transaction_name(transaction_name(job), source: :task)
        scope.set_tags(tags(job, queue))
        scope.set_context(CONTEXT_KEY, context(job, queue))
        scope
      end

      def transaction_name(job)
        "#{TRANSACTION_PREFIX}#{job['class']}"
      end

      def tags(job, queue)
        { queue: job['queue'] || queue, jid: job['jid'] }
      end

      # Deliberately enumerated, never `job.dup.except("args")`: job arguments
      # routinely carry PII, tokens, or `encrypt: true` ciphertext, and Sentry
      # is not a place any of that belongs. An allow-list can't leak a new
      # payload key that a future Wurk release starts stamping.
      def context(job, queue)
        {
          'class' => job['class'],
          'jid' => job['jid'],
          'queue' => job['queue'] || queue,
          'retry_count' => job['retry_count'],
          'created_at' => job['created_at'],
          'enqueued_at' => job['enqueued_at']
        }
      end
    end
  end
end
