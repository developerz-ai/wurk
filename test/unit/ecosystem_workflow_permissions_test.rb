# frozen_string_literal: true

require_relative '../test_helper'
require 'yaml'

# Guards the GITHUB_TOKEN permissions of .github/workflows/ecosystem.yml.
#
# The workflow runs third-party gem suites against this repo and, on the
# weekly schedule, POSTs to an external API with the workflow's own token, so
# its permissions ARE the blast radius of the lane. The workflow-level
# `permissions:` block is the ceiling every job inherits, and it must stay
# exactly the read-only set:
#
#   * contents: read      — the checkout step;
#   * pull-requests: read — dorny/paths-filter reads the PR's changed-file
#                            list on pull_request events;
#   * actions: read       — bin/ci-dup-push reads the merged PR's workflow
#                            runs, and the watcher reads its own prior
#                            `wurk-watcher-state` artifact through
#                            `gh api .../actions/artifacts`
#                            (.github/workflows/ecosystem.yml:194-199).
#
# A job-level `permissions:` block REPLACES the workflow-level set — GitHub
# does not merge the two — so an override that grants `write`, or a scope
# outside the three above, silently widens that job's token. NO job in this
# workflow declares one today: the rule below passes by the ABSENCE of an
# override, and the mutation cases carry the weight.
#
# Reads files; touches no Redis, no network and no shared state.
class EcosystemWorkflowPermissionsTest < Wurk::Test::UnitCase
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  ECOSYSTEM_YML = File.join(ROOT, '.github', 'workflows', 'ecosystem.yml')

  EXPECTED_PERMISSIONS = {
    'contents' => 'read',
    'pull-requests' => 'read',
    'actions' => 'read'
  }.freeze

  # `none` switches a scope off; anything above `read` is a widening.
  ALLOWED_LEVELS = %w[read none].freeze

  def test_workflow_level_permissions_are_exactly_the_read_only_set
    assert_workflow_permissions(ecosystem_workflow)
  end

  # The guard must be able to fail. Each case below runs the SAME guard over
  # a mutated copy of the parsed workflow and pins the failure to a message
  # that names the offending grant.
  def test_a_workflow_level_issues_grant_is_rejected
    workflow = workflow_copy
    workflow.fetch('permissions')['issues'] = 'read'

    error = assert_raises(Minitest::Assertion) do
      assert_workflow_permissions(workflow)
    end

    assert_includes error.message, 'issues', 'the guard must name the offending grant'
  end

  def test_a_workflow_level_pull_requests_write_grant_is_rejected
    workflow = workflow_copy
    workflow.fetch('permissions')['pull-requests'] = 'write'

    error = assert_raises(Minitest::Assertion) do
      assert_workflow_permissions(workflow)
    end

    assert_includes error.message, 'pull-requests'
    assert_includes error.message, 'write'
  end

  def test_a_job_level_contents_write_block_is_rejected
    workflow = workflow_copy
    target = workflow.fetch('jobs').keys.first
    workflow.fetch('jobs').fetch(target)['permissions'] = { 'contents' => 'write' }

    error = assert_raises(Minitest::Assertion) do
      assert_workflow_permissions(workflow)
    end

    assert_includes error.message, 'contents'
    assert_includes error.message, 'write'
  end

  def test_a_job_level_issues_block_is_rejected
    workflow = workflow_copy
    target = workflow.fetch('jobs').keys.first
    workflow.fetch('jobs').fetch(target)['permissions'] = { 'issues' => 'read' }

    error = assert_raises(Minitest::Assertion) do
      assert_workflow_permissions(workflow)
    end

    assert_includes error.message, 'issues'
  end

  # A DROPPED scope is as much a regression as an added one: `actions: read`
  # is what the watcher reads its own prior artifact through (`gh api
  # .../actions/artifacts`, ecosystem.yml:194-199), so a workflow that
  # quietly loses it breaks the watcher's dedup. `extra` and `wrong_level`
  # both stay empty when a scope disappears — only `missing` sees it, so
  # this case is the one that proves that branch fires.
  def test_a_dropped_workflow_level_scope_is_rejected
    workflow = workflow_copy
    workflow.fetch('permissions').delete('actions')

    error = assert_raises(Minitest::Assertion) do
      assert_workflow_permissions(workflow)
    end

    assert_includes error.message, 'actions'
  end

  # A scalar (`read-all`/`write-all`) grants EVERY scope — the opposite of
  # least privilege, and it cannot be narrowed by the jobs that carry no
  # block of their own.
  def test_a_scalar_workflow_level_permissions_block_is_rejected
    workflow = workflow_copy
    workflow['permissions'] = 'read-all'

    error = assert_raises(Minitest::Assertion) do
      assert_workflow_permissions(workflow)
    end

    assert_includes error.message, 'mapping'
  end

  # Same for a job-level block: it REPLACES the workflow-level set, so a
  # scalar there hands that job every scope, whatever the workflow-level
  # block says.
  def test_a_scalar_job_level_permissions_block_is_rejected
    workflow = workflow_copy
    target = workflow.fetch('jobs').keys.first
    workflow.fetch('jobs').fetch(target)['permissions'] = 'write-all'

    error = assert_raises(Minitest::Assertion) do
      assert_workflow_permissions(workflow)
    end

    assert_includes error.message, 'mapping'
  end

  private

  # The whole guard, parameterized on the parsed workflow, so a mutated copy
  # can be run through it.
  def assert_workflow_permissions(workflow)
    permissions = workflow['permissions']

    refute_nil permissions, 'the workflow must declare a workflow-level `permissions:` block'
    assert_kind_of Hash, permissions, 'the workflow-level `permissions:` must be a mapping, not a scalar'

    extra = permissions.keys - EXPECTED_PERMISSIONS.keys
    missing = EXPECTED_PERMISSIONS.keys - permissions.keys
    wrong_level = permissions.reject { |scope, level| EXPECTED_PERMISSIONS[scope] == level }

    assert_empty extra, "the workflow-level `permissions:` grants #{extra.join(', ')} — outside the read set"
    assert_empty missing, "the workflow-level `permissions:` is missing #{missing.join(', ')}"
    assert_empty wrong_level, "the workflow-level `permissions:` must grant read, not #{wrong_level.inspect}"

    assert_no_job_level_widening(workflow)
  end

  # A job-level block REPLACES the workflow-level set: it is not merged with
  # it. So every scope it names must be one the workflow already holds, and
  # every level must be read or none.
  def assert_no_job_level_widening(workflow)
    workflow.fetch('jobs').each do |name, job|
      job_permissions = job['permissions']

      next if job_permissions.nil?

      assert_kind_of Hash, job_permissions, "the job #{name} must declare `permissions:` as a mapping, not a scalar"

      job_permissions.each do |scope, level|
        assert_includes EXPECTED_PERMISSIONS.keys, scope, "the job #{name} grants #{scope} — outside the read set"
        assert_includes ALLOWED_LEVELS, level, "the job #{name} grants #{scope}: #{level} — only read or none"
      end
    end
  end

  def ecosystem_workflow
    @ecosystem_workflow ||= YAML.load_file(ECOSYSTEM_YML)
  end

  # The parsed workflow as a mutable copy, for the mutation cases above: the
  # real file stays untouched while the gate is proven to reject a regression.
  def workflow_copy
    deep_dup(ecosystem_workflow)
  end

  def deep_dup(object)
    case object
    when Hash then object.to_h { |key, value| [key, deep_dup(value)] }
    when Array then object.map { |value| deep_dup(value) }
    else object
    end
  end
end
