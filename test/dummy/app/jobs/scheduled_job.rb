# frozen_string_literal: true

class ScheduledJob < ActiveJob::Base
  queue_as :default

  def perform(*args); end
end
