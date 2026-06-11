# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Parity test for the SortedEntry mutation API. Mirrors upstream Sidekiq's
# api_test.rb expectations: `retry` decrements `retry_count` (the count was
# bumped entering the retry set; the next failure re-bumps it), while
# `add_to_queue` pushes the payload untouched — and `kill` fires death
# handlers by default with the synthesized RuntimeError("Job killed by API").
#
# When this file diverges from upstream Sidekiq's tests, Wurk is wrong
# unless the divergence is explicitly documented in
# docs/target/sidekiq-free.md §19.
class SortedEntryApiParityTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns           = "#{Process.pid}-#{object_id}"
    @parent       = Wurk::RetrySet.new("retry-#{@ns}")
    @pool         = Wurk.configuration.redis_pool
    @dead_members = []
    @queues       = []
  end

  def teardown
    @pool.with do |c|
      c.call('UNLINK', @parent.name)
      @queues.each do |q|
        c.call('DEL', "queue:#{q}")
        c.call('SREM', 'queues', q)
      end
      c.call('ZREM', 'dead', *@dead_members) unless @dead_members.empty?
    end
  ensure
    super
  end

  def test_retry_pushed_payload_matches_sidekiq
    queue = unique_queue
    entry = add_entry('retry_count' => 3, 'queue' => queue)

    entry.retry

    assert_equal 2, pushed_payload(queue)['retry_count']
  end

  def test_add_to_queue_pushed_payload_matches_sidekiq
    queue = unique_queue
    entry = add_entry('retry_count' => 3, 'queue' => queue)

    entry.add_to_queue

    assert_equal 3, pushed_payload(queue)['retry_count']
  end

  def test_kill_fires_death_handlers_with_api_exception
    entry = add_entry
    @dead_members << entry.value

    ex = kill_and_capture_exception(entry)

    assert_instance_of RuntimeError, ex
    assert_equal 'Job killed by API', ex.message
  end

  private

  # Kills the entry with a jid-keyed capture handler installed (the handler
  # list is process-global and this class is parallel) and returns the
  # exception the handlers observed for it.
  def kill_and_capture_exception(entry)
    received = {}
    handler = ->(job, ex) { received[job['jid']] = ex }
    Wurk.configuration.death_handlers << handler
    entry.kill
    received[entry.jid]
  ensure
    Wurk.configuration.death_handlers.delete(handler)
  end

  def add_entry(extra = {})
    item = {
      'class' => 'SortedEntryParityJob',
      'args' => [],
      'queue' => 'default',
      'jid' => SecureRandom.hex(12),
      'created_at' => Time.now.to_f
    }.merge(extra)
    payload = Wurk.dump_json(item)
    @pool.with { |c| c.call('ZADD', @parent.name, 100.0, payload) }
    Wurk::SortedEntry.new(@parent, 100.0, payload)
  end

  def pushed_payload(queue)
    Wurk.load_json(@pool.with { |c| c.call('LRANGE', "queue:#{queue}", 0, 0) }.first)
  end

  def unique_queue
    q = "sep-q-#{@ns}-#{@queues.size}"
    @queues << q
    q
  end
end
