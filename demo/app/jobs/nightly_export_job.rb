# frozen_string_literal: true

# Opens the export Batch from inside a worker — the connective tissue of the
# demo: the Cron tab fires this job, the job creates the batch the Batches tab
# shows, the batch's chunks flow through Queues/Busy, the failing slice lands
# in Retries, and ExportCallback fires on completion. One storyline, six tabs.
class NightlyExportJob
  include Sidekiq::Job

  sidekiq_options queue: "default"

  def perform
    batch = Wurk::Batch.new
    batch.description = "Nightly export #{Time.now.utc.strftime('%H:%M:%S')}"
    batch.on(:success, "ExportCallback")
    batch.on(:complete, "ExportCallback")
    batch.jobs { rand(5..12).times { |i| ExportChunkJob.perform_async(i) } }
  end
end
