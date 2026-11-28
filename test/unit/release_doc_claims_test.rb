# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'

# Gates the alignment between .github/workflows/release.yml's publish tail (the
# `name:` steps of the `publish` and `release` jobs, in order) and
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

  # The publish tail is derived from release.yml: every named step of `publish`
  # then `release`. Nothing is hardcoded, so a step added to either job must also
  # gain its row.
  def test_release_table_steps_match_release_yml_publish_tail_in_order
    workflow_tail = publish_tail_step_names
    md_steps = table_step_names

    refute_empty workflow_tail,
                 "release.yml's `publish` and `release` jobs have no named steps"

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

  def publish_tail_step_names
    jobs = YAML.load_file(RELEASE_YML).fetch('jobs')
    %w[publish release].flat_map { |job| jobs.fetch(job).fetch('steps').filter_map { |step| step['name'] } }
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

  # Pins the availability probe RELEASE.md presents: the canonical RubyGems API v2
  # per-version endpoint that release.yml's preflight and release-smoke.yml already
  # run, as THE availability check, with interpretable results.
  def test_availability_probe_is_canonical
    endpoint = 'rubygems.org/api/v2/rubygems/wurk/versions/'

    release_text = File.read(RELEASE_MD)

    assert_includes release_text, endpoint,
                    'RELEASE.md must name the canonical RubyGems API v2 per-version endpoint'

    section = verifying_section(release_text)

    refute_nil section,
               "RELEASE.md must keep its 'Verifying a release actually shipped' section"
    assert_includes section, 'ONE availability probe',
                    'the section must present the v2 probe as THE availability check, ' \
                    'not one of several competing predicates'
    assert_includes section, 'HTTP 200',
                    'the section must give the probe an interpretable HTTP 200 result'
    assert_includes section, 'HTTP 404',
                    'the section must give the probe an interpretable HTTP 404 result'
    assert_match(/probe failed|PROBE failed/, section,
                 'the section must state a failed probe is not evidence the version is absent')
  end

  # The RELEASE.md block between the 'Verifying a release actually shipped'
  # heading and the next heading of any level.
  def verifying_section(text)
    lines = text.lines
    first = lines.index { |l| l.start_with?('### Verifying a release actually shipped') }
    return nil unless first

    last = ((first + 1)...lines.size).find { |i| lines[i].start_with?('#') } || lines.size
    lines[first...last].join
  end

  BRIEF_RANGE = /RELEASE\.md:(\d+)-(\d+)/

  def brief_release_md_anchor
    match = BRIEF_RANGE.match(File.read(BRIEF))
    return nil unless match

    { first: match[1].to_i, last: match[2].to_i }
  end
end
