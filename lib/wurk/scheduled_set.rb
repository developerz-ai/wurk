# frozen_string_literal: true

require_relative 'job_set'

module Wurk
  # ZSET of jobs scheduled to run at a future time (score = epoch seconds).
  # The scheduled-poller pops eligible members and re-enqueues via the
  # client. Wire-compat with Sidekiq's `schedule` key.
  #
  # Spec: docs/target/sidekiq-free.md §19.5.
  class ScheduledSet < JobSet
    def initialize
      super('schedule')
    end
  end
end
