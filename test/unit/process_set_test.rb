# frozen_string_literal: true

require_relative '../test_helper'

# Drives Wurk::ProcessSet + Wurk::Process against real Redis. The `processes`
# SET is globally shared, so tests use uniquely-named identities and assert
# `>=` lower bounds on cluster-wide counters. `cleanup` is rate-limited via
# a global SET NX EX 60 — we reset that lock per-test to keep behavior
# deterministic.
class ProcessSetTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns         = "#{Process.pid}-#{object_id}"
    @hostname   = "host-#{@ns}"
    @identity   = "#{@hostname}:1234:abcdef#{object_id.to_s(16)}"
    @pool       = Wurk.configuration.redis_pool
    @identities = []
    @leader_touched = false
    @pool.with { |c| c.call('DEL', 'process_cleanup') }
  end

  def teardown
    @pool.with do |c|
      @identities.each do |id|
        c.call('SREM', 'processes', id)
        c.call('DEL', id, "#{id}:work", "#{id}-signals")
      end
      # Only touch `dear-leader` if the test mutated it; otherwise leave the
      # shared key alone so parallel siblings reading it stay deterministic.
      c.call('DEL', 'dear-leader') if @leader_touched
      c.call('DEL', 'process_cleanup')
    end
  ensure
    super
  end

  # --- shape -------------------------------------------------------------

  def test_includes_enumerable
    assert_includes Wurk::ProcessSet.ancestors, Enumerable
  end

  def test_initialize_with_false_skips_cleanup
    @pool.with { |c| c.call('SET', 'process_cleanup', '1', 'EX', '60') }
    Wurk::ProcessSet.new(false)
    lock = @pool.with { |c| c.call('GET', 'process_cleanup') }

    assert_equal '1', lock
  end

  # --- [] lookup ---------------------------------------------------------

  def test_lookup_returns_nil_for_unknown_identity
    assert_nil Wurk::ProcessSet["#{@identity}-missing"]
  end

  def test_lookup_returns_process_when_info_present
    register!(info: base_info, busy: '2')
    process = Wurk::ProcessSet[@identity]

    refute_nil process
    assert_kind_of Wurk::Process, process
  end

  # rubocop:disable Minitest/MultipleAssertions
  # One test, one Process shape: each field is part of the public contract.
  def test_lookup_populates_busy_beat_quiet_rss
    register!(info: base_info, busy: '3', beat: '12345.6', quiet: 'false', rss: '4096', rtt_us: '900')
    process = Wurk::ProcessSet[@identity]

    assert_equal 3, process['busy']
    assert_in_delta 12_345.6, process['beat']
    assert_equal 'false',  process['quiet']
    assert_equal 4096,     process['rss']
    assert_equal 900,      process['rtt_us']
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_lookup_returns_nil_when_info_expired_but_identity_present
    @identities << @identity
    @pool.with { |c| c.call('SADD', 'processes', @identity) }

    assert_nil Wurk::ProcessSet[@identity]
  end

  # --- size --------------------------------------------------------------

  def test_size_is_scard_processes
    register!(info: base_info)

    assert_operator Wurk::ProcessSet.new(false).size, :>=, 1
  end

  # --- each --------------------------------------------------------------

  def test_each_yields_process_instances
    register!(info: base_info, concurrency: '10')
    seen = Wurk::ProcessSet.new(false).select { |p| p.identity == @identity }

    refute_empty seen
    assert_kind_of Wurk::Process, seen.first
  end

  def test_each_skips_identities_missing_info
    @identities << @identity
    @pool.with { |c| c.call('SADD', 'processes', @identity) }
    seen = Wurk::ProcessSet.new(false).map(&:identity)

    refute_includes seen, @identity
  end

  def test_each_merges_concurrency_and_busy_from_hmget
    register!(info: base_info, concurrency: '7', busy: '4')
    me = Wurk::ProcessSet.new(false).find { |p| p.identity == @identity }

    assert_equal 7, me['concurrency']
    assert_equal 4, me['busy']
  end

  # --- total_concurrency / total_rss ------------------------------------

  def test_total_concurrency_sums_across_processes
    register!(info: base_info, concurrency: '5')
    total = Wurk::ProcessSet.new(false).total_concurrency

    assert_operator total, :>=, 5
  end

  def test_total_rss_in_kb_sums_across_processes
    register!(info: base_info, rss: '2048')
    total = Wurk::ProcessSet.new(false).total_rss_in_kb

    assert_operator total, :>=, 2048
  end

  def test_total_rss_aliases_total_rss_in_kb
    # Method-identity check, not call-result comparison. Both methods iterate
    # `each`, which re-fetches Redis on every call — under parallel siblings
    # the two reads can return different sums even though the methods are
    # the same. `alias` makes UnboundMethods equal.
    assert_equal Wurk::ProcessSet.instance_method(:total_rss_in_kb),
                 Wurk::ProcessSet.instance_method(:total_rss)
  end

  # --- leader ------------------------------------------------------------

  def test_leader_returns_empty_string_when_unset
    # `dear-leader` is shared globally; in parallel, a sibling test may have
    # written to it. Verify the unset path by reading the leader *before*
    # mutating, only when the key happens to be absent. Skip otherwise.
    skip 'dear-leader populated by parallel sibling' if @pool.with { |c| c.call('GET', 'dear-leader') }

    assert_equal '', Wurk::ProcessSet.new(false).leader
  end

  def test_leader_returns_dear_leader_value
    @leader_touched = true
    @pool.with { |c| c.call('SET', 'dear-leader', @identity) }

    assert_equal @identity, Wurk::ProcessSet.new(false).leader
  end

  def test_leader_is_memoized
    @leader_touched = true
    @pool.with { |c| c.call('SET', 'dear-leader', @identity) }
    set = Wurk::ProcessSet.new(false)
    first = set.leader
    @pool.with { |c| c.call('SET', 'dear-leader', "#{@identity}-other") }

    assert_equal first, set.leader
  end

  # --- cleanup -----------------------------------------------------------

  def test_cleanup_prunes_identities_with_no_info_field
    stale = "#{@identity}-stale"
    @identities << stale
    @pool.with { |c| c.call('SADD', 'processes', stale) }
    Wurk::ProcessSet.new(false).cleanup

    refute_includes @pool.with { |c| c.call('SMEMBERS', 'processes') }, stale
  end

  def test_cleanup_leaves_live_identities_alone
    register!(info: base_info)
    Wurk::ProcessSet.new(false).cleanup

    assert_includes @pool.with { |c| c.call('SMEMBERS', 'processes') }, @identity
  end

  def test_cleanup_rate_limited_by_global_lock
    @pool.with { |c| c.call('SET', 'process_cleanup', '1', 'EX', '60') }

    assert_equal 0, Wurk::ProcessSet.new(false).cleanup
  end

  def test_cleanup_returns_zero_when_processes_set_empty
    # `processes` is shared globally — snapshot and restore so parallel
    # siblings keep their registered identities intact. Snapshot+restore
    # alone isn't enough: a sibling test could SADD between SMEMBERS and
    # DEL (lost on restore) or read the empty set mid-window. The mutex
    # serializes against any other test that asserts on `processes`.
    Wurk::Test::PROCESSES_MUTEX.synchronize do
      snapshot = @pool.with { |c| c.call('SMEMBERS', 'processes') }
      @pool.with { |c| c.call('DEL', 'processes') }
      begin
        assert_equal 0, Wurk::ProcessSet.new(false).cleanup
      ensure
        @pool.with { |c| c.call('SADD', 'processes', *snapshot) } unless snapshot.empty?
      end
    end
  end

  # --- Wurk::Process -----------------------------------------------------

  # rubocop:disable Minitest/MultipleAssertions
  # One test, one Process shape: identity / id / tag / labels are all
  # public contract surface.
  def test_process_attributes_passthrough
    process = Wurk::Process.new('tag' => 'web', 'identity' => @identity, 'labels' => %w[a b])

    assert_equal 'web', process.tag
    assert_equal @identity, process.identity
    assert_equal @identity, process.id
    assert_equal %w[a b], process.labels
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_process_labels_defaults_to_empty_array
    assert_empty Wurk::Process.new({}).labels
  end

  def test_process_capsules_returns_hash
    cap = { 'default' => { 'mode' => 'weighted', 'concurrency' => 5, 'weights' => { 'a' => 1 } } }
    process = Wurk::Process.new('capsules' => cap)

    assert_equal cap, process.capsules
  end

  def test_process_queues_from_capsules
    process = Wurk::Process.new(
      'capsules' => {
        'cap1' => { 'weights' => { 'a' => 1, 'b' => 2 } },
        'cap2' => { 'weights' => { 'b' => 1, 'c' => 3 } }
      }
    )

    assert_equal %w[a b c], process.queues.sort
  end

  def test_process_queues_falls_back_to_legacy_field
    process = Wurk::Process.new('queues' => %w[x y])

    assert_equal %w[x y], process.queues
  end

  def test_process_weights_from_capsules
    process = Wurk::Process.new(
      'capsules' => {
        'cap1' => { 'weights' => { 'a' => 1 } },
        'cap2' => { 'weights' => { 'b' => 2 } }
      }
    )

    assert_equal({ 'a' => 1, 'b' => 2 }, process.weights)
  end

  def test_process_weights_falls_back_to_legacy_field
    legacy = { 'a' => 3 }

    assert_equal legacy, Wurk::Process.new('weights' => legacy).weights
  end

  def test_process_version_passthrough
    assert_equal '8.1.5', Wurk::Process.new('version' => '8.1.5').version
  end

  def test_process_embedded_passthrough
    assert_predicate Wurk::Process.new('embedded' => true), :embedded?
  end

  def test_process_stopping_is_true_when_quiet
    assert_predicate Wurk::Process.new('quiet' => 'true'), :stopping?
  end

  def test_process_stopping_is_false_otherwise
    refute_predicate Wurk::Process.new('quiet' => 'false'), :stopping?
  end

  def test_process_quiet_bang_lpushes_tstp
    register!(info: base_info)
    Wurk::ProcessSet[@identity].quiet!

    assert_equal 'TSTP', latest_signal
  end

  def test_process_stop_bang_lpushes_term
    register!(info: base_info)
    Wurk::ProcessSet[@identity].stop!

    assert_equal 'TERM', latest_signal
  end

  def test_process_dump_threads_lpushes_ttin
    register!(info: base_info)
    Wurk::ProcessSet[@identity].dump_threads

    assert_equal 'TTIN', latest_signal
  end

  def test_process_signals_have_ttl
    register!(info: base_info)
    Wurk::ProcessSet[@identity].quiet!
    ttl = @pool.with { |c| c.call('TTL', "#{@identity}-signals") }

    assert_operator ttl, :>, 0
    assert_operator ttl, :<=, 60
  end

  def test_process_quiet_bang_raises_when_embedded
    process = Wurk::Process.new('embedded' => true, 'identity' => @identity)

    assert_raises(RuntimeError) { process.quiet! }
  end

  def test_process_stop_bang_raises_when_embedded
    process = Wurk::Process.new('embedded' => true, 'identity' => @identity)

    assert_raises(RuntimeError) { process.stop! }
  end

  def test_process_leader_predicate_true_when_identity_matches_dear_leader
    @leader_touched = true
    register!(info: base_info)
    @pool.with { |c| c.call('SET', 'dear-leader', @identity) }

    assert_predicate Wurk::ProcessSet[@identity], :leader?
  end

  def test_process_leader_predicate_false_when_identity_does_not_match
    @leader_touched = true
    register!(info: base_info)
    @pool.with { |c| c.call('SET', 'dear-leader', 'someone-else') }

    refute_predicate Wurk::ProcessSet[@identity], :leader?
  end

  # --- Sidekiq aliases ---------------------------------------------------

  def test_sidekiq_process_set_aliased
    assert_equal Wurk::ProcessSet, Sidekiq::ProcessSet
  end

  def test_sidekiq_process_aliased
    assert_equal Wurk::Process, Sidekiq::Process
  end

  private

  def latest_signal
    @pool.with { |c| c.call('LRANGE', "#{@identity}-signals", 0, 0) }.first
  end

  def base_info
    Wurk.dump_json(
      'hostname' => @hostname,
      'pid' => 1234,
      'tag' => 'wurk-test',
      'concurrency' => 5,
      'identity' => @identity,
      'version' => Wurk::VERSION,
      'started_at' => ::Process.clock_gettime(::Process::CLOCK_REALTIME).to_f
    )
  end

  def register!(fields)
    @identities << @identity
    @pool.with do |c|
      c.call('SADD', 'processes', @identity)
      fields.each { |k, v| c.call('HSET', @identity, k.to_s, v) }
    end
  end
end
