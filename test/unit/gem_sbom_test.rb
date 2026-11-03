# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'open3'
require 'rbconfig'
require 'rubygems/package'
require 'tmpdir'

# bin/gem-sbom runs in the release lane's attest job. Stdlib only, so it is run here
# with no bundle, the way that job runs it.
class GemSbomTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  SCRIPT = File.join(ROOT, 'bin', 'gem-sbom')

  def built_gem(dir)
    spec = Gem::Specification.new do |s|
      s.name = 'wurk'
      s.version = '9.9.9'
      s.summary = 'x'
      s.authors = ['x']
      s.files = []
      s.add_dependency 'redis-client', '>= 0.22'
      s.add_development_dependency 'rake'
    end
    Dir.chdir(dir) { Gem::Package.build(spec, true) }
    File.join(dir, 'wurk-9.9.9.gem')
  end

  def test_the_sbom_names_the_gem_its_runtime_deps_and_the_bundled_packages
    Dir.mktmpdir('gem-sbom') do |dir|
      env = { 'RUBYOPT' => nil, 'BUNDLE_GEMFILE' => nil }
      out, err, status = Open3.capture3(env, RbConfig.ruby, SCRIPT, built_gem(dir))

      assert_predicate status, :success?, err
      bom = JSON.parse(out)

      assert_equal 'CycloneDX', bom.fetch('bomFormat')
      assert_equal 'pkg:gem/wurk@9.9.9', bom.dig('metadata', 'component', 'purl')

      names = bom.fetch('components').to_h { |component| [component.fetch('name'), component] }

      assert_equal '>= 0.22', names.dig('redis-client', 'version')
      refute names.key?('rake'), 'a development dependency does not ship'
      assert_match(/\A\d/, names.dig('solid-js', 'version'), 'the dashboard package is at its locked version')
      refute names.key?('vite'), 'a build tool does not ship'
    end
  end

  def test_no_argument_is_a_usage_error
    _out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT)

    refute_predicate status, :success?
    assert_includes err, 'usage:'
  end
end
