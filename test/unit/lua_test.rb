# frozen_string_literal: true

require_relative '../test_helper'

class LuaTest < Wurk::Test::UnitCase
  parallelize_me!


  def setup
    super
    @pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, timeout: 2, name: 'lua-test')
    @ns   = "luatest:#{Process.pid}:#{object_id}"
    @pool.with { |c| Wurk::Lua::Loader.script_load_all(c) }
  end

  def teardown
    @pool.with do |c|
      cursor = '0'
      loop do
        cursor, keys = c.call('SCAN', cursor, 'MATCH', "#{@ns}:*", 'COUNT', 500)
        c.call('DEL', *keys) unless keys.empty?
        break if cursor == '0'
      end
    end
    @pool.disconnect!
  ensure
    super
  end

  # --- registry shape ------------------------------------------------

  def test_scripts_registry_holds_expected_keys
    assert_equal(
      %i[zpopbyscore bulk_push reliable_schedule_promote reliable_requeue
         batch_push batch_ack_success batch_ack_failed batch_ack_complete batch_invalidate
         batch_append_callback
         fast_delete_job fast_delete_by_class release_if_owner
         limiter_concurrent_acquire limiter_concurrent_release
         limiter_bucket_acquire limiter_window_acquire limiter_leaky_acquire
         limiter_points_acquire limiter_points_refund].sort,
      Wurk::Lua::SCRIPTS.keys.sort
    )
  end

  def test_scripts_registry_is_frozen
    assert_predicate Wurk::Lua::SCRIPTS, :frozen?, 'SCRIPTS must be frozen to prevent mutation'
  end

  def test_every_script_source_is_a_non_empty_string
    Wurk::Lua::SCRIPTS.each do |name, src|
      assert_kind_of String, src, "#{name} source must be a String"
      refute_empty src, "#{name} source must not be empty"
    end
  end

  def test_shas_match_sha1_of_each_source
    Wurk::Lua::SCRIPTS.each do |name, src|
      expected = Digest::SHA1.hexdigest(src)

      assert_equal expected, Wurk::Lua::SHAS[name],
                   "#{name} SHA must equal SHA1(source)"
    end
  end

  def test_shas_is_frozen
    assert_predicate Wurk::Lua::SHAS, :frozen?, 'SHAS must be frozen'
  end

  # --- zpopbyscore: verbatim from sidekiq-free.md §1.8 ---------------
  #
  # Wire-compat sanity check. Any whitespace edit changes the SHA and
  # forces all production processes to re-upload on first call. The exact
  # bytes below come from docs/target/sidekiq-free.md §1.8.

  def test_zpopbyscore_matches_spec_verbatim
    expected = <<~LUA
      local key, now = KEYS[1], ARGV[1]
      local jobs = redis.call("zrange", key, "-inf", now, "byscore", "limit", 0, 1)
      if jobs[1] then
        redis.call("zrem", key, jobs[1])
        return jobs[1]
      end
    LUA

    assert_equal expected, Wurk::Lua::ZPOPBYSCORE
  end

  # --- execution against real Redis ---------------------------------

  def test_zpopbyscore_pops_oldest_due_job
    set_key = "#{@ns}:retry"
    @pool.with do |c|
      c.call('ZADD', set_key, 100, 'jobA', 200, 'jobB', 300, 'jobC')
      result = Wurk::Lua::Loader.eval_cached(c, :zpopbyscore, keys: [set_key], argv: [250])

      assert_equal 'jobA', result
      assert_equal 2, c.call('ZCARD', set_key)
    end
  end

  def test_zpopbyscore_returns_nil_when_no_jobs_due
    set_key = "#{@ns}:retry"
    @pool.with do |c|
      c.call('ZADD', set_key, 1000, 'jobFuture')
      result = Wurk::Lua::Loader.eval_cached(c, :zpopbyscore, keys: [set_key], argv: [500])

      assert_nil result
      assert_equal 1, c.call('ZCARD', set_key)
    end
  end

  def test_bulk_push_lpushes_all_jobs_and_registers_queue
    qname = "#{@ns}:q"
    list  = "queue:#{qname}"
    qset  = "#{@ns}:queues"
    @pool.with do |c|
      count = Wurk::Lua::Loader.eval_cached(
        c, :bulk_push, keys: [list, qset], argv: [qname, '{"jid":"1"}', '{"jid":"2"}', '{"jid":"3"}']
      )

      assert_equal 3, count
      assert_equal 3, c.call('LLEN', list)
      assert_equal 1, c.call('SISMEMBER', qset, qname)
      c.call('DEL', list, qset)
    end
  end

  # rubocop:disable Minitest/MultipleAssertions
  def test_reliable_schedule_promote_moves_due_jobs_to_their_queues
    sset = "#{@ns}:schedule"
    qset = "#{@ns}:queues"
    @pool.with do |c|
      c.call('ZADD', sset, 100, '{"queue":"alpha","jid":"a"}', 150, '{"queue":"beta","jid":"b"}',
             900, '{"queue":"alpha","jid":"future"}')
      count = Wurk::Lua::Loader.eval_cached(
        c, :reliable_schedule_promote, keys: [sset, qset], argv: [500, "#{@ns}:queue:"]
      )

      assert_equal 2, count
      assert_equal 1, c.call('LLEN', "#{@ns}:queue:alpha")
      assert_equal 1, c.call('LLEN', "#{@ns}:queue:beta")
      assert_equal 1, c.call('ZCARD', sset)
      assert_equal 2, c.call('SCARD', qset)
      c.call('DEL', "#{@ns}:queue:alpha", "#{@ns}:queue:beta")
    end
  end

  def test_batch_push_increments_counters_jids_and_queue
    bkey  = "#{@ns}:b-x"
    jids  = "#{@ns}:b-x-jids"
    list  = "#{@ns}:queue:default"
    qset  = "#{@ns}:queues"
    @pool.with do |c|
      Wurk::Lua::Loader.eval_cached(
        c, :batch_push,
        keys: [bkey, jids, list, qset, "#{@ns}:b-x-died", "#{@ns}:dead-batches"],
        argv: ['default', 'JID1', '{"jid":"JID1"}', 'x']
      )

      assert_equal '1', c.call('HGET', bkey, 'total')
      assert_equal '1', c.call('HGET', bkey, 'pending')
      assert_equal 1, c.call('SISMEMBER', jids, 'JID1')
      assert_equal 1, c.call('LLEN', list)
      assert_equal 1, c.call('SISMEMBER', qset, 'default')
      c.call('DEL', list)
    end
  end

  # SADD-guard idempotency: re-pushing a jid already in the live set (a retry
  # or scheduled promotion re-enqueueing a job that never left the batch) must
  # re-LPUSH the payload but must NOT recount total/pending — else pending
  # inflates past the acks and :success never fires (spec §2.3/§2.5).
  def test_batch_push_repush_of_live_jid_does_not_recount # rubocop:disable Minitest/MultipleAssertions
    bkey = "#{@ns}:b-rp"
    jids = "#{@ns}:b-rp-jids"
    list = "#{@ns}:queue:default"
    qset = "#{@ns}:queues"
    keys = [bkey, jids, list, qset, "#{@ns}:b-rp-died", "#{@ns}:dead-batches"]
    argv = ['default', 'JID1', '{"jid":"JID1"}', 'rp']
    @pool.with do |c|
      2.times { Wurk::Lua::Loader.eval_cached(c, :batch_push, keys: keys, argv: argv) }

      assert_equal '1', c.call('HGET', bkey, 'total'), 're-push must not recount total'
      assert_equal '1', c.call('HGET', bkey, 'pending'), 're-push must not recount pending'
      assert_equal 1, c.call('SCARD', jids)
      assert_equal 2, c.call('LLEN', list), 're-push must still re-enqueue the payload'
      c.call('DEL', list)
    end
  end

  # The guard must not over-suppress: distinct jids each register once. Guards
  # §2.3 re-entrancy — `batch.jobs { ... }` adding siblings grows total.
  def test_batch_push_counts_each_distinct_jid
    bkey = "#{@ns}:b-dj"
    jids = "#{@ns}:b-dj-jids"
    list = "#{@ns}:queue:default"
    qset = "#{@ns}:queues"
    died = "#{@ns}:b-dj-died"
    dead = "#{@ns}:dead-batches"
    @pool.with do |c|
      %w[A B].each do |jid|
        Wurk::Lua::Loader.eval_cached(
          c, :batch_push, keys: [bkey, jids, list, qset, died, dead],
                          argv: ['default', jid, %({"jid":"#{jid}"}), 'dj']
        )
      end

      assert_equal '2', c.call('HGET', bkey, 'total')
      assert_equal '2', c.call('HGET', bkey, 'pending')
      assert_equal 2, c.call('SCARD', jids)
      c.call('DEL', list)
    end
  end

  # #212: pushing a jid found in the died set is a manual retry of a dead
  # job — it rejoins the live set without recounting (total/pending already
  # include it), and draining the died set clears the death mark so a later
  # full drain can fire :success.
  def test_batch_push_dead_jid_rejoins_live_set_without_recount # rubocop:disable Minitest/MultipleAssertions
    bkey = "#{@ns}:b-dr"
    jids = "#{@ns}:b-dr-jids"
    died = "#{@ns}:b-dr-died"
    dead = "#{@ns}:dead-batches"
    list = "#{@ns}:queue:default"
    @pool.with do |c|
      c.call('HSET', bkey, 'total', 1, 'pending', 1, 'death', 1)
      c.call('SADD', died, 'JID1')
      c.call('ZADD', dead, 1, 'dr')

      Wurk::Lua::Loader.eval_cached(
        c, :batch_push,
        keys: [bkey, jids, list, "#{@ns}:queues", died, dead],
        argv: ['default', 'JID1', '{"jid":"JID1"}', 'dr']
      )

      assert_equal '1', c.call('HGET', bkey, 'total')
      assert_equal '1', c.call('HGET', bkey, 'pending')
      assert_equal 1, c.call('SISMEMBER', jids, 'JID1')
      assert_equal 0, c.call('SCARD', died)
      assert_nil c.call('HGET', bkey, 'death'), 'death suppression must clear when died drains'
      assert_nil c.call('ZSCORE', dead, 'dr'), 'bid must leave dead-batches'
      assert_equal 1, c.call('LLEN', list)
      c.call('DEL', list)
    end
  end

  def test_batch_push_dead_jid_keeps_death_mark_while_other_dead_jids_remain
    bkey = "#{@ns}:b-dp"
    jids = "#{@ns}:b-dp-jids"
    died = "#{@ns}:b-dp-died"
    dead = "#{@ns}:dead-batches"
    list = "#{@ns}:queue:default"
    @pool.with do |c|
      c.call('HSET', bkey, 'total', 2, 'pending', 2, 'death', 1)
      c.call('SADD', died, 'JID1', 'JID2')
      c.call('ZADD', dead, 1, 'dp')

      Wurk::Lua::Loader.eval_cached(
        c, :batch_push,
        keys: [bkey, jids, list, "#{@ns}:queues", died, dead],
        argv: ['default', 'JID1', '{"jid":"JID1"}', 'dp']
      )

      assert_equal %w[JID2], c.call('SMEMBERS', died)
      assert_equal '1', c.call('HGET', bkey, 'death'), 'death mark must persist while a dead jid remains'
      refute_nil c.call('ZSCORE', dead, 'dp'), 'bid must stay in dead-batches'
      c.call('DEL', list)
    end
  end

  def test_batch_ack_success_decrements_pending_only_for_known_jid
    bkey = "#{@ns}:b-y"
    jids = "#{@ns}:b-y-jids"
    failed = "#{@ns}:b-y-failed"
    @pool.with do |c|
      c.call('HSET', bkey, 'total', 2, 'pending', 2)
      c.call('SADD', jids, 'A', 'B')

      pending, live = Wurk::Lua::Loader.eval_cached(c, :batch_ack_success, keys: [bkey, jids, failed], argv: ['A'])

      assert_equal 1, pending
      assert_equal 1, live
      assert_equal '1', c.call('HGET', bkey, 'pending')

      pending, live = Wurk::Lua::Loader.eval_cached(c, :batch_ack_success, keys: [bkey, jids, failed], argv: ['ZZZ'])

      assert_equal(-1, pending)
      assert_equal(-1, live)
      assert_equal '1', c.call('HGET', bkey, 'pending')
    end
  end

  # A retry that finally succeeds clears the jid from the failed set and
  # decrements failures (currently-failing count converges).
  def test_batch_ack_success_clears_prior_failure
    bkey = "#{@ns}:b-yf"
    jids = "#{@ns}:b-yf-jids"
    failed = "#{@ns}:b-yf-failed"
    @pool.with do |c|
      c.call('HSET', bkey, 'total', 1, 'pending', 1, 'failures', 1)
      c.call('SADD', jids, 'A')
      c.call('SADD', failed, 'A')

      Wurk::Lua::Loader.eval_cached(c, :batch_ack_success, keys: [bkey, jids, failed], argv: ['A'])

      assert_equal '0', c.call('HGET', bkey, 'failures')
      assert_equal 0, c.call('SISMEMBER', failed, 'A')
    end
  end

  # Transient failure: records the jid and bumps failures only on first add.
  def test_batch_ack_failed_records_currently_failing_idempotently
    bkey = "#{@ns}:b-fail"
    failed = "#{@ns}:b-fail-failed"
    @pool.with do |c|
      c.call('HSET', bkey, 'total', 1, 'pending', 1, 'failures', 0)

      Wurk::Lua::Loader.eval_cached(c, :batch_ack_failed, keys: [bkey, failed], argv: ['A'])
      Wurk::Lua::Loader.eval_cached(c, :batch_ack_failed, keys: [bkey, failed], argv: ['A'])

      assert_equal '1', c.call('HGET', bkey, 'failures')
      assert_equal 1, c.call('SISMEMBER', failed, 'A')
    end
  end

  def test_batch_ack_complete_records_death_and_signals_first # rubocop:disable Metrics/AbcSize
    bkey   = "#{@ns}:b-d"
    jids   = "#{@ns}:b-d-jids"
    died   = "#{@ns}:b-d-died"
    failed = "#{@ns}:b-d-failed"
    @pool.with do |c|
      c.call('HSET', bkey, 'total', 2, 'pending', 2, 'failures', 0)
      c.call('SADD', jids, 'A', 'B')

      live, died_n, first = Wurk::Lua::Loader.eval_cached(
        c, :batch_ack_complete, keys: [bkey, jids, died, failed], argv: ['A']
      )

      assert_equal 1, live
      assert_equal 1, died_n
      assert_equal 1, first
      # A job that dies without a prior transient failure leaves `failures`
      # untouched and lands in `died` only — not `failed` (spec §2.8).
      assert_equal '0', c.call('HGET', bkey, 'failures')
      assert_equal 1, c.call('SISMEMBER', died, 'A')
      assert_equal 0, c.call('SISMEMBER', failed, 'A')

      _live, _died_n, second_first = Wurk::Lua::Loader.eval_cached(
        c, :batch_ack_complete, keys: [bkey, jids, died, failed], argv: ['B']
      )

      assert_equal 0, second_first
    end
  end
  # rubocop:enable Minitest/MultipleAssertions

  # A job that was failing (in the failed set) then dies moves out of
  # currently-failing: failures decrements and the jid leaves the failed set.
  def test_batch_ack_complete_clears_prior_failure_on_death
    bkey   = "#{@ns}:b-df"
    jids   = "#{@ns}:b-df-jids"
    died   = "#{@ns}:b-df-died"
    failed = "#{@ns}:b-df-failed"
    @pool.with do |c|
      c.call('HSET', bkey, 'total', 1, 'pending', 1, 'failures', 1)
      c.call('SADD', jids, 'A')
      c.call('SADD', failed, 'A')

      Wurk::Lua::Loader.eval_cached(c, :batch_ack_complete, keys: [bkey, jids, died, failed], argv: ['A'])

      assert_equal '0', c.call('HGET', bkey, 'failures')
      assert_equal 0, c.call('SISMEMBER', failed, 'A')
      assert_equal 1, c.call('SISMEMBER', died, 'A')
    end
  end

  def test_batch_invalidate_clears_jids_and_flags_hash
    bkey = "#{@ns}:b-z"
    jids = "#{@ns}:b-z-jids"
    @pool.with do |c|
      c.call('HSET', bkey, 'total', 3, 'pending', 3)
      c.call('SADD', jids, 'A', 'B', 'C')

      Wurk::Lua::Loader.eval_cached(c, :batch_invalidate, keys: [bkey, jids], argv: [])

      assert_equal 0, c.call('EXISTS', jids)
      assert_equal '1', c.call('HGET', bkey, 'invalidated')
    end
  end
end
