# frozen_string_literal: true

require_relative '../test_helper'

# Guards the TEST= invocation of .github/workflows/topology.yml's "core
# integration subset on Valkey 8 + topology tests" step.
#
# The step assembles its file list in a shell loop and hands it to
# `rake test:integration TEST="test/{$stems}_test.rb"`. Rake's TestTask reads
# ENV["TEST"] into a FileList, which resolves a non-glob string as ONE literal
# path — the comma-joined list introduced by PR #625 made the loader require a
# single file literally named "test/a_test.rb,test/b_test.rb,…" and the step
# died on LoadError, a failure invisible to bin/check and test.yml (both run
# the whole suite and never this list); the lane first went red on main at
# 189f3886ce2d1434aa8e33aabba1fd4c4597ef24. The step must therefore pass ONE
# brace-glob pattern (contains "{" → Dir.glob expands it).
#
# This test reads the step exactly as CI executes it: it extracts the TEST=
# value, resolves $stems from the loop's own for-list (comma-joined, the way
# bash expands the accumulator before rake sees it), then Dir.globs the result
# and pins it to the 25 files the subset names. It also pins the comma-joined
# shape to the empty glob that turned the lane red.
#
# Pure file test: reads .github/workflows/topology.yml, touches no Redis.
class TopologyWorkflowTest < Wurk::Test::UnitCase
  parallelize_me!

  TOPOLOGY_YML = File.expand_path('../../.github/workflows/topology.yml', __dir__)

  # The 25 files the subset step names — 15 integration + 10 unit — in the
  # step's loop order.
  EXPECTED = %w[
    test/integration/redis_topology_test.rb
    test/integration/scheduled_promotion_test.rb
    test/integration/graceful_shutdown_test.rb
    test/integration/reaper_kill9_test.rb
    test/integration/reaper_full_sweep_test.rb
    test/integration/reaper_owner_race_test.rb
    test/integration/swarm_boot_test.rb
    test/integration/redis_options_fork_test.rb
    test/integration/batch_retry_roundtrip_test.rb
    test/integration/batch_nested_callbacks_test.rb
    test/integration/limiter_stress_test.rb
    test/integration/periodic_leader_test.rb
    test/integration/global_concurrency_test.rb
    test/integration/debounce_concurrent_test.rb
    test/integration/rolling_restart_test.rb
    test/unit/client_push_test.rb
    test/unit/client_test.rb
    test/unit/client_batch_pipeline_test.rb
    test/unit/fetcher_reliable_test.rb
    test/unit/fetcher_reaper_test.rb
    test/unit/fetcher_capped_test.rb
    test/unit/lua_loader_test.rb
    test/unit/lua_test.rb
    test/unit/lua_declared_keys_test.rb
    test/unit/scheduled_poller_test.rb
  ].freeze

  def test_integration_subset_step_sets_a_brace_glob_naming_exactly_the_expected_files
    text = File.read(TOPOLOGY_YML)

    invocations = text.scan(/rake test:integration TEST="([^"]+)"/)
    flunk 'topology.yml lost its `rake test:integration TEST="..."` invocation' if invocations.empty?

    assert_equal 1, invocations.length,
                 'the workflow must carry exactly one integration-subset invocation'

    # Resolve the accumulator the step interpolates into TEST=, exactly as
    # bash does before rake sees the value: the loop's for-list, comma-joined.
    loop_list = text[/for f in (.*?)\s*; do/m, 1]
    flunk "topology.yml lost the subset step's `for f in … ; do` loop" unless loop_list
    stems = loop_list.gsub(/\\\s*\n\s*/, ' ').split

    test_value = invocations.first.first.sub('$stems', stems.join(','))

    root = File.expand_path('../..', __dir__)
    resolved = Dir.chdir(root) { Dir.glob(test_value) }

    assert_equal EXPECTED.sort, resolved.sort,
                 "the TEST= brace glob must resolve to exactly the 25 subset files; got #{resolved.inspect}"
    resolved.each do |path|
      assert File.file?(File.join(root, path)), "#{path} must exist on disk"
    end

    # The guard bites: the comma-joined value the step used before the repair
    # is ONE literal path as far as rake's FileList is concerned, and as a
    # glob it matches nothing.
    comma_joined = "#{EXPECTED.fetch(0)},#{EXPECTED.fetch(1)}"

    assert_empty Dir.glob(comma_joined),
                 'a comma-joined TEST value must glob to nothing — the pre-repair failure this guard pins'
  end
end
