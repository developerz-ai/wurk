# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../bench/require_profile'
require 'English'
require 'tmpdir'

# bench/require_profile.rb is the evidence every lazy-loading tier cites, so the
# numbers it reports are pinned here on a fixture tree whose shape is known:
# one record per file whatever loaded it, parents and depths right, exclusive
# never above inclusive, the stop hook ending the window at the named method,
# and the unhooked control run seeing the same features as the hooked one.
class RequireProfileTest < Wurk::Test::UnitCase
  parallelize_me!

  HOOK = File.expand_path('../../bench/require_profile.rb', __dir__)

  def setup
    super
    @dir = Dir.mktmpdir('require_profile_test')
    write('entry.rb', "require_relative 'mid'\nrequire 'leaf_by_require'\nENTRY = 1\n")
    write('mid.rb', "require_relative 'leaf'\nrequire_relative 'leaf'\nclass Mid; def go = :ran; end\n")
    write('leaf.rb', "LEAF = Array.new(500) { |i| i.to_s }\n")
    write('leaf_by_require.rb', "BY_REQUIRE = 1\n")
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  def test_records_each_file_once_with_its_parent_and_depth
    result = profile_child("require_relative '#{File.join(@dir, 'entry')}'")
    recs = result[:records].to_h { |r| [File.basename(r[:path]), r] }

    assert_equal %w[entry.rb leaf.rb leaf_by_require.rb mid.rb], recs.keys.sort,
                 'a second require_relative of a loaded file is not a load'
    assert_equal 4, result[:features]
    assert_equal([0, 1, 2, 1], recs.values_at('entry.rb', 'mid.rb', 'leaf.rb', 'leaf_by_require.rb').map { _1[:depth] })
    assert_nil recs['entry.rb'][:parent]
    assert_equal 'mid.rb', File.basename(recs['leaf.rb'][:parent])
    assert_equal 'entry.rb', File.basename(recs['leaf_by_require.rb'][:parent]), '`require` is hooked as well'
  end

  def test_exclusive_excludes_children
    recs = profile_child("require_relative '#{File.join(@dir, 'entry')}'")[:records]
           .to_h { |r| [File.basename(r[:path]), r] }
    entry = recs['entry.rb']

    assert_operator recs['leaf.rb'][:excl_alloc], :>=, 500, 'the leaf builds 500 strings in its own body'
    assert_operator entry[:incl_alloc], :>=, recs['leaf.rb'][:incl_alloc] + entry[:excl_alloc]
    assert_operator entry[:excl_alloc], :<, recs['leaf.rb'][:excl_alloc]
    recs.each_value { |r| assert_operator r[:excl_ms], :<=, r[:incl_ms] }
  end

  def test_stop_hook_ends_the_window_at_the_named_method
    out = File.join(@dir, 'stop.bin')
    script = "require_relative '#{File.join(@dir, 'entry')}'; RequireProfile::Hook.app_loaded; Mid.new.go; exit 3"
    _, status = spawn_child(script, out, 'WURK_REQPROF_STOP' => 'Mid#go')

    assert_equal 0, status.exitstatus, 'the hook exits at the stop method, before the script reaches exit 3'
    assert_equal 4, load_result(out)[:features]
  end

  def test_unhooked_control_run_counts_the_same_features_and_no_records
    out = File.join(@dir, 'plain.bin')
    log, status = spawn_child("require_relative '#{File.join(@dir, 'entry')}'", out, 'WURK_REQPROF_PLAIN' => '1')

    assert_predicate status, :success?, log
    result = load_result(out)

    assert_equal 4, result[:features]
    assert_empty result[:records]
  end

  def test_summarize_takes_totals_from_the_control_runs
    hooked = { wall_ms: 9.0, gc_ms: 0.0, rss_kb: 1, features: 2, allocations: 70,
               records: [{ path: '/a.rb', parent: nil, depth: 0, incl_ms: 8.0, excl_ms: 8.0, gc_ms: 0.0,
                           incl_alloc: 60, excl_alloc: 60 }] }
    plain = { wall_ms: 7.0, gc_ms: 0.0, rss_kb: 1, features: 2, allocations: 60, records: [] }
    s = RequireProfile::Stats.summarize([hooked], [plain])

    assert_equal [60, 60], s[:allocations]
    assert_equal [70, 70], s[:hooked_allocations]
    assert_in_delta 7.0, s[:wall_ms]
    assert_in_delta 8.0, s[:require_ms]
  end

  def test_group_for_names_gems_stdlib_and_wurk
    dirs = ['/ruby/lib/ruby/3.4.0/x86_64-linux', '/ruby/lib/ruby/3.4.0']
    group = ->(path) { RequireProfile::Stats.group_for(path, wurk_lib: '/src/wurk/lib', rubylibdirs: dirs) }

    assert_equal 'wurk', group.call('/src/wurk/lib/wurk/client.rb')
    assert_equal 'gem:redis-client', group.call('/g/gems/3.4.0/gems/redis-client-0.31.0/lib/redis_client.rb')
    assert_equal 'gem:connection_pool', group.call('/g/gems/connection_pool-3.0.2/lib/connection_pool.rb')
    assert_equal 'stdlib/openssl', group.call('/ruby/lib/ruby/3.4.0/openssl/ssl.rb')
    assert_equal 'stdlib/openssl', group.call('/ruby/lib/ruby/3.4.0/x86_64-linux/openssl.so')
    assert_equal 'stdlib/set', group.call('/ruby/lib/ruby/3.4.0/set.rb')
    assert_equal 'other', group.call('/tmp/app.rb')
  end

  def test_summarize_takes_median_times_and_reports_count_spread
    run = lambda do |ms, allocations|
      { wall_ms: ms, gc_ms: 0.0, rss_kb: 100, features: 2, allocations: allocations,
        records: [{ path: '/a.rb', parent: nil, depth: 0, incl_ms: ms, excl_ms: ms / 2, gc_ms: 0.0,
                    incl_alloc: 10, excl_alloc: 4 }] }
    end
    s = RequireProfile::Stats.summarize([run.call(10.0, 50), run.call(30.0, 50), run.call(20.0, 52)])

    assert_in_delta 20.0, s[:wall_ms]
    assert_in_delta 20.0, s[:require_ms]
    assert_equal [2, 2], s[:features]
    assert_equal [50, 52], s[:allocations]
    assert_in_delta 10.0, s[:files].first[:excl_ms]
  end

  def test_usage_tier_prefers_client_then_server
    client = { '/a.rb' => 2 }
    server = { '/a.rb' => 5, '/b.rb' => 1, '/c.rb' => 0 }

    assert_equal 'client', RequireProfile::Stats.usage_tier('/a.rb', client, server)
    assert_equal 'server', RequireProfile::Stats.usage_tier('/b.rb', client, server)
    assert_equal 'unused', RequireProfile::Stats.usage_tier('/c.rb', client, server)
    assert_equal 'unused', RequireProfile::Stats.usage_tier('/d.rb', client, server)
  end

  private

  def write(name, body) = File.write(File.join(@dir, name), body)

  def profile_child(script)
    out = File.join(@dir, 'result.bin')
    log, status = spawn_child(script, out)

    assert_predicate status, :success?, log
    load_result(out)
  end

  # No bundler and no COVERAGE: the hook needs only core Ruby, and a child
  # sharing the suite's coverage dir would clobber its results.
  def spawn_child(script, out, env = {})
    env = { RequireProfile::HOOK_ENV => out, 'RUBYOPT' => nil, 'COVERAGE' => nil, 'RUBYLIB' => @dir }.merge(env)
    log = IO.popen(env, [RbConfig.ruby, '-r', HOOK, '-e', script], err: %i[child out], &:read)
    [log, $CHILD_STATUS]
  end

  def load_result(path) = Marshal.load(File.binread(path)) # rubocop:disable Security/MarshalLoad
end
