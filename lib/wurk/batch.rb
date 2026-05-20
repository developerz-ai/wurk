# frozen_string_literal: true

module Wurk
  # Sidekiq Pro Batches. Group jobs, attach success/complete/death
  # callbacks, track progress. Spec: docs/target/sidekiq-pro.md.
  class Batch
    def initialize(bid = nil); end
    def jobs(&block); end
    def on(event, callback_class, options = {}); end
    def status; end
  end
end
