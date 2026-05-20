# frozen_string_literal: true

module Wurk
  # Inspects/iterates a named queue. Pause/resume is the Pro extension.
  # Redis keys are IDENTICAL to Sidekiq — wire-compat is sacred.
  class Queue
    def initialize(name = "default"); end

    def size; end
    def latency; end
    def each(&block); end
    def clear; end
    def pause!; end
    def unpause!; end
    def paused?; end
  end
end
