# frozen_string_literal: true

# ---------------------------------------------------------------------------
# developerz.ai stage-7 review-lane CANARY FIXTURE #2 — NOT PRODUCTION CODE.
#
# Second planted-defect fixture, deliberately on a NEW path: the grounding fix
# (#1482) lets a finding cite the patch itself, which is the only citation a
# brand-new file can ever carry — an index cannot know a file that did not
# exist when it was built.
#
# This file is never required, never executed, and never merged. It exists on
# the #361 smoke branch only to hand the native reviewer a diff containing
# KNOWN, deliberately planted defects, so that the findings count reads as a
# measurement against an answer key rather than a guess. Delete with the branch.
# ---------------------------------------------------------------------------

require 'yaml'
require 'digest'

module Wurk
  module Stage7ReviewCanaryTwo
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
