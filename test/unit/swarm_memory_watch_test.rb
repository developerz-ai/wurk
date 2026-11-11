# frozen_string_literal: true

require_relative '../test_helper'
require 'fileutils'
require 'tmpdir'

# MAXMEM recycling against a fake /proc: which children are recycled, how
# often the watch reads, and the fresh-child guard that stops a limit below a
# booted child's size from fork-looping the slot.
class SwarmMemoryWatchTest < Wurk::Test::UnitCase
  LIMIT_KB = 100_000
  OLD = Wurk::Swarm::MemoryWatch::FRESH + 1

  def setup
    super
    @root = Dir.mktmpdir('wurk-proc')
    @log = StringIO.new
    @recycled = []
    @clock = 1_000.0
  end

  def teardown
    FileUtils.remove_entry(@root)
    super
  end

  def test_an_old_child_over_the_limit_is_recycled
    statm(11, size_kb: LIMIT_KB + 4)
    watch.tick({ 11 => [OLD, 0] })

    assert_equal [11], @recycled
    assert_match(/child 11 \(slot 0\) RSS #{LIMIT_KB + 4}KB >= #{LIMIT_KB}KB #{OLD.round}s after boot; recycling/,
                 @log.string)
  end

  def test_a_child_under_the_limit_is_left_alone
    statm(11, size_kb: LIMIT_KB - 4)
    watch.tick({ 11 => [OLD, 0] })

    assert_empty @recycled
    assert_empty @log.string
  end

  def test_reads_at_most_once_per_interval
    statm(11, size_kb: LIMIT_KB + 4)
    subject = watch(interval: 10)
    subject.tick({ 11 => [OLD, 0] })
    @clock += 9
    subject.tick({ 11 => [OLD, 0] })

    assert_equal [11], @recycled

    @clock += 1
    subject.tick({ 11 => [OLD, 0] })

    assert_equal [11, 11], @recycled
  end

  # The fork loop: a limit below what a booted child needs. Recycling the
  # fresh child forks another as large, so the watch recycles none, ever, and
  # says so once per slot.
  def test_a_fresh_child_over_the_limit_is_never_recycled_and_reported_once_per_slot
    statm(21, size_kb: LIMIT_KB + 4)
    statm(22, size_kb: LIMIT_KB + 4)
    subject = watch(interval: 0)
    subject.tick({ 21 => [1.0, 0] })
    subject.tick({ 21 => [OLD, 0] })
    subject.tick({ 22 => [1.0, 0] })

    assert_empty @recycled
    assert_equal 1, @log.string.scan('already over memory_limit_mb').size
    assert_match(/child 21 \(slot 0\) is #{LIMIT_KB + 4}KB RSS 1s after boot/, @log.string)

    statm(31, size_kb: LIMIT_KB + 4)
    subject.tick({ 31 => [1.0, 1] })

    assert_equal 2, @log.string.scan('already over memory_limit_mb').size
  end

  # A recycle's replacement over the limit within its own fresh window is the
  # one spared, so the slot recycles once and stops instead of looping.
  def test_a_recycled_slot_whose_replacement_is_already_over_stops_recycling
    statm(41, size_kb: LIMIT_KB + 4)
    statm(42, size_kb: LIMIT_KB + 4)
    subject = watch(interval: 0)
    subject.tick({ 41 => [OLD, 0] })
    subject.forget(41)
    10.times { |i| subject.tick({ 42 => [1.0 + i, 0] }) }
    subject.tick({ 42 => [OLD + 100, 0] })

    assert_equal [41], @recycled
  end

  def test_forget_lets_a_reused_pid_be_judged_afresh
    statm(51, size_kb: LIMIT_KB + 4)
    subject = watch(interval: 0)
    subject.tick({ 51 => [1.0, 0] })
    subject.forget(51)
    subject.tick({ 51 => [OLD, 0] })

    assert_equal [51], @recycled
  end

  # statm counts pages; on a 16KB-page arm64 kernel a hard-coded 4KB read RSS
  # at a quarter of its size and the memory limit never recycled anything (K26).
  def test_rss_scales_statm_pages_by_the_kernel_page_size
    write(61, 'statm', "900 50 10 1 0 40 0\n")
    with_page_size(16_384) { watch(limit_kb: 800).tick({ 61 => [OLD, 0] }) }

    assert_equal [61], @recycled
  end

  def test_pss_reads_smaps_rollup
    smaps(71, pss: LIMIT_KB + 4, private_clean: 10, private_dirty: 10)
    watch(metric: :pss).tick({ 71 => [OLD, 0] })

    assert_equal [71], @recycled
    assert_match(/PSS #{LIMIT_KB + 4}KB/, @log.string)
  end

  def test_uss_sums_the_private_pages
    smaps(81, pss: LIMIT_KB * 3, private_clean: LIMIT_KB / 2, private_dirty: LIMIT_KB / 2)
    watch(metric: :uss).tick({ 81 => [OLD, 0] })

    assert_equal [81], @recycled

    smaps(82, pss: LIMIT_KB * 3, private_clean: 10, private_dirty: 10)
    watch(metric: :uss).tick({ 82 => [OLD, 0] })

    assert_equal [81], @recycled
  end

  def test_an_unreadable_child_is_skipped
    watch.tick({ 91 => [OLD, 0] })

    assert_empty @recycled
  end

  def test_warns_at_boot_when_this_host_cannot_read_the_metric
    watch.warn_if_unreadable

    assert_match(%r{memory_limit_mb is set but this host has no /proc statm to read rss from}, @log.string)

    @log.truncate(0)
    statm(::Process.pid, size_kb: 1)
    watch.warn_if_unreadable

    assert_empty @log.string
  end

  # The real /proc, on Linux: the default reader sees this process.
  def test_reads_the_real_proc_by_default
    skip 'no /proc' unless File.exist?("/proc/#{::Process.pid}/smaps_rollup")

    log = StringIO.new
    %i[rss pss uss].each do |metric|
      Wurk::Swarm::MemoryWatch.new(limit_kb: 1, metric: metric, logger: Logger.new(log), recycle: ->(_) {})
                              .warn_if_unreadable
    end

    assert_empty log.string
  end

  private

  def watch(limit_kb: LIMIT_KB, metric: :rss, interval: Wurk::Swarm::MemoryWatch::CHECK_INTERVAL)
    Wurk::Swarm::MemoryWatch.new(limit_kb: limit_kb, metric: metric, logger: Logger.new(@log),
                                 recycle: ->(pid) { @recycled << pid }, interval: interval,
                                 proc_root: @root, now: -> { @clock })
  end

  def statm(pid, size_kb:)
    pages = size_kb * 1024 / Wurk::Heartbeat::PAGE_SIZE
    write(pid, 'statm', "#{pages * 2} #{pages} 10 1 0 40 0\n")
  end

  def smaps(pid, pss:, private_clean:, private_dirty:)
    write(pid, 'smaps_rollup', <<~SMAPS)
      55d0c0000000-7ffd00000000 ---p 00000000 00:00 0                          [rollup]
      Rss:              #{pss * 2} kB
      Pss:              #{pss} kB
      Pss_Anon:         #{pss / 2} kB
      Shared_Clean:     1000 kB
      Private_Clean:    #{private_clean} kB
      Private_Dirty:    #{private_dirty} kB
    SMAPS
  end

  def write(pid, name, content)
    FileUtils.mkdir_p(File.join(@root, pid.to_s))
    File.write(File.join(@root, pid.to_s, name), content)
  end

  def with_page_size(bytes)
    original = Wurk::Heartbeat::PAGE_SIZE
    Wurk::Heartbeat.send(:remove_const, :PAGE_SIZE)
    Wurk::Heartbeat.const_set(:PAGE_SIZE, bytes)
    yield
  ensure
    Wurk::Heartbeat.send(:remove_const, :PAGE_SIZE)
    Wurk::Heartbeat.const_set(:PAGE_SIZE, original)
  end
end
