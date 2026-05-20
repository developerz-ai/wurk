# frozen_string_literal: true

module Wurk
  # Retry surface. The full retry algorithm (counter bump, jitter, morgue,
  # death handlers) lands in a later PR — this stub exists so middleware can
  # raise `Wurk::JobRetry::Skip` to tell the processor "I already handled
  # this; do not retry, do not log error".
  #
  # Spec: docs/target/sidekiq-free.md §17.
  class JobRetry
    DEFAULT_MAX_RETRY_ATTEMPTS = 25

    # Raised after process_retry has dealt with the failure. The processor
    # rescues `Handled` and exits the job cleanly.
    class Handled < RuntimeError; end

    # Subclass of Handled with the same semantics — used when middleware
    # short-circuits processing (e.g. interrupt-handler re-pushed the job).
    class Skip < Handled; end
  end
end
