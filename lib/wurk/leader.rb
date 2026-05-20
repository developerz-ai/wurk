# frozen_string_literal: true

module Wurk
  # Leader election via Redis SETNX + fencing token. Used by Cron and any
  # other once-per-cluster work. Spec: docs/target/sidekiq-ent.md.
  class Leader
    def initialize(key:); end
    def acquire; end
    def release; end
    def leader?; end
  end
end
