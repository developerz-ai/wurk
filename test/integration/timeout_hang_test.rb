# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Top-level for the same fork/Marshal reason as SwarmBootSentinelWorker /
# GracefulShutdownSentinelWorker: Object.const_get(name) has to resolve the
# same way inside the forked child, which inherits the constant table but no
# Minitest lexical scope. Genuinely sleeps — nothing here cooperates with the
# cut, so only Wurk::Watchdog raising into the thread stops it early.
class TimeoutHangWorker
  include Wurk::Job

  sidekiq_options timeout: 0.3, retry: 1

  def perform(redis_url, started_key, done_key, sleep_seconds)
    client = RedisClient.config(url: redis_url).new_client
    client.call('SET', started_key, ::Process.pid.to_s)
    client.call('EXPIRE', started_key, 60)
    sleep sleep_seconds
    client.call('SET', done_key, '1')
    client.call('EXPIRE', done_key, 60)
  ensure
    client&.close
  end
end

class DeadlineHangWorker
  include Wurk::Job

  sidekiq_options deadline: 0.5, retry: 3

  def perform(redis_url, started_key, done_key, sleep_seconds)
    client = RedisClient.config(url: redis_url).new_client
    client.call('SET', started_key, ::Process.pid.to_s)
    client.call('EXPIRE', started_key, 60)
    sleep sleep_seconds
    client.call('SET', done_key, '1')
    client.call('EXPIRE', done_key, 60)
  ensure
    client&.close
  end
end

# A bound long enough that Watchdog's 0.5s production scan interval never
# gets near it within this test's window — proves shutdown's own drain budget
# is what cuts the job, not the declared timeout:.
class LongTimeoutWorker
  include Wurk::Job

  sidekiq_options timeout: 30, retry: 1

  def perform(redis_url, started_key, done_key, sleep_seconds)
    client = RedisClient.config(url: redis_url).new_client
    client.call('SET', started_key, ::Process.pid.to_s)
    client.call('EXPIRE', started_key, 60)
    sleep sleep_seconds
    client.call('SET', done_key, '1')
    client.call('EXPIRE', done_key, 60)
  ensure
    client&.close
  end
end

# 08-timeout-deadline.md done-when: "wurk_options timeout: 30, deadline:
# 5.minutes bounds a hanging job." The unit suite (timeout_middleware_test.rb,
# deadline_test.rb, watchdog_test.rb) pins the middleware/Watchdog contract
# against a hand-built chain and a fast test-only scan interval; this is the
# one test proving the whole stack — a real fork, a real Redis round trip, a
# job that genuinely never yields — actually cuts a job that would otherwise
# sleep for HANG_SLEEP_SECONDS, in well under that, at production's own
# Watchdog::SCAN_INTERVAL (no test-only speedup here).
#
# Also covers the shutdown_timeout interaction lib/wurk/middleware/timeout.rb
# documents (swarm.rb's shutdown/hard_shutdown path, cli.rb's `config[:timeout]`
# → Swarm#shutdown_timeout wiring): the shorter of the two bounds wins. A
# `timeout:` under the drain budget fires first (first test below); one far
# longer than it never gets the chance, and shutdown's own hard_shutdown wins
# instead (last test below).
class TimeoutHangTest < Wurk::Test::UnitCase
  parallelize_me!

  POLL_TIMEOUT = 20.0
  POLL_INTERVAL = 0.1
  HANG_SLEEP_SECONDS = 5
  FAST_DRAIN_TIMEOUT = 2

  def setup
    super
    @ns = "tohang-#{::Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @started_key = "#{@ns}-started"
    @done_key = "#{@ns}-done"
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
    @expired_before = @observer.call('GET', 'stat:expired').to_i
  end

  def teardown
    @observer&.call('UNLINK', @started_key, @done_key, public_queue_key)
    @observer&.call('SREM', 'queues', @queue_name)
    remove_retry_entries
    @observer&.close
  ensure
    super
  end

  def test_a_genuinely_sleeping_job_is_cut_at_its_timeout_bound_and_booked_for_retry
    jid = push(TimeoutHangWorker)

    run_swarm(shutdown_timeout: 10) do
      assert wait_for_key(@started_key), 'job never started within the poll window'
      start = monotonic_now

      entry = wait_for_retry_entry(jid)

      assert entry, "job never landed on the retry set — the bound never fired (#{elapsed(start)}s elapsed)"
      assert_operator elapsed(start), :<, HANG_SLEEP_SECONDS,
                      'the job must be cut well before its own sleep would have returned on its own'
      assert_equal 'Wurk::Job::TimedOut', entry['error_class']
      assert_match(/timed out after 0\.3s/, entry['error_message'])
      refute @observer.call('GET', @done_key), 'a cut attempt must not reach its own completion write'
    end
  end

  # stat:expired is process-local (Processor::EXPIRED) until the next
  # heartbeat or shutdown flushes it — waiting out a real BEAT_PAUSE would
  # make this test as slow as the cadence it's not actually testing, so the
  # swarm is shut down as soon as the abandonment itself is confirmed
  # (private list empty — nothing left in flight), which flushes it deterministically.
  def test_a_genuinely_sleeping_job_past_its_deadline_is_abandoned_and_booked_expired
    jid = push(DeadlineHangWorker)

    run_swarm(shutdown_timeout: 10) do |swarm|
      assert wait_for_key(@started_key), 'job never started within the poll window'
      start = monotonic_now

      assert wait_for { private_list_keys.empty? }, 'the abandoned job never cleared the in-flight private list'
      abandoned_within = elapsed(start)
      swarm.shutdown(timeout: 10)

      assert_operator abandoned_within, :<, HANG_SLEEP_SECONDS,
                      'the job must be abandoned well before its own sleep would have returned on its own'
      assert_operator stat_expired_delta, :>, 0, 'stat:expired must be booked once the shutdown flush runs'
      refute @observer.call('GET', @done_key), 'an abandoned job must not reach its own completion write'
      refute wait_for_retry_entry(jid, timeout: 1), 'a deadline cut is booked expired, never retried'
    end
  end

  # The bound (30s) never gets near firing inside this test; a short
  # shutdown_timeout has to win the race on its own, exactly as
  # lib/wurk/middleware/timeout.rb's class comment claims.
  def test_a_timeout_far_longer_than_the_drain_budget_loses_to_shutdown
    push(LongTimeoutWorker)

    run_swarm(shutdown_timeout: FAST_DRAIN_TIMEOUT) do |swarm|
      assert wait_for_key(@started_key), 'job never started within the poll window'

      swarm.shutdown(timeout: FAST_DRAIN_TIMEOUT)

      refute @observer.call('GET', @done_key), 'job must not have completed'
      assert_equal 1, @observer.call('LLEN', public_queue_key),
                   'hard_shutdown must requeue — the drain budget lost the race, not the 30s bound'
      assert_empty private_list_keys, 'bulk_requeue must leave no residual private-list entries'
    end
  end

  private

  # The actual class, not its name: JobUtil only merges class-level
  # sidekiq_options (the timeout:/deadline: this whole file bounds jobs with)
  # when it can call get_sidekiq_options on what 'class' points at.
  def push(klass)
    Wurk::Client.new.push(
      'class' => klass, 'args' => [Wurk::Test.redis_url, @started_key, @done_key, HANG_SLEEP_SECONDS],
      'queue' => @queue_name
    )
  end

  def run_swarm(shutdown_timeout:)
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config[:timeout] = shutdown_timeout
    seed_default_middleware!(config)
    topology = Wurk::Topology.flat(count: 1, queues: [@queue_name], concurrency: 1)
    swarm = Wurk::Swarm.new(topology: topology, config: config, shutdown_timeout: shutdown_timeout)
    supervisor = nil
    begin
      swarm.boot(install_signals: false)
      supervisor = Thread.new { swarm.supervise }
      yield swarm
    ensure
      begin
        swarm.shutdown(timeout: shutdown_timeout)
      rescue StandardError
        nil
      end
      stop_supervisor_thread(supervisor, shutdown_timeout + 10)
      config.reset_redis_pools!
    end
  end

  # Wurk::Middleware::Timeout/Expiry (and every other built-in) register
  # themselves once, at file-require time, onto the ONE `Wurk.configuration`
  # the gem lazily creates on first access (lib/wurk.rb's trailing
  # `Wurk.configuration.server_middleware.add(...)` calls) — a *later*
  # `Wurk::Configuration.new` starts with an empty chain of its own and never
  # sees them. Every other real-fork integration test in this suite gets away
  # with that because it only exercises swarm/launcher lifecycle, not job
  # middleware; this file specifically needs Timeout and Expiry to be the ones
  # doing the cutting, so the fresh, test-private config this harness needs
  # for queue isolation has to replay the same registrations by hand. None of
  # the built-ins take constructor args, so klass-only entries round-trip.
  def seed_default_middleware!(config)
    Wurk.configuration.client_middleware.entries.each { |e| config.client_middleware.add(e.klass) }
    Wurk.configuration.server_middleware.entries.each { |e| config.server_middleware.add(e.klass) }
  end

  def public_queue_key = "#{Wurk::Keys::QUEUE_PREFIX}#{@queue_name}"

  def private_list_keys
    keys = []
    cursor = '0'
    loop do
      cursor, batch = @observer.call('SCAN', cursor, 'MATCH', "#{public_queue_key}|*", 'COUNT', 100)
      keys.concat(batch)
      break if cursor == '0'
    end
    keys
  end

  def wait_for_key(key)
    wait_for { @observer.call('GET', key) }
  end

  def wait_for_retry_entry(jid, timeout: POLL_TIMEOUT)
    wait_for(timeout: timeout) { find_retry_entry(jid) }
  end

  def find_retry_entry(jid)
    @observer.call('ZRANGE', 'retry', 0, -1)
             .map { |raw| ::JSON.parse(raw) }
             .find { |msg| msg['jid'] == jid }
  end

  def stat_expired_delta
    @observer.call('GET', 'stat:expired').to_i - @expired_before
  end

  def remove_retry_entries
    @observer&.call('ZRANGE', 'retry', 0, -1)&.each do |raw|
      @observer.call('ZREM', 'retry', raw) if ::JSON.parse(raw)['queue'] == @queue_name
    end
  end

  def wait_for(timeout: POLL_TIMEOUT)
    deadline = monotonic_now + timeout
    while monotonic_now < deadline
      value = yield
      return value if value

      sleep POLL_INTERVAL
    end
    false
  end

  def monotonic_now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  def elapsed(start) = monotonic_now - start
end
