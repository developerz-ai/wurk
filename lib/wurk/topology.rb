# frozen_string_literal: true

module Wurk
  # Worker topology DSL (Wurk extension on top of Ent's flat swarm).
  # Lets users declare specialized slots: e.g. 2 forks dedicated to the
  # critical queue with low concurrency, 2 forks for bulk + low with high
  # concurrency. Stronger queue isolation than a flat swarm.
  class Topology
    def initialize; end
    def slot(count:, queues:, concurrency:); end
    def slots; end
  end
end
