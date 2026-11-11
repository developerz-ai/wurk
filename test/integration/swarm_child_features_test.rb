# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'open3'
require 'rbconfig'

# M3: every feature a swarm child requires after its fork is a private copy in
# each of N children. The parent loads them before the first fork
# (Swarm::Prefork), so a booted child that has run a job has loaded nothing
# its parent had not.
class SwarmChildFeaturesTest < Wurk::Test::UnitCase
  ROOT = File.expand_path('../..', __dir__)
  PROBE = File.join(ROOT, 'test/fixtures/swarm_child_features_probe.rb')

  def test_a_booted_child_loads_no_feature_its_parent_had_not
    queue = "features-#{Process.pid}-#{object_id}"
    env = { 'REDIS_URL' => Wurk::Test.redis_url, 'COVERAGE' => nil, 'RUBY_DISABLE_WARMUP' => '1' }
    out, err, status = Open3.capture3(env, RbConfig.ruby, '-I', File.join(ROOT, 'lib'), PROBE, queue,
                                      "features-result-#{object_id}", chdir: ROOT)

    assert_predicate status, :success?, "probe failed:\n#{err}"
    assert_empty JSON.parse(out.lines.last), 'loaded only after the fork, once per child'
  end
end
