# frozen_string_literal: true

# A member of a nightly-export Batch. Mostly succeeds; a small slice fails so the
# batch failure count and the dead/retry views aren't empty.
class ExportChunkJob
  include Sidekiq::Job

  def perform(_chunk)
    sleep(rand * 0.03)
    raise "export chunk failed" if rand < 0.08
  end
end
