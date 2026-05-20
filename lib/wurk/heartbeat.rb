# frozen_string_literal: true

module Wurk
  # Process heartbeat written to Redis on a fixed interval. The dashboard
  # process list reads this. Identical key shape to Sidekiq's processes set.
  class Heartbeat
    def initialize(identity:); end
    def beat!; end
    def stop!; end
  end
end
