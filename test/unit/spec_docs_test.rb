# frozen_string_literal: true

require 'minitest/autorun'

# Ensures authoritative spec docs (the oracles for wire-compat) are present
# and non-empty. These files are critical to parity testing and must never be
# deleted or truncated; they live under docs/target/ at repo root.
#
# Background: during audit, spec files were found deleted but uncommitted,
# breaking parity-test validation. This guard prevents silent regressions.
class SpecDocsTest < Minitest::Test
  SPEC_FILES = %w[
    sidekiq-free.md
    sidekiq-pro.md
    sidekiq-ent.md
  ].freeze

  def test_spec_docs_exist_and_are_nonempty
    root = File.expand_path('../../', __dir__)
    docs_target = File.join(root, 'docs', 'target')

    refute(
      !File.directory?(docs_target),
      "docs/target/ directory does not exist"
    )

    SPEC_FILES.each do |filename|
      spec_file = File.join(docs_target, filename)
      assert(
        File.exist?(spec_file),
        "spec doc #{filename} does not exist in docs/target/"
      )
      assert(
        File.size(spec_file) > 0,
        "spec doc #{filename} is empty (0 bytes)"
      )
    end
  end
end
