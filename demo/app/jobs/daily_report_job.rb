# frozen_string_literal: true

# Target of the periodic (cron) schedule registered in config/initializers/wurk.rb.
# The leader fires it on cadence, so the Cron page shows real "last fired" times.
class DailyReportJob
  include Sidekiq::Job

  sidekiq_options queue: "low"

  def perform
    sleep(rand * 0.05)
  end
end
