# frozen_string_literal: true

module Demo
  # Target of the demo cron loops — firing it from the leader keeps the
  # Cron/Periodic widget's "last fired" column moving.
  class ReportJob
    include Wurk::Job

    def perform(*)
      sleep(rand * 0.01)
    end
  end
end
