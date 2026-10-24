# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# bin/ci-dup-push declares its prerequisites in the comment block at the top of
# the script, and that block is the only place a reader learns what the script
# needs. It named `gh` and GH_TOKEN but not the `jq` binary the script shells
# out to to parse the PR JSON — a contributor had no way to know jq was
# required, and a runner without jq would break the script instead of the run.
#
# Three guards here:
#   1. the header names gh, jq AND GH_TOKEN;
#   2. the body still calls a real jq, so the header cannot claim a
#      prerequisite the code stopped using (gh's own `--jq` flag is not jq);
#   3. a run with a prerequisite missing fails OPEN — stdout exactly `false`,
#      exit status 0 — because a wrong `true` would skip the only gate a
#      direct push to main ever gets.
#
# Reads the script and runs it in a temp dir; touches no Redis.
class CiDupPushPrereqsTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  SCRIPT = File.join(ROOT, 'bin', 'ci-dup-push')

  # bash is the interpreter the script's shebang names. Absolute paths only:
  # the fail-open run below empties PATH on purpose.
  BASH = %w[/bin/bash /usr/bin/bash].find { |path| File.executable?(path) }

  # Stands in for git so the run reaches the gh call — the step whose missing
  # prerequisite the fail-open contract is about. git supplies a HEAD sha, a
  # tree sha and a subject carrying the PR number; nothing else is read.
  GIT_STUB = <<~SH
    #!/bin/sh
    case "$1" in
      rev-parse)
        if [ "$2" = 'HEAD^{tree}' ]; then
          echo "0000000000000000000000000000000000000002"
        else
          echo "0000000000000000000000000000000000000001"
        fi
        ;;
      log)
        echo "chore: ci-dup-push fixture (#42)"
        ;;
    esac
    exit 0
  SH

  def setup
    @source = File.read(SCRIPT)
  end

  def test_header_names_every_prerequisite
    header = header_comment

    assert_match(/\bgh\b/, header, 'the header comment must name the gh binary')
    assert_match(/\bjq\b/, header, 'the header comment must name the jq binary')
    assert_match(/\bGH_TOKEN\b/, header, 'the header comment must name GH_TOKEN')
  end

  def test_body_still_calls_the_jq_binary
    body = @source.lines.reject { |line| line.strip.start_with?('#') }.join

    assert_match(/(?<![\w-])jq\s+-/, body,
                 "the script must still call the jq binary — gh's own --jq flag is not jq")
  end

  def test_missing_prerequisite_fails_open
    skip 'bash is not installed on this box' unless BASH

    out, err, status = run_without_prerequisites

    assert_equal 0, status.exitstatus, "a missing prerequisite must not fail the run:\n#{err}"
    assert_equal "false\n", out, 'the script must print exactly `false` when a prerequisite is missing'
    assert_match(/PR #42\b/, err, "the run must have reached the gh call:\n#{err}")
  end

  private

  # The comment block between the shebang and the first executable line.
  def header_comment
    lines = @source.lines
    lines = lines.drop(1) if lines.first&.start_with?('#!')
    lines.take_while { |line| line.strip.empty? || line.strip.start_with?('#') }.join
  end

  # PATH holds the temp dir and nothing else, so gh and jq are genuinely
  # absent rather than stubbed to fail, and GH_TOKEN is unset.
  def run_without_prerequisites
    Dir.mktmpdir('ci-dup-push') do |dir|
      stub = File.join(dir, 'git')
      File.write(stub, GIT_STUB)
      File.chmod(0o755, stub)
      env = {
        'PATH' => dir,
        'GITHUB_EVENT_NAME' => 'push',
        'GITHUB_REPOSITORY' => 'wurk/wurk',
        'GH_TOKEN' => nil
      }
      Open3.capture3(env, BASH, SCRIPT, chdir: ROOT)
    end
  end
end
