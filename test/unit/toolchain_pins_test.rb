# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'net/http'
require 'tmpdir'
require 'uri'
require 'yaml'

# bun is pinned in several places nobody edits together: the `bun-version:`
# inputs in the CI workflows, mise.toml (the fleet box), the Dockerfile's
# `oven/bun` base (the demo image, the one dependabot bumps), and the example
# Dockerfile in docs/deployment.md that readers copy. They drifted to three
# different versions once already, so a bump that misses a site fails here
# instead of surfacing as "green locally, red in CI".
#
# The node pins get the same treatment and one more: the dashboard declares
# the lowest Node it supports in frontend/package.json ("engines.node"), and
# a pin that resolves below that floor installs a runtime the dashboard does
# not support — nothing else in the repo notices. A node pin is a spec, not
# a version: "24" installs the newest 24.x.y PUBLISHED when the pin is
# installed, so the floor check resolves each pin against nodejs.org's
# release index instead of trusting the spec to float high enough forever.
class ToolchainPinsTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)

  # The floor check resolves a pin spec against the releases nodejs.org has
  # actually published. Connection trouble is the one failure it tolerates —
  # the comparison skips, so an offline box does not go red over the guard.
  # A response that is not the index at all fails the test: the endpoint
  # moving must not masquerade as "no published release matches".
  NODE_RELEASE_INDEX_URL = 'https://nodejs.org/dist/index.json'
  UNREACHABLE_ERRORS = [SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
                        Errno::ENETUNREACH, Errno::ETIMEDOUT, Net::OpenTimeout,
                        Net::ReadTimeout, OpenSSL::SSL::SSLError, EOFError].freeze
  RELEASE_INDEX_LOCK = Mutex.new

  # The only failure the comparison tolerates: nodejs.org unreachable.
  class NodeReleaseIndexUnreachable < StandardError; end

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

  # The setup-node steps' pins, on their own. The agreement check has to be
  # able to see that the workflows lost their setup-node steps, which a
  # merged hash (mise.toml always contributes one pin) would hide.
  def setup_node_pins
    workflow_pins('actions/setup-node', 'node-version')
  end

  # Every node pin: the mise pin and each actions/setup-node step's pin. The
  # method is a seam so a test can point the read at a fixture instead of
  # the tracked files: parallelize_me! runs the tests of this class
  # concurrently in one process, so patching ::File would leak into them.
  def node_pins
    setup_node_pins.merge('mise.toml' => mise_pin('node'))
  end

  # The dashboard's declared Node floor. The path is a seam for the same
  # reason as the deployment doc's: the tracked file is the source of truth
  # for the floor, so the check never hardcodes a version.
  def frontend_package_json_path
    File.join(ROOT, 'frontend', 'package.json')
  end

  def declared_node_floor
    JSON.parse(File.read(frontend_package_json_path)).dig('engines', 'node')
  end

  def assert_one_version(tool, workflow, others = {})
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
    assert_one_version('node', setup_node_pins, 'mise.toml' => mise_pin('node'))
  end

  # The node pins must not resolve below the engine floor the dashboard
  # declares. A pin names a spec: setup-node and mise install the newest
  # PUBLISHED release matching it, so "24" is only fine while a 24.x.y at or
  # above the floor exists — the check resolves every pin against
  # nodejs.org's index and compares that release with the floor.
  def test_every_node_pin_satisfies_the_declared_engine_floor
    assert_node_pins_satisfy_floor
  end

  # The floor must come from the tracked frontend/package.json: a reader
  # that returned a hardcoded version would keep this check green after the
  # floor moved.
  def test_the_declared_node_floor_is_read_from_frontend_package_json
    pkg = JSON.parse(File.read(File.join(ROOT, 'frontend', 'package.json')))

    assert_equal File.join(ROOT, 'frontend', 'package.json'), frontend_package_json_path
    assert_equal pkg.dig('engines', 'node'), declared_node_floor
  end

  # A pin set that agrees with itself but resolves below the floor must
  # fail: that is the shape of a real drift — every site moved together to a
  # runtime the dashboard does not support. Drop the floor comparison and
  # this fixture stops mattering: the check passes and this test fails.
  def test_node_pins_below_the_declared_engine_floor_fail_the_check
    below = version_below_floor(parse_floor(declared_node_floor))

    with_node_pins('mise.toml' => below, 'test.yml:build#1' => below) do
      assert_one_version('node', node_pins)

      error = assert_raises(Minitest::Assertion) { assert_node_pins_satisfy_floor }

      assert_includes error.message, 'mise.toml'
      assert_includes error.message, below
      assert_includes error.message, declared_node_floor
    end
  end

  # The same check must pass for pins that satisfy the floor, or it would
  # reject every pin set.
  def test_node_pins_satisfying_the_declared_engine_floor_pass_the_check
    satisfying = floor_version_spec(parse_floor(declared_node_floor))

    with_node_pins('mise.toml' => satisfying, 'test.yml:build#1' => satisfying) do
      assert_one_version('node', node_pins)

      assert_node_pins_satisfy_floor
    end
  end

  # A floor above every published release in the pin's line used to pass:
  # the spec compared as unbounded above, so nothing anchored the pin to a
  # release that exists. With frontend/package.json naming >=24.99.0 — above
  # every 24.x that will ever ship — the pin "24" resolves to a real release
  # below the floor, and the check has to fail naming it.
  def test_a_floor_above_every_published_release_in_the_pins_line_fails_the_check
    with_node_pins('mise.toml' => '24') do
      with_frontend_package_json('>=24.99.0') do
        error = assert_raises(Minitest::Assertion) { assert_node_pins_satisfy_floor }

        assert_includes error.message, 'mise.toml'
        assert_includes error.message, '>=24.99.0'
        assert_match(/resolves to 24\.\d+\.\d+ \(/, error.message)
      end
    end
  end

  # A setup-node step that lost its `node-version:` input installs whatever
  # setup-node defaults to: there is no version to compare with the floor,
  # and the check has to say so instead of reading it as one.
  def test_a_node_pin_without_a_version_fails_the_check
    with_node_pins('test.yml:build#1' => nil) do
      error = assert_raises(Minitest::Assertion) { assert_node_pins_satisfy_floor }

      assert_includes error.message, 'has no version'
      assert_includes error.message, 'test.yml:build#1'
      assert_includes error.message, declared_node_floor
    end
  end

  # A pin that is not a version at all (a tag, a range) cannot be compared
  # with the floor: the check has to refuse it rather than pass it silently.
  def test_a_node_pin_that_is_not_a_version_fails_the_check
    with_node_pins('test.yml:build#1' => 'lts/*') do
      error = assert_raises(Minitest::Assertion) { assert_node_pins_satisfy_floor }

      assert_includes error.message, 'is not a version'
      assert_includes error.message, 'test.yml:build#1'
      assert_includes error.message, 'lts/*'
      assert_includes error.message, declared_node_floor
    end
  end

  # A floor the dashboard declares in another shape than a ">= range" cannot
  # be compared with a pin: the check has to refuse it, or it would pass
  # every pin against a floor it never read.
  def test_a_declared_node_floor_that_is_not_a_range_fails_the_check
    with_frontend_package_json('24.15.0') do
      error = assert_raises(Minitest::Assertion) { assert_node_pins_satisfy_floor }

      assert_includes error.message, '24.15.0'
      assert_includes error.message, "must declare a '>=' range"
    end
  end

  # The patterns that decide whether a pull request runs this suite at all.
  def ruby_filter_patterns
    detect = YAML.load_file(File.join(ROOT, '.github', 'workflows', 'test.yml')).dig('jobs', 'detect', 'steps')
    filters = detect.find { |step| step['id'] == 'filter' }.dig('with', 'filters')
    YAML.safe_load(filters).fetch('ruby')
  end

  # Every file a pin — or the declared node floor — is read from,
  # repo-relative.
  def pin_sites
    workflows = (setup_steps('oven-sh/setup-bun') + setup_steps('actions/setup-node'))
                .map { |site, _| ".github/workflows/#{site.split(':').first}" }
    (%w[Dockerfile mise.toml docs/deployment.md frontend/package.json] + workflows).uniq
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

  # Serve a package.json declaring `node_range` as the dashboard's package
  # for the block's duration, by pointing this instance's package path at a
  # fixture in a temp dir. The tracked file is never written, and the
  # override lives on this test instance, so the other tests of this class —
  # which run concurrently in this process — still read the real package.
  def with_frontend_package_json(node_range)
    Dir.mktmpdir('wurk-pins') do |dir|
      path = File.join(dir, 'package.json')
      File.write(path, JSON.generate('engines' => { 'node' => node_range }))
      singleton_class.send(:define_method, :frontend_package_json_path) { path }
      yield
    ensure
      singleton_class.send(:remove_method, :frontend_package_json_path)
    end
  end

  # The one place the node pins are compared with the declared engine floor.
  # The real test AND the fixtures that prove the comparison is load-bearing
  # both call THIS, so dropping it fails the fixtures.
  def assert_node_pins_satisfy_floor
    floor = declared_node_floor
    floor_version = parse_floor(floor)

    node_pins.each do |site, pin|
      spec = parse_version_spec(pin)
      resolved = spec && newest_published_release_matching(spec)

      next if resolved && version_at_least?(resolved, floor_version)

      flunk node_pin_failure_message(site, pin, floor, spec, resolved)
    end
  end

  # Component-wise comparison of two (major, minor, patch) triples. Array has
  # no comparison operators, so the spaceship result decides.
  def version_at_least?(version, floor)
    comparison = version <=> floor

    !comparison.nil? && comparison >= 0
  end

  # Why one pin does not satisfy the floor. The failures are named apart on
  # purpose: an unpinned step, a version this check cannot compare, a spec
  # nothing published matches and a spec whose newest published release sits
  # below the floor each need a different fix.
  def node_pin_failure_message(site, pin, floor, spec, resolved)
    return "node pin #{site} has no version; it cannot satisfy the declared floor #{floor}" if pin.nil?

    subject = "node pin #{site}=#{pin.inspect}"
    return "#{subject} is not a version; it cannot satisfy the declared floor #{floor}" if spec.nil?
    return "#{subject} matches no published release; it cannot satisfy the declared floor #{floor}" if resolved.nil?

    "#{subject} resolves to #{resolved.join('.')} (the newest published release matching it), " \
      "below the declared floor #{floor} (frontend/package.json engines.node)"
  end

  # The release a pin spec installs: the newest PUBLISHED release whose
  # version starts with the components the spec names — not "the newest
  # there ever will be". A floor above every published release in the
  # spec's line has to fail here, because that release is what the
  # installed runtime would be. nil when nothing published matches: a pin
  # naming one installs nothing.
  def newest_published_release_matching(spec)
    major, minor, patch = spec

    published_node_releases.select do |version|
      version[0] == major &&
        (minor.nil? || version[1] == minor) &&
        (patch.nil? || version[2] == patch)
    end.max
  end

  # The published Node releases, as concrete (major, minor, patch) triples:
  # nodejs.org's index, fetched once per process and shared by every pin
  # this class compares. The memo is a class ivar (instances are per test),
  # the lock keeps concurrent tests to one fetch, and a memoized failure
  # skips every later caller without refetching.
  def published_node_releases
    releases, unreachable = RELEASE_INDEX_LOCK.synchronize do
      memo = ToolchainPinsTest.instance_variable_get(:@published_node_releases)
      next memo if memo

      begin
        memo = [fetch_published_node_releases, nil]
      rescue *UNREACHABLE_ERRORS => e
        memo = [nil, NodeReleaseIndexUnreachable.new(
          "could not read the published Node release index (#{NODE_RELEASE_INDEX_URL}): #{e.class}: #{e.message}"
        )]
      end
      ToolchainPinsTest.instance_variable_set(:@published_node_releases, memo)
      memo
    end

    skip unreachable.message if unreachable
    releases
  end

  # Read nodejs.org's index and parse it to concrete triples.
  def fetch_published_node_releases
    uri = URI(NODE_RELEASE_INDEX_URL)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15) do |http|
      http.get(uri.request_uri)
    end
    unless response.is_a?(Net::HTTPSuccess)
      flunk "the Node release index at #{NODE_RELEASE_INDEX_URL} answered HTTP #{response.code}, not 200"
    end

    releases = JSON.parse(response.body).filter_map { |entry| parse_release_tag(entry['version'].to_s) }
    flunk "the Node release index at #{NODE_RELEASE_INDEX_URL} holds no readable release" if releases.empty?

    releases
  rescue JSON::ParserError => e
    flunk "the Node release index at #{NODE_RELEASE_INDEX_URL} is not JSON (#{e.message})"
  end

  # "v24.13.0" → [24, 13, 0]; nil for anything else — the index also lists
  # prereleases ("v27.0.0-alpha.0.0.0") that no stable version pin selects.
  def parse_release_tag(tag)
    match = /\Av(\d+)\.(\d+)\.(\d+)\z/.match(tag)
    return unless match

    match.captures.map(&:to_i)
  end

  # A pin is a version SPEC: setup-node and mise both install the newest
  # published release matching it, so "24" selects the newest 24.x.y that
  # exists and "24.15" the newest 24.15.y. The components the spec names
  # select; the ones it omits float — nil here, resolved against the
  # published index by newest_published_release_matching. "24" is
  # (24, nil, nil) and "24.15.0" is (24, 15, 0).
  def parse_version_spec(spec)
    match = /\A(\d+)(?:\.(\d+))?(?:\.(\d+))?\z/.match(spec.to_s.strip)
    return nil unless match

    match.captures.map { |part| part&.to_i }
  end

  # The floor is a ">= range": ">=24.15.0" names the lowest Node the
  # dashboard supports. A declaration in another shape cannot be compared
  # with a pin, and guessing would pass it silently. Omitted components mean
  # zeros (">=24.15" ≡ ">=24.15.0"), so the floor is always a concrete
  # triple a pin's resolution can be compared with.
  def parse_floor(range)
    match = /\A>=\s*(\d+(?:\.\d+){0,2})\z/.match(range.to_s.strip)
    flunk "frontend/package.json engines.node must declare a '>=' range, got #{range.inspect}" unless match

    major, minor, patch = parse_version_spec(match[1])
    [major, minor || 0, patch || 0]
  end

  # The version the declared floor names, as a spec: ">=24.15.0" names
  # "24.15.0". Derived from the parsed floor so the fixtures above keep
  # their meaning when the floor moves.
  def floor_version_spec(floor)
    floor.join('.')
  end

  # A version spec one below the declared floor: the floor's patch minus
  # one, borrowing from the component above it, so the fixture stays below
  # the floor when the floor moves.
  def version_below_floor(floor)
    major, minor, patch = floor
    return "#{major - 1}.0.0" if minor.zero?
    return "#{major}.#{minor - 1}.0" if patch.zero?

    "#{major}.#{minor}.#{patch - 1}"
  end

  # Serve `pins` as the node pins for the block's duration, by pointing this
  # instance's pin source at a fixture hash. The tracked files are never
  # written, and the override lives on this test instance, so the other
  # tests of this class — which run concurrently in this process — still
  # read the real pins.
  def with_node_pins(pins)
    singleton_class.send(:define_method, :node_pins) { pins }
    yield
  ensure
    singleton_class.send(:remove_method, :node_pins)
  end
end
