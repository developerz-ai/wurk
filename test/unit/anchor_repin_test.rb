# frozen_string_literal: true

require_relative '../test_helper'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../support/anchor_repin'

class AnchorRepinTest < Wurk::Test::UnitCase
  BIN = File.expand_path('../../bin/repin-anchors', __dir__)
  ROOT = File.expand_path('../..', __dir__)
  LEDGER = 'docs/idea/parity-divergences.md'
  RECORDS = 'test/conformance/ledger_anchors/a.yml'
  CASES = 'test/conformance/cases.yml'

  def setup
    super
    @root = Dir.mktmpdir
    write('lib/code.rb', "one\ntarget line\nthree\nfour\n")
    write(RECORDS, <<~YAML)
      - entry: "An entry"
        anchor: "lib/code.rb#L2"
        fragment: |-
          target line
    YAML
    write(LEDGER, <<~MD)
      # Ledger

      ## An entry

      **Wurk:** it behaves (`lib/code.rb:2`), a quoted promise.

      **Anchor:** [code](../../lib/code.rb#L2).
    MD
    write(CASES, <<~YAML)
      - id: a.case
        source: docs/idea/parity-divergences.md#L3-L5
        promise: >-
          a quoted promise.
    YAML
  end

  def teardown
    FileUtils.remove_entry(@root)
    super
  end

  def write(relative, text)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def read(relative) = File.read(File.join(@root, relative))

  def repin(*)
    out, status = Open3.capture2e({ 'REPIN_ROOT' => @root, 'RUBYOPT' => nil }, RbConfig.ruby, BIN, *)
    [out, status.exitstatus]
  end

  def test_nothing_moved_is_clean
    out, status = repin('--check')

    assert_equal 0, status, out
    assert_includes out, '0 records, 0 ledger references, 0 case sources; 0 unresolved'
  end

  def test_moved_code_updates_the_record_and_both_ledger_styles
    write('lib/code.rb', "new\nnew\none\ntarget line\nthree\nfour\n")

    out, status = repin

    assert_equal 0, status, out
    assert_includes read(RECORDS), 'anchor: "lib/code.rb#L4"'
    assert_includes read(LEDGER), '`lib/code.rb:4`'
    assert_includes read(LEDGER), '(../../lib/code.rb#L4)'
    assert_equal 0, repin('--check')[1]
  end

  def test_check_reports_without_writing_and_exits_one
    write('lib/code.rb', "new\none\ntarget line\nthree\nfour\n")
    before = read(RECORDS)

    out, status = repin('--check')

    assert_equal 1, status
    assert_includes out, 'record  lib/code.rb#L2 -> lib/code.rb#L3'
    assert_equal before, read(RECORDS)
  end

  def test_a_moved_ledger_moves_the_case_source_with_its_heading
    write(LEDGER, "# Ledger\n\nAdded.\n\n#{read(LEDGER).delete_prefix("# Ledger\n\n")}")

    out, status = repin

    assert_equal 0, status, out
    assert_includes read(CASES), 'source: docs/idea/parity-divergences.md#L5-L7'
  end

  def test_a_fragment_that_is_gone_is_unresolved_and_left_alone
    write('lib/code.rb', "one\nsomething else\n")

    out, status = repin

    assert_equal 1, status
    assert_includes out, 'UNRESOLVED lib/code.rb#L2: fragment not found, in "An entry"'
    assert_includes read(RECORDS), 'anchor: "lib/code.rb#L2"'
  end

  def test_a_promise_that_is_gone_is_unresolved
    write(LEDGER, read(LEDGER).sub('a quoted promise.', 'something else.'))

    out, status = repin

    assert_equal 1, status
    assert_includes out, 'promise of a.case not found'
  end

  def test_a_range_stays_off_a_mid_paragraph_start
    write(CASES, <<~YAML)
      - id: a.case
        source: docs/idea/parity-divergences.md#L5-L6
        promise: >-
          a quoted promise.
    YAML
    write(LEDGER, read(LEDGER).sub('a quoted promise.', "a quoted promise.\nmore"))
    write(LEDGER, read(LEDGER).sub('## An entry', "## An entry\n\nLead in"))

    out, status = repin

    assert_equal 1, status, out
  end

  def test_a_reference_already_stale_takes_the_closest_record
    write(LEDGER, read(LEDGER).sub('`lib/code.rb:2`', '`lib/code.rb:9`'))

    assert_equal 0, repin[1]
    assert_includes read(LEDGER), '`lib/code.rb:2`'
  end

  def test_prose_naming_unpinned_lines_is_left_alone
    write(LEDGER, read(LEDGER).sub('`lib/code.rb:2`', '`lib/code.rb:2,3,7-9`'))

    out, status = repin('--check')

    assert_equal 0, status, out
    assert_includes out, '0 ledger references'
  end

  def test_this_repository_is_in_sync
    out, status = Open3.capture2e({ 'RUBYOPT' => nil }, RbConfig.ruby, BIN, '--check', chdir: ROOT)

    assert_equal 0, status.exitstatus, out
  end

  def test_rejects_unknown_arguments
    assert_equal 1, repin('--bogus')[1]
  end
end
