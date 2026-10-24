# frozen_string_literal: true

class DemoCanaryJob
  include Sidekiq::Job

  sidekiq_options retry: 0

  class CanaryFault < StandardError; end

  def perform
    return unless ENV['WURK_DEMO_CANARY'] == '1'

    raise CanaryFault, 'DEMO-ONLY CANARY: DemoCanaryJob fault probe'
  end
end
