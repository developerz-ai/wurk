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
  end
end
