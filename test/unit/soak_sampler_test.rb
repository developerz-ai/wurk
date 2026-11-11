# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../bench/soak/sampler'

# The memory and key-count numbers bench/rss_soak.rb and bench/soak/run.rb
# publish all come through these readers, so their parsing is pinned here.
class SoakSamplerTest < Wurk::Test::UnitCase
  parallelize_me!

  ROLLUP = <<~SMAPS
    600d8e5fb000-7ffe3f647000 ---p 00000000 00:00 0                          [rollup]
    Rss:                8000 kB
    Pss:                4900 kB
    Pss_Dirty:          1536 kB
    Shared_Clean:       3400 kB
    Shared_Dirty:        600 kB
    Private_Clean:      2464 kB
    Private_Dirty:      1536 kB
  SMAPS

  def test_parses_smaps_rollup_and_derives_the_shared_ratio
    row = WurkSoak::Sampler.parse_smaps_rollup(ROLLUP)

    assert_equal 8000, row[:rss]
    assert_equal 4900, row[:pss]
    assert_equal 1536, row[:private_dirty]
    assert_equal 4000, row[:shared]
    assert_in_delta 0.5, row[:shared_ratio]
  end

  def test_a_rollup_without_rss_reads_as_nil
    assert_nil WurkSoak::Sampler.parse_smaps_rollup('')
  end

  def test_parse_stat_counts_fields_from_the_last_paren
    stat = "4242 (ruby (worker) 1) S 4200 4242 4200 0 -1 4194560 #{(['0'] * 12).join(' ')} 987654 rest"

    assert_equal [4242, 4200, 987_654], WurkSoak::Sampler.parse_stat(stat)
  end

  def test_slope_is_least_squares_and_nil_when_undefined
    assert_in_delta 2.0, WurkSoak::Sampler.slope([[0, 1], [1, 3], [2, 5]])
    assert_nil WurkSoak::Sampler.slope([[0, 1]])
    assert_nil WurkSoak::Sampler.slope([[1, 1], [1, 2]])
  end

  def test_key_family_is_the_prefix_before_the_first_separator
    assert_equal 'queue', WurkSoak::Sampler.key_family('queue:soak')
    assert_equal 'b', WurkSoak::Sampler.key_family('b-abc123-jids')
    assert_equal 'processes', WurkSoak::Sampler.key_family('processes')
  end

  def test_reads_a_live_child_and_finds_it_under_its_parent
    skip 'Linux /proc only' unless File.exist?("/proc/#{::Process.pid}/smaps_rollup")

    read_a_live_child
  end

  def test_a_gone_process_reads_as_nil
    pid = ::Process.spawn(RbConfig.ruby, '-e', 'exit')
    ::Process.wait(pid)

    assert_nil WurkSoak::Sampler.memory(pid)
    assert_nil WurkSoak::Sampler.age(pid)
  end

  private

  def read_a_live_child
    reader, writer = IO.pipe
    pid = ::Process.spawn(RbConfig.ruby, '-e', '$stdin.read', in: reader)
    reader.close

    assert_includes WurkSoak::Sampler.children(::Process.pid), pid
    assert_operator WurkSoak::Sampler.memory(pid)[:rss], :>, 0
    assert_operator WurkSoak::Sampler.age(pid), :>=, 0
  ensure
    writer&.close
    ::Process.wait(pid) if pid
  end
end
