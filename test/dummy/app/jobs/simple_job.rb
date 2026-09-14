# frozen_string_literal: true

# Plain ActiveJob via the Wurk adapter — exercises the most common path.
class SimpleJob < ActiveJob::Base
  queue_as :default

  def perform(*args)
    Wurk.redis { |c| c.call('SET', "simple_job:#{args.first}", Process.pid, 'EX', 60) }
  end
end
