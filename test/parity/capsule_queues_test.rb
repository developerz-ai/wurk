# frozen_string_literal: true

require_relative '../test_helper'

# Parity oracle for queue weights. Spec: docs/target/sidekiq-free.md §5 capsule
# `queues=` ("name" or "name,weight"; `:weighted` shuffles the expanded list on
# every fetch), and the `-q QUEUE[,WEIGHT]` form in §21.
# An entry with no weight stays a served queue when others carry one. Real
# Redis: the assertion is that the fetcher actually hands out the job.
class CapsuleQueuesParityTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @prefix = "cq-#{Process.pid}-#{object_id}"
    @config = Wurk::Configuration.new
  end

  def teardown
    Wurk.redis { |c| c.call('FLUSHDB') }
  ensure
    super
  end

  def test_an_unweighted_queue_in_a_weighted_list_is_fetched
    weighted = "#{@prefix}-weighted"
    bare = "#{@prefix}-bare"
    payload = push(bare)

    assert_equal payload, fetch([[weighted, 2], bare]).job
  end

  def test_string_form_of_the_same_list_is_fetched
    bare = "#{@prefix}-bare"
    payload = push(bare)

    assert_equal payload, fetch(["#{@prefix}-weighted,2", bare]).job
  end

  # The weighted queue is reachable too, and neither one starves the other.
  def test_both_queues_are_served
    weighted = "#{@prefix}-weighted"
    bare = "#{@prefix}-bare"
    jobs = [push(weighted), push(bare)]

    fetched = Array.new(2) { fetch([[weighted, 2], bare]).job }

    assert_equal jobs.sort, fetched.sort
  end

  private

  def fetch(queues)
    capsule = Wurk::Capsule.new('default', @config)
    capsule.queues = queues
    Wurk::Fetcher::Reliable.new(capsule).retrieve_work
  end

  def push(queue)
    json = Wurk.dump_json('class' => 'X', 'args' => [], 'queue' => queue, 'jid' => SecureRandom.hex(12))
    Wurk.redis { |c| c.call('LPUSH', "queue:#{queue}", json) }
    json
  end
end
