# frozen_string_literal: true

module Wurk
  # Parent supervisor. Forks N children per the worker topology, monitors
  # PIDs, relays signals, respawns crashed children, handles rolling
  # restart on SIGUSR1, recycles RSS-bloated children.
  # See docs/idea/03-process-model.md and docs/idea/04-signals.md.
  class Swarm
    def initialize(topology:); end
    def boot; end
    def supervise; end
    def shutdown(timeout:); end
    def rolling_restart; end
  end
end
