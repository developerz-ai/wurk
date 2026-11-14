# frozen_string_literal: true

require 'yaml'

require_relative '../test_helper'
require 'fileutils'
require 'open3'
require 'tmpdir'

# Pins the sidekiq release watcher in .github/workflows/ecosystem.yml by
# driving the watcher's own step bodies, extracted from the YAML, in a tmpdir
# with stub `gh` and `curl` binaries (the system `jq` and `sort` run for real).
#
# What is pinned, and why each one matters on the live schedule:
#   1. An empty or absent marker SEEDS to the newest stable upstream version
#      and files nothing. Without it, the first run files the whole history.
#   2. Only stable versions ABOVE the high-water mark are filed, oldest first,
#      capped at MAX_ASKS per run; the marker advances after each 2xx only.
#   3. The POST body is exactly `POST /v1/asks`'s strict schema: `ask`,
#      `repos`, `dedupe_key`, `evidence.urls`, nothing else (an unknown key
#      is a 400 there).
#   4. A non-2xx answer fails the step, prints the status and the response
#      body, never the key, and leaves the marker where it was.
#   5. DRY_RUN files nothing and never writes the marker.
#   6. A missing API key fails a schedule and skips a dispatch.
class EcosystemWatcherTest < Wurk::Test::UnitCase
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  WORKFLOW = File.join(ROOT, '.github/workflows/ecosystem.yml')
  POST_STEP = 'list sidekiq tags and file one ask per new release'
  API_KEY = 'test-key-must-never-be-printed'

  # What `gh api --paginate .../tags --jq '.[].name'` prints: one tag per
  # line, in no particular order. Betas, rcs and a junk name must be ignored,
  # and 8.1.10 must sort above 8.1.9 (version sort, not lexical).
  TAGS = %w[v8.1.9 v8.1.10 v8.2.0.beta1 v8.1.8 v7.3.10 v8.1.7 v8.0.0.rc1 v8.1.6 not-a-version].freeze
  LATEST = '8.1.10'

  STUB_GH = <<~SH.freeze
    #!/usr/bin/env bash
    printf '%s\\n' #{TAGS.join(' ')}
  SH

  # Stub `curl`: appends its argv to $CURL_LOG (one arg per line), drains the
  # header block from stdin as real curl does, writes $CURL_RESPONSE to the
  # `-o` file and prints the HTTP code for `-w`. The POST number named by
  # $CURL_FAIL_ON (1-based) answers 400 instead of 200.
  STUB_CURL = <<~SH
    #!/usr/bin/env bash
    if [ ! -t 0 ]; then cat >> "$CURL_STDIN_LOG"; fi
    out=""
    prev=""
    for arg in "$@"; do
      echo "$arg" >> "$CURL_LOG"
      [ "$prev" = "-o" ] && out="$arg"
      prev="$arg"
    done
    n=$(grep -cx 'POST' "$CURL_LOG")
    if [ "${CURL_FAIL_ON:-0}" = "$n" ]; then
      printf '%s' '{"type":"about:blank","status":400,"detail":"invalid ask body"}' > "$out"
      printf '400'
    else
      printf '%s' '{"kind":"created","ask":{"id":"rtk_1"}}' > "$out"
      printf '200'
    fi
  SH

  # Extracts the `run: |` body of the named step from the workflow YAML,
  # dedented to column 0. The capture ends at the first non-empty line whose
  # indentation is shallower than the body's.
  def extract_run_body(step_name)
    lines = File.read(WORKFLOW).lines
    step_idx = find_step(lines, step_name)
    run_idx = find_run_directive(lines, step_idx)
    indent = lines[run_idx].match(/^(\s+)/)[1].size + 2
    collect_run_body(lines, run_idx, indent).join
  end

  def find_step(lines, step_name)
    step_re = /^\s*-\s+name:\s*#{Regexp.escape(step_name)}\b/
    idx = lines.index { |l| l =~ step_re }
    raise "step #{step_name.inspect} not found in #{WORKFLOW}" unless idx

    idx
  end

  def find_run_directive(lines, from_idx)
    idx = (from_idx..).lazy.find { |i| lines[i] =~ /^(\s+)run:\s*\|/ }
    raise 'run: directive not found for step' unless idx

    idx
  end

  def collect_run_body(lines, run_idx, indent)
    body = []
    ((run_idx + 1)..(lines.size - 1)).each do |i|
      line = lines[i]
      break unless line.strip.empty? || line.start_with?(' ' * indent)

      body << line
    end
    body.pop while body.last && body.last.strip.empty?
    body.map { |l| l.sub(/^ {#{indent}}/, '') }
  end

  # Runs the POST step with `marker` as state/marker.txt (nil = no file).
  # Everything is read back INSIDE the block: Dir.mktmpdir deletes the
  # directory the moment the block returns.
  Result = Struct.new(:out, :err, :status, :marker, :curl_log, :curl_stdin, keyword_init: true)

  def run_loop(marker: '', dry_run: false, fail_on: nil)
    Dir.mktmpdir('wurk-watcher-') do |tmpdir|
      prepare_loop_dir(tmpdir, marker)
      env = loop_env(tmpdir, dry_run: dry_run, fail_on: fail_on)
      out, err, status = Open3.capture3(env, 'bash', File.join(tmpdir, 'watcher.sh'), chdir: tmpdir)
      marker_path = File.join(tmpdir, 'state/marker.txt')
      Result.new(
        out: out, err: err, status: status,
        marker: File.exist?(marker_path) ? File.read(marker_path) : nil,
        curl_log: File.read(File.join(tmpdir, 'curl.log')),
        curl_stdin: File.read(File.join(tmpdir, 'curl.stdin'))
      )
    end
  end

  def prepare_loop_dir(tmpdir, marker)
    FileUtils.mkdir_p(File.join(tmpdir, 'state'))
    File.write(File.join(tmpdir, 'state/marker.txt'), marker) unless marker.nil?
    File.write(File.join(tmpdir, 'curl.log'), '')
    File.write(File.join(tmpdir, 'curl.stdin'), '')

    bin_dir = File.join(tmpdir, 'bin')
    Dir.mkdir(bin_dir)
    { 'gh' => STUB_GH, 'curl' => STUB_CURL }.each do |name, body|
      path = File.join(bin_dir, name)
      File.write(path, body)
      File.chmod(0o755, path)
    end

    # The step writes the tag list to a fixed /tmp path; give each run its own.
    run_body = extract_run_body(POST_STEP).gsub('/tmp/sidekiq-tags.txt', File.join(tmpdir, 'tags.txt'))
    File.write(File.join(tmpdir, 'watcher.sh'), "#!/usr/bin/env bash\n#{run_body}")
  end

  def loop_env(tmpdir, dry_run:, fail_on:)
    {
      'PATH' => "#{File.join(tmpdir, 'bin')}:#{ENV.fetch('PATH', '')}",
      'API_KEY' => API_KEY,
      'API_URL' => 'https://example.test/v1/asks',
      'DRY_RUN' => dry_run ? 'true' : 'false',
      'MAX_ASKS' => '3',
      'CURL_LOG' => File.join(tmpdir, 'curl.log'),
      'CURL_STDIN_LOG' => File.join(tmpdir, 'curl.stdin'),
      'CURL_FAIL_ON' => fail_on&.to_s,
      'COVERAGE' => nil
    }
  end

  def post_count(result)
    result.curl_log.lines.count { |l| l.chomp == 'POST' }
  end

  # STUB_CURL logs argv one per line, so each body is the line after `--data`.
  def post_bodies(result)
    lines = result.curl_log.lines.map(&:chomp)
    lines.each_index.select { |i| lines[i] == '--data' }.map { |i| JSON.parse(lines[i + 1]) }
  end

  def assert_no_key_printed(result)
    refute_includes result.out, API_KEY, 'the API key must never reach stdout'
    refute_includes result.err, API_KEY, 'the API key must never reach stderr'
    refute_includes result.curl_log, API_KEY, 'the API key must never be on curl argv'
  end

  # --- seed ----------------------------------------------------------------

  # The live input on the first real run: the 2026-11-11 dispatch left a
  # `wurk-watcher-state` artifact holding a ZERO-BYTE marker.txt.
  def test_empty_marker_seeds_to_newest_stable_version_and_files_nothing
    result = run_loop(marker: '')

    assert_predicate result.status, :success?, "seed run must exit 0 (out=#{result.out.inspect})"
    assert_equal 0, post_count(result), 'a seed run must POST nothing'
    assert_equal "#{LATEST}\n", result.marker, 'the seed is the newest vX.Y.Z tag, by version sort'
    assert_includes result.out, "seeded: marker set to #{LATEST}"
  end

  def test_absent_or_blank_marker_seeds_the_same_way
    [nil, "\n  \n"].each do |marker|
      result = run_loop(marker: marker)

      assert_predicate result.status, :success?
      assert_equal 0, post_count(result), "marker #{marker.inspect} must seed, not file"
      assert_equal "#{LATEST}\n", result.marker
    end
  end

  def test_dry_run_on_empty_marker_announces_the_seed_and_writes_nothing
    result = run_loop(marker: '', dry_run: true)

    assert_predicate result.status, :success?
    assert_includes result.out, "[dry-run] would seed marker to #{LATEST}"
    assert_equal 0, post_count(result)
    assert_equal '', result.marker, 'a dry run must not seed the marker'
  end

  # --- filing --------------------------------------------------------------

  def test_files_only_versions_above_the_marker_oldest_first_and_advances_it
    result = run_loop(marker: "8.1.8\n")

    assert_predicate result.status, :success?, "out=#{result.out.inspect} err=#{result.err.inspect}"
    keys = post_bodies(result).map { |b| b['dedupe_key'] }

    assert_equal %w[sidekiq-release:v8.1.9 sidekiq-release:v8.1.10], keys,
                 'betas, rcs, older lines and the marker itself are never filed'
    assert_equal "#{LATEST}\n", result.marker
    assert_no_key_printed(result)
  end

  # The body is the platform's strict schema and nothing more: an extra key
  # (the old title/url/name/source/body/kind) is a 400 at `POST /v1/asks`.
  def test_post_body_is_exactly_the_asks_schema
    body = post_bodies(run_loop(marker: "8.1.9\n")).fetch(0)

    assert_equal %w[ask dedupe_key evidence repos], body.keys.sort
    assert_equal %w[urls], body['evidence'].keys
    assert_equal ['developerz-ai/wurk'], body['repos']
    assert_equal 'sidekiq-release:v8.1.10', body['dedupe_key']
    assert_equal %w[https://github.com/sidekiq/sidekiq/blob/v8.1.10/Changes.md
                    https://github.com/sidekiq/sidekiq/tree/v8.1.10], body['evidence']['urls']
    assert_kind_of String, body['ask']
    assert_includes body['ask'], 'Sidekiq v8.1.10'
    refute_includes body['ask'], "\n", 'the ask is one paragraph'
  end

  def test_authorization_header_travels_on_stdin_only
    result = run_loop(marker: "8.1.9\n")

    assert_includes result.curl_stdin, "Authorization: Bearer #{API_KEY}"
    assert_includes result.curl_log.lines.map(&:chomp), '@-'
    refute_includes result.curl_log.lines.map(&:chomp), '-v'
    assert_no_key_printed(result)
  end

  def test_a_run_files_at_most_max_asks_and_warns
    result = run_loop(marker: "8.1.6\n")

    assert_predicate result.status, :success?
    assert_equal(%w[sidekiq-release:v8.1.7 sidekiq-release:v8.1.8 sidekiq-release:v8.1.9],
                 post_bodies(result).map { |b| b['dedupe_key'] })
    assert_equal "8.1.9\n", result.marker, 'the marker stops at the last version filed'
    assert_includes result.out, '::warning::4 versions above the marker'
  end

  def test_second_run_files_nothing
    first = run_loop(marker: "8.1.8\n")
    second = run_loop(marker: first.marker)

    assert_predicate second.status, :success?
    assert_equal 0, post_count(second)
    assert_equal first.marker, second.marker
  end

  # A marker written by the old watcher is a list of versions; it reads as
  # its highest.
  def test_legacy_list_marker_reads_as_its_highest_version
    result = run_loop(marker: "7.3.10\n8.1.9\n8.1.10\n8.1.7\n")

    assert_equal 0, post_count(result)
    assert_equal "#{LATEST}\n", result.marker
  end

  def test_unparseable_marker_fails_rather_than_reseeding
    result = run_loop(marker: "garbage\n")

    assert_equal 1, result.status.exitstatus
    assert_includes result.out, '::error::marker'
    assert_equal 0, post_count(result)
  end

  def test_dry_run_with_a_marker_announces_and_posts_nothing
    result = run_loop(marker: "8.1.9\n", dry_run: true)

    assert_predicate result.status, :success?
    assert_includes result.out, '[dry-run] would file: v8.1.10'
    assert_equal 0, post_count(result)
    assert_equal "8.1.9\n", result.marker
  end

  # --- failure -------------------------------------------------------------

  def test_non_2xx_fails_loudly_with_status_and_body_and_keeps_the_marker
    result = run_loop(marker: "8.1.9\n", fail_on: 1)

    assert_equal 1, result.status.exitstatus
    assert_includes result.out, 'answered HTTP 400'
    assert_includes result.out, 'invalid ask body', 'the response body is the diagnosis; print it'
    assert_equal "8.1.9\n", result.marker
    assert_no_key_printed(result)
  end

  def test_failure_mid_run_keeps_the_asks_already_filed
    result = run_loop(marker: "8.1.8\n", fail_on: 2)

    assert_equal 1, result.status.exitstatus
    assert_equal 2, post_count(result)
    assert_equal "8.1.9\n", result.marker, 'the 2xx before the failure advanced the marker'
  end

  # --- workflow wiring -----------------------------------------------------

  def watcher_job
    YAML.load_file(WORKFLOW).fetch('jobs').fetch('watcher')
  end

  # The token is stored only in the `sidekiq-release-watcher` environment,
  # whose branch policy admits main alone.
  def test_watcher_job_runs_in_the_main_only_secret_environment
    assert_equal 'sidekiq-release-watcher', watcher_job['environment']
  end

  # After a failed marker read, state/marker.txt is empty; uploading it would
  # make the next run re-seed past every version in between.
  def test_marker_upload_requires_a_successful_read
    upload = watcher_job.fetch('steps').find { |s| s['uses'].to_s.start_with?('actions/upload-artifact@') }

    assert_includes upload['if'], "steps.read_marker.outcome == 'success'"
    read = watcher_job.fetch('steps').find { |s| s['name'] == 'read prior marker artifact' }

    assert_equal 'read_marker', read['id']
  end

  def test_marker_steps_are_gated_on_the_api_key
    names = ['read prior marker artifact', POST_STEP]
    steps = watcher_job.fetch('steps').select { |s| names.include?(s['name']) }

    assert_equal names.size, steps.size
    steps.each { |s| assert_equal "env.API_KEY != ''", s['if'], "#{s['name']} must be key-gated" }
  end

  # Drives the API_KEY check step. With API_KEY unset it exits 0 (skip) on a
  # manual dispatch and 1 on a schedule; the step itself never calls gh.
  def run_api_key_check(env_value, event: 'workflow_dispatch')
    Dir.mktmpdir('wurk-watcher-') do |tmpdir|
      bin_dir = File.join(tmpdir, 'bin')
      Dir.mkdir(bin_dir)
      sentinel = File.join(tmpdir, 'gh_called')
      gh = File.join(bin_dir, 'gh')
      File.write(gh, "#!/usr/bin/env bash\ntouch #{sentinel}\nexit 0\n")
      File.chmod(0o755, gh)

      script = File.join(tmpdir, 'check.sh')
      File.write(script, "#!/usr/bin/env bash\n#{extract_run_body('require DEVELOPERZ_API_KEY on schedule')}")

      env = { 'PATH' => "#{bin_dir}:#{ENV.fetch('PATH', '')}", 'API_KEY' => env_value,
              'EVENT' => event, 'COVERAGE' => nil }
      out, _err, status = Open3.capture3(env, 'bash', script, chdir: tmpdir)
      [out, status, File.exist?(sentinel)]
    end
  end

  def test_missing_api_key_fails_a_scheduled_run
    out, status, gh_called = run_api_key_check('', event: 'schedule')

    assert_equal 1, status.exitstatus, "a scheduled run must fail: stdout=#{out.inspect}"
    assert_includes out, '::error::DEVELOPERZ_API_KEY missing'
    refute gh_called
  end

  def test_missing_api_key_skips_a_manual_dispatch
    out, status, gh_called = run_api_key_check('')

    assert_equal 0, status.exitstatus, "stdout=#{out.inspect}"
    assert_includes out, 'DEVELOPERZ_API_KEY missing'
    refute gh_called
  end
end
