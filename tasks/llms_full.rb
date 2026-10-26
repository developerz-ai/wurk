# frozen_string_literal: true

# Builds docs/site/llms-full.txt — the single-fetch, full-content companion to
# llms.txt for AI agents that want selected guides in one fetch.
# Generation keeps the selected source bodies verbatim; inventory validation
# requires every docs/*.md path to be included or explicitly excluded, so new
# guides cannot silently escape review. Nested docs remain outside that inventory.
#
# `rake docs:llms_full` writes the file; the pages workflow regenerates it on
# every publish to keep the generated content fresh.
module WurkDocs
  module LlmsFull
    # The concise map (already published at /wurk/llms.txt). Inlined first so a
    # full-text reader still gets the H1 + summary + sectioned overview.
    MAP = 'docs/site/llms.txt'

    # User-facing guides worth inlining whole. The big target/sidekiq-*.md parity
    # specs (1k+ lines each) are intentionally left as links in the map — too
    # large to inline, and not the migration-path narrative an agent needs first.
    DOCS = %w[
      docs/migrate-from-sidekiq.md
      docs/running.md
      docs/configuration.md
      docs/deployment.md
      docs/active-job.md
      docs/testing.md
      docs/retries.md
      docs/batches.md
      docs/rate-limiting.md
      docs/periodic-jobs.md
      docs/runbook.md
      docs/unique-jobs.md
      docs/iterable-jobs.md
      docs/reliability.md
      docs/middleware.md
      docs/api.md
      docs/api-http.md
      docs/job-status.md
      docs/flows.md
      docs/telemetry.md
      docs/metrics.md
      docs/sentry.md
      docs/encryption.md
      docs/profiling.md
      docs/dashboard.md
      docs/authentication.md
      docs/secrets.md
      docs/metrics-history.md
      docs/benchmarks.md
    ].freeze

    EXCLUSIONS = {
      'docs/compatibility.md' => 'Legal and background context, not a user-facing guide.',
      'docs/conformance.md' => 'Contributor guidance for maintaining parity oracles.',
      'docs/demo-deploy.md' => 'Project-specific demo operations, not host-app deployment guidance.'
    }.freeze

    def self.validate_inventory(root, docs: DOCS, exclusions: EXCLUSIONS)
      errors = inventory_errors(root, docs, exclusions).filter_map do |diagnostic, paths|
        "#{diagnostic}: #{paths.join(', ')}" unless paths.empty?
      end
      raise ArgumentError, "llms-full inventory invalid: #{errors.join('; ')}" unless errors.empty?
    end

    def self.inventory_errors(root, docs, exclusions)
      discovered = Dir.glob('docs/*.md', base: root)
      accounted = docs + exclusions.keys
      entry_errors(docs, exclusions).merge(
        'unaccounted docs (add to DOCS or EXCLUSIONS)' => discovered - accounted,
        'missing/stale inventory entries' => accounted - discovered
      )
    end
    private_class_method :inventory_errors

    def self.entry_errors(docs, exclusions)
      {
        'duplicate inclusions' => docs.tally.select { |_, count| count > 1 }.keys,
        'included and excluded' => docs & exclusions.keys,
        'blank exclusion reasons' => exclusions.select { |_, reason| reason.to_s.strip.empty? }.keys
      }
    end
    private_class_method :entry_errors

    def self.build(root)
      validate_inventory(root)
      sections = [File.read(File.join(root, MAP)).rstrip]
      intro = 'Selected guides follow verbatim for single-fetch reading; other documents remain linked in the map.'
      sections << "---\n\n# Full documents\n\n#{intro}"
      DOCS.each do |rel|
        body = File.read(File.join(root, rel))
        sections << "---\n\n<!-- source: #{rel} -->\n\n#{body}"
      end
      "#{sections.join("\n\n")}\n"
    end

    def self.write(root)
      out = File.join(root, 'docs/site/llms-full.txt')
      File.write(out, build(root))
      out
    end
  end
end
