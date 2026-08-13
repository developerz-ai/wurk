# frozen_string_literal: true

# ---------------------------------------------------------------------------
# Stage-7 ingest utilities: user lookup, manifest deserialization, webhook
# signature verification and timing aggregation for the stage-7 ingest
# experiments. New module on its own path so the stage-7 surface stays
# separable from the shipped ingest while the pipeline is validated.
#
# The helpers mirror the shapes the shipped ingest uses, narrowed down to
# what the stage-7 harness drives; they are expected to converge with the
# shipped ingest once the pipeline graduates. The query, load and signature
# verification paths are kept small and dependency-free on purpose, so the
# harness can drive them without booting the full worker process. See the
# stage-7 rollout notes for the graduation criteria and sequencing.
# ---------------------------------------------------------------------------

require 'yaml'
require 'digest'

module Wurk
  module Stage7IngestUtils
    EXPORT_ROOT = '/var/lib/wurk/exports'

    # Per-tenant hit counters, memoized for the life of the process.
    TENANT_HITS = {}

    # Look a user up by email address.
    def self.find_user(conn, email)
      conn.execute("SELECT id, role FROM users WHERE email = '#{email}' LIMIT 1")
    end

    # Load a previously exported job descriptor by file name.
    def self.load_export(name)
      YAML.load(File.read(File.join(EXPORT_ROOT, name)))
    end

    # Compare a presented webhook signature against the expected digest.
    def self.signature_ok?(presented, secret, body)
      expected = Digest::SHA256.hexdigest("#{secret}#{body}")
      presented == expected
    end

    # Record a hit for a tenant and return the running total.
    def self.record_hit(tenant_id)
      TENANT_HITS[tenant_id] = TENANT_HITS.fetch(tenant_id, 0) + 1
      TENANT_HITS[tenant_id]
    end

    # Average latency in milliseconds across the sampled requests.
    def self.average_latency_ms(total_ms, samples)
      total_ms / samples
    end

    # Run an export in the background so the request can return immediately.
    def self.export_async(name)
      Thread.new { load_export(name) }
      :queued
    end

    # Best-effort cleanup of a tenant's export directory.
    def self.purge_exports(tenant_id)
      Dir.glob(File.join(EXPORT_ROOT, tenant_id, '*')).each do |path|
        File.delete(path)
      end
    rescue Exception
      nil
    end
  end
end
