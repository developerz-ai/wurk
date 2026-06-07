# frozen_string_literal: true

require_relative '../batch/status'

module Wurk
  class Web
    # Lightweight Rack middleware for batch-progress polling without mounting
    # the full dashboard. Drop into a rack stack and app JS can drive progress
    # bars off plain JSON:
    #
    #   # config.ru
    #   use Sidekiq::Pro::BatchStatus
    #   run Rails.application
    #
    # `GET /batch_status/<bid>.json` → `Wurk::Batch::Status#data` JSON
    # (bid, total, pending, failures, complete, created_at, description, …).
    # Unknown/expired bid → 404. Every other request passes straight through.
    #
    # Spec: docs/target/sidekiq-pro.md §10.3.
    class BatchStatus
      ROUTE = %r{\A/batch_status/(?<bid>[^/]+)\.json\z}

      def initialize(app)
        @app = app
      end

      def call(env)
        match = env['REQUEST_METHOD'] == 'GET' && ROUTE.match(env['PATH_INFO'])
        return @app.call(env) unless match

        status = Wurk::Batch::Status.new(match[:bid])
        status.exists? ? json(200, status.data) : json(404, { 'error' => 'not_found' })
      end

      private

      def json(code, payload)
        [code, { 'content-type' => 'application/json' }, [Wurk.dump_json(payload)]]
      end
    end
  end
end
