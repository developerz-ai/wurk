# frozen_string_literal: true

require_relative '../test_helper'

# Top-level so Object.const_get resolves them inside the forked child.
module Batch547Events
  def self.record(options, label)
    client = RedisClient.config(url: options['url']).new_client
    client.call('RPUSH', options['events'], label)
  ensure
    client&.close
  end
end

class Batch547Step
  include Wurk::Job

  def perform(options, label)
    Batch547Events.record(options, label)
  end
end

# Opens its own batch (spec §2.9: "a job opens its own batch only") and adds
# step 1 as a child of it.
class Batch547StartWorkflow
  include Wurk::Job

  def perform(options)
    Batch547Events.record(options, 'start')
    batch.jobs do
      step1 = Wurk::Batch.new
      step1.callback_queue = options['queue']
      step1.on(:success, 'Batch547Fulfillment#step1_done', options)
      step1.jobs { Batch547Step.set(queue: options['queue']).perform_async(options, 'A') }
    end
  end
end

class Batch547Fulfillment
  # Sleeps before adding step 2 so a parent that fired as soon as step 1's
  # *jobs* drained (instead of waiting for this callback) has all the time it
  # needs to show up first in the event log.
  def step1_done(status, options)
    Batch547Events.record(options, 'step1_done')
    sleep 0.3
    parent = Wurk::Batch.new(status.parent_bid)
    parent.jobs do
      step2 = Wurk::Batch.new
      step2.callback_queue = options['queue']
      step2.on(:success, 'Batch547Fulfillment#step2_done', options)
      step2.jobs do
        Batch547Step.set(queue: options['queue']).perform_async(options, 'B')
        Batch547Step.set(queue: options['queue']).perform_async(options, 'C')
      end
    end
  end

  def step2_done(_status, options)
    Batch547Events.record(options, 'step2_done')
  end

  def shipped(_status, options)
    Batch547Events.record(options, 'shipped')
  end
end

# E3 — the spec §2.9 step workflow end to end under real forks and real
# Redis: the overall batch's `:success` must wait for step 1's callback (which
# adds step 2 to the overall batch) and then for step 2 and its callback.
# Before the fix the overall batch fired the moment step 1's jobs drained,
# ahead of `step1_done`, so `shipped` ran before step 2 even existed.
class BatchStepWorkflowTest < Wurk::Test::UnitCase
  parallelize_me!

  POLL_TIMEOUT = 20.0
  POLL_INTERVAL = 0.05

  def setup
    super
    @ns = "batch547-#{Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @events = "#{@ns}-events"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config[:timeout] = 5
    @config.server_middleware.add(Wurk::Batch::ServerMiddleware)
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
    @bids = []
  end

  def teardown
    @observer&.call('DEL', @events, "queue:#{@queue_name}",
                    Wurk::Fetcher::Reliable.private_queue_name("queue:#{@queue_name}"))
    @observer&.call('SREM', 'queues', @queue_name)
    @observer&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_overall_success_waits_for_every_step_and_its_callback
    options = { 'url' => Wurk::Test.redis_url, 'events' => @events, 'queue' => @queue_name }
    overall = Wurk::Batch.new
    overall.callback_queue = @queue_name
    overall.on(:success, 'Batch547Fulfillment#shipped', options)
    overall.jobs { Batch547StartWorkflow.set(queue: @queue_name).perform_async(options) }

    swarm = Wurk::Swarm.new(topology: Wurk::Topology.flat(count: 1, queues: [@queue_name], concurrency: 3),
                            config: @config, shutdown_timeout: 5)
    supervisor = nil
    begin
      swarm.boot(install_signals: false)
      supervisor = Thread.new { swarm.supervise }

      assert wait_until { events.include?('shipped') }, "workflow never shipped: #{events.inspect}"
      sleep 0.3 # a duplicate `shipped` would land within this window

      log = events

      assert_equal 1, log.count('shipped'), "shipped must fire exactly once: #{log.inspect}"
      assert_equal 'shipped', log.last, "shipped must come after every step: #{log.inspect}"
      %w[start A step1_done B C step2_done].each { |e| assert_includes log, e }
      assert_operator log.index('step1_done'), :<, log.index('B')
      assert_operator log.index('step2_done'), :>, [log.index('B'), log.index('C')].max
    ensure
      begin
        swarm.shutdown(timeout: 5)
      rescue StandardError
        nil
      end
      stop_supervisor_thread(supervisor, 10)
    end
  end

  private

  def events
    @observer.call('LRANGE', @events, 0, -1)
  end

  def wait_until
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + POLL_TIMEOUT
    until ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
      return true if yield

      sleep POLL_INTERVAL
    end
    false
  end
end
