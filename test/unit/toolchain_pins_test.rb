# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'

# bun is pinned in four places nobody edits together: the `bun-version:`
# inputs in the CI workflows, mise.toml (the fleet box), and the Dockerfile's
# `oven/bun` base (the demo image, the one dependabot bumps). They drifted to
# three different versions once already, so a bump that misses a site fails
# here instead of surfacing as "green locally, red in CI". Reads files only.
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
    assert_one_version('bun', workflow_pins('oven-sh/setup-bun', 'bun-version'),
                       'mise.toml' => mise_pin('bun'), 'Dockerfile' => dockerfile_bun_pin)
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
    (%w[Dockerfile mise.toml] + workflows).uniq
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
end
