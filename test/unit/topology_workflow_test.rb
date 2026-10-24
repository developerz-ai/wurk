# frozen_string_literal: true

require_relative '../test_helper'
require 'open3'
require 'rake'

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
# The guard therefore executes the step's loop under bash and takes the
# accumulator's REAL value — re-deriving the paths from the for-list in Ruby
# would pass an accumulator that lost its separators just as easily
# (`files="${files}test/${f}_test.rb"` concatenates every path into one
# chunk) — and passes that value through Rake::TestTask's own file-list
# resolution before comparing with the 25 subset files.
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
    assert_step_hands_rake_comma_joined_explicit_paths(File.read(TOPOLOGY_YML))
  end

  # The guard must be able to fail. An accumulator that concatenates without
  # separators is invisible to an expectation derived from the for-list and
  # only bites mid-run in CI, after the subset has been spinning up Valkey.
  # Mutate the step to exactly that form and pin the failure to the message
  # that names it.
  def test_guard_rejects_an_accumulator_that_drops_the_separators
    text = File.read(TOPOLOGY_YML)
    broken = text.sub(
      'files="${files:+$files,}test/${f}_test.rb"',
      'files="${files}test/${f}_test.rb"'
    )
    if broken == text
      flunk 'the mutation was a no-op — topology.yml no longer carries the ' \
            'comma-joining accumulator this mutant exists to guard'
    end

    error = assert_raises(Minitest::Assertion) do
      assert_step_hands_rake_comma_joined_explicit_paths(broken)
    end

    assert_includes error.message, 'separators',
                    'the guard must name the lost separator, not just a count mismatch'
  end

  private

  # The whole guard, parameterized on the workflow text, so the mutant above
  # can run it over a mutated copy.
  def assert_step_hands_rake_comma_joined_explicit_paths(text)
    invocations = text.scan(/rake test:integration TEST="([^"]+)"/)
    flunk 'topology.yml lost its `rake test:integration TEST="..."` invocation' if invocations.empty?

    assert_equal 1, invocations.length,
                 'the workflow must carry exactly one integration-subset invocation'

    test_value = invocations.first.first

    # Rake splits TEST on commas before it ever globs, so the value must be
    # the loop's accumulator variable — nothing inline, and no glob magic: a
    # brace or star here resolves per-chunk and an unmatched chunk pattern is
    # silently dropped by FileList, deleting tests instead of failing loudly.
    # The brace glob is exactly the shape that went red at 7621a10.
    # Held MatchData, never Regexp.last_match: the assertion helpers match in
    # their own frames, so $~ here is still text.scan's — group 1 of THAT is
    # "$files", which as an accumulator interpolates `$$` into the printf and
    # reads as the shell's PID.
    var_match = test_value.match(/\A\$(\w+)\z/)
    flunk "TEST= must pass the loop's accumulator variable, nothing else (got #{test_value.inspect})" unless var_match

    refute_match(/[*{?\[]/, test_value,
                 'TEST= must carry no glob magic — rake splits the value on commas first')

    accumulator = var_match[1]
    # The file's only `for f in` loop is this step's (the TLS wait loop is
    # `for _`); a second one must anchor this match to the subset step.
    loop_block = text.match(/^\s*for f in (.*?);[ \t]*do\n(.*?)^\s*done[ \t]*$/m)
    flunk "topology.yml lost the subset step's `for f in … ; do` loop" unless loop_block

    # (No shape check that the loop assigns the same variable TEST= passes:
    # the shell run below is that check — an unassigned variable comes back
    # empty and fails loudly there.)

    # Evaluate the actual shell: the separator handling lives in the
    # accumulator expression, which no for-list-derived expectation can see.
    # Unset behaves as empty for every accumulator form this guard accepts
    # (`${files:+...}`, plain concatenation), so the bare loop reproduces
    # CI's value exactly.
    script = "#{loop_block[0]}\nprintf '%s' \"$#{accumulator}\"\n"
    evaluated, status = Open3.capture2('bash', '-c', script, err: %i[child out])

    assert_predicate status, :success?,
                     "the step's loop must run under bash: #{evaluated}"
    refute_empty evaluated,
                 "$#{accumulator} came back empty — TEST= would hand rake nothing to run"

    refute_match(/[*{?\[]/, evaluated,
                 'the evaluated TEST= must carry no glob magic — rake splits the value on commas first')

    # The locked rake's TestTask resolves ENV["TEST"] as exactly
    # FileList[ENV["TEST"].split(",")] — resolve the accumulator's real
    # value through it before comparing.
    chunks = evaluated.split(',')

    assert_equal EXPECTED.length, chunks.length,
                 'the accumulator must comma-join one path per iteration; got ' \
                 "#{chunks.length} chunk(s) for #{EXPECTED.length} expected files — " \
                 'it is losing its separators (bare `"${files}test/${f}_test.rb"` ' \
                 'concatenates every path into one)'
    resolved = Rake::FileList[chunks].to_a

    assert_equal EXPECTED, resolved,
                 'the file list rake will actually see after TestTask resolution'

    root = File.expand_path('../..', __dir__)

    resolved.each do |path|
      assert File.file?(File.join(root, path)),
             "#{path} must exist on disk — rake_test_loader aborts the whole lane on one missing file"
    end
  end
end
