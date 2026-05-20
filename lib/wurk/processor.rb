# frozen_string_literal: true

module Wurk
  # Pops a job from the per-process private list, runs the server
  # middleware chain, invokes the worker's `perform`, then ACKs by
  # removing from the private list.
  class Processor
    def initialize(manager:); end
    def run; end
    def stop; end
  end
end
