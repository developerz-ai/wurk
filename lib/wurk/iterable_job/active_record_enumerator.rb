# frozen_string_literal: true

module Wurk
  module IterableJob
    # Cursor-resumable ActiveRecord iteration helpers for
    # IterableJob#build_enumerator. Behavior parity with Sidekiq's
    # `Sidekiq::Job::Iterable::ActiveRecordEnumerator`: the cursor is the
    # primary key of the last-yielded record, threaded back through AR's
    # `start:` so iteration resumes after an interruption without re-scanning.
    #
    # ActiveRecord is NOT a wurk dependency — these methods simply call the
    # relation's batching API, so they work when the host app has AR and raise
    # a plain NoMethodError otherwise (you can't build a relation without AR).
    #
    # Spec: docs/target/sidekiq-free.md §6.4; Sidekiq wiki Iteration.
    class ActiveRecordEnumerator
      def initialize(relation, cursor: nil, **options)
        @relation = relation
        @cursor = cursor
        @options = options
      end

      # `[record, record.id]` pairs.
      def records
        ::Enumerator.new(-> { @relation.count }) do |yielder|
          @relation.find_each(**@options, start: @cursor) do |record|
            yielder.yield(record, record.id)
          end
        end
      end

      # `[records_batch, batch.first.id]` pairs. The size lambda is the record
      # count, NOT the batch count — byte-for-byte with upstream Sidekiq's
      # `ActiveRecordEnumerator#batches`, so `enum.size` returns the same value
      # a drop-in app gets from Sidekiq. (Only the lazy `#size` differs from
      # `relations`; the run loop never calls it.)
      def batches
        ::Enumerator.new(-> { @relation.count }) do |yielder|
          @relation.find_in_batches(**@options, start: @cursor) do |batch|
            yielder.yield(batch, batch.first.id)
          end
        end
      end

      # `[relation, first_record.id]` pairs. `:batch_size` is normalized to
      # `:of` so callers use one option name across all three helpers. Delete
      # `:batch_size` unconditionally before the `||=` so a caller passing both
      # `:of` and `:batch_size` can't leak `:batch_size` into `in_batches`
      # (which has no such keyword) — upstream's `||=` short-circuits and
      # raises ArgumentError there; valid single-option calls are unaffected.
      def relations
        ::Enumerator.new(-> { relations_size }) do |yielder|
          options = @options.dup
          batch_size = options.delete(:batch_size)
          options[:of] ||= batch_size

          @relation.in_batches(**options, start: @cursor) do |relation|
            yielder.yield(relation, relation.first.id)
          end
        end
      end

      private

      def relations_size
        batch_size = @options[:batch_size] || 1000
        (@relation.count + batch_size - 1) / batch_size # ceiling division
      end
    end
  end
end
