# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'
require_relative '../../bench/soak/ledger'

# The soak's verdict is only as good as its bookkeeping: a ledger that calls a
# lost jid balanced, or waves an unexplained duplicate through, proves nothing.
# Each case writes the lines the harness would and checks what the verdict
# makes of them.
class SoakLedgerTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @dir = Dir.mktmpdir('soak-ledger')
    @path = File.join(@dir, 'ledger.tsv')
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  def test_every_push_completed_once_is_balanced
    write %w[push 1.0 10 j1 plain], %w[run 1.1 20 j1 plain], %w[done 1.2 20 j1 plain]

    verdict = judge

    assert verdict[:balanced]
    assert_equal 1, verdict[:completed]
    assert_empty verdict[:lost]
  end

  def test_a_push_that_never_completed_is_lost
    write %w[push 1.0 10 j1 plain], %w[run 1.1 20 j1 plain]

    verdict = judge

    refute verdict[:balanced]
    assert_equal %w[j1], verdict[:lost]
  end

  def test_a_job_in_the_dead_set_is_reported_not_lost
    write %w[push 1.0 10 j1 limited]

    verdict = judge(dead: { 'j1' => 'rate_limited: limit reached' })

    assert verdict[:balanced]
    assert_equal({ 'j1' => 'rate_limited: limit reached' }, verdict[:dead])
  end

  def test_lossy_drops_show_up_as_lost
    write %w[push 1.0 10 j1 plain], %w[drop 1.1 20 j1 plain]

    verdict = judge

    refute verdict[:balanced]
    assert_equal 1, verdict[:lossy_drops]
    assert_equal %w[j1], verdict[:lost]
  end

  def test_a_second_completion_after_its_process_was_killed_is_the_deferred_ack_window
    write %w[push 1.0 10 j1 plain], %w[done 2.0 20 j1 plain], %w[chaos 2.5 10 20 kill9],
          %w[done 4.0 30 j1 plain]

    dups = judge[:duplicates]

    assert_equal 1, dups[:by_window].dig('deferred_ack', :count)
    assert_empty dups[:unattributed]
  end

  def test_a_kill_of_another_process_does_not_explain_a_plain_duplicate
    write %w[push 1.0 10 j1 plain], %w[done 2.0 20 j1 plain], %w[chaos 2.5 10 99 kill9],
          %w[done 4.0 30 j1 plain]

    verdict = judge

    refute verdict[:balanced]
    assert_equal %w[j1], verdict[:duplicates][:unattributed]
  end

  def test_a_duplicate_across_a_redis_outage_is_attributed_to_it
    write %w[push 1.0 10 j1 plain], %w[done 2.0 20 j1 plain], %w[outage_start 3.0 10],
          %w[outage_end 4.0 10], %w[done 40.0 20 j1 plain]

    assert_equal 1, judge[:duplicates][:by_window].dig('redis_outage', :count)
  end

  def test_a_scheduled_duplicate_near_any_kill_is_the_scheduler_lease
    write %w[push 1.0 10 j1 scheduled], %w[chaos 5.0 10 99 kill9], %w[done 20.0 20 j1 scheduled],
          %w[done 50.0 30 j1 scheduled]

    assert_equal 1, judge[:duplicates][:by_window].dig('scheduler_lease', :count)
  end

  def test_a_run_nobody_pushed_is_unledgered_unless_cron_fired_it
    write %w[run 1.0 20 jx plain], %w[done 1.1 20 jx plain], %w[run 1.0 20 jc cron], %w[done 1.1 20 jc cron]

    verdict = judge

    refute verdict[:balanced]
    assert_equal %w[jx], verdict[:unledgered]
    assert_equal({ fired: 1, completed: 1, completed_twice: 0 }, verdict[:cron])
  end

  def test_a_push_that_raised_but_ran_is_accepted_not_unledgered
    write %w[push_err 1.0 10 j1 plain RedisClient::ConnectionError], %w[run 2.0 20 j1 plain],
          %w[done 2.1 20 j1 plain]

    verdict = judge

    assert verdict[:balanced]
    assert_equal({ total: 1, accepted_anyway: 1 }, verdict[:push_errors])
  end

  def test_a_batch_without_its_success_callback_is_missing
    write %w[batch 1.0 10 b1 batch -], %w[batch 1.0 10 b2 batch b1], %w[cb 5.0 20 b2 success b1]

    verdict = judge

    refute verdict[:balanced]
    assert_equal %w[b1], verdict[:batches][:missing]
  end

  def test_a_parent_callback_before_its_child_is_out_of_order
    write %w[batch 1.0 10 b1 batch -], %w[batch 1.0 10 b2 batch b1], %w[cb 4.0 20 b1 success -],
          %w[cb 5.0 20 b2 success b1]

    assert_equal %w[b1], judge[:batches][:out_of_order]
  end

  def test_reruns_count_attempts_beyond_the_first
    write %w[push 1.0 10 j1 retry], %w[run 1.1 20 j1 retry], %w[run 3.0 20 j1 retry], %w[done 3.1 20 j1 retry]

    assert_equal 1, judge[:reruns]
  end

  def test_ingest_keeps_a_partial_line_for_the_next_read
    File.write(@path, "push\t1.0\t10\tj1\tplain\t-\npush\t1.0\t10\tj2")
    book = WurkSoak::Ledger::Book.new(@path).ingest!

    assert_equal %w[j1], book.pushes.keys

    File.write(@path, "\tplain\t-\n", mode: 'a')
    book.ingest!

    assert_equal %w[j1 j2], book.pushes.keys
  end

  def test_record_appends_one_tab_separated_line_per_event
    saved = ENV.fetch('SOAK_LEDGER', nil)
    ENV['SOAK_LEDGER'] = @path
    WurkSoak::Ledger.record('push', 'j1', 'plain')
    WurkSoak::Ledger.record('chaos', 42, 'kill9', 'age=70')
    saved ? ENV['SOAK_LEDGER'] = saved : ENV.delete('SOAK_LEDGER')
    lines = File.readlines(@path, chomp: true).map { |l| l.split("\t") }

    assert_equal([%w[push j1 plain -], %w[chaos 42 kill9 age=70]], lines.map { |l| [l[0], *l[3..]] })
    assert_equal [::Process.pid.to_s], lines.map { |l| l[2] }.uniq
  end

  private

  def write(*rows)
    File.write(@path, rows.map { |r| "#{(r + (['-'] * (6 - r.size))).join("\t")}\n" }.join)
  end

  def judge(dead: {})
    WurkSoak::Ledger::Verdict.new(WurkSoak::Ledger::Book.new(@path).ingest!, dead: dead).to_h
  end
end
