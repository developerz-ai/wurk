# frozen_string_literal: true

# The plainest path: a Sidekiq::Job (aliased to Wurk) enqueued with perform_async.
class WelcomeJob
  include Sidekiq::Job

  def perform(_user_id)
    sleep(rand * 0.05)
  end
end
