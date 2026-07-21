# frozen_string_literal: true

# Builds docs/site/llms-full.txt — the single-fetch, full-content companion to
# llms.txt for AI agents that would rather inline everything than follow links.
# Generated (never hand-edited) from the canonical guides so it cannot drift:
# the llms.txt map up top, then each user-facing guide inlined verbatim.
#
# `rake docs:llms_full` writes the file; the pages workflow regenerates it on
# every publish; llms_full_test.rb exercises this builder so a removed/renamed
# source doc fails CI instead of silently dropping out of the dump.
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
      docs/unique-jobs.md
      docs/iterable-jobs.md
      docs/reliability.md
      docs/middleware.md
      docs/api.md
      docs/metrics.md
      docs/encryption.md
      docs/profiling.md
      docs/dashboard.md
      docs/authentication.md
      docs/metrics-history.md
    ].freeze

    def self.build(root)
      sections = [File.read(File.join(root, MAP)).rstrip]
      intro = 'The complete text of each guide linked above, inlined for single-fetch reading.'
      sections << "---\n\n# Full documents\n\n#{intro}"
      DOCS.each do |rel|
        body = File.read(File.join(root, rel)).rstrip
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
