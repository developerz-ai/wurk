# frozen_string_literal: true

require_relative '../test_helper'

# Wurk::Topology is a pure-data DSL — no Redis. Parallel-safe.
class TopologyTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_starts_empty # rubocop:disable Minitest/MultipleAssertions
    t = Wurk::Topology.new

    assert_empty t.slots
    assert_predicate t, :empty?
    assert_equal 0, t.total_processes
    assert_empty t.assignments
  end

  def test_slot_appends_and_chains
    t = Wurk::Topology.new

    result = t.slot(count: 2, queues: ['critical'], concurrency: 5)

    assert_same t, result, 'slot should return self for chaining'
    assert_equal 1, t.slots.size
    refute_predicate t, :empty?
  end

  def test_slot_records_count_queues_concurrency
    t = Wurk::Topology.new.slot(count: 2, queues: %w[critical default], concurrency: 5)
    slot = t.slots.first

    assert_equal 2, slot.count
    assert_equal %w[critical default], slot.queues
    assert_equal 5, slot.concurrency
  end

  def test_slot_stringifies_queue_symbols
    t = Wurk::Topology.new.slot(count: 1, queues: %i[high low], concurrency: 1)

    assert_equal %w[high low], t.slots.first.queues
  end

  def test_slot_rejects_zero_or_negative_count
    t = Wurk::Topology.new

    assert_raises(ArgumentError) { t.slot(count: 0, queues: ['q'], concurrency: 1) }
    assert_raises(ArgumentError) { t.slot(count: -1, queues: ['q'], concurrency: 1) }
  end

  def test_slot_rejects_empty_queues
    t = Wurk::Topology.new

    assert_raises(ArgumentError) { t.slot(count: 1, queues: [], concurrency: 1) }
  end

  def test_slot_rejects_zero_or_negative_concurrency
    t = Wurk::Topology.new

    assert_raises(ArgumentError) { t.slot(count: 1, queues: ['q'], concurrency: 0) }
    assert_raises(ArgumentError) { t.slot(count: 1, queues: ['q'], concurrency: -1) }
  end

  def test_slots_is_frozen
    t = Wurk::Topology.new.slot(count: 1, queues: ['q'], concurrency: 1)

    assert_predicate t.slots, :frozen?
  end

  def test_assignments_expands_count_in_order
    t = Wurk::Topology.new
    t.slot(count: 2, queues: ['critical'], concurrency: 1)
    t.slot(count: 3, queues: ['default'],  concurrency: 5)

    assignments = t.assignments

    assert_equal 5, assignments.size
    assert_equal(%w[critical critical default default default], assignments.map { |s| s.queues.first })
  end

  def test_total_processes_sums_counts
    t = Wurk::Topology.new
    t.slot(count: 2, queues: ['a'], concurrency: 1)
    t.slot(count: 3, queues: ['b'], concurrency: 1)

    assert_equal 5, t.total_processes
  end

  def test_flat_builds_single_slot_topology # rubocop:disable Minitest/MultipleAssertions
    t = Wurk::Topology.flat(count: 4, queues: %w[default low], concurrency: 10)

    assert_equal 1, t.slots.size
    assert_equal 4, t.total_processes

    slot = t.slots.first

    assert_equal 4, slot.count
    assert_equal %w[default low], slot.queues
    assert_equal 10, slot.concurrency
  end
end
