# frozen_string_literal: true

require_relative '../test_helper'

# Guards the TEST= invocation of .github/workflows/topology.yml's "core
# integration subset on Valkey 8 + topology tests" step.
#
# The step assembles its file list in a shell loop and hands it to
# `rake test:integration TEST=...`. The locked rake (13.4, Gemfile.lock) splits
# ENV["TEST"] on commas BEFORE any globbing — Rake::TestTask#file_list is
# `FileList[ENV["TEST"].split(",")]`, and FileList silently drops a glob
# pattern that matches nothing — so the brace glob this lane carried at
# 7621a10 reached rake_test_loader as bare-stem chunks
# ("test/{integration/redis_topology" globbed away, "integration/scheduled_
# promotion" kept as a literal) and the step aborted with "File does not
# exist" before a single test ran. The brace form was itself a repair for
# older rake, where the WHOLE ENV["TEST"] value was one FileList pattern and
# a comma-joined path list died as a single nonexistent literal; the locked
# rake wants the opposite shape, and it defines the contract: comma-joined
# EXPLICIT paths, no glob magic anywhere in TEST.
#
# This test reads the step exactly as CI executes it: it extracts the TEST=
# value, resolves the loop's for-list the way bash expands the accumulator
# before rake sees it, pins that list to the 25 subset files, and asserts
# every chunk rake will split out names a file on disk — the same existence
# check rake_test_loader performs before requiring anything.
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

  def test_integration_subset_step_hands_rake_comma_joined_explicit_paths
    text = File.read(TOPOLOGY_YML)

    invocations = text.scan(/rake test:integration TEST="([^"]+)"/)
    flunk 'topology.yml lost its `rake test:integration TEST="..."` invocation' if invocations.empty?

    assert_equal 1, invocations.length,
                 'the workflow must carry exactly one integration-subset invocation'

    test_value = invocations.first.first

    # Rake splits TEST on commas before it ever globs, so the value must be
    # the loop's accumulator — nothing inline, and no glob magic: a brace or
    # star here resolves per-chunk and an unmatched chunk pattern is silently
    # dropped by FileList, deleting tests instead of failing loudly. The
    # brace glob is exactly the shape that went red at 7621a10.
    assert_match(/\A\$(\w+)\z/, test_value,
                 "TEST= must pass the loop's accumulator variable, nothing else")
    refute_match(/[*{?\[]/, test_value,
                 'TEST= must carry no glob magic — rake splits the value on commas first')

    accumulator = Regexp.last_match(1)
    loop_block = text.match(/^\s*for f in (.*?);[ \t]*do\n(.*?)^\s*done[ \t]*$/m)
    flunk "topology.yml lost the subset step's `for f in … ; do` loop" unless loop_block

    assert_includes loop_block[2], accumulator,
                    'the loop must assign the same variable TEST= passes'
    assert_includes loop_block[2], 'test/${', 'the loop must build full test/..._test.rb paths'

    # Resolve the accumulator exactly as bash does before rake sees the
    # value: the loop's for-list, mapped to full paths, comma-joined.
    stems = loop_block[1].gsub(/\\\s*\n\s*/, ' ').split

    paths = stems.map { |stem| "test/#{stem}_test.rb" }

    assert_equal EXPECTED, paths,
                 "the loop must build exactly the 25 subset files, in order; got #{paths.inspect}"

    root = File.expand_path('../..', __dir__)

    paths.each do |path|
      assert File.file?(File.join(root, path)),
             "#{path} must exist on disk — rake_test_loader aborts the whole lane on one missing file"
    end
  end
end
