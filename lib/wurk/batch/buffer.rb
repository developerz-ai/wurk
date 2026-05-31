# frozen_string_literal: true

module Wurk
  class Batch
    # Accumulates batched payloads inside an autoflush `Batch#jobs` block so
    # the whole block flushes in one pipeline (`autoflush == true`) or every
    # N jobs (`autoflush == Integer`). Client#raw_push fills it; Batch#jobs
    # drains the remainder at block exit.
    Buffer = Struct.new(:payloads, :threshold) do
      def add(items)
        payloads.concat(items)
        self
      end

      def ready?
        !threshold.nil? && payloads.length >= threshold
      end

      def drain
        out = payloads.dup
        payloads.clear
        out
      end
    end
  end
end
