# frozen_string_literal: true

require_relative '../test_helper'

# 07-A3: the Pro fast deletes walk the queue a window per call instead of
# copying it whole into one script. A small window here puts many window
# boundaries inside a short list.
class LuaFastDeleteTest < Wurk::Test::UnitCase
  parallelize_me!

  WINDOW = 7

  def setup
    super
    @key = "queue:fastdel-#{Process.pid}-#{object_id}"
  end

  def teardown
    Wurk.redis { |c| c.call('DEL', @key) }
  ensure
    super
  end

  def test_removes_every_match_across_windows_and_keeps_order
    seed(Array.new(60) { |i| payload((i % 3).zero? ? 'Victim' : 'Keep', i) })

    removed, first = walk('"class":"Victim"')

    assert_equal 20, removed
    assert_equal 0, Wurk.load_json(first)['args'].first, 'the first match from the head'
    assert_equal((0...60).reject { |i| (i % 3).zero? }, args_left)
  end

  def test_a_window_of_nothing_but_matches
    seed(Array.new(WINDOW * 3) { |i| payload('Victim', i) } + [payload('Keep', 99)])

    assert_equal WINDOW * 3, walk('"class":"Victim"').first
    assert_equal [99], args_left
  end

  # A call stops at its match cap mid-window and the next call resumes right
  # after the last entry it rewrote: nothing in the rest of that window is
  # skipped, and no call rewrites more than the cap (review of #916: 1,000
  # LSETs deep in a 1M-entry list held Redis 17ms in one call).
  def test_a_call_stops_at_its_match_cap_and_the_next_resumes_the_window
    seed(Array.new(WINDOW * 4) { |i| payload(i.odd? ? 'Victim' : 'Keep', i) } + [payload('Victim', 999)])
    per_call = []
    loader = Wurk::Lua::Loader.singleton_class
    loader.alias_method(:__real_eval_cached, :eval_cached)
    loader.define_method(:eval_cached) { |*a, **k| __real_eval_cached(*a, **k).tap { |r| per_call << r[1] } }

    removed, = walk('"class":"Victim"', max_removed: 2)

    assert_equal 15, removed
    assert_operator per_call.max, :<=, 2
    assert_equal((0...(WINDOW * 4)).select(&:even?), args_left)
  ensure
    loader.alias_method(:eval_cached, :__real_eval_cached)
    loader.remove_method(:__real_eval_cached)
  end

  def test_an_empty_or_missing_list
    assert_equal [0, nil], walk('"class":"Victim"')
  end

  def test_one_call_reads_at_most_a_window
    seed(Array.new(WINDOW * 5) { |i| payload('Keep', i) })
    calls = 0
    loader = Wurk::Lua::Loader.singleton_class
    loader.alias_method(:__real_eval_cached, :eval_cached)
    loader.define_method(:eval_cached) { |*a, **k| (calls += 1) && __real_eval_cached(*a, **k) }

    walk('"class":"Victim"')

    assert_equal 6, calls, 'five full windows, then the short one that ends the walk'
  ensure
    loader.alias_method(:eval_cached, :__real_eval_cached)
    loader.remove_method(:__real_eval_cached)
  end

  # The overview's risk for this row: windows must stay correct under live
  # traffic. A consumer pops from the tail and a producer pushes at the head
  # while the walk runs; nothing that did not match may be removed, and every
  # match not popped first must be.
  def test_concurrent_tail_pops_and_head_pushes
    initial = Array.new(3000) { |i| payload(i.even? ? 'Victim' : 'Keep', i) }
    seed(initial)
    popped = []
    pushed = []
    stop = false
    consumer = Thread.new { Wurk.redis { |c| popped << c.call('RPOP', @key) until stop } }
    producer = Thread.new do
      Wurk.redis do |c|
        until stop
          pushed << payload('Keep', 10_000 + pushed.size)
          c.call('LPUSH', @key, pushed.last)
        end
      end
    end

    removed, = walk('"class":"Victim"')
    stop = true
    [consumer, producer].each(&:join)
    popped.compact!

    refute_empty popped, 'the consumer ran during the walk'
    refute_empty pushed, 'the producer ran during the walk'
    left = list
    popped_victims = popped.count { |p| p.include?('"class":"Victim"') }

    assert_empty left.select { |p| p.include?('"class":"Victim"') }, 'every match not popped was removed'
    assert_equal 1500, removed + popped_victims
    assert_equal initial.count { |p| p.include?('Keep') } + pushed.size,
                 left.size + popped.count { |p| p.include?('"class":"Keep"') },
                 'no payload that did not match was removed'
  end

  private

  def walk(needle, max_removed: Wurk::Lua::FastDelete::MAX_REMOVED_PER_CALL)
    Wurk.redis { |c| Wurk::Lua::FastDelete.call(c, @key, needle, window: WINDOW, max_removed: max_removed) }
  end

  def seed(payloads)
    Wurk.redis { |c| c.call('RPUSH', @key, *payloads) }
  end

  def list
    Wurk.redis { |c| c.call('LRANGE', @key, 0, -1) }
  end

  def args_left
    list.map { |p| Wurk.load_json(p)['args'].first }
  end

  def payload(klass, index)
    Wurk.dump_json('class' => klass, 'args' => [index], 'jid' => format('%024x', index))
  end
end
