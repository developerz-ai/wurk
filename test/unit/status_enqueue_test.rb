# frozen_string_literal: true

require 'securerandom'
require_relative '../test_helper'

# The Wurk::Status opt-in: where `track:` is validated, what an enqueue writes
# for a class that opted in, how long the row lives — and the proof that a class
# which never opts in pays nothing at all for the feature's existence.
class StatusEnqueueTest < Wurk::Test::UnitCase
  parallelize_me!

  # The batched push is an EVALSHA, which counts as one command only against a
  # warm script cache; a cold one pays NOSCRIPT + SCRIPT LOAD + retry.
  def setup
    super
    @queue = "status-enq-#{SecureRandom.hex(4)}"
    Wurk.redis { |conn| Wurk::Lua::Loader.script_load_all(conn) }
  end

  # Counts round trips as well as commands: the whole claim of the enqueue path
  # is that a tracked push adds commands to the pipeline the queue write already
  # opened, never a round trip of its own.
  class PipelineCountingSpy < Wurk::Test::CommandSpy
    attr_reader :pipelines

    def initialize(pool)
      super
      @pipelines = 0
      @corrections = 0
    end

    # CommandSpy folds a pipeline's one round trip into the command count;
    # undoing that correction recovers the raw round-trip tally.
    def trips = count - @corrections

    def record_batch(actual_commands)
      @pipelines += 1
      @corrections += actual_commands - 1
      super
    end
  end

  class TrackedJob
    include Wurk::Worker

    sidekiq_options track: true

    def perform(*); end
  end

  def job(track: nil, **extra)
    item = { 'class' => 'StatusEnqueueJob', 'args' => [1], 'queue' => @queue }.merge(extra)
    item['track'] = track unless track.nil?
    item
  end

  def client(pool = Wurk.redis_pool, config: Wurk.configuration)
    Wurk::Client.new(pool: pool, config: config)
  end

  def ttl(jid) = Wurk.redis { |c| c.call('TTL', Wurk::Status.key(jid)) }.to_i

  # --- validation ----------------------------------------------------

  def test_the_worker_dsl_accepts_boolean_track
    klass = Class.new { include Wurk::Worker }

    assert_same true, klass.sidekiq_options(track: true)['track']
    assert_same false, klass.sidekiq_options(track: false)['track']
  end

  # `Status.tracked?` asks the payload for truthiness, so a string would track
  # every job of the class — including the string "false".
  def test_the_worker_dsl_rejects_a_non_boolean_track
    klass = Class.new { include Wurk::Worker }

    ['yes', 'false', 1, :on].each do |value|
      error = assert_raises(ArgumentError) { klass.sidekiq_options(track: value) }
      assert_match(/'track' must be true or false/, error.message)
    end
    refute klass.get_sidekiq_options.key?('track'), 'a rejected option must not be half-applied'
  end

  # The ActiveJob options DSL is a second copy of the same surface; a bad value
  # has to fail identically there or the two drift.
  def test_the_activejob_options_dsl_rejects_a_non_boolean_track
    klass = Class.new { include Wurk::Job::Options }

    assert_raises(ArgumentError) { klass.sidekiq_options(track: 'yes') }
    assert_same true, klass.sidekiq_options(track: true)['track']
  end

  def test_a_string_keyed_track_is_validated_too
    klass = Class.new { include Wurk::Worker }

    assert_raises(ArgumentError) { klass.sidekiq_options('track' => 'yes') }
  end

  # The other door: a payload pushed straight at the client, never through a
  # class-level option.
  def test_a_non_boolean_track_is_rejected_at_push
    error = assert_raises(ArgumentError) { client.push(job(track: 'yes')) }

    assert_match(/'track' must be true or false/, error.message)
  end

  def test_a_boolean_track_survives_normalization_onto_the_wire
    payload = client.normalize_item(job(track: true))

    assert_same true, payload['track']
    assert_same true, Wurk.load_json(Wurk.dump_json(payload))['track']
  end

  # --- configuration -------------------------------------------------

  def test_status_ttl_and_retention_ship_as_defaults
    assert_equal Wurk::Keys::STATUS_TTL, Wurk::Configuration::DEFAULTS[:status_ttl]
    assert_nil Wurk::Configuration::DEFAULTS[:status_retention]
  end

  def test_ttl_and_retention_are_read_from_the_configuration
    config = Wurk::Configuration.new

    assert_equal Wurk::Keys::STATUS_TTL, Wurk::Status.default_ttl(config)
    assert_nil Wurk::Status.retention(config)

    config[:status_ttl] = 60
    config[:status_retention] = 0

    assert_equal 60, Wurk::Status.default_ttl(config)
    assert_equal 0, Wurk::Status.retention(config)
  end

  # --- the enqueued row ----------------------------------------------

  def test_a_tracked_push_writes_the_enqueued_row
    jid = client.push(job(track: true))
    row = Wurk::Status.get(jid)

    assert_equal 'enqueued', row.state
    assert_equal @queue, row.queue
    assert_equal 'StatusEnqueueJob', row.job_class
    assert_in_delta Time.now.to_f, row.enqueued_at, 60
    assert_operator ttl(jid), :>, 0
  end

  def test_the_enqueued_row_expires_on_the_configured_ttl
    config = Wurk::Configuration.new
    config[:status_ttl] = 90
    jid = client(config: config).push(job(track: true))

    assert_operator ttl(jid), :<=, 90
    assert_operator ttl(jid), :>, 60
  end

  def test_an_untracked_push_writes_no_row
    assert_nil Wurk::Status.get(client.push(job))
    assert_nil Wurk::Status.get(client.push(job(track: false)))
  end

  def test_a_tracked_class_writes_a_row_through_perform_async
    jid = TrackedJob.set(queue: @queue).perform_async(1)

    assert_equal 'enqueued', Wurk::Status.get(jid).state
  end

  def test_a_bulk_push_writes_one_row_per_tracked_job
    jids = client.push_bulk('class' => 'StatusEnqueueJob', 'queue' => @queue,
                            'track' => true, 'args' => [[1], [2], [3]])

    assert_equal 3, jids.size
    jids.each { |jid| assert_equal 'enqueued', Wurk::Status.get(jid).state }
  end

  def test_a_tracked_batched_push_writes_the_row_from_the_batch_pipeline
    jid = client.push(job(track: true, 'bid' => "senq-#{SecureRandom.hex(4)}"))

    assert_equal 'enqueued', Wurk::Status.get(jid).state
  end

  # A scheduled job sits in the ZSET for minutes or days — past the row's TTL —
  # so an `enqueued` row would expire before it ran, and the state machine has
  # no `scheduled` state to tell the truth with. Its first row is the `running`
  # one the server middleware writes.
  def test_a_scheduled_tracked_push_writes_no_row
    jid = client.push(job(track: true, 'at' => Time.now.to_f + 3600))

    assert_nil Wurk::Status.get(jid)
  end

  # --- zero cost when untracked --------------------------------------

  def test_an_untracked_push_costs_exactly_two_commands
    spy = PipelineCountingSpy.new(Wurk.redis_pool)
    client(spy).push(job)

    assert_equal 2, spy.count, 'a plain push is SADD + LPUSH and must stay so'
    assert_equal 1, spy.trips
  end

  def test_an_untracked_bulk_push_costs_exactly_two_commands
    spy = PipelineCountingSpy.new(Wurk.redis_pool)
    client(spy).push_bulk('class' => 'StatusEnqueueJob', 'queue' => @queue, 'args' => [[1], [2], [3]])

    assert_equal 2, spy.count
    assert_equal 1, spy.pipelines
  end

  # The point of folding the row onto the open pipeline: tracking costs commands,
  # never a round trip.
  def test_a_tracked_push_adds_two_commands_and_no_round_trip
    spy = PipelineCountingSpy.new(Wurk.redis_pool)
    client(spy).push(job(track: true))

    assert_equal 4, spy.count, 'SADD + LPUSH + HSET + EXPIRE'
    assert_equal 1, spy.pipelines, 'the row must ride the queue write, not open a pipeline of its own'
    assert_equal 1, spy.trips
  end

  def test_a_tracked_bulk_push_stays_one_round_trip
    spy = PipelineCountingSpy.new(Wurk.redis_pool)
    client(spy).push_bulk('class' => 'StatusEnqueueJob', 'queue' => @queue,
                          'track' => true, 'args' => [[1], [2], [3]])

    assert_equal 8, spy.count, 'SADD + LPUSH + two commands per tracked job'
    assert_equal 1, spy.trips
  end

  def test_an_untracked_batched_push_costs_exactly_one_command
    spy = PipelineCountingSpy.new(Wurk.redis_pool)
    client(spy).push(job('bid' => "senq-#{SecureRandom.hex(4)}"))

    assert_equal 1, spy.count, 'the batch Lua and nothing else'
    assert_equal 1, spy.pipelines
  end

  def test_a_tracked_batched_push_rides_the_same_pipeline
    spy = PipelineCountingSpy.new(Wurk.redis_pool)
    client(spy).push(job(track: true, 'bid' => "senq-#{SecureRandom.hex(4)}"))

    assert_equal 3, spy.count, 'the batch Lua + HSET + EXPIRE'
    assert_equal 1, spy.trips
  end

  def test_a_scheduled_push_is_unchanged_by_tracking
    spy = PipelineCountingSpy.new(Wurk.redis_pool)
    client(spy).push(job(track: true, 'at' => Time.now.to_f + 3600))

    assert_equal 1, spy.count, 'a scheduled push is one ZADD, tracked or not'
  end

  # --- retention -----------------------------------------------------

  def with_retention(seconds)
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      previous = Wurk.configuration[:status_retention]
      Wurk.configuration[:status_retention] = seconds
      yield
    ensure
      Wurk.configuration[:status_retention] = previous
    end
  end

  def run_tracked_job(jid, &)
    chain = Wurk::Middleware::Chain.new(Wurk.configuration.default_capsule) do |c|
      c.add(Wurk::Middleware::Status)
    end
    job = { 'class' => 'StatusEnqueueJob', 'args' => [], 'jid' => jid, 'queue' => @queue, 'track' => true }
    block = block_given? ? proc(&) : proc { :ok }
    chain.invoke(Object.new, job, @queue, &block)
  end

  def test_a_complete_row_keeps_the_standard_ttl_when_retention_is_off
    jid = SecureRandom.hex(12)
    with_retention(nil) { run_tracked_job(jid) }

    assert_equal 'complete', Wurk::Status.get(jid).state
    assert_operator ttl(jid), :>, Wurk::Keys::STATUS_TTL - 60
  end

  # Retention 0 is Sidekiq's own behavior, asked for on purpose: a job that
  # succeeds leaves nothing behind.
  def test_retention_zero_deletes_the_row_on_success
    jid = SecureRandom.hex(12)
    with_retention(0) { run_tracked_job(jid) }

    assert_nil Wurk::Status.get(jid)
  end

  def test_retention_keeps_a_succeeded_job_past_the_standard_ttl
    jid = SecureRandom.hex(12)
    with_retention(7 * 24 * 60 * 60) { run_tracked_job(jid) }

    assert_equal 'complete', Wurk::Status.get(jid).state
    assert_operator ttl(jid), :>, Wurk::Keys::STATUS_TTL
  end

  # Retention is about the job Sidekiq loses — the one that succeeded. A failure
  # is still findable in the retry and dead sets, so its row is untouched by it.
  def test_retention_zero_leaves_a_failed_row_alone
    jid = SecureRandom.hex(12)

    with_retention(0) do
      assert_raises(RuntimeError) { run_tracked_job(jid) { raise 'boom' } }
    end

    assert_equal 'failed', Wurk::Status.get(jid).state
  end
end
