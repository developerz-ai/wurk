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
      # `size` is the row count of the whole file, not of the remainder — a
      # resumed run reports the same total as a fresh one.
      def rows(cursor:)
        scan(cursor, -> { count_of_rows_in_file }) { |sink| @csv.each { |row| sink.call(row) } }
      end

      # Enumerator of `[rows_batch, batch_index]` pairs, skipping the first
      # `cursor` batches. `size` is the batch count, rounded up.
      def batches(cursor:, batch_size: 100)
        size = -> { (count_of_rows_in_file.to_i + batch_size - 1) / batch_size }
        scan(cursor, size) { |sink| @csv.each_slice(batch_size) { |rows| sink.call(rows) } }
      end

      private

      # Shared skeleton for both readers: number every element the block feeds
      # in, emit the ones at or past the cursor. Kept as one pass over the CSV
      # (rather than enumerate-then-drop) because the source is a file handle —
      # skipped rows are read and discarded, never buffered.
      def scan(cursor, size)
        skip = cursor.to_i
        ::Enumerator.new(size) do |yielder|
          position = -1
          sink = lambda do |element|
            position += 1
            yielder.yield(element, position) if position >= skip
          end
          yield sink
        end
      end

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
