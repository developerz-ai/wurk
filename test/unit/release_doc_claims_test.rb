# frozen_string_literal: true

require 'minitest/autorun'

# Gates the alignment between .github/workflows/release.yml's `release` job
# publish tail (the `- name:` steps that follow `build & verify gem`) and
# the step table in RELEASE.md, and the alignment between the brief's
# `RELEASE.md:<a>-<b>` anchor and the gem-less-marker block. RELEASE.md is
# the landing page a maintainer reaches for about a step before any other,
# and the table has drifted before (one row merged three `- name:` values
# into a single sentence); without this gate, the step table and the brief
# anchor can silently fall out of sync with the workflow. Reads files;
# touches no Redis or shared state.
class ReleaseDocClaimsTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  RELEASE_MD = File.join(ROOT, 'RELEASE.md')
  RELEASE_YML = File.join(ROOT, '.github', 'workflows', 'release.yml')
  BRIEF = File.join(ROOT, '.dz', 'briefs', 'release-due.md')

  # The publish tail is derived from release.yml by structural position —
  # inside the `release:` job, every `- name:` step AFTER `build & verify
  # gem`. Counting them is not hardcoded: if a future step is added at the
  # tail end, this test picks it up automatically.
  def test_release_table_steps_match_release_yml_publish_tail_in_order
    workflow_tail = publish_tail_step_names
    md_steps = table_step_names

    refute_empty workflow_tail,
                 "release.yml's `release` job has no `- name:` steps after `build & verify gem`; " \
                 'the publish tail should have at least one step'

    matches = md_steps.each_cons(workflow_tail.length).any? do |window|
      window == workflow_tail
    end

    assert matches,
           'RELEASE.md\'s step table must list release.yml\'s publish-tail `- name:` values ' \
           'as consecutive rows in workflow order; ' \
           "workflow=#{workflow_tail.inspect}, table=#{md_steps.inspect}"
  end

  # Catches drift between the brief's `RELEASE.md:<a>-<b>` cite and the
  # gem-less-marker block the cite is supposed to point at. Without this
  # assertion, an edit to RELEASE.md that retitles a section (or inserts
  # a paragraph above the bash fence) can move the cited range away from
  # the bash fence and the `gem-less release` sentence it grounds.
  def test_brief_anchor_landing_covers_gem_less_marker_block
    cite = brief_release_md_anchor

    refute_nil cite,
               '.dz/briefs/release-due.md must cite a single `RELEASE.md:<a>-<b>` range'

    lines = File.readlines(RELEASE_MD)
    if cite[:last] > lines.length
      raise "RELEASE.md cite #{cite[:first]}-#{cite[:last]} past EOF (file has #{lines.length} lines)"
    end

    cited = lines[(cite[:first] - 1)..(cite[:last] - 1)].join

    assert_includes cited, '```bash',
                    "RELEASE.md:#{cite[:first]}-#{cite[:last]} must include the bash fence " \
                    '(the brief cites this range to point at the gem-less-marker block)'
    assert_includes cited, 'gem-less release',
                    "RELEASE.md:#{cite[:first]}-#{cite[:last]} must include the " \
                    "'gem-less release' marker sentence"
  end

  # Each `- name:` step inside the `release` job whose entry comes AFTER
  # the `build & verify gem` step, in workflow order. Bounded by the next
  # 2-space-indent job (the `demo` job that follows) — the comment block
  # above `demo:` sits at the same indent and is excluded.
  def publish_tail_step_names
    workflow = File.readlines(RELEASE_YML)
    release_idx = workflow.index { |l| l.match?(/\A  release:\s*(?:#.*)?\z/) }
    raise 'release.yml: no `release:` job found' unless release_idx

    job_end_offset = workflow[(release_idx + 1)..].index do |l|
      l.match?(/\A  [a-zA-Z_]/) && !l.lstrip.start_with?('#')
    end
    job_end = job_end_offset ? (release_idx + 1 + job_end_offset) : workflow.length

    block = workflow[(release_idx + 1)...job_end]
    build_offset = block.index { |l| l.include?('build & verify gem') }
    raise 'release.yml: no `build & verify gem` step inside the `release` job' unless build_offset

    block[(build_offset + 1)..]
      .grep(/\A\s+- name:\s+/)
      .map { |l| l.sub(/\A\s+- name:\s+/, '').chomp }
  end

  # The second cell of every row in RELEASE.md's `# | Job / step | Detail`
  # table, with surrounding `**…**` and any wrapping backticks stripped.
  # The bold-cell style is inconsistent across rows (some use `**name**`,
  # others `**`name`**), so the comparison normalises to the bare name.
  # The table ends at the first blank line after the header separator.
  def table_step_names
    text = File.readlines(RELEASE_MD)
    header_idx = text.index { |l| l.include?('| # | Job / step | Detail |') }
    raise 'RELEASE.md: no step table header found' unless header_idx

    text.drop(header_idx + 2).take_while { |l| !l.strip.empty? }.map do |line|
      cells = line.split('|', -1).map(&:strip).reject(&:empty?)
      next nil if cells.length < 2

      cells[1].sub(/\A\*\*(.*?)\*\*\z/, '\1').delete('`').strip
    end.compact
  end

  BRIEF_RANGE = /RELEASE\.md:(\d+)-(\d+)/

  def brief_release_md_anchor
    match = BRIEF_RANGE.match(File.read(BRIEF))
    return nil unless match

    { first: match[1].to_i, last: match[2].to_i }
  end
end
