# frozen_string_literal: true

require_relative 'job_set'

module Wurk
  # ZSET of jobs scheduled to run at a future time (score = epoch seconds).
  # The scheduled-poller pops eligible members and re-enqueues via the
  # client. Wire-compat with Sidekiq's `schedule` key.
  #
  # Spec: docs/target/sidekiq-free.md §19.5.
  class ScheduledSet < JobSet
    # Optional `name` allows tests to operate on a namespaced ZSET; production
    # callers always use the default `'schedule'` key (wire-compat with Sidekiq).
    def initialize(name = 'schedule')
      super
    end
  end
end
