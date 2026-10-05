# frozen_string_literal: true

# Plain ActiveJob via the Wurk adapter — exercises the most common path.
# Writes `simple_job:<first arg>` = pid so a test can prove perform ran
# (test/engine/active_job_roundtrip_test.rb).
class SimpleJob < ActiveJob::Base
  queue_as :default

  def perform(*args)
    Wurk.redis { |c| c.call('SET', "simple_job:#{args.first}", Process.pid, 'EX', 60) }
  end
end
