# frozen_string_literal: true

module Wurk
  # Sidekiq Enterprise periodic jobs. Cron-spec strings, distributed
  # firing via Wurk::Leader so only one process enqueues per tick.
  module Cron
    class Job; end

    class << self
      def register(name, cron, worker_class, args = []); end
      def jobs; end
    end
  end
end
