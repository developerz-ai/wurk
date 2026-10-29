# frozen_string_literal: true

require 'minitest/autorun'
require 'date'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'yaml'

# Pins the error paths of the `spec-docs` CI job's shell block
# (.github/workflows/test.yml, the `check spec docs` step).
#
# test/unit/spec_docs_test.rb pins the Ruby half of the same contract: the
# manifest exists and lists at least one spec doc, every listed doc exists and
# is non-empty, and the manifest's set equals the docs/target/*.md set on disk.
# The CI half was pinned by nothing: dropping the `diff` comparison from the
# workflow would leave the job green for an unlisted spec doc and nothing in
# the suite would go red.
#
# So this file EXTRACTS the step's `run:` body from the workflow and RUNS it
# under bash against a throwaway docs/target tree — the shell block is
# executed as CI runs it rather than re-implemented here, so a deleted error
# path cannot leave this guard green.
#
# Reads files only: no test_helper, no Redis, no network, so it stays
# runnable on its own
# (`bin/rake test:unit TEST=test/unit/spec_docs_workflow_test.rb`).
class SpecDocsWorkflowTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  WORKFLOW = File.join(ROOT, '.github', 'workflows', 'test.yml')
  STEP_NAME = 'check spec docs'

  def test_a_missing_manifest_fails_the_check
    _stdout, stderr, status = run_check(manifest: nil, docs: { 'sidekiq-free.md' => "# free\n" })

    refute_predicate status, :success?, "the check must fail without a manifest:\n#{stderr}"
    assert_includes stderr, 'docs/target/SPEC_FILES does not exist'
  end

  def test_a_manifest_that_lists_no_spec_docs_fails_the_check
    _stdout, stderr, status = run_check(manifest: "# a comment only\n\n", docs: {})

    refute_predicate status, :success?, "the check must fail on an empty manifest:\n#{stderr}"
    assert_includes stderr, 'lists no spec docs'
  end

  # The case the set comparison used to swallow: the manifest and the
  # docs/target/*.md set disagree BECAUSE a listed doc was deleted. The
  # per-file check runs first, so the failure names the missing file.
  def test_a_listed_spec_doc_that_was_deleted_fails_with_the_missing_file_error
    _stdout, stderr, status = run_check(manifest: "sidekiq-free.md\nsidekiq-pro.md\n",
                                        docs: { 'sidekiq-free.md' => "# free\n" })

    refute_predicate status, :success?, "the check must fail when a listed spec doc is gone:\n#{stderr}"
    assert_includes stderr, 'docs/target/sidekiq-pro.md does not exist'
    refute_includes stderr, 'disagree',
                    'a listed-but-deleted spec doc is a missing file, not a set disagreement — ' \
                    'the set comparison must not pre-empt the per-file check'
  end

  def test_a_zero_byte_listed_spec_doc_fails_the_check
    _stdout, stderr, status = run_check(manifest: "sidekiq-free.md\n", docs: { 'sidekiq-free.md' => '' })

    refute_predicate status, :success?, "the check must fail on an empty spec doc:\n#{stderr}"
    assert_includes stderr, 'docs/target/sidekiq-free.md is empty'
  end

  def test_a_spec_doc_on_disk_that_the_manifest_does_not_list_fails_the_check
    _stdout, stderr, status = run_check(manifest: "sidekiq-free.md\n",
                                        docs: { 'sidekiq-free.md' => "# free\n" },
                                        unlisted: ['sidekiq-extra.md'])

    refute_predicate status, :success?, "the check must fail on an unlisted spec doc:\n#{stderr}"
    assert_includes stderr, 'disagree'
  end

  def test_a_manifest_matching_the_spec_docs_on_disk_passes_the_check
    stdout, stderr, status = run_check(manifest: "# the authoritative set\nsidekiq-free.md\n\n",
                                       docs: { 'sidekiq-free.md' => "# free\n" })

    assert_predicate status, :success?, "the check must pass for a consistent tree:\n#{stderr}"
    assert_includes stdout, 'docs/target/sidekiq-free.md exists and is non-empty'
  end

  # The manifest format promises "strip surrounding whitespace from each line"
  # (docs/target/SPEC_FILES). The shell reader trims every entry, so a padded
  # line and a blank line must still name the same doc.
  def test_a_manifest_entry_with_surrounding_whitespace_is_trimmed
    padded_manifest = "# a comment\n\n  sidekiq-free.md  \n"
    stdout, stderr, status = run_check(manifest: padded_manifest, docs: { 'sidekiq-free.md' => "# free\n" })

    assert_predicate status, :success?, "the check must pass for a padded manifest entry:\n#{stderr}"
    assert_includes stdout, 'docs/target/sidekiq-free.md exists and is non-empty'
  end

  private

  # Runs the workflow's own `run:` body over a throwaway docs/target tree and
  # returns [stdout, stderr, status]. `bash -e` is the shell GitHub Actions
  # runs a `run:` block with.
  def run_check(manifest:, docs:, unlisted: [])
    Dir.mktmpdir('wurk-spec-docs-') do |dir|
      target = File.join(dir, 'docs', 'target')
      FileUtils.mkdir_p(target)
      File.write(File.join(target, 'SPEC_FILES'), manifest) if manifest
      docs.each { |name, body| File.write(File.join(target, name), body) }
      unlisted.each { |name| File.write(File.join(target, name), "# unlisted\n") }

      script = File.join(dir, 'check-spec-docs.sh')
      File.write(script, check_spec_docs_script)

      stdout, stderr, status = Open3.capture3('bash', '-e', script, chdir: dir)

      [stdout, stderr, status]
    end
  end

  # The `check spec docs` step's shell block, as CI runs it.
  def check_spec_docs_script
    workflow = YAML.safe_load_file(WORKFLOW, permitted_classes: [Date, Time], aliases: true)
    job = workflow.fetch('jobs').fetch('spec-docs')
    step = job.fetch('steps').find { |candidate| candidate['name'] == STEP_NAME }

    raise "the spec-docs job lost its #{STEP_NAME.inspect} step" if step.nil?

    step.fetch('run')
  end
end
