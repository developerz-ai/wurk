# frozen_string_literal: true

module Wurk
  # Enqueue interface. Lua bulk path. Redis-outage local buffer is in
  # Wurk::Client::Buffered (Pro feature parity).
  # Spec: docs/target/sidekiq-free.md + docs/target/sidekiq-pro.md.
  class Client
    def push(job_hash); end

    def push_bulk(job_hash); end
  end
end
