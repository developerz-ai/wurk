# frozen_string_literal: true

# A real Rails host for the boot-mode tests in
# test/integration/rails_executor_boot_modes_test.rb, loaded via `-r` by the
# runners or directly by a host process. Runs one job that records what the
# Rails executor looks like from inside perform.
require_relative '../dummy/config/application'

# Booted by a host process (not a runner) as a preforking server opted into
# embedding, so RailsBoot takes its threads-only path.
if ENV['PROBE_EMBED'] == '1'
  module PhusionPassenger; end
  Dummy::Application.config.wurk.embed_in_web = true
end

Wurk.configuration.default_capsule.queues = [ENV.fetch('PROBE_QUEUE')] if ENV['PROBE_SET_QUEUE'] == '1'

class RailsExecutorProbeJob
  include Wurk::Job

  def perform(list)
    connection = ActiveRecord::Base.connection
    connection.execute('SELECT 1')
    report = {
      executor_active: Rails.application.executor.active?,
      query_cache: connection.query_cache_enabled
    }
    Wurk.redis { |conn| conn.call('RPUSH', list, Wurk.dump_json(report)) }
  end
end

Rails.application.initialize!
