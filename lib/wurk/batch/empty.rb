# frozen_string_literal: true

require_relative '../worker'

module Wurk
  class Batch
    # No-op marker job inserted into an empty `batch.jobs { }` block so
    # `:complete` and `:success` callbacks still fire. Pro 7.1+ behaviour:
    # without this marker, total=0 means no batch_push ever ran and the
    # callback path can't tell "empty batch" from "never flushed batch".
    #
    # Spec: docs/target/sidekiq-pro.md §2.3 / §12.
    class Empty
      include Wurk::Job

      sidekiq_options retry: false, queue: 'default'

      def perform; end
    end
  end
end
