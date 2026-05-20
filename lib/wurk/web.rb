# frozen_string_literal: true

module Wurk
  # Rack app serving the precompiled React SPA and JSON APIs.
  # Mounted by the engine under whatever path the host chose.
  # Spec: docs/target/sidekiq-free.md (Web UI), with Pro search and Ent
  # panes layered in via web/search.rb and web/enterprise.rb.
  class Web
    def self.call(env); end
  end
end
