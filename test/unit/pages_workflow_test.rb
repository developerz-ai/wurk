# frozen_string_literal: true

require_relative '../test_helper'
require 'yaml'

# Guards the job graph of .github/workflows/pages.yml.
#
# Run 45202224101 failed at actions/deploy-pages with "No artifacts named
# 'github-pages' were found for this workflow run" although the same run had
# uploaded a 1.62 MB artifact. That is actions/deploy-pages#451: a deploy step
# in the same job as the upload looks up run-scoped artifacts while one is
# still finalizing and can see none. The repair is to put the upload in a
# `build` job and let `deploy` consume it across the job boundary, where the
# artifact is already visible.
#
# This test pins that boundary, the least-privilege split that goes with it
# (only `deploy` may hold pages/id-token), and the build inputs the site
# needs. The invariants are parameterized so a mutated workflow, including
# the old one-job shape, must be rejected. Each mutation runs on a fixture in
# this file rather than on the checked-in workflow, so the negative cases
# still exercise the guard while pages.yml is being changed.
#
# Reads files; touches no Redis, no network and no shared state.
class PagesWorkflowTest < Wurk::Test::UnitCase
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  PAGES_YML = File.join(ROOT, '.github', 'workflows', 'pages.yml')

  CHECKOUT = 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
  SETUP_RUBY = 'ruby/setup-ruby@f9c4492e86def3e644ab32a0ef185eda5b0c20d0'
  CONFIGURE_PAGES = 'actions/configure-pages@45bfe0192ca1faeb007ade9deae92b16b8254a0d'
  UPLOAD_PAGES = 'actions/upload-pages-artifact@fc324d3547104276b827a68afc52ff2a11cc49c9'
  DEPLOY_PAGES = 'actions/deploy-pages@368f82528645a54fb793d4d04e342629a3f51346'

  PINS = {
    'actions/checkout' => '3d3c42e5aac5ba805825da76410c181273ba90b1',
    'ruby/setup-ruby' => 'f9c4492e86def3e644ab32a0ef185eda5b0c20d0',
    'actions/configure-pages' => '45bfe0192ca1faeb007ade9deae92b16b8254a0d',
    'actions/upload-pages-artifact' => 'fc324d3547104276b827a68afc52ff2a11cc49c9',
    'actions/deploy-pages' => '368f82528645a54fb793d4d04e342629a3f51346'
  }.freeze

  PUSH_PATHS = [
    'docs/**',
    'lib/**',
    '.yardopts',
    'README.md',
    'Rakefile',
    'tasks/llms_full.rb',
    'Gemfile',
    '.github/workflows/pages.yml'
  ].freeze

  # The contract in full. The positive case checks the checked-in file against
  # it; every negative case mutates a copy of this shape and must be rejected.
  def split_workflow
    {
      'permissions' => { 'contents' => 'read' },
      'on' => {
        'push' => { 'branches' => ['main'], 'paths' => PUSH_PATHS.dup },
        'workflow_dispatch' => nil
      },
      'concurrency' => {
        'group' => '${{ github.workflow }}-${{ github.ref }}',
        'cancel-in-progress' => false
      },
      'jobs' => {
        'build' => {
          'runs-on' => 'ubuntu-latest',
          'timeout-minutes' => 10,
          'permissions' => { 'contents' => 'read' },
          'steps' => [
            { 'uses' => CHECKOUT, 'with' => { 'persist-credentials' => false } },
            { 'uses' => SETUP_RUBY, 'with' => { 'ruby-version' => '3.4', 'bundler-cache' => true } },
            { 'run' => 'bundle exec rake yard docs:llms_full' },
            { 'uses' => CONFIGURE_PAGES },
            { 'uses' => UPLOAD_PAGES, 'with' => { 'path' => 'docs/site' } }
          ]
        },
        'deploy' => {
          'runs-on' => 'ubuntu-latest',
          'timeout-minutes' => 10,
          'needs' => ['build'],
          'permissions' => { 'pages' => 'write', 'id-token' => 'write' },
          'environment' => {
            'name' => 'github-pages',
            'url' => '${{ steps.deploy.outputs.page_url }}'
          },
          'steps' => [{ 'id' => 'deploy', 'uses' => DEPLOY_PAGES }]
        }
      }
    }
  end

  def test_pages_workflow_keeps_the_race_free_job_graph
    assert_pages_workflow(pages_workflow)
  end

  # The exact shape that produced run 45202224101: one job uploading and
  # deploying. The guard must fail on it, or it pins nothing.
  def test_guard_rejects_a_single_job_that_uploads_and_deploys
    workflow = split_workflow
    jobs = workflow.fetch('jobs')
    jobs['deploy']['steps'] = jobs.fetch('build').fetch('steps') + jobs.fetch('deploy').fetch('steps')
    jobs.delete('build')
    jobs.fetch('deploy').delete('needs')

    error = assert_raises(Minitest::Assertion) { assert_pages_workflow(workflow) }

    assert_includes error.message, 'build',
                    'the guard must name the missing build job, not just a count mismatch'
  end

  def test_guard_rejects_a_deploy_job_that_does_not_wait_for_build
    workflow = split_workflow
    workflow.fetch('jobs').fetch('deploy').delete('needs')

    error = assert_raises(Minitest::Assertion) { assert_pages_workflow(workflow) }

    assert_includes error.message, 'needs: build'
  end

  # Without the OIDC/pages grant the deploy step cannot publish; with it on
  # `build`, third-party code in `bundle exec rake yard` holds a publish token.
  def test_guard_rejects_publish_permissions_on_the_build_job
    workflow = split_workflow
    workflow.fetch('jobs').fetch('build')['permissions'] = {
      'contents' => 'read', 'pages' => 'write'
    }

    error = assert_raises(Minitest::Assertion) { assert_pages_workflow(workflow) }

    assert_includes error.message, 'pages'
  end

  # A renamed artifact (or an explicit `name:` on only one side) makes deploy
  # fail to find the upload, which is the failure class this guard exists for.
  def test_guard_rejects_an_explicit_artifact_name_on_one_side
    workflow = split_workflow
    upload = find_step(workflow.fetch('jobs').fetch('build'), UPLOAD_PAGES, 'build')
    upload['with']['name'] = 'site'

    error = assert_raises(Minitest::Assertion) { assert_pages_workflow(workflow) }

    assert_includes error.message, 'artifact name'
  end

  def test_guard_rejects_an_unpinned_action
    workflow = split_workflow
    find_step(workflow.fetch('jobs').fetch('build'), CHECKOUT, 'build')['uses'] = 'actions/checkout@v4'

    error = assert_raises(Minitest::Assertion) { assert_pages_workflow(workflow) }

    assert_includes error.message, 'SHA'
  end

  private

  def assert_pages_workflow(workflow)
    jobs = workflow.fetch('jobs')

    assert_equal %w[build deploy], jobs.keys.sort,
                 'pages.yml must have a `build` job and a `deploy` job and nothing else'

    assert_equal ['build'], Array(jobs.fetch('deploy')['needs']),
                 'the `deploy` job must declare `needs: build` so the artifact is finalized first'

    assert_work_ownership(jobs)
    assert_permissions(jobs, workflow['permissions'])
    assert_pins_and_build_inputs(workflow, jobs)
    assert_unweakened_settings(workflow)
  end

  def assert_work_ownership(jobs)
    upload = find_step(jobs.fetch('build'), UPLOAD_PAGES, 'build')
    deploy = find_step(jobs.fetch('deploy'), DEPLOY_PAGES, 'deploy')

    assert_equal 'docs/site', upload.dig('with', 'path'),
                 'the upload must ship docs/site — the YARD api/ and llms-full.txt live there'
    refute upload['with'].key?('name'),
           'the artifact name must stay at its default on both sides; pinning one side alone breaks the lookup'
    assert_equal 'deploy', deploy['id'],
                 'the deploy step must keep id `deploy` for environment.url and the check output'
    assert_equal '${{ steps.deploy.outputs.page_url }}', jobs.fetch('deploy').dig('environment', 'url')

    %w[build deploy].each do |name|
      uses = jobs.fetch(name).fetch('steps').filter_map { |step| step['uses'] }
      own = name == 'build' ? UPLOAD_PAGES : DEPLOY_PAGES
      foreign = uses.grep(%r{actions/(upload-pages-artifact|deploy-pages)@}).reject do |use|
        use.start_with?(own)
      end

      assert_empty foreign, "#{name} must not carry the other job's pages action"
    end
  end

  def assert_permissions(jobs, workflow_permissions)
    assert_equal({ 'contents' => 'read' }, jobs.fetch('build')['permissions'],
                 'the build job runs doc generation and must hold only `contents: read`')
    assert_equal({ 'pages' => 'write', 'id-token' => 'write' }, jobs.fetch('deploy')['permissions'],
                 'only the deploy job may hold the pages publish permissions')
    assert_equal({ 'contents' => 'read' }, workflow_permissions,
                 'the workflow-level ceiling must stay `contents: read`')
    assert_equal 'github-pages', jobs.fetch('deploy').dig('environment', 'name')
  end

  def assert_pins_and_build_inputs(workflow, jobs)
    build_steps = jobs.fetch('build').fetch('steps')
    uses = workflow.fetch('jobs').values.flat_map { |job| job.fetch('steps').filter_map { |step| step['uses'] } }

    uses.each do |use|
      assert_match(/\A[^@]+@[0-9a-f]{40}\z/, use, "action must be pinned to a 40-hex SHA: #{use}")
    end
    pinned = uses.to_h do |use|
      action, sha = use.split('@', 2)
      [action, sha]
    end

    assert_equal PINS, pinned,
                 'every action must keep its pinned SHA; an added or changed action is a supply-chain change'

    assert_includes build_steps.map { |step| step['run'] }, 'bundle exec rake yard docs:llms_full',
                    'the build job must still generate the YARD api/ pages and llms-full.txt'
    ruby = build_steps.find { |step| step['uses']&.start_with?('ruby/setup-ruby@') }

    assert_equal '3.4', ruby.dig('with', 'ruby-version'),
                 'the docs job stays on Ruby 3.4; it makes no statement about supported versions'
    assert ruby.dig('with', 'bundler-cache')
  end

  def assert_unweakened_settings(workflow)
    workflow.fetch('jobs').each do |name, job|
      assert_equal 'ubuntu-latest', job['runs-on'], "#{name} runner"
      assert_equal 10, job['timeout-minutes'], "#{name} timeout"
    end

    # YAML 1.1 parses a bare `on:` key as true; the fixture spells it out.
    trigger = workflow.fetch('on') { workflow.fetch(true) }
    push = trigger.fetch('push')

    checkout = find_step(workflow.fetch('jobs').fetch('build'), CHECKOUT, 'build')

    refute checkout.dig('with', 'persist-credentials'),
           'the docs job must not persist the checkout credentials'
    assert_equal ['main'], push.fetch('branches')
    assert_equal PUSH_PATHS, push.fetch('paths'),
                 'the push path filter must still cover every input the generated site depends on'
    assert_equal '${{ github.workflow }}-${{ github.ref }}', workflow.dig('concurrency', 'group')
    refute workflow.dig('concurrency', 'cancel-in-progress')
    assert trigger.key?('workflow_dispatch'), 'manual dispatch of the pages workflow must stay available'
  end

  def find_step(container, pinned, job_name)
    action = pinned.split('@', 2).first
    container.fetch('steps').find { |step| step['uses']&.start_with?("#{action}@") } ||
      raise(Minitest::Assertion, "#{job_name} lost its #{action} step")
  end

  def pages_workflow
    @pages_workflow ||= YAML.load_file(PAGES_YML)
  end
end
