# frozen_string_literal: true

module Wurk
  class Error < StandardError; end

  # Raised inside a worker process to abort the run loop. User code must not
  # rescue this — the swarm uses it to signal teardown across thread boundaries.
  # Spec: docs/target/sidekiq-free.md §3.
  #
  # Lives in its own file, loaded before everything else, because Processor
  # freezes its `Thread.handle_interrupt` masks into constants: those are
  # evaluated the moment `wurk/processor` is required, so this class has to
  # exist by then.
  class Shutdown < Interrupt; end
end
