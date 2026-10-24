# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'

# bun is pinned in several places nobody edits together: the `bun-version:`
# inputs in the CI workflows, mise.toml (the fleet box), the Dockerfile's
# `oven/bun` base (the demo image, the one dependabot bumps), and the example
# Dockerfile in docs/deployment.md that readers copy. They drifted to three
# different versions once already, so a bump that misses a site fails here
# instead of surfacing as "green locally, red in CI". Reads files only.
class ToolchainPinsTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)

  # Parsed per step, so a pin left in a comment or on another step can't stand
  # in for a step that lost its own `with:` input.
  def setup_steps(action)
    Dir[File.join(ROOT, '.github', 'workflows', '*.yml')].flat_map do |path|
      jobs = YAML.load_file(path).fetch('jobs', {})
      jobs.flat_map do |job, spec|
        Array(spec['steps']).select { |step| step['uses'].to_s.start_with?("#{action}@") }
                            .map { |step| ["#{File.basename(path)}:#{job}", step] }
      end
    end
  end

  def workflow_pins(action, input)
    setup_steps(action).each_with_index.to_h { |(site, step), i| ["#{site}##{i + 1}", step.dig('with', input)&.to_s] }
  end

  def mise_pin(tool)
    File.read(File.join(ROOT, 'mise.toml'))[/^#{tool}\s*=\s*"([^"]+)"/, 1]
  end

  def dockerfile_bun_pin
    File.read(File.join(ROOT, 'Dockerfile'))[%r{^FROM oven/bun:([\d.]+)}, 1]
  end

  # The deployment doc's example Dockerfile is a fifth pin site: it ships as
  # prose readers copy, so its bun base tag has to move with the real one.
  # The path is a seam so a test can point the read at a fixture instead of
  # the tracked file: parallelize_me! runs the tests of this class
  # concurrently in one process, so patching ::File would leak into them.
  def deployment_doc_path
    File.join(ROOT, 'docs', 'deployment.md')
  end

  def deployment_doc_bun_pin
    File.read(deployment_doc_path)[%r{^FROM oven/bun:([\d.]+)}, 1]
  end

  def assert_one_version(tool, workflow, others)
    refute_empty workflow, "expected at least one #{tool} pin in .github/workflows"
    pins = workflow.merge(others)

    assert_equal 1, pins.values.uniq.size,
                 "#{tool} pins disagree — move them together: " \
                 "#{pins.map { |site, v| "#{site}=#{v.inspect}" }.join(', ')}"
  end

  # Without a pin, setup-bun falls back to package.json or latest, which the
  # agreement check below cannot see.
  def test_every_setup_bun_step_is_pinned
    unpinned = workflow_pins('oven-sh/setup-bun', 'bun-version').select { |_, v| v.nil? }

    assert_empty unpinned.keys, 'setup-bun steps without a bun-version pin'
  end

  def test_every_bun_pin_names_the_same_version
    assert_bun_pins_agree
  end

  # The agreement check above is only load-bearing if docs/deployment.md's pin
  # really takes part in it. Point the doc's read at a fixture whose `oven/bun`
  # tag disagrees with the other sites and require the shared check to fail.
  # Delete the deployment-doc pin helper, or drop its entry from the check, and
  # the fixture stops mattering: the check passes and this test fails — the
  # fifth site cannot go unchecked.
  def test_a_disagreeing_deployment_doc_pin_fails_the_bun_pin_check
    with_deployment_doc("FROM oven/bun:#{disagreeing_bun_version} AS spa\n") do
      error = assert_raises(Minitest::Assertion) { assert_bun_pins_agree }

      assert_includes error.message, 'docs/deployment.md'
    end
  end

  # A doc that lost its `oven/bun` line must fail too: the pin would go
  # missing and setup-bun would fall back to package.json or latest, which the
  # agreement check cannot see.
  def test_a_deployment_doc_without_a_bun_pin_fails_the_bun_pin_check
    with_deployment_doc("FROM ruby:3.4-slim-bookworm\n") do
      error = assert_raises(Minitest::Assertion) { assert_bun_pins_agree }

      assert_includes error.message, 'docs/deployment.md'
    end
  end

  # The fixture above only proves the check is load-bearing if the real
  # deployment doc is the file it reads. Pin that: the helper must read
  # docs/deployment.md and parse the very tag the example Dockerfile carries.
  def test_the_deployment_doc_bun_pin_is_read_from_the_deployment_doc
    doc = File.read(File.join(ROOT, 'docs', 'deployment.md'))

    assert_equal File.join(ROOT, 'docs', 'deployment.md'), deployment_doc_path
    assert_equal doc[%r{^FROM oven/bun:([\d.]+)}, 1], deployment_doc_bun_pin
  end

  def test_every_node_pin_names_the_same_version
    assert_one_version('node', workflow_pins('actions/setup-node', 'node-version'), 'mise.toml' => mise_pin('node'))
  end

  # The patterns that decide whether a pull request runs this suite at all.
  def ruby_filter_patterns
    detect = YAML.load_file(File.join(ROOT, '.github', 'workflows', 'test.yml')).dig('jobs', 'detect', 'steps')
    filters = detect.find { |step| step['id'] == 'filter' }.dig('with', 'filters')
    YAML.safe_load(filters).fetch('ruby')
  end

  # Every file a pin is read from, repo-relative.
  def pin_sites
    workflows = (setup_steps('oven-sh/setup-bun') + setup_steps('actions/setup-node'))
                .map { |site, _| ".github/workflows/#{site.split(':').first}" }
    (%w[Dockerfile mise.toml docs/deployment.md] + workflows).uniq
  end

  # The agreement checks above only gate a PR that runs them. A pin site
  # missing from test.yml's `ruby` paths-filter lets a PR that moves that one
  # pin (dependabot's docker bump edits only the Dockerfile) skip the suite and
  # report green with the pins disagreeing.
  def test_a_change_to_any_pin_site_runs_this_suite
    patterns = ruby_filter_patterns
    unwatched = pin_sites.reject { |path| patterns.any? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME) } }

    assert_empty unwatched, "test.yml's `ruby` paths-filter must list every pin site; a PR touching only " \
                            "#{unwatched.join(', ')} would skip the test that checks the pins agree"
  end

  private

  # The one place the bun pins are compared. The agreement test AND the test
  # that proves the agreement is load-bearing both call THIS, so dropping
  # docs/deployment.md from it fails the latter.
  def assert_bun_pins_agree
    assert_one_version('bun', workflow_pins('oven-sh/setup-bun', 'bun-version'),
                       'mise.toml' => mise_pin('bun'), 'Dockerfile' => dockerfile_bun_pin,
                       'docs/deployment.md' => deployment_doc_bun_pin)
  end

  # A bun version that differs from every real pin, so the fixture cannot
  # accidentally agree with the other sites. Derived from the pins themselves
  # rather than hardcoded, so it survives a bump of the real version.
  def disagreeing_bun_version
    pinned = [
      mise_pin('bun'), dockerfile_bun_pin,
      File.read(File.join(ROOT, 'docs', 'deployment.md'))[%r{^FROM oven/bun:([\d.]+)}, 1],
      *workflow_pins('oven-sh/setup-bun', 'bun-version').values
    ].compact
    candidate = '0.0.1'
    candidate = '0.0.2' while pinned.include?(candidate)

    candidate
  end

  # Serve `content` as the deployment doc for the block's duration, by
  # pointing this instance's doc path at a fixture in a temp dir. The tracked
  # file is never written, and the override lives on this test instance, so
  # the other tests of this class — which run concurrently in this process —
  # still read the real doc.
  def with_deployment_doc(content)
    Dir.mktmpdir('wurk-pins') do |dir|
      path = File.join(dir, 'deployment.md')
      File.write(path, content)
      singleton_class.send(:define_method, :deployment_doc_path) { path }
      yield
    ensure
      singleton_class.send(:remove_method, :deployment_doc_path)
    end
  end
end
