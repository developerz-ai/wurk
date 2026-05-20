# frozen_string_literal: true

module Wurk
  class Batch
    # Snapshot of a batch's progress: total, pending, failures, completed,
    # parent_bid, etc. Same fields as Sidekiq::Batch::Status.
    class Status
      def initialize(bid); end
      def total; end
      def pending; end
      def failures; end
      def complete?; end
    end
  end
end
