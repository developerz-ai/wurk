# frozen_string_literal: true

require_relative '../test_helper'

# Slice 11 — the build-time half of flows: what a graph is allowed to be.
#
# Nothing here touches Redis, and that is the point. Every refusal in this file
# has to happen before creation writes anything, because the failures being
# refused are silent at runtime: a cycle deadlocks without raising, and an
# oversized graph does not fail so much as bury Redis.
class FlowBuilderTest < Wurk::Test::UnitCase
  parallelize_me!

  class FetchJob
    include Wurk::Job

    def perform(*); end
  end

  class MergeJob
    include Wurk::Job

    def perform(*); end
  end

  def test_allocates_a_batch_shaped_fid_without_touching_redis
    flow = Wurk::Flow.new { |f| f.job(FetchJob) }

    assert_match(/\A[A-Za-z0-9_-]+\z/, flow.fid)
    refute_equal flow.fid, Wurk::Flow.new { |f| f.job(FetchJob) }.fid
  end

  def test_requires_a_block
    assert_raises(ArgumentError) { Wurk::Flow.new }
  end

  def test_refuses_a_flow_with_no_jobs
    error = assert_raises(Wurk::Flow::InvalidGraph) { Wurk::Flow.new { |_f| nil } }

    assert_match(/at least one job/, error.message)
  end

  def test_job_returns_a_handle_carrying_the_declaration
    node = nil
    Wurk::Flow.new { |f| node = f.job(FetchJob, 'https://a', 1, queue: 'critical', name: :a) }

    assert_equal 0, node.index
    assert_equal :a, node.name
    assert_equal FetchJob, node.klass
    assert_equal ['https://a', 1], node.args
    assert_equal({ queue: 'critical' }, node.options)
  end

  def test_diamond_links_both_directions_and_orders_dependencies_first
    flow = Wurk::Flow.new do |f|
      a = f.job(FetchJob, 'a', name: :a)
      b = f.job(FetchJob, 'b', name: :b)
      f.job(MergeJob, name: :merge, depends_on: [a, b])
    end

    a, b, merge = flow.nodes

    assert_equal %i[a b merge], flow.nodes.map(&:name)
    assert_equal [a, b], merge.dependencies
    assert_equal [merge], a.dependents
    assert_equal [merge], b.dependents
    assert_equal [a, b], flow.roots
    assert_equal 2, flow.depth
    assert_equal 2, flow.width
  end

  def test_names_may_be_forward_references
    flow = Wurk::Flow.new do |f|
      f.job(MergeJob, name: :merge, depends_on: %i[a b])
      f.job(FetchJob, 'a', name: :a)
      f.job(FetchJob, 'b', name: :b)
    end

    assert_equal %i[a b merge], flow.nodes.map(&:name)
    assert_equal 2, flow.nodes.last.dependencies.size
  end

  def test_string_and_symbol_names_address_the_same_node
    flow = Wurk::Flow.new do |f|
      f.job(FetchJob, name: 'a')
      f.job(MergeJob, depends_on: :a)
    end

    assert_equal [flow.nodes.first], flow.nodes.last.dependencies
  end

  def test_repeated_dependency_is_one_edge
    flow = Wurk::Flow.new do |f|
      a = f.job(FetchJob, name: :a)
      f.job(MergeJob, depends_on: [a, :a, a])
    end

    assert_equal 1, flow.nodes.last.dependencies.size
    assert_equal 1, flow.width
  end

  def test_levels_follow_the_longest_path_not_the_shortest
    flow = Wurk::Flow.new do |f|
      a = f.job(FetchJob, name: :a)
      b = f.job(FetchJob, name: :b, depends_on: a)
      f.job(MergeJob, name: :merge, depends_on: [a, b])
    end

    assert_equal [0, 1, 2], flow.nodes.map(&:level)
    assert_equal 3, flow.depth
  end

  def test_built_nodes_are_frozen
    flow = Wurk::Flow.new { |f| f.job(FetchJob) }

    assert_predicate flow.nodes.first, :frozen?
    assert_raises(FrozenError) { flow.nodes.first.dependencies << :x }
  end

  # --- cycles -------------------------------------------------------------

  def test_cycle_is_refused_and_the_message_names_the_whole_loop
    error = assert_raises(Wurk::Flow::CycleError) do
      Wurk::Flow.new do |f|
        f.job(FetchJob, name: :a, depends_on: :c)
        f.job(FetchJob, name: :b, depends_on: :a)
        f.job(FetchJob, name: :c, depends_on: :b)
      end
    end

    path = error.message[/cycle: (.+) \(→ reads/, 1].split(' → ')

    assert_equal 4, path.size, error.message
    assert_equal path.first, path.last
    %i[a b c].each { |name| assert_includes error.message, name.inspect }
  end

  def test_self_dependency_is_a_cycle
    error = assert_raises(Wurk::Flow::CycleError) do
      Wurk::Flow.new { |f| f.job(FetchJob, name: :a, depends_on: :a) }
    end

    assert_match(/FetchJob\[:a\] → .*FetchJob\[:a\]/, error.message)
  end

  def test_cycle_is_reported_even_when_acyclic_nodes_surround_it
    error = assert_raises(Wurk::Flow::CycleError) do
      Wurk::Flow.new do |f|
        f.job(FetchJob, name: :root)
        f.job(FetchJob, name: :a, depends_on: %i[root b])
        f.job(FetchJob, name: :b, depends_on: :a)
      end
    end

    refute_includes error.message, ':root'
  end

  # `:tail` is stuck behind the cycle but is not part of it, and the walk that
  # finds the loop starts there — declaration order seeds it. Reporting the
  # approach path would point at an edge whose deletion fixes nothing.
  def test_cycle_path_excludes_nodes_that_only_lead_into_the_cycle
    error = assert_raises(Wurk::Flow::CycleError) do
      Wurk::Flow.new do |f|
        f.job(MergeJob, name: :tail, depends_on: :a)
        f.job(FetchJob, name: :a, depends_on: :b)
        f.job(FetchJob, name: :b, depends_on: :a)
      end
    end

    refute_includes error.message, ':tail'
    assert_equal 3, error.message[/cycle: (.+) \(→ reads/, 1].split(' → ').size
  end

  # --- caps ---------------------------------------------------------------

  def test_node_past_max_nodes_is_refused_at_the_call_that_declares_it
    error = assert_raises(Wurk::Flow::LimitExceeded) do
      Wurk::Flow.new { |f| (Wurk::Flow::MAX_NODES + 1).times { f.job(FetchJob) } }
    end

    assert_match(/would be flow node #{Wurk::Flow::MAX_NODES + 1}/, error.message)
  end

  def test_max_nodes_exactly_is_allowed
    flow = Wurk::Flow.new { |f| Wurk::Flow::MAX_NODES.times { f.job(FetchJob) } }

    assert_equal Wurk::Flow::MAX_NODES, flow.size
  end

  def test_graph_deeper_than_max_depth_is_refused
    error = assert_raises(Wurk::Flow::LimitExceeded) do
      Wurk::Flow.new do |f|
        previous = f.job(FetchJob)
        Wurk::Flow::MAX_DEPTH.times { previous = f.job(FetchJob, depends_on: previous) }
      end
    end

    assert_match(/depth #{Wurk::Flow::MAX_DEPTH + 1} exceeds MAX_DEPTH/, error.message)
  end

  def test_max_depth_exactly_is_allowed
    flow = Wurk::Flow.new do |f|
      previous = f.job(FetchJob)
      (Wurk::Flow::MAX_DEPTH - 1).times { previous = f.job(FetchJob, depends_on: previous) }
    end

    assert_equal Wurk::Flow::MAX_DEPTH, flow.depth
  end

  def test_fan_in_past_max_width_is_refused_and_points_at_the_alternative
    error = assert_raises(Wurk::Flow::LimitExceeded) do
      Wurk::Flow.new do |f|
        children = Array.new(Wurk::Flow::MAX_WIDTH + 1) { f.job(FetchJob) }
        f.job(MergeJob, name: :merge, depends_on: children)
      end
    end

    assert_match(/MergeJob\[:merge\] has #{Wurk::Flow::MAX_WIDTH + 1} dependencies/, error.message)
    assert_match(/belongs inside one node's own batch/, error.message)
  end

  def test_fan_out_past_max_width_is_refused
    error = assert_raises(Wurk::Flow::LimitExceeded) do
      Wurk::Flow.new do |f|
        root = f.job(FetchJob, name: :root)
        (Wurk::Flow::MAX_WIDTH + 1).times { f.job(MergeJob, depends_on: root) }
      end
    end

    assert_match(/FetchJob\[:root\] has #{Wurk::Flow::MAX_WIDTH + 1} dependents/, error.message)
  end

  def test_max_width_exactly_is_allowed
    flow = Wurk::Flow.new do |f|
      children = Array.new(Wurk::Flow::MAX_WIDTH) { f.job(FetchJob) }
      f.job(MergeJob, depends_on: children)
    end

    assert_equal Wurk::Flow::MAX_WIDTH, flow.width
  end

  # --- malformed declarations ---------------------------------------------

  def test_dependency_on_an_undeclared_name_is_refused
    error = assert_raises(Wurk::Flow::InvalidGraph) do
      Wurk::Flow.new { |f| f.job(MergeJob, depends_on: :nope) }
    end

    assert_match(/MergeJob\[#0\] depends on :nope, which no node declares/, error.message)
  end

  def test_handle_from_another_flow_is_refused
    foreign = nil
    Wurk::Flow.new { |f| foreign = f.job(FetchJob) }

    error = assert_raises(Wurk::Flow::InvalidGraph) do
      Wurk::Flow.new do |f|
        f.job(FetchJob)
        f.job(MergeJob, depends_on: foreign)
      end
    end

    assert_match(/belongs to a different flow/, error.message)
  end

  def test_duplicate_node_name_is_refused
    error = assert_raises(Wurk::Flow::InvalidGraph) do
      Wurk::Flow.new do |f|
        f.job(FetchJob, name: :a)
        f.job(MergeJob, name: 'a')
      end
    end

    assert_match(/duplicate flow node name :a/, error.message)
  end

  def test_unusable_name_is_refused
    [42, '', :''].each do |name|
      assert_raises(Wurk::Flow::InvalidGraph) { Wurk::Flow.new { |f| f.job(FetchJob, name: name) } }
    end
  end

  def test_unusable_dependency_ref_is_refused
    error = assert_raises(Wurk::Flow::InvalidGraph) do
      Wurk::Flow.new { |f| f.job(MergeJob, depends_on: 42) }
    end

    assert_match(/depends_on takes nodes returned by #job or their names/, error.message)
  end

  def test_missing_job_class_is_refused
    [nil, '', :FetchJob].each do |klass|
      assert_raises(Wurk::Flow::InvalidGraph) { Wurk::Flow.new { |f| f.job(klass) } }
    end
  end

  # Every refusal is an ArgumentError, so the HTTP API's existing rescue turns
  # a bad graph into a 400 without a new arm (api/jobs.rb:100).
  def test_every_refusal_is_an_argument_error
    assert_operator Wurk::Flow::InvalidGraph, :<, ArgumentError
    assert_operator Wurk::Flow::CycleError, :<, Wurk::Flow::InvalidGraph
    assert_operator Wurk::Flow::LimitExceeded, :<, Wurk::Flow::InvalidGraph
  end
end
