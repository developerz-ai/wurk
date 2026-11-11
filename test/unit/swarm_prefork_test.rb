# frozen_string_literal: true

require_relative '../test_helper'

# M2: the heap is settled once, before the first fork, on every swarm entry
# point (Swarm#boot serves `wurkswarm` and the railtie alike), with a Ruby 3.2
# fallback for `Process.warmup`.
class SwarmPreforkTest < Wurk::Test::UnitCase
  class GCWithoutCompaction
    attr_reader :calls

    def initialize = @calls = []
    def start(**opts) = @calls << [:start, opts]
  end

  class RecordingGC < GCWithoutCompaction
    def compact = @calls << [:compact]
  end

  class NoCompactionGC < GCWithoutCompaction
    def compact = raise(NotImplementedError, 'compaction unsupported')
  end

  # Records the order of the fork and the prefork step without forking.
  class OrderProbeSwarm < Wurk::Swarm
    attr_reader :events

    private

    def settle_memory_before_fork
      (@events ||= []) << :prefork
    end

    def fork_child(_slot, _idx)
      (@events ||= []) << :fork
      @fake_pid = (@fake_pid || 7000) + 1
    end
  end

  def test_uses_process_warmup_when_the_ruby_has_it
    process = Object.new
    process.define_singleton_method(:warmup) { :warmed }
    gc = RecordingGC.new

    assert_equal :warmed, Wurk::Swarm::Prefork.warmup(process, gc)
    assert_empty gc.calls
  end

  def test_ruby_3_2_falls_back_to_a_full_gc_then_compaction
    gc = RecordingGC.new
    Wurk::Swarm::Prefork.warmup(Object.new, gc)

    assert_equal [[:start, { full_mark: true, immediate_sweep: true }], [:compact]], gc.calls
  end

  def test_skips_compaction_where_the_gc_has_none
    gc = GCWithoutCompaction.new
    Wurk::Swarm::Prefork.warmup(Object.new, gc)

    assert_equal [:start], gc.calls.map(&:first)
  end

  def test_a_platform_without_compaction_is_not_an_error
    gc = NoCompactionGC.new

    assert_nil Wurk::Swarm::Prefork.warmup(Object.new, gc)
  end

  def test_ruby_disable_warmup_skips_the_warmup_but_still_loads_child_features
    warmed = false
    with_singleton(Wurk::Swarm::Prefork, :warmup, -> { warmed = true }) do
      Wurk::Swarm::Prefork.run({ 'RUBY_DISABLE_WARMUP' => '1' })
    end

    refute warmed
    assert(Wurk::Swarm::Prefork::CHILD_FEATURES.all? { |f| $LOADED_FEATURES.any? { |l| l.include?("/#{f}") } })
  end

  def test_warms_up_by_default
    warmed = false
    with_singleton(Wurk::Swarm::Prefork, :warmup, -> { warmed = true }) { Wurk::Swarm::Prefork.run({}) }

    assert warmed
  end

  # The leader child would otherwise load tzinfo and each zone on its first
  # tick, privately; resolved here they are shared copy-on-write.
  def test_resolves_the_registered_periodic_zones_before_the_fork
    mgr = Wurk::Cron::Manager.new(nil, deferred: true)
    mgr.register('0 4 * * *', 'SwarmPreforkTest::ZoneJob', tz: 'Pacific/Chatham')
    Wurk::Cron::Parser.instance_variable_get(:@tz_cache).delete('Pacific/Chatham')

    Wurk::Swarm::Prefork.run({ 'RUBY_DISABLE_WARMUP' => '1' }, periodic: mgr)

    assert Wurk::Cron::Parser.instance_variable_get(:@tz_cache)['Pacific/Chatham']
  end

  def test_a_config_without_periodic_has_no_manager_to_warm
    assert_nil Wurk::Configuration.new.periodic_manager
  end

  def test_a_missing_feature_is_skipped
    assert_nil Wurk::Swarm::Prefork.try_require('wurk_no_such_feature')
  end

  def test_boot_settles_memory_once_before_the_first_fork
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    swarm = OrderProbeSwarm.new(topology: Wurk::Topology.flat(count: 3, queues: ['default'], concurrency: 1),
                                config: config)
    swarm.boot(install_signals: false)

    assert_equal %i[prefork fork fork fork], swarm.events
  end

  private

  def with_singleton(target, name, body)
    original = target.method(name)
    target.define_singleton_method(name) { |*| body.call }
    yield
  ensure
    target.define_singleton_method(name, original)
  end
end
