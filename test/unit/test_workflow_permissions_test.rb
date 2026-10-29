# frozen_string_literal: true

require_relative '../test_helper'
require 'yaml'

# Gates the GITHUB_TOKEN permissions of .github/workflows/test.yml — the main
# CI lane.
#
# The workflow-level `permissions:` block is the ceiling every job without a
# `permissions:` block of its own inherits, so it is the one place this lane's
# blast radius is written down. It is pinned to exactly three read scopes:
#
#   * contents: read       — the checkout step;
#   * pull-requests: read  — dorny/paths-filter reads the PR's changed-file
#                             list on pull_request events;
#   * actions: read        — bin/ci-dup-push reads the merged PR's workflow
#                             runs.
#
# A MAPPING, never a scalar: `permissions: read-all` (or `write-all`) grants
# every scope, which is the opposite of least privilege and cannot be narrowed
# by a job that carries no block of its own.
#
# A DROPPED scope is not a widening — the set is still a subset — so the
# exact-set assertion is the only thing that catches a lost grant such as
# `actions: read`, the scope bin/ci-dup-push needs to read the merged PR's
# workflow runs.
#
# A job-level `permissions:` block REPLACES the workflow-level set — GitHub
# does not merge the two — so it is a silent widening whenever it grants more
# than the workflow-level set does. Today NO job in test.yml declares one, so
# that half of the guard passes by the ABSENCE of an override; the mutation
# cases below carry the weight and prove the guard would reject one.
#
# Reads files; touches no Redis, no network and no shared state.
class TestWorkflowPermissionsTest < Wurk::Test::UnitCase
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  WORKFLOW_YML = File.join(ROOT, '.github', 'workflows', 'test.yml')

  # The exact workflow-level set the lane may grant: a scope outside it, or a
  # level other than `read`, is a widening.
  EXPECTED_PERMISSIONS = {
    'contents' => 'read',
    'pull-requests' => 'read',
    'actions' => 'read'
  }.freeze

  # A job-level block may only narrow the workflow-level set: `read` (or
  # `none`) on a scope the workflow-level set already grants.
  ALLOWED_JOB_LEVELS = %w[read none].freeze

  def test_workflow_level_permissions_are_exactly_the_three_read_scopes
    assert_workflow_permissions_are_least_privilege(workflow)
  end

  def test_no_job_declares_a_permissions_block_that_widens_the_workflow_level_set
    assert_no_job_widens_permissions(workflow)
  end

  # --- mutation cases ------------------------------------------------------
  # The guard must be able to fail. Each case mutates a COPY of the parsed
  # workflow, runs the SAME guard over it, and pins the failure to a message
  # that names the offending grant.

  # A scope the lane never needed: `issues: read` would let a step read the
  # tracker on every PR.
  def test_a_workflow_level_issues_grant_is_rejected
    mutated = workflow_copy
    mutated['permissions']['issues'] = 'read'

    error = assert_raises(Minitest::Assertion) do
      assert_workflow_permissions_are_least_privilege(mutated)
    end

    assert_includes error.message, 'issues'
  end

  # A write on a scope the lane reads: `pull-requests: write` would let a step
  # act on the PR.
  def test_a_workflow_level_pull_requests_write_grant_is_rejected
    mutated = workflow_copy
    mutated['permissions']['pull-requests'] = 'write'

    error = assert_raises(Minitest::Assertion) do
      assert_workflow_permissions_are_least_privilege(mutated)
    end

    assert_includes error.message, 'pull-requests'
    assert_includes error.message, 'write'
  end

  # A job-level block REPLACES the workflow-level set, so a job that asks for
  # `contents: write` gets it, whatever the workflow-level block says.
  def test_a_job_level_contents_write_block_is_rejected
    mutated = workflow_copy
    job = mutated.fetch('jobs').fetch(mutated.fetch('jobs').keys.first)
    job['permissions'] = { 'contents' => 'write' }

    error = assert_raises(Minitest::Assertion) do
      assert_workflow_permissions_are_least_privilege(mutated)
    end

    assert_includes error.message, 'contents'
    assert_includes error.message, 'write'
  end

  # The same replacement, one scope further out: `issues: read` is outside the
  # workflow-level read set.
  def test_a_job_level_issues_block_is_rejected
    mutated = workflow_copy
    job = mutated.fetch('jobs').fetch(mutated.fetch('jobs').keys.first)
    job['permissions'] = { 'issues' => 'read' }

    error = assert_raises(Minitest::Assertion) do
      assert_workflow_permissions_are_least_privilege(mutated)
    end

    assert_includes error.message, 'issues'
  end

  # A DROPPED workflow-level scope is invisible to a widening check — the set
  # is still a subset, so `outside` and `widened` both stay empty — and only
  # the exact-set assertion can catch it. Losing `actions: read` takes away
  # the `gh api .../actions/runs` scope bin/ci-dup-push needs.
  def test_a_dropped_workflow_level_scope_is_rejected
    mutated = workflow_copy
    mutated['permissions'].delete('actions')

    error = assert_raises(Minitest::Assertion) do
      assert_workflow_permissions_are_least_privilege(mutated)
    end

    assert_includes error.message, 'actions'
  end

  # A scalar workflow-level block grants EVERY scope — the opposite of least
  # privilege — and no job can narrow it, since it carries no block of its own.
  def test_a_scalar_workflow_level_permissions_block_is_rejected
    mutated = workflow_copy
    mutated['permissions'] = 'read-all'

    error = assert_raises(Minitest::Assertion) do
      assert_workflow_permissions_are_least_privilege(mutated)
    end

    assert_includes error.message, 'MAPPING'
    assert_includes error.message, 'scalar'
  end

  # The same scalar shape one level down: a job-level `read-all` hands that
  # job every scope, whatever the workflow-level block says.
  def test_a_scalar_job_level_permissions_block_is_rejected
    mutated = workflow_copy
    job = mutated.fetch('jobs').fetch(mutated.fetch('jobs').keys.first)
    job['permissions'] = 'read-all'

    error = assert_raises(Minitest::Assertion) do
      assert_no_job_widens_permissions(mutated)
    end

    assert_includes error.message, 'scalar'
    assert_includes error.message, 'read-all'
  end

  private

  # The whole guard, parameterized on the parsed workflow hash, so a mutated
  # copy can be run through it.
  def assert_workflow_permissions_are_least_privilege(workflow)
    permissions = workflow['permissions']

    assert_kind_of Hash, permissions,
                   'the workflow-level `permissions:` must be a MAPPING of scope => level — a scalar ' \
                   "(`read-all`/`write-all`) grants every scope (got #{permissions.inspect})"

    outside = permissions.reject { |scope, _level| EXPECTED_PERMISSIONS.key?(scope) }

    assert_empty outside,
                 "the workflow-level `permissions:` grants #{describe_grants(outside)} — only " \
                 "#{EXPECTED_PERMISSIONS.keys.join(', ')} may be granted"

    widened = permissions.reject { |scope, level| EXPECTED_PERMISSIONS[scope] == level }

    assert_empty widened,
                 "the workflow-level `permissions:` grants #{describe_grants(widened)} — every scope " \
                 'must stay at `read`'

    assert_equal EXPECTED_PERMISSIONS, permissions,
                 "the workflow-level `permissions:` must be exactly #{EXPECTED_PERMISSIONS.inspect}"

    assert_no_job_widens_permissions(workflow)
  end

  # A job-level block is the job's own ceiling — GitHub REPLACES the
  # workflow-level set with it, it does not merge — so it may only narrow the
  # workflow-level set, never widen it.
  def assert_no_job_widens_permissions(workflow)
    workflow.fetch('jobs', {}).each do |job_name, job|
      next unless job.is_a?(Hash)

      job_permissions = job['permissions']
      next if job_permissions.nil?

      assert_kind_of Hash, job_permissions,
                     "the job #{job_name.inspect} declares a `permissions:` block — a scalar " \
                     "(`read-all`/`write-all`) grants every scope (got #{job_permissions.inspect})"

      job_permissions.each do |scope, level|
        assert_includes EXPECTED_PERMISSIONS.keys, scope,
                        "the job #{job_name.inspect} grants `#{scope}: #{level}` — a job-level block " \
                        'REPLACES the workflow-level set, so it may only narrow it ' \
                        "(#{EXPECTED_PERMISSIONS.keys.join(', ')})"

        assert_includes ALLOWED_JOB_LEVELS, level.to_s,
                        "the job #{job_name.inspect} grants `#{scope}: #{level}` — a job-level block " \
                        'REPLACES the workflow-level set, so it may only narrow it (read, none)'
      end
    end
  end

  # "contents: read, pull-requests: write" — the offending grant, named.
  def describe_grants(grants)
    grants.map { |scope, level| "`#{scope}: #{level}`" }.join(', ')
  end

  def workflow
    @workflow ||= YAML.load_file(WORKFLOW_YML)
  end

  # A mutable copy of the parsed workflow, so a mutation case cannot touch the
  # file on disk.
  def workflow_copy
    deep_dup(workflow)
  end

  def deep_dup(object)
    case object
    when Hash then object.to_h { |key, value| [key, deep_dup(value)] }
    when Array then object.map { |value| deep_dup(value) }
    else object
    end
  end
end
