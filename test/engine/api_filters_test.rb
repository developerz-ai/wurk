# frozen_string_literal: true

require_relative '../engine_test_helper'
require_relative '../../bench/algo/support'

# The dashboard's filters and filtered bulk actions (rows 07-A12, 09-W4 and
# 09-W9 of docs/plans/2026/11/10/101-evidence-driven-improvement-sweep/):
# Dead/Retries filtered by error message or args and acted on as a whole,
# bulk `keys[]` resolved in one round trip, batches by tag and the dead-batches
# listing, oldest-first queue pages and `?days=N` history. Round trips are
# counted by AlgoBench::Tally on a web pool built for the test.
class ApiFiltersTest < Wurk::Test::EngineCase
  def setup
    super
    header 'Sec-Fetch-Site', 'same-origin'
    @pool = ::Wurk::RedisPool.new(size: 2, url: ::Wurk::Test.redis_url, middlewares: [AlgoBench::Tally])
    @pool.with { |c| ::Wurk::Test.flush!(c) }
  end

  def teardown
    @pool.with { |c| ::Wurk::Test.flush!(c) }
    @pool.disconnect!
  ensure
    super
  end

  # --- 07-A12: bulk keys[] ------------------------------------------------------

  # 100 keys were 100 serial ZRANGEBYSCOREs before the first delete; now they
  # ride one pipeline, and the deletes are what is left.
  def test_bulk_action_resolves_every_key_in_one_round_trip
    keys = seed_set('retry', 100)
    _, cost = tallied(:post, '/wurk/api/retries', cmd: 'delete', keys: keys)

    assert_equal 100, json[:count]
    assert_equal 100, cost.by_command['zrangebyscore']
    assert_equal 101, cost.round_trips, cost.inspect
    assert_equal 0, ::Wurk::RetrySet.new.size
  end

  def test_bulk_action_skips_keys_that_match_nothing
    keys = seed_set('dead', 2)
    post '/wurk/api/dead', cmd: 'delete', keys: [*keys, '1.0|gone', 'no-pipe', '5|']

    assert_equal 2, json[:count]
  end

  # --- 09-W4: filter by error message or args ------------------------------------

  def test_dead_listing_filters_by_error_message_and_by_args
    seed_set('dead', 6) do |i|
      { 'error_message' => i.even? ? "Timeout talking to db#{i}" : 'boom', 'args' => [i, "user-#{i}@x.io"] }
    end

    get '/wurk/api/dead?substr=timeout'

    assert_equal [4, 2, 0], arg_column(:entries)
    assert_equal 3, json[:filtered_total]
    assert json[:filtered_total_exact]

    get "/wurk/api/dead?substr=#{CGI.escape('user-3@x')}"

    assert_equal [3], arg_column(:entries)
  end

  def test_retries_listing_filters_by_error_class
    seed_set('retry', 3) { |i| { 'error_class' => i == 1 ? 'Net::ReadTimeout' : 'RuntimeError' } }

    get '/wurk/api/retries?substr=net::read'

    assert_equal [1], arg_column(:entries)
  end

  # A no-match filter over a set bigger than the scan budget stops at the
  # budget, in ~25 round trips rather than one per 50 rows.
  def test_filter_on_a_set_past_the_budget_stops_at_the_budget
    seed_set('dead', ::Wurk::Api::Pagination::FILTER_SCAN_LIMIT + 5_000)
    _, cost = tallied(:get, '/wurk/api/dead?substr=nowhere-to-be-found')

    assert_empty json[:entries]
    refute json[:filtered_total_exact]
    assert_operator cost.round_trips, :<=, 25, cost.inspect
  end

  def test_all_retry_with_substr_retries_only_the_matches
    seed_set('dead', 5) { |i| { 'error_message' => i < 2 ? 'Timeout' : 'boom' } }
    post '/wurk/api/dead/all/retry?substr=timeout'

    assert_equal({ ok: true, count: 2, matched: 2, done: true, cursor: 3 }, json)
    assert_equal 3, ::Wurk::DeadSet.new.size
    assert_equal 2, ::Wurk::Queue.new('filters-q').size
  end

  def test_all_delete_with_substr_leaves_the_rest
    seed_set('retry', 4) { |i| { 'args' => [i, i.odd? ? 'acct-9' : 'acct-1'] } }
    post '/wurk/api/retries/all/delete?substr=acct-9'

    assert_equal 2, json[:count]
    assert_equal([0, 2], ::Wurk::RetrySet.new.map { |e| e.args.first }.sort)
  end

  def test_all_add_to_queue_with_substr_and_an_unknown_cmd
    seed_set('schedule', 3) { |i| { 'args' => [i, i.zero? ? 'now' : 'later'] } }
    post '/wurk/api/scheduled/all/add_to_queue?substr=now'

    assert_equal 1, json[:count]
    assert_equal 2, ::Wurk::ScheduledSet.new.size

    post '/wurk/api/scheduled/all/explode?substr=now'

    assert_equal 400, last_response.status
  end

  # Past SWEEP_LIMIT matches a request stops, answers done: false and a
  # cursor; sending it back carries on until done.
  def test_filtered_sweep_resumes_from_its_cursor
    limit = ::Wurk::Api::Pagination::SWEEP_LIMIT
    seed_set('dead', (2 * limit) + 10) { |i| { 'error_message' => i.even? ? 'keep' : 'drop' } }
    post '/wurk/api/dead/all/delete?substr=drop'
    first = json

    assert_equal [limit, false], [first[:count], first[:done]]
    post "/wurk/api/dead/all/delete?substr=drop&cursor=#{first[:cursor]}"

    assert_equal [5, true], [json[:count], json[:done]]
    assert_equal(['keep'], ::Wurk::DeadSet.new.map { |e| e['error_message'] }.uniq)
    assert_equal limit + 5, ::Wurk::DeadSet.new.size
  end

  # --- 09-W9: batches, queue direction, days --------------------------------------

  def test_batches_filter_by_tag_newest_first
    seed_batch('b1', 1, tags: %w[red])
    seed_batch('b2', 2, tags: %w[red blue])
    seed_batch('b3', 3, tags: %w[blue])
    ::Wurk.redis { |c| c.call('SADD', 'tags:red', 'expired-bid') }

    get '/wurk/api/batches?tag=red'

    assert_equal 2, json[:total]
    assert_equal(%w[b2 b1], json[:batches].map { |row| row[:bid] })

    get '/wurk/api/batches?tag=red&page=1&count=1'

    assert_equal(%w[b1], json[:batches].map { |row| row[:bid] })

    get '/wurk/api/batches?tag=none'

    assert_equal [0, []], [json[:total], json[:batches]]
  end

  def test_dead_batches_listing_and_tag_within_it
    seed_batch('b1', 1, tags: %w[red])
    seed_batch('b2', 2, tags: %w[red])
    seed_batch('b3', 3)
    ::Wurk.redis do |c|
      c.call('ZADD', 'dead-batches', 10, 'b1')
      c.call('ZADD', 'dead-batches', 11, 'b3')
    end

    get '/wurk/api/batches?dead=1'

    assert_equal(%w[b3 b1], json[:batches].map { |row| row[:bid] })

    get '/wurk/api/batches?dead=true&tag=red'

    assert_equal(%w[b1], json[:batches].map { |row| row[:bid] })
  end

  def test_queue_direction_asc_lists_oldest_first
    ::Wurk.redis do |c|
      c.call('SADD', 'queues', 'dir')
      7.times { |i| c.call('LPUSH', 'queue:dir', ::JSON.generate(job(i, 'dir'))) }
    end

    get '/wurk/api/queues/dir?count=3&direction=asc'

    assert_equal [0, 1, 2], arg_column(:jobs)
    get '/wurk/api/queues/dir?count=3&page=2&direction=asc'

    assert_equal [6], arg_column(:jobs)
    get '/wurk/api/queues/dir?count=3&page=5&direction=asc'

    assert_empty json[:jobs]
    get '/wurk/api/queues/dir?count=3'

    assert_equal [6, 5, 4], arg_column(:jobs)
    get '/wurk/api/queues/dir?count=2&direction=asc&substr=CostJob&page=1'

    assert_equal [2, 3], arg_column(:jobs)
  end

  def test_history_days_sets_the_window
    get '/wurk/api/history/1h?days=3'

    assert_equal 3 * 86_400, json[:window]
    get '/wurk/api/history/1h?days=999&window=2h'

    assert_equal 180 * 86_400, json[:window]
    get '/wurk/api/history/1h?days=x&window=2h'

    assert_equal 7200, json[:window]
    get '/wurk/api/queue-history/1h?days=2'

    assert_equal 2 * 86_400, json[:window]
  end

  private

  def json = ::JSON.parse(last_response.body, symbolize_names: true)

  def arg_column(key) = json[key].map { |row| row[:args].first }

  def job(index, queue)
    { 'class' => 'CostJob', 'args' => [index], 'queue' => queue, 'jid' => format('%024x', index + 1),
      'created_at' => 1_700_000_000.0, 'enqueued_at' => 1_700_000_000.0 + index, 'retry' => true }
  end

  # `count` entries of `key`, entry i at score 1.7e9 + i, the block adding to
  # each payload. Returns their "<score>|<jid>" keys.
  def seed_set(key, count)
    entries = Array.new(count) do |i|
      payload = job(i, 'filters-q').merge('error_class' => 'RuntimeError', 'error_message' => 'boom')
      payload.merge!(yield(i)) if block_given?
      [1_700_000_000.0 + i, payload]
    end
    ::Wurk.redis do |c|
      entries.each_slice(1_000) do |slice|
        c.call('ZADD', key, *slice.flat_map { |score, payload| [score, ::JSON.generate(payload)] })
      end
    end
    entries.map { |score, payload| "#{score}|#{payload['jid']}" }
  end

  def seed_batch(bid, score, tags: [])
    ::Wurk.redis do |c|
      c.call('ZADD', 'batches', score, bid)
      c.call('HSET', "b-#{bid}", 'total', '1', 'pending', '1', 'created_at', '1700000000.0',
             'tags', ::JSON.generate(tags))
      tags.each { |tag| c.call('SADD', "tags:#{tag}", bid) }
    end
  end

  # [body, AlgoBench::Count] of a request served from the tallied web pool.
  def tallied(verb, path, params = {})
    @pool.with { |c| c.call('PING') }
    cost = AlgoBench.count do
      with_tallied_web_pool { public_send(verb, path, params) }
    end
    [last_response.body, cost]
  end

  def with_tallied_web_pool
    pool = @pool
    config = ::Wurk.configuration
    config.define_singleton_method(:web_redis_pool) { pool }
    yield
  ensure
    config.singleton_class.remove_method(:web_redis_pool)
  end
end
