# frozen_string_literal: true

module Wurk
  # Abstract fetcher. Wurk::Fetcher::Reliable is the only implementation
  # we ship and the only one we recommend — BLMOVE-based reliable fetch.
  # No "basic fetch" mode.
  class Fetcher
    def retrieve_work; end
    def bulk_requeue(in_progress); end

    # Quiet hook: Manager#quiet calls this so retrieve_work can short-circuit
    # and stop pulling new work the instant a process is quieted. No-op in the
    # abstract base; Reliable flips its drain flag.
    def terminate; end

    # Send any ACK the fetcher is holding back rather than sending immediately.
    # Processor calls this as it stops, so a job that finished but whose ACK
    # never caught a fetch to ride on can't be reclaimed as unfinished. No-op
    # in the abstract base; only Reliable defers.
    def flush_pending_acks; end
  end
end
