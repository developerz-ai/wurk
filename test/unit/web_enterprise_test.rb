# frozen_string_literal: true

require_relative '../test_helper'

class WebEnterpriseTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns = "wurkent:#{Process.pid}:#{object_id}"
    @limiter = "lmt-#{@ns}"
    @lid = ::Digest::SHA1.hexdigest(@ns)[0, 16]
    @class_name = "EntPeriodicJob@#{@ns}"
  end

  def teardown
    Wurk.redis do |c|
      c.call('SREM', Wurk::Limiter::LIST_KEY, @limiter)
      %W[lmtr:#{@limiter} lmtr-cs:#{@limiter} lmtr-b:#{@limiter}
         lmtr-w:#{@limiter} lmtr-l:#{@limiter} lmtr-p:#{@limiter}
         lmtr-stats:#{@limiter}].each { |k| c.call('DEL', k) }
      c.call('SREM', Wurk::Cron::PERIODIC_KEY, @lid)
      c.call('DEL', "#{Wurk::Cron::LOOP_PREFIX}#{@lid}", "#{Wurk::Cron::HISTORY_PREFIX}#{@lid}")
      # drain anything the enqueue_now test pushed
      c.call('DEL', "queue:#{@ns}-q")
      c.call('SREM', 'queues', "#{@ns}-q")
    end
  ensure
    super
  end

  # --- Limits -----------------------------------------------------------

  def test_limits_list_returns_registered_names
    seed_limiter
    names = Wurk::Web::Enterprise::Limits.list

    assert_includes names, @limiter
  end

  def test_limits_list_filters_by_substring
    seed_limiter
    needle = @ns.split(':').last
    names = Wurk::Web::Enterprise::Limits.list(filter: needle)

    assert_includes names, @limiter
  end

  def test_limits_list_substring_miss_excludes_unrelated
    seed_limiter
    names = Wurk::Web::Enterprise::Limits.list(filter: 'totally-unrelated-xyz')

    refute_includes names, @limiter
  end

  def test_limits_metadata_returns_hash
    seed_limiter
    meta = Wurk::Web::Enterprise::Limits.metadata(@limiter)

    assert_equal 'concurrent', meta['type']
  end

  def test_limits_reset_clears_state_keys_but_keeps_metadata
    seed_limiter
    Wurk.redis do |c|
      c.call('ZADD', "lmtr-cs:#{@limiter}", '999', 'slot1')
      c.call('HSET', "lmtr-stats:#{@limiter}", 'held', '5')
    end

    Wurk::Web::Enterprise::Limits.reset(@limiter)

    assert_equal(
      { state: 0, stats: 0, meta: 1, list: 1 },
      reset_aftermath_state
    )
  end

  # --- Periodic ---------------------------------------------------------

  def test_periodic_list_returns_loop_set
    seed_loop
    lids = Wurk::Web::Enterprise::Periodic.list.map(&:lid)

    assert_includes lids, @lid
  end

  def test_periodic_fetch_unknown_returns_nil
    assert_nil Wurk::Web::Enterprise::Periodic.fetch('no-such-lid')
  end

  def test_periodic_pause_sets_paused_flag
    seed_loop

    assert Wurk::Web::Enterprise::Periodic.pause(@lid)
    assert_predicate Wurk::Web::Enterprise::Periodic.fetch(@lid), :paused?
  end

  def test_periodic_unpause_clears_paused_flag
    seed_loop(paused: '1')

    assert Wurk::Web::Enterprise::Periodic.unpause(@lid)
    refute_predicate Wurk::Web::Enterprise::Periodic.fetch(@lid), :paused?
  end

  def test_periodic_pause_unknown_returns_false
    refute Wurk::Web::Enterprise::Periodic.pause('no-such-lid')
  end

  def test_periodic_enqueue_now_pushes_job
    seed_loop(queue: "#{@ns}-q")

    jid = Wurk::Web::Enterprise::Periodic.enqueue_now(@lid)

    refute_nil jid
    payload = Wurk.redis { |c| c.call('LRANGE', "queue:#{@ns}-q", 0, -1) }.first

    refute_nil payload
    assert_equal @class_name, Wurk.load_json(payload)['class']
  end

  def test_periodic_enqueue_now_unknown_returns_nil
    assert_nil Wurk::Web::Enterprise::Periodic.enqueue_now('no-such-lid')
  end

  def test_periodic_history_unknown_returns_empty
    assert_equal [], Wurk::Web::Enterprise::Periodic.history('no-such-lid')
  end

  def test_periodic_history_returns_recorded_entries
    seed_loop
    entry = Wurk.dump_json([Time.now.to_i, 'abc123'])
    Wurk.redis { |c| c.call('LPUSH', "#{Wurk::Cron::HISTORY_PREFIX}#{@lid}", entry) }

    history = Wurk::Web::Enterprise::Periodic.history(@lid)

    assert_equal 1, history.size
    assert_equal 'abc123', history[0][1]
  end

  # --- Historical -------------------------------------------------------

  def test_historical_top_returns_array
    rows = Wurk::Web::Enterprise::Historical.top(minutes: 5)

    assert_kind_of Array, rows
  end

  def test_historical_for_job_requires_klass
    assert_raises(ArgumentError) do
      Wurk::Web::Enterprise::Historical.for_job(nil, minutes: 5)
    end
  end

  def test_historical_for_job_returns_series
    rows = Wurk::Web::Enterprise::Historical.for_job(@class_name, minutes: 3)

    assert_equal 3, rows.size
    rows.each { |r| assert(%i[at p f ms].all? { |k| r.key?(k) }) }
  end

  private

  def reset_aftermath_state
    Wurk.redis do |c|
      {
        state: c.call('EXISTS', "lmtr-cs:#{@limiter}").to_i,
        stats: c.call('EXISTS', "lmtr-stats:#{@limiter}").to_i,
        meta: c.call('EXISTS', "lmtr:#{@limiter}").to_i,
        list: c.call('SISMEMBER', Wurk::Limiter::LIST_KEY, @limiter).to_i
      }
    end
  end

  def seed_limiter
    Wurk.redis do |c|
      c.call('SADD', Wurk::Limiter::LIST_KEY, @limiter)
      c.call('HSET', "lmtr:#{@limiter}", 'type', 'concurrent', 'fingerprint', 'fp', 'options', '{"limit":5}')
    end
  end

  def seed_loop(paused: '0', queue: 'default')
    Wurk.redis do |c|
      c.call('SADD', Wurk::Cron::PERIODIC_KEY, @lid)
      c.call(
        'HSET', "#{Wurk::Cron::LOOP_PREFIX}#{@lid}",
        'schedule', '* * * * *',
        'klass', @class_name,
        'options', JSON.dump('queue' => queue, 'args' => [1]),
        'tz', '',
        'paused', paused
      )
    end
  end
end
