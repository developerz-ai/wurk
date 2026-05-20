# frozen_string_literal: true

module Wurk
  class Fetcher
    # Default fetcher. BLMOVE atomically moves a job from the main queue
    # list into a per-process private list. Jobs left in the private list
    # at boot are reclaimed by the swarm. Spec: docs/target/sidekiq-pro.md
    # (super_fetch).
    class Reliable < Fetcher
    end
  end
end
