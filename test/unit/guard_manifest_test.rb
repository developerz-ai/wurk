# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require_relative '../../tasks/release_helpers'

# A docs-only PR runs test/guards.txt instead of the suite, so a test that reads
# docs and is missing from the list is a test such a PR can break unnoticed.
class GuardManifestTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  MANIFEST = File.join(ROOT, 'test', 'guards.txt')
  TEST_YML = File.join(ROOT, '.github', 'workflows', 'test.yml')
  # A string naming a doc, policy or workflow path. Reading anything like this makes
  # a test a guard; test/parity and test/conformance run on docs-only PRs anyway.
  READS_DOCS = %r{
    ^[^\#\n]*(?:
      \b(?:README|CLAUDE|CHANGELOG|CONTRIBUTING|RELEASE|SECURITY)\.md
      | ['"/]docs/ | ['"]docs['"] | ['"/]\.dz['"/] | ['"/]\.github['"/]
    )
  }x

  def listed = ReleaseHelpers.guard_manifest(MANIFEST)

  def workflow = @workflow ||= YAML.load_file(TEST_YML)

  def filters
    step = workflow.dig('jobs', 'detect', 'steps').find { |candidate| candidate['id'] == 'filter' }
    YAML.safe_load(step.dig('with', 'filters'))
  end

  def test_every_test_that_reads_docs_is_a_guard
    tests = Dir[File.join(ROOT, 'test', '{unit,engine,integration}', '**', '*_test.rb')]
    readers = tests.select { |path| File.read(path).match?(READS_DOCS) }
                   .map { |path| path.delete_prefix("#{ROOT}/") }

    assert_empty readers - listed - EXEMPT.keys,
                 'these read docs: add them to test/guards.txt, or to EXEMPT here with the reason'
  end

  # Reads a doc but boots the dummy app, which the guards job does not build. The full
  # run on main still covers it, so a docs-only PR could only break it there.
  # release_helpers_test.rb builds its CHANGELOG.md and docs/changelog/ in a tmpdir and
  # reads no checked-in doc, so a docs-only PR cannot break it.
  EXEMPT = {
    'test/engine/api_mutations_test.rb' => 'needs the dummy app',
    'test/unit/release_helpers_test.rb' => 'writes its docs in a tmpdir'
  }.freeze

  def test_a_listed_file_that_does_not_exist_is_an_error_not_a_smaller_guard
    Dir.mktmpdir('guards') do |dir|
      FileUtils.mkdir_p(File.join(dir, 'test'))
      path = File.join(dir, 'test', 'guards.txt')
      File.write(path, "# comment\ntest/unit/gone_test.rb\n")

      error = assert_raises(RuntimeError) { ReleaseHelpers.guard_manifest(path) }

      assert_includes error.message, 'gone_test.rb'
    end
  end

  # What separates a docs-only change from a code one is the gap between the two filters.
  def test_the_only_paths_treated_as_docs_are_docs
    assert_equal %w[*.md .claude/** .dz/** .github/*.md docs/**], (filters.fetch('ruby') - filters.fetch('code')).sort
    assert_empty filters.fetch('code') - filters.fetch('ruby'), 'the code filter must stay inside `ruby`'
  end

  # The required check must carry a verdict on a docs-only PR, or a guard failure there
  # could merge.
  def test_the_required_job_runs_the_guards_on_a_docs_only_change
    test_job = workflow.dig('jobs', 'test')
    step = test_job.fetch('steps').find { |candidate| candidate['name'].to_s.start_with?('guard manifest') }

    assert_equal "env.GUARDS_ONLY == 'true'", step.fetch('if')
    assert_includes step.fetch('run'), 'rake test:guards'
    refute_includes Array(test_job['needs']), 'guards', 'the required job must not depend on a job that can fail first'
  end

  # A shared group replaces a queued run whatever cancel-in-progress says, which left
  # one main commit in six with no verdict.
  def test_each_main_commit_gets_its_own_run
    %w[test topology].each do |name|
      concurrency = YAML.load_file(File.join(ROOT, '.github', 'workflows', "#{name}.yml")).fetch('concurrency')

      assert_includes concurrency.fetch('group'), "github.event_name == 'push' && github.sha", name
      assert_equal "${{ github.event_name == 'pull_request' }}", concurrency.fetch('cancel-in-progress'), name
    end
  end

  # With a green PR run and the same tree, main used to skip, and a docs-only PR's green
  # run was only the guards. EXEMPT above relies on main running the suite for these.
  def test_main_skips_only_when_the_pr_really_ran_the_suite
    dup_step = workflow.dig('jobs', 'detect', 'steps').find { |step| step['id'] == 'dup' }
    suite_step = 'rake test (with coverage gate)'

    assert_includes dup_step.fetch('run'), suite_step
    assert(workflow.dig('jobs', 'test', 'steps').any? { |step| step['name'] == suite_step })
  end

  # A skipped check satisfies the ruleset, so a failed `detect` must not skip anything.
  def test_a_failed_detect_runs_every_gated_job_rather_than_skipping_it
    %w[test topology ecosystem].each do |name|
      jobs = YAML.load_file(File.join(ROOT, '.github', 'workflows', "#{name}.yml")).fetch('jobs')
      gated = jobs.select { |_, job| Array(job['needs']).include?('detect') }

      refute_empty gated
      gated.each do |job_name, job|
        assert_equal '${{ !cancelled() }}', job['if'], "#{name}/#{job_name}"
        assert_includes job.dig('env', 'RUN'), "needs.detect.result != 'success' ||", "#{name}/#{job_name}"
      end
    end
  end

  def test_the_compat_legs_wait_for_the_guards
    compat = workflow.dig('jobs', 'compat')

    assert_includes compat.fetch('needs'), 'guards'
    assert_includes compat.dig('env', 'RUN'), "needs.guards.result == 'success'"
  end
end
