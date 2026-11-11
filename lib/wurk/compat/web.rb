# frozen_string_literal: true

# Autoload target of the dashboard's Sidekiq aliases (compat.rb).

module Sidekiq
  Web        = Wurk::Web
  WebHelpers = Wurk::Web::Extension::Helpers
  Paginator  = Wurk::Web::Paginator

  module Pro
    # Sidekiq Pro mounts the dashboard at `Sidekiq::Pro::Web`; it is the same
    # board as `Sidekiq::Web` here, so a Pro app's `mount Sidekiq::Pro::Web`
    # drops in unchanged.
    Web = Wurk::Web

    # `use Sidekiq::Pro::BatchStatus` — the polling Rack middleware that serves
    # GET /batch_status/<bid>.json. Spec: docs/target/sidekiq-pro.md §10.3.
    BatchStatus = Wurk::Web::BatchStatus
  end
end
