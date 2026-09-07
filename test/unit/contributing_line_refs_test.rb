# frozen_string_literal: true

require 'minitest/autorun'

# CONTRIBUTING.md cites `bin/check` by line number — in the exit-code table
# ("| `75` | No Redis ... | `bin/check:92-96` |") and in the env-knob list
# ("`SKIP_PARITY=1` ... (`bin/check:153`)"). Line numbers in prose rot the
# moment a stage is added: #512 alone moved five of them, and the reference
# a reviewer flagged as stale was itself stale by the time it was read.
#
# So gate the claim rather than re-checking it by hand. Reads files only;
# touches no Redis and no shared state.
class ContributingLineRefsTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  CONTRIBUTING = File.join(ROOT, 'CONTRIBUTING.md')
  CHECK = File.join(ROOT, 'bin', 'check')

  # `bin/check:92` or `bin/check:92-96`, always inside backticks in the doc.
  REF = %r{`bin/check:(\d+)(?:-(\d+))?`}

  def setup
    @doc_lines = File.readlines(CONTRIBUTING)
    @check_lines = File.readlines(CHECK)
  end

  # The lines bin/check actually has at a cited range, 1-based and inclusive.
  def cited_source(first, last)
    @check_lines[(first - 1)...last] || []
  end

  def refs_on(line)
    line.scan(REF).map { |first, last| [first.to_i, (last || first).to_i] }
  end

  def test_every_cited_range_is_inside_bin_check
    out_of_range = []

    @doc_lines.each_with_index do |line, i|
      refs_on(line).each do |first, last|
        next if first.between?(1, last) && last <= @check_lines.length

        out_of_range << "CONTRIBUTING.md:#{i + 1} cites bin/check:#{first}-#{last}"
      end
    end

    assert_empty out_of_range,
                 "bin/check has #{@check_lines.length} lines; these references fall outside it: " \
                 "#{out_of_range.join('; ')}"
  end

  def test_exit_code_rows_cite_lines_that_carry_that_exit
    wrong = []

    @doc_lines.each_with_index do |line, i|
      # Table rows look like: | `75` | reason | `bin/check:92-96` |
      code = line[/\A\|\s*`(\d+)`\s*\|/, 1]
      next unless code

      refs_on(line).each do |first, last|
        source = cited_source(first, last).join
        next if source.include?("exit #{code}")

        wrong << "CONTRIBUTING.md:#{i + 1} says exit #{code} at bin/check:#{first}-#{last}"
      end
    end

    assert_empty wrong,
                 'each exit-code row must cite lines that actually carry that exit: ' \
                 "#{wrong.join('; ')}"
  end

  def test_env_knob_bullets_cite_lines_that_mention_the_knob
    wrong = []

    @doc_lines.each_with_index do |line, i|
      # Bullets look like: - `SKIP_PARITY=1` — drop ... (`bin/check:153`).
      knob = line[/\A-\s*`(SKIP_[A-Z]+)=1`/, 1]
      next unless knob

      refs_on(line).each do |first, last|
        source = cited_source(first, last).join
        next if source.include?(knob)

        wrong << "CONTRIBUTING.md:#{i + 1} documents #{knob} at bin/check:#{first}-#{last}"
      end
    end

    assert_empty wrong,
                 'each env-knob bullet must cite lines that actually mention the knob: ' \
                 "#{wrong.join('; ')}"
  end
end
