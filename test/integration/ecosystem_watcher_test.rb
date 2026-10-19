# frozen_string_literal: true

require_relative '../test_helper'
require 'fileutils'
require 'open3'
require 'tmpdir'

# Pins the four branches the watcher diff added so each FAILS if its branch
# is deleted:
#   1. fresh empty marker.txt → POST path (the diff DROPS the no-POST fresh
#      carveout, so every release goes through curl)
#   2. DRY_RUN=true prints "[dry-run] would file:" and POSTs none
#   3. API_KEY unset prints 'DEVELOPERZ_API_KEY missing' and exits 0; the
#      dedup+POST step (step 240 in ecosystem.yml) must not run — the
#      per-step `if: env.API_KEY != ''` gate is what short-circuits it
#   4. Two consecutive runs against the same releases: first files N,
#      second files 0 (every version is already in the marker)
#
# Mirrors test/unit/bin_check_redis_url_test.rb: drive the watcher's step
# bodies via Open3.capture3 in a tmpdir with stub gh/curl/jq binaries,
# asserting on stdout, exit code, stub call counts, and the marker file.
class EcosystemWatcherTest < Wurk::Test::UnitCase
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  WORKFLOW = File.join(ROOT, '.github/workflows/ecosystem.yml')

  # Three releases the stub `gh` returns as TSV — the shape the workflow's
  # `gh api ... --jq '.[] | [.tag_name, .html_url, .name] | @tsv'` filter
  # produces. `read tag url name` (IFS=$'\t') parses each row.
  RELEASES = [
    %w[v7.3.0 https://github.com/sidekiq/sidekiq/releases/tag/v7.3.0 Release-7.3.0],
    %w[v7.2.0 https://github.com/sidekiq/sidekiq/releases/tag/v7.2.0 Release-7.2.0],
    %w[v7.1.3 https://github.com/sidekiq/sidekiq/releases/tag/v7.1.3 Release-7.1.3]
  ].freeze
  VERSIONS = RELEASES.map { |r| r[0].sub(/\Av/, '') }.freeze

  # Stub `gh` returning the fixed release list as TSV. The heredoc
  # interpolates the RELEASES rows; `\\n` becomes the literal `\n` shell
  # format spec for a `\n` newline, `\t` becomes a real TAB separator.
  STUB_GH = <<~SH.freeze
    #!/usr/bin/env bash
    printf '%s\\n' #{RELEASES.map { |r| "'#{r.join("\t")}'" }.join(' ')}
  SH

  # Stub `curl` appending each argv line to `$CURL_LOG`. The script pipes
  # the `Authorization: Bearer …` header into curl's stdin via `-H @-`; this
  # stub does not read stdin — only argv needs to land in the log so the
  # test can count POSTs. Returns 0 so the script records the version in
  # marker.txt after the curl call.
  STUB_CURL = <<~SH
    #!/usr/bin/env bash
    for arg in "$@"; do
      echo "$arg" >> "$CURL_LOG"
    done
    exit 0
  SH

  # Stub `jq` emitting a placeholder JSON body. The script invokes
  # `jq -nc --arg … '{…}'`, but this stub ignores args and just echoes a
  # minimal valid body — the curl `--data` arg only needs the literal body,
  # not its JSON shape, to land in CURL_LOG.
  STUB_JQ = <<~SH
    #!/usr/bin/env bash
    echo '{"title":"x","url":"x","name":"x","source":"x"}'
  SH

  # Extracts the `run: |` body of the named step from the workflow YAML,
  # dedented to column 0. Blank lines in the body are preserved; the
  # capture terminates at the first non-empty line whose indentation is
  # shallower than the `run:` directive's body (i.e. the next step).
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
      break unless run_body_line?(line, indent)

      body << line
    end
    body.pop while body.last && body.last.strip.empty?
    body.map { |l| l.sub(/^ {#{indent}}/, '') }
  end

  def run_body_line?(line, indent)
    line.strip.empty? || line.start_with?(' ' * indent)
  end

  # Drives the dedup+POST loop in an isolated tmpdir with stub gh/curl/jq
  # on PATH and the marker pre-populated as `marker`. Returns
  # [stdout, stderr, status, marker_text_after, curl_log_content].
  # Curl log content (not the path) is returned because Dir.mktmpdir's block
  # form deletes the directory the moment the block returns — every test
  # would otherwise pass an already-deleted path to curl_post_count and silently
  # observe 0 POSTs (regression class: "green curl log, missing assertions").
  def run_loop(env_overrides: {}, marker: '')
    Dir.mktmpdir('wurk-watcher-') do |tmpdir|
      prepare_loop_dir(tmpdir, marker)
      script = File.join(tmpdir, 'watcher.sh')
      env = loop_env(env_overrides, tmpdir)

      out, err, status = Open3.capture3(env, 'bash', script, chdir: tmpdir)
      marker_after = File.read(File.join(tmpdir, 'state/marker.txt'))
      curl_log_after = File.read(File.join(tmpdir, 'curl.log'))
      [out, err, status, marker_after, curl_log_after]
    end
  end

  def prepare_loop_dir(tmpdir, marker)
    FileUtils.mkdir_p(File.join(tmpdir, 'state'))
    File.write(File.join(tmpdir, 'state/marker.txt'), marker)

    bin_dir = File.join(tmpdir, 'bin')
    Dir.mkdir(bin_dir)
    File.write(File.join(tmpdir, 'curl.log'), '')

    write_stub_binaries(bin_dir)
    write_watcher_script(tmpdir)
  end

  def write_stub_binaries(bin_dir)
    stubs = { 'gh' => STUB_GH, 'curl' => STUB_CURL, 'jq' => STUB_JQ }
    stubs.each do |name, body|
      path = File.join(bin_dir, name)
      File.write(path, body)
      File.chmod(0o755, path)
    end
  end

  def write_watcher_script(tmpdir)
    script_body = build_watcher_script_body(tmpdir)
    script = File.join(tmpdir, 'watcher.sh')
    File.write(script, script_body)
    File.chmod(0o755, script)
  end

  def build_watcher_script_body(tmpdir)
    # The extracted `run:` body hardcodes `/tmp/releases.tsv` — substitute
    # with this tmpdir's path so parallel test workers don't collide on a
    # shared `/tmp` file (the workflow itself only ever runs one job at a
    # time on GitHub's runner; the test runs many in parallel).
    run_body = extract_run_body('list releases and POST one ask per unhandled release')
    run_body = run_body.gsub('/tmp/releases.tsv', File.join(tmpdir, 'releases.tsv'))
    "#!/usr/bin/env bash\n#{run_body}"
  end

  def loop_env(env_overrides, tmpdir)
    {
      'PATH' => "#{File.join(tmpdir, 'bin')}:#{ENV.fetch('PATH', '')}",
      'API_KEY' => env_overrides.fetch(:api_key, 'test-key'),
      'API_URL' => env_overrides.fetch(:api_url, 'https://example.test/asks'),
      'DRY_RUN' => env_overrides[:dry_run] ? 'true' : '',
      'CURL_LOG' => File.join(tmpdir, 'curl.log'),
      'COVERAGE' => nil
    }
  end

  # Drives the API_KEY check step. The step exits 0 (skip) when API_KEY is
  # unset; the dedup+POST step (which would call `gh`) must NOT run.
  # The gh stub writes a sentinel file the test asserts does not exist.
  def run_api_key_check(env_value)
    Dir.mktmpdir('wurk-watcher-') do |tmpdir|
      bin_dir = File.join(tmpdir, 'bin')
      Dir.mkdir(bin_dir)
      sentinel = File.join(tmpdir, 'gh_called')

      gh = File.join(bin_dir, 'gh')
      File.write(gh, "#!/usr/bin/env bash\ntouch #{sentinel}\nexit 0\n")
      File.chmod(0o755, gh)

      script = File.join(tmpdir, 'check.sh')
      check_body = "#!/usr/bin/env bash\n#{extract_run_body('exit 0 if DEVELOPERZ_API_KEY is missing')}"
      File.write(script, check_body)
      File.chmod(0o755, script)

      env = {
        'PATH' => "#{bin_dir}:#{ENV.fetch('PATH', '')}",
        'API_KEY' => env_value,
        'COVERAGE' => nil
      }

      out, err, status = Open3.capture3(env, 'bash', script, chdir: tmpdir)
      [out, err, status, sentinel]
    end
  end

  def curl_post_count(curl_log_content)
    curl_log_content.lines.count { |l| l.chomp == 'POST' }
  end

  # Branch 1: fresh empty marker.txt → POST path. Every fetched version ends
  # up in marker.txt; zero 'seeded:' lines on stdout (the diff removed the
  # fresh carveout that previously produced them — empty marker.txt causes
  # grep -qxF to miss, the loop falls through to the POST branch).
  def test_fresh_empty_marker_posts_each_release_with_zero_seeded_lines
    out, _err, status, marker, curl_log = run_loop(marker: '')

    assert_predicate status, :success?,
                     "loop must exit 0 on a fresh marker (out=#{out.inspect})"

    refute_match(/seeded:/, out,
                 "fresh carveout is removed; 'seeded:' lines on stdout are a " \
                 "regression (out=#{out.inspect})")

    VERSIONS.each do |v|
      assert_includes marker, "#{v}\n",
                      "version #{v} must be recorded in marker.txt after the POST"
    end

    assert_equal VERSIONS.size, curl_post_count(curl_log),
                 'every fetched version must trigger exactly one curl POST on a ' \
                 "fresh marker (curl.log=#{curl_log.inspect})"
  end

  # Branch 2: DRY_RUN=true prints "[dry-run] would file:" and POSTs none.
  # The marker is still updated so the next real run does not re-announce.
  def test_dry_run_lists_without_posting_and_records_them
    out, _err, status, marker, curl_log = run_loop(marker: '', env_overrides: { dry_run: true })

    assert_predicate status, :success?,
                     "loop must exit 0 in dry-run (out=#{out.inspect})"

    VERSIONS.each do |v|
      assert_includes out, "[dry-run] would file: #{v}",
                      "dry-run must announce version #{v} on stdout"
    end

    assert_equal 0, curl_post_count(curl_log),
                 "dry-run must POST nothing (curl.log=#{curl_log.inspect})"

    VERSIONS.each do |v|
      assert_includes marker, "#{v}\n",
                      "dry-run must record version #{v} in marker.txt so the " \
                      'next real run does not re-announce'
    end
  end

  # Branch 3: API_KEY unset → 'DEVELOPERZ_API_KEY missing' and exits 0; the
  # dedup+POST step (step 240) must NOT run. The per-step `if: env.API_KEY
  # != ''` gate is what short-circuits it; the step body itself exits 0
  # unconditionally on missing key.
  def test_missing_api_key_exits_zero_without_running_dedup_post
    out, _err, status, sentinel = run_api_key_check('')

    assert_equal 0, status.exitstatus,
                 "step must exit 0 (skip; exit 0; ...): stdout=#{out.inspect}"
    assert_includes out, 'DEVELOPERZ_API_KEY missing',
                    'the message must announce the missing secret'

    refute_path_exists sentinel,
                       'the dedup+POST step must not run when API_KEY is unset; the ' \
                       "`if: env.API_KEY != ''` per-step gate is what short-circuits it " \
                       "(gh stub would have created #{sentinel})"

    # Text check that the dedup+POST step is gated on API_KEY presence. A
    # regression that drops the `if:` from that step would let an absent
    # API_KEY reach `gh api ...`, POST with `Authorization: Bearer ` (an
    # empty bearer), and turn the job red. Pin the gate in the YAML itself
    # so the regression cannot ship even when no live watcher run is
    # exercising it.
    yaml = File.read(WORKFLOW)
    # %w splits on whitespace; escape spaces so each step name is one element,
    # not 13: the regex below matches `- name: <full name>`, which silently
    # only ever finds the first word of each line otherwise (#history: a
    # "prior" iteration was finding nil and turning the whole test red).
    [
      'read prior marker artifact',
      'list releases and POST one ask per unhandled release'
    ].each do |step_name|
      step_block = yaml.match(
        /^\s*-\s*name:\s*#{Regexp.escape(step_name)}\b.*?(?=^\s*-\s*(?:name|uses):|\z)/m
      )

      refute_nil step_block,
                 "step `#{step_name}` must exist in #{WORKFLOW} so the gate " \
                 'has somewhere to live'

      assert_match(/\bif:\s*env\.API_KEY\s*!=\s*''/, step_block[0],
                   "step `#{step_name}` must carry `if: env.API_KEY != ''` so " \
                   'an absent secret short-circuits it before curl POSTs an ' \
                   'empty bearer')
    end
  end

  # Pin the POST body schema in the YAML itself. STUB_JQ echoes a placeholder
  # body, so branches 1/2/4 cannot detect a regression that drops
  # `kind:"parity-check"`, `body:$notes`, or `--arg notes` from the jq
  # template at ecosystem.yml:287-293 — curl would still POST (every argv
  # is logged), but the API would receive a body without the release notes
  # or the parity-check identifier. Mirror the per-step gate regex pattern
  # used in branch 3.
  def test_post_step_run_block_includes_kind_notes_and_notes_arg
    yaml = File.read(WORKFLOW)
    step_block = yaml.match(
      /^\s*-\s*name:\s*list releases and POST one ask per unhandled release\b.*?(?=^\s*-\s*(?:name|uses):|\z)/m
    )

    refute_nil step_block,
               'POST step must exist in ecosystem.yml so the body schema has ' \
               'somewhere to live'

    [
      'kind:\s*"parity-check"',
      'body:\$notes',
      '--arg notes'
    ].each do |needle|
      assert_match(/#{needle}/, step_block[0],
                   "POST step's run block must contain /#{needle}/ so the API " \
                   'receives the release notes + parity-check identifier')
    end
  end

  # Branch 4: two consecutive runs against the same releases. The first
  # files N, the second files 0 (every version is in the marker from the
  # previous run, so grep -qxF hits and the loop `continue`s before POST).
  def test_second_run_dedupes_against_marker_and_files_zero
    out1, _err1, status1, marker1, curl_log1 = run_loop(marker: '')

    assert_predicate status1, :success?, "first run must exit 0 (out=#{out1.inspect})"

    assert_equal VERSIONS.size, curl_post_count(curl_log1),
                 "first run must POST every version (#{curl_post_count(curl_log1)} POSTs observed)"

    out2, _err2, status2, marker2, curl_log2 = run_loop(marker: marker1)

    assert_predicate status2, :success?, "second run must exit 0 (out=#{out2.inspect})"

    assert_equal 0, curl_post_count(curl_log2),
                 'second run must POST nothing — every version is already in the ' \
                 "marker (curl.log=#{curl_log2.inspect})"

    assert_equal marker1, marker2,
                 'marker is unchanged on the second run (all versions were skipped)'
  end
end
