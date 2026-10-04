# frozen_string_literal: true

require 'minitest/autorun'

# bun is pinned in four places nobody edits together: the `bun-version:`
# inputs in the CI workflows, mise.toml (the fleet box), and the Dockerfile's
# `oven/bun` base (the demo image, the one dependabot bumps). They drifted to
# three different versions once already, so a bump that misses a site fails
# here instead of surfacing as "green locally, red in CI". Reads files only.
class ToolchainPinsTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)

  def workflow_pins(input)
    Dir[File.join(ROOT, '.github', 'workflows', '*.yml')].each_with_object({}) do |path, pins|
      File.read(path).scan(/#{input}:\s*"?([\w.]+)"?/).flatten.each_with_index do |version, i|
        pins["#{File.basename(path)}##{i + 1}"] = version
      end
    end
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
    Dir[File.join(ROOT, '.github', 'workflows', '*.yml')].each do |path|
      text = File.read(path)
      steps = text.scan(%r{uses:\s*oven-sh/setup-bun@}).size
      pins = text.scan('bun-version:').size

      assert_equal steps, pins, "#{File.basename(path)}: #{steps} setup-bun steps but #{pins} bun-version pins"
    end
  end

  def test_every_bun_pin_names_the_same_version
    assert_one_version('bun', workflow_pins('bun-version'),
                       'mise.toml' => mise_pin('bun'), 'Dockerfile' => dockerfile_bun_pin)
  end

  def test_every_node_pin_names_the_same_version
    assert_one_version('node', workflow_pins('node-version'), 'mise.toml' => mise_pin('node'))
  end
end
