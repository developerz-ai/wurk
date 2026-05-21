# frozen_string_literal: true

require_relative '../job'

# Defined under the `Sidekiq::ActiveJob` namespace (not `Wurk::ActiveJob`) so
# the canonical `class` string written to Redis stays `"Sidekiq::ActiveJob::Wrapper"`
# — the exact wire shape Sidekiq emits. Mixed Sidekiq/Wurk worker pools can
# read the same payloads either way. Wire-compat is sacred.
#
# `Wurk::ActiveJob::Wrapper` and `ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper`
# both resolve here so legacy enqueued payloads load on the gem swap.
#
# Spec: docs/target/sidekiq-free.md §28.
module Sidekiq
  module ActiveJob
    class Wrapper
      include Wurk::Job

      def perform(job_data)
        ::ActiveJob::Base.execute(job_data.merge('provider_job_id' => jid))
      end
    end
  end
end

# Wurk-namespaced alias kept tight against the Sidekiq definition above; the
# extra module is a pure constant rebind, not a second class definition.
module Wurk # rubocop:disable Style/OneClassPerFile
  module ActiveJob
    Wrapper = ::Sidekiq::ActiveJob::Wrapper
  end
end
