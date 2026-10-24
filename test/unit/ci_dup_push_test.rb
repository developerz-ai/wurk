# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# bin/ci-dup-push lets a push to main skip a workflow's gated jobs when the
# pushed tree already passed that workflow on the merged PR's head. Two
# properties are pinned here:
#
#   1. The header declares every command the script runs — `git`, `gh`, `jq`
#      — plus `GH_TOKEN`. `jq` reads the PR JSON, so a header naming only
#      `gh` documents a dependency the runner may not have.
#   2. A missing prerequisite fails OPEN: stdout is exactly `false`, the exit
#      status is 0, and stderr carries `ci-dup-push: <reason> — full run`. A
#      wrong `true` would skip the only gate a direct push to main ever gets.
#
# The script runs against stub `git`, `gh` and `jq` executables in a tmpdir
# whose PATH holds that directory and nothing else: no Redis, no network, and
# none of the host's own git/gh/jq. The stubs use bash builtins only, so a
# one-directory PATH is enough to run them.
class CiDupPushTest < Minitest::Test
  parallelize_me!

  SCRIPT = File.expand_path('../../bin/ci-dup-push', __dir__)
  BASH = %w[/bin/bash /usr/bin/bash /usr/local/bin/bash].find { |path| File.executable?(path) } || '/bin/bash'

  HEAD_SHA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  HEAD_TREE = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  PR_HEAD_SHA = 'cccccccccccccccccccccccccccccccccccccccc'
  PARENT_SHA = 'dddddddddddddddddddddddddddddddddddddddd'
  MERGE_SHA = HEAD_SHA
  PR_TREE = HEAD_TREE
  RUN_ID = '42'
  PR_NUMBER = '7'
  SUBJECT = 'Squash merge of #7 (#7)'

  STUB_GIT = <<~'SHELL'
    #!/bin/bash
    case "${1:-}" in
      rev-parse)
        case "${2:-}" in
          HEAD) printf '%s\n' "$WURK_TEST_HEAD_SHA" ;;
          'HEAD^{tree}') printf '%s\n' "$WURK_TEST_HEAD_TREE" ;;
        esac
        ;;
      log) printf '%s\n' "$WURK_TEST_SUBJECT" ;;
    esac
  SHELL

  STUB_GH = <<~'SHELL'
    #!/bin/bash
    endpoint=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --jq) shift 2; continue ;;
        api) shift; continue ;;
        *) endpoint="$1"; shift; continue ;;
      esac
    done
    case "$endpoint" in
      */pulls/"$WURK_TEST_PR")
        printf '{"merge_commit_sha":"%s","head":{"sha":"%s"}}\n' \
          "$WURK_TEST_MERGE_SHA" "$WURK_TEST_PR_HEAD_SHA"
        ;;
      */commits/"$WURK_TEST_PR_HEAD_SHA") printf '%s\n' "$WURK_TEST_PR_TREE" ;;
      */commits/"$WURK_TEST_HEAD_SHA") printf '%s\n' "$WURK_TEST_PARENT_SHA" ;;
      *"actions/runs?head_sha=$WURK_TEST_PR_HEAD_SHA&"*) printf '%s\n' "$WURK_TEST_RUN_ID" ;;
      *"actions/runs?head_sha=$WURK_TEST_PARENT_SHA&"*) printf '%s\n' 1 ;;
      *) printf 'stub gh: unexpected endpoint: %s\n' "$endpoint" >&2; exit 1 ;;
    esac
  SHELL

  STUB_JQ = <<~'SHELL'
    #!/bin/bash
    if [ "${1:-}" = "-r" ]; then shift; fi
    filter="${1:-}"
    json=""
    while IFS= read -r line || [ -n "$line" ]; do
      json="$json$line"
    done
    case "$filter" in
      *merge_commit_sha*)
        pattern='"merge_commit_sha":"([^"]*)"'
        if [[ "$json" =~ $pattern ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; else exit 1; fi
        ;;
      *head.sha*)
        pattern='"head":.*"sha":"([^"]*)"'
        if [[ "$json" =~ $pattern ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; else exit 1; fi
        ;;
      *)
        printf 'stub jq: unexpected filter: %s\n' "$filter" >&2
        exit 1
        ;;
    esac
  SHELL

  def test_the_header_declares_every_command_the_script_runs
    header = header_comment

    assert_match(whole_word('git'), header, 'the header must name `git`, which the script runs')
    assert_match(whole_word('gh'), header, 'the header must name `gh`, which the script runs')
    assert_match(whole_word('jq'), header, 'the header must name `jq`, which the script runs')
    assert_match(/GH_TOKEN/, header, 'the header must name the GH_TOKEN environment variable')
  end

  def test_a_missing_jq_fails_open
    Dir.mktmpdir('wurk-ci-dup-push-') do |dir|
      stub_git(dir)
      stub_gh(dir)

      out, err, status = run_script(dir)

      assert_full_run(out, err, status)
      assert_includes err, 'jq'
    end
  end

  def test_a_missing_gh_fails_open
    Dir.mktmpdir('wurk-ci-dup-push-') do |dir|
      stub_git(dir)
      stub_jq(dir)

      out, err, status = run_script(dir)

      assert_full_run(out, err, status)
      assert_includes err, 'gh'
    end
  end

  def test_the_duplicate_push_happy_path_still_prints_true
    Dir.mktmpdir('wurk-ci-dup-push-') do |dir|
      stub_git(dir)
      stub_gh(dir)
      stub_jq(dir)

      out, err, status = run_script(dir)

      assert_equal 0, status.exitstatus, err
      assert_equal "true\n", out
      assert_match(/— skipping/, err)
    end
  end

  # The dup is a claim about THIS tree: a PR head whose tree moved on must
  # still fall open to a full run.
  def test_the_happy_path_still_requires_the_pr_head_tree
    Dir.mktmpdir('wurk-ci-dup-push-') do |dir|
      stub_git(dir)
      stub_gh(dir)
      stub_jq(dir)

      out, err, status = run_script(dir, 'WURK_TEST_PR_TREE' => 'e' * 40)

      assert_full_run(out, err, status)
      assert_includes err, 'tree moved'
    end
  end

  private

  # The script's leading comment block: where a reader looks for what it needs.
  def header_comment
    File.readlines(SCRIPT).take_while { |line| line.start_with?('#') }.join
  end

  # A command name as a whole word: `GitHub` (the runner host) must not
  # satisfy the `git` requirement, and `GH_TOKEN` must not satisfy `gh`.
  def whole_word(word)
    /(?<![\w-])#{word}(?![\w-])/
  end

  def stub_git(dir)
    write_stub(dir, 'git', STUB_GIT)
  end

  def stub_gh(dir)
    write_stub(dir, 'gh', STUB_GH)
  end

  def stub_jq(dir)
    write_stub(dir, 'jq', STUB_JQ)
  end

  def write_stub(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  def run_script(dir, overrides = {})
    Open3.capture3(script_env(dir).merge(overrides), BASH, SCRIPT)
  end

  # PATH holds the stub directory only, so the host's own git/gh/jq can never
  # answer for a tool the test means to be missing.
  def script_env(dir)
    {
      'PATH' => dir,
      'GITHUB_EVENT_NAME' => 'push',
      'GITHUB_REPOSITORY' => 'wurk/wurk',
      'GH_TOKEN' => 'stub-token',
      'WURK_TEST_HEAD_SHA' => HEAD_SHA,
      'WURK_TEST_HEAD_TREE' => HEAD_TREE,
      'WURK_TEST_PR_HEAD_SHA' => PR_HEAD_SHA,
      'WURK_TEST_PARENT_SHA' => PARENT_SHA,
      'WURK_TEST_MERGE_SHA' => MERGE_SHA,
      'WURK_TEST_PR_TREE' => PR_TREE,
      'WURK_TEST_RUN_ID' => RUN_ID,
      'WURK_TEST_PR' => PR_NUMBER,
      'WURK_TEST_SUBJECT' => SUBJECT
    }
  end

  # The fail-open contract: `false` on stdout, exit 0, and the stderr
  # signature the health brief greps for.
  def assert_full_run(out, err, status)
    assert_equal 0, status.exitstatus, err
    assert_equal "false\n", out
    assert_match(/\Aci-dup-push: /, err)
    assert_match(/— full run\n\z/, err, 'stderr must end with the fail-open signature')
  end
end
