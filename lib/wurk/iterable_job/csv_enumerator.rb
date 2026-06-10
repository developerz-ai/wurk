# frozen_string_literal: true

module Wurk
  module IterableJob
    # Cursor-resumable CSV iteration helper for IterableJob#build_enumerator.
    # Byte-for-byte behavior parity with Sidekiq's
    # `Sidekiq::Job::Iterable::CsvEnumerator`: the cursor is the integer row
    # (or batch) index, and resume drops that many rows. Requires the host to
    # have loaded `csv` (we don't force the dependency).
    #
    # Spec: docs/target/sidekiq-free.md §6.4; Sidekiq wiki Iteration.
    class CsvEnumerator
      def initialize(csv)
        raise ArgumentError, 'CsvEnumerator.new takes CSV object' unless defined?(::CSV) && csv.instance_of?(::CSV)

        @csv = csv
      end

      # Enumerator of `[row, index]` pairs, skipping the first `cursor` rows.
      def rows(cursor:)
        @csv.lazy
            .each_with_index
            .drop(cursor || 0)
            .to_enum { count_of_rows_in_file }
      end

      # Enumerator of `[rows_batch, batch_index]` pairs, skipping the first
      # `cursor` batches.
      def batches(cursor:, batch_size: 100)
        @csv.lazy
            .each_slice(batch_size)
            .with_index
            .drop(cursor || 0)
            .to_enum { (count_of_rows_in_file.to_f / batch_size).ceil }
      end

      private

      # Best-effort row count for the enumerator's `size` (progress display).
      # Only invoked if a caller asks for `#size`; the run loop never does.
      def count_of_rows_in_file
        filepath = @csv.path
        return unless filepath

        count = ::IO.popen(['wc', '-l', filepath]) { |out| out.read.strip.to_i }
        count -= 1 if @csv.headers
        count
      end
    end
  end
end
