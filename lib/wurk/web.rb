# frozen_string_literal: true

require_relative 'web/config'
require_relative 'web/search'
require_relative 'web/enterprise'
require_relative 'web/batch_status'

module Wurk
  # Web UI namespace. Holds three sibling concerns:
  #
  #   * `Wurk::Web::Config` + `Wurk::Web::Authorization` — the Rack-level
  #     authorization hook (sidekiq-ent §9.2), 403 on falsey.
  #   * `Wurk::Web::Search` — Pro substring search across queues/retries/
  #     scheduled/dead (ZSCAN + glob; sidekiq-pro §10.1).
  #   * `Wurk::Web::Enterprise` — Limits / Periodic / Historical helpers
  #     (sidekiq-ent §9.1) used by the JSON APIs.
  #
  # Wurk ships every Pro/Ent web feature free. Loading this file is enough
  # to make `Wurk::Web.configure` available — no separate require needed.
  #
  # The class body is intentionally empty — every concern lives in a sibling
  # file already required above. Rubocop's Lint/EmptyClass is disabled
  # because this is a namespace anchor, not a missing-implementation bug.
  class Web # rubocop:disable Lint/EmptyClass
  end
end
