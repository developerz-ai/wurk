# frozen_string_literal: true

module Wurk
  # Abstract fetcher. Wurk::Fetcher::Reliable is the only implementation
  # we ship and the only one we recommend — BLMOVE-based reliable fetch.
  # No "basic fetch" mode.
  class Fetcher
    def retrieve_work; end
    def bulk_requeue(in_progress); end
  end
end
