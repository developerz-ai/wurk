# frozen_string_literal: true

require 'minitest/autorun'
require 'digest'
require 'json'
require 'yaml'
require 'fileutils'
require 'open3'
require 'tmpdir'

# Gates .github/workflows/release.yml. The lane cannot run end to end before a
# real release, and a mistake in it surfaces after an irreversible `gem push`, so
# the two things that decide its behaviour are executed here instead of read:
#
#   * preflight's state step, with curl and gh stubbed, for every combination of
#     gem, tag and Release;
#   * the job graph, by evaluating the workflow's real `if:` expressions under
#     GitHub's skip rules, so no combination of outcomes can yield a green run
#     that owed a release and did not finish it.
#
# Reads files and runs shell against stubs; touches no Redis and no network.
class ReleaseWorkflowTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  RELEASE_YML = File.join(ROOT, '.github', 'workflows', 'release.yml')
  HEAD = 'c' * 40
  ELSEWHERE = 'd' * 40
  VERSION = '9.9.9'
  TAG = 'v9.9.9'
  GEM_ASSET = 'wurk-9.9.9.gem'

  # --- triggers and permissions --------------------------------------------

  # CLAUDE.md: the tag is an output, never an input.
  def test_nothing_but_a_version_bump_on_main_triggers_the_lane
    on = workflow.fetch(true) # YAML reads the bare `on:` key as true.

    assert_equal %w[push workflow_dispatch], on.keys
    assert_equal({ 'branches' => ['main'], 'paths' => ['lib/wurk/version.rb'] }, on.fetch('push'))
  end

  def test_workflow_level_permissions_are_read_only
    assert_equal({ 'contents' => 'read' }, workflow.fetch('permissions'))
  end

  def test_only_publish_can_mint_a_credential_and_only_release_can_write_the_tag
    grants = jobs.transform_values { |job| job.fetch('permissions', {}) }

    assert_equal(['publish'], grants.select { |_, perms| perms['id-token'] == 'write' }.keys)
    assert_equal(['release'], grants.select { |_, perms| perms['contents'] == 'write' }.keys)
    assert_empty jobs.fetch('build').fetch('permissions', {}),
                 '`build` runs third-party code and must inherit read-only'
  end

  # Everything that runs in the job holding the OIDC token can mint a publish
  # credential. So: pinned actions and this file's shell, nothing else.
  def test_the_publish_job_runs_no_third_party_code
    steps = jobs.fetch('publish').fetch('steps')
    uses = steps.filter_map { |step| step['uses'] }

    assert_equal %w[actions/download-artifact ruby/setup-ruby rubygems/configure-rubygems-credentials],
                 uses.map { |action| action.split('@').first }.sort
    uses.each { |action| assert_match(/@[0-9a-f]{40}\z/, action, 'the publish job pins every action by SHA') }

    shell = steps.filter_map { |step| step['run'] }.join("\n")

    refute_match(/\b(bundle|bun|rake|npm|gem exec|gem install)\b/, shell)
    setup_ruby = steps.find { |step| step['uses'].to_s.start_with?('ruby/setup-ruby') }

    refute_equal true, setup_ruby.dig('with', 'bundler-cache')
  end

  def test_build_gates_on_the_suite_and_uploads_the_gem
    steps = jobs.fetch('build').fetch('steps')

    assert_includes steps.filter_map { |step| step['run'] }.join("\n"), 'rake release:check'
    assert(steps.any? { |step| step['uses'].to_s.start_with?('actions/upload-artifact') })
  end

  # The live trusted publisher is registered to this repository and the filename
  # `release.yml`. RubyGems matches that against the token's job_workflow_ref, which
  # names the file DEFINING the job. A `gem push` moved to a called workflow would
  # present the callee's filename and be refused, after the release is underway.
  def test_gem_push_is_defined_in_release_yml_itself
    publish = jobs.fetch('publish')

    assert_equal 'release.yml', File.basename(RELEASE_YML)
    refute publish.key?('uses'), '`publish` must be steps in this file, not a reusable-workflow call'
    assert_includes publish.fetch('steps').filter_map { |step| step['run'] }.join("\n"), 'gem push'
    assert(publish.fetch('steps').any? do |step|
      step['uses'].to_s.start_with?('rubygems/configure-rubygems-credentials')
    end)
  end

  # RubyGems trusts release.yml with no environment, so any id-token in that file could
  # publish. The SBOM lives in its own file, whose OIDC workflow claim cannot match.
  def test_the_sbom_workflow_has_no_reach_into_publishing
    attest = YAML.load_file(File.join(ROOT, '.github', 'workflows', 'attest.yml'))
    triggers = attest.fetch('on', attest[true])

    assert_equal ['release'], triggers.dig('workflow_run', 'workflows')
    assert_equal({ 'contents' => 'read' }, attest.fetch('permissions'))

    upload = attest.dig('jobs', 'sbom')
    sign = attest.dig('jobs', 'attest')

    assert_equal 'write', upload.dig('permissions', 'contents')
    refute upload.fetch('permissions').key?('id-token')
    assert_equal 'write', sign.dig('permissions', 'id-token')
    refute_equal 'write', sign.dig('permissions', 'contents')
    refute(sign.fetch('steps').any? { |step| step['run'] || step['uses'].to_s.start_with?('actions/checkout') })
    refute_match(/gem push|release-gem/, File.read(File.join(ROOT, '.github', 'workflows', 'attest.yml')))
  end

  # A blank-environment publisher accepts this claim; RELEASE.md has the steps
  # that turn it into a real gate.
  def test_publish_names_the_rubygems_environment
    assert_equal 'rubygems', jobs.fetch('publish').dig('environment', 'name')
  end

  # --- what preflight decides ----------------------------------------------

  def test_gem_absent_publishes_and_finishes
    assert_state({ 'publish' => 'true', 'finish' => 'true' }, gem: 404)
    assert_state({ 'publish' => 'true', 'finish' => 'true' }, gem: 404, tag: HEAD)
    assert_state({ 'publish' => 'true', 'finish' => 'true' }, gem: 404, tag: HEAD, assets: [GEM_ASSET])
  end

  # A failed upload leaves this behind under the expected name. It must not read as
  # complete, or every fresh re-run would no-op over a release with no usable gem.
  def test_an_unfinished_gem_asset_does_not_complete_the_release
    finish = { 'publish' => 'false', 'finish' => 'true' }

    assert_state(finish, gem: 200, tag: HEAD, assets: [{ 'name' => GEM_ASSET, 'state' => 'starter', 'size' => 0 }])
    assert_state(finish, gem: 200, tag: HEAD, assets: [{ 'name' => GEM_ASSET, 'state' => 'starter', 'size' => 512 }])
    assert_state(finish, gem: 200, tag: HEAD, assets: [{ 'name' => GEM_ASSET, 'state' => 'uploaded', 'size' => 0 }])
  end

  def test_gem_live_with_the_tag_or_release_missing_skips_the_push_and_finishes
    finish = { 'publish' => 'false', 'finish' => 'true' }

    assert_state(finish, gem: 200)
    assert_state(finish, gem: 200, tag: HEAD)
    assert_state(finish, gem: 200, tag: HEAD, assets: [])
    assert_state(finish, gem: 200, tag: HEAD, assets: ['notes.txt'])
  end

  # A dispatch after main moved would tag code the gem never held.
  def test_finishing_from_a_later_commit_is_refused_with_the_way_forward
    result = state(gem: 200, version_commit: ELSEWHERE)

    refute_predicate result[:status], :success?
    assert_includes result[:stdout], ELSEWHERE
    assert_includes result[:stdout], 'Re-run all jobs'
    assert_empty result[:outputs]
  end

  def test_an_unreadable_version_commit_refuses_to_finish
    [:error, ''].each do |version_commit|
      result = state(gem: 200, version_commit: version_commit)

      refute_predicate result[:status], :success?, version_commit.inspect
      assert_empty result[:outputs]
    end
  end

  # Only cutting a tag depends on it: a release with its tag already here does not.
  def test_a_gem_absent_run_or_an_existing_tag_does_not_read_the_version_commit
    assert_state({ 'publish' => 'true', 'finish' => 'true' }, gem: 404, version_commit: ELSEWHERE)
    assert_state({ 'publish' => 'false', 'finish' => 'true' }, gem: 200, tag: HEAD, version_commit: ELSEWHERE)
  end

  def test_a_fully_released_version_is_an_announced_no_op
    result = state(gem: 200, tag: HEAD, assets: [GEM_ASSET])

    assert_predicate result[:status], :success?, result[:stderr]
    assert_equal({ 'publish' => 'false', 'finish' => 'false' }, result[:outputs])
    assert_includes result[:stdout], '::notice::'
    assert_includes result[:summary], 'nothing to do'
  end

  # A later edit to version.rb runs on a later commit than the tag; that is
  # still fully released.
  def test_a_complete_release_tagged_at_an_earlier_commit_is_a_no_op
    assert_state({ 'publish' => 'false', 'finish' => 'false' }, gem: 200, tag: ELSEWHERE, assets: [GEM_ASSET])
  end

  def test_a_tag_on_another_commit_is_refused_before_anything_irreversible
    [
      { gem: 404, tag: ELSEWHERE },
      { gem: 200, tag: ELSEWHERE },
      { gem: 404, tag: ELSEWHERE, assets: [GEM_ASSET] }
    ].each do |args|
      result = state(**args)

      refute_predicate result[:status], :success?, "must refuse #{args}"
      assert_includes result[:stdout], 'Refusing to move it'
      assert_empty result[:outputs], 'a refusal must not publish a decision'
    end
  end

  def test_a_probe_that_cannot_answer_fails_the_run
    [{ gem: 503 }, { gem: '000' }, { gem: 200, tag: :error }, { gem: 200, tag: HEAD, assets: :error }].each do |args|
      result = state(**args)

      refute_predicate result[:status], :success?, "must not guess on #{args}"
      assert_empty result[:outputs], "must not publish a decision on #{args}"
    end
  end

  # --- the job graph -------------------------------------------------------

  # Each row: preflight's outputs, which jobs fail, the jobs that must run, and
  # the run's conclusion. This is the truth table in RELEASE.md, evaluated.
  [
    ['a full release', %w[true true], [], %w[build publish release demo smoke], 'success'],
    ['finishing after a push', %w[false true], [], %w[release demo smoke], 'success'],
    ['a no-op', %w[false false], [], [], 'success'],
    ['a failed build', %w[true true], %w[build], %w[build], 'failure'],
    ['a failed push', %w[true true], %w[publish], %w[build publish], 'failure'],
    ['a failed tag', %w[true true], %w[release], %w[build publish release], 'failure'],
    ['a failed tag while finishing', %w[false true], %w[release], %w[release], 'failure'],
    ['a failed demo', %w[true true], %w[demo], %w[build publish release demo], 'failure'],
    ['a failed demo while finishing', %w[false true], %w[demo], %w[release demo], 'failure'],
    ['a failed smoke', %w[true true], %w[smoke], %w[build publish release demo smoke], 'failure']
  ].each do |label, (publish, finish), failing, expected, conclusion|
    define_method("test_the_job_graph_for_#{label.tr(' ', '_')}") do
      result = simulate(publish: publish, finish: finish, failing: failing)

      assert_equal expected, result[:ran], "jobs that ran for #{label}"
      assert_equal conclusion, result[:conclusion], "conclusion for #{label}"
    end
  end

  def test_a_failed_preflight_runs_nothing_and_goes_red
    result = simulate(publish: '', finish: '', failing: %w[preflight])

    assert_empty result[:ran]
    assert_equal 'failure', result[:conclusion]
  end

  # The exhaustive form of the rule: a run owing a release cannot go green unless
  # the release job actually ran.
  def test_no_failure_pattern_turns_an_owed_release_green_without_finishing_it
    names = %w[build publish release demo smoke]
    (0..names.size).flat_map { |count| names.combination(count).to_a }.each do |failing|
      [%w[true true], %w[false true]].each do |publish, finish|
        result = simulate(publish: publish, finish: finish, failing: failing)
        next unless result[:conclusion] == 'success'

        assert_includes result[:ran], 'release', "green without a release: failing=#{failing} publish=#{publish}"
      end
    end
  end

  # --- the steps after the push --------------------------------------------

  def test_gem_push_does_not_push_a_version_already_live
    out, _err, status, calls = run_step('publish', 'gem push', http: 200)

    assert_predicate status, :success?
    assert_includes out, 'not pushing it again'
    refute_includes calls, 'gem push'
  end

  def test_gem_push_pushes_an_absent_version
    _out, _err, status, calls = run_step('publish', 'gem push', http: 404)

    assert_predicate status, :success?
    assert_includes calls, "gem push pkg/wurk-#{VERSION}.gem"
  end

  def test_a_rubygems_that_never_serves_the_gem_does_not_fail_the_await
    out, _err, status, = run_step('publish', 'await RubyGems propagation', http: 404)

    assert_predicate status, :success?, 'the gem is already accepted; a slow CDN is not a failed release'
    assert_includes out, '::warning::'
  end

  def test_a_gem_rubygems_will_not_serve_fails_the_finish_loudly
    out, _err, status, = run_step('release', 'fetch the published gem', http: 404)

    refute_predicate status, :success?, 'no gem, no tag'
    assert_includes out, 're-run'
  end

  def test_a_served_gem_matching_its_published_digest_is_fetched
    out, status, gem = run_fetch(body: 'gem-bytes', published_sha: Digest::SHA256.hexdigest('gem-bytes'))

    assert_predicate status, :success?, out
    assert_equal 'gem-bytes', gem, 'the verified gem must land where the tag step attaches it from'
  end

  def test_a_served_gem_not_matching_its_published_digest_is_refused
    out, status, = run_fetch(body: 'tampered', published_sha: Digest::SHA256.hexdigest('gem-bytes'))

    refute_predicate status, :success?
    assert_includes out, '::error::'
  end

  def test_the_tag_step_completes_an_existing_release
    out, _err, status, calls = run_tag_step(tag: HEAD, existing_release: '77')

    assert_predicate status, :success?, out
    assert_includes out, '::warning::'
    assert_match(/gh release edit #{TAG} .*--target #{HEAD} .*--draft=false/, calls)
    assert_includes calls, "gh release upload #{TAG} pkg/#{GEM_ASSET} --clobber"
    refute_includes calls, 'gh release create'
  end

  # `--clobber` is what replaces a `starter` asset left by a failed upload; without
  # it `gh release upload` refuses an existing name and the release cannot be repaired.
  def test_the_repair_replaces_a_stale_asset
    _out, _err, status, calls = run_tag_step(tag: HEAD, existing_release: '77')

    assert_predicate status, :success?
    assert_match(/gh release upload #{TAG} \S+ --clobber/, calls)
  end

  def test_the_tag_step_completes_a_draft_with_no_tag_yet
    _out, _err, status, calls = run_tag_step(tag: nil, existing_release: '77')

    assert_predicate status, :success?
    assert_includes calls, 'gh release edit'
    refute_includes calls, 'gh release create'
  end

  def test_the_tag_step_refuses_a_tag_on_another_commit_even_with_no_release
    out, _err, status, calls = run_tag_step(tag: ELSEWHERE)

    refute_predicate status, :success?
    assert_includes out, 'refusing to move it'
    refute_match(/gh release (create|edit)/, calls)
  end

  def test_the_tag_step_creates_the_release_with_the_fetched_gem
    _out, _err, status, calls = run_tag_step(tag: nil)

    assert_predicate status, :success?
    assert_match(%r{gh release create #{TAG} .*--target #{HEAD} .*pkg/#{GEM_ASSET}}, calls)
  end

  private

  def workflow = @workflow ||= YAML.load_file(RELEASE_YML)
  def jobs = workflow.fetch('jobs')

  def step_run(job, name)
    jobs.fetch(job).fetch('steps').find { |step| step['name'] == name }&.fetch('run') || raise("no step #{job}/#{name}")
  end

  def assert_state(expected, **args)
    result = state(**args)

    assert_predicate result[:status], :success?, "#{args}: #{result[:stdout]} #{result[:stderr]}"
    assert_equal expected, result[:outputs], args.to_s
  end

  # Runs preflight's state step with curl answering `gem` and gh answering `tag`
  # (a sha, nil for 404, :error) and `assets` (a list, nil for 404, :error).
  def state(gem:, tag: nil, assets: nil, version_commit: HEAD)
    Dir.mktmpdir('release-preflight') do |dir|
      output = File.join(dir, 'output')
      summary = File.join(dir, 'summary')
      bin = File.join(dir, 'bin')
      FileUtils.mkdir_p(bin)
      stub(bin, 'curl', %(#!/usr/bin/env bash\nprintf '%s' "#{gem}"\n[ "#{gem}" != 000 ] || exit 7\n))
      stub(bin, 'gh', state_gh(tag, assets, version_commit))
      env = base_env(bin).merge('GITHUB_OUTPUT' => output, 'GITHUB_STEP_SUMMARY' => summary,
                                'TAG' => TAG, 'GH_TOKEN' => 'x')
      stdout, stderr, status = Open3.capture3(env, 'bash', '-c', step_run('preflight', 'read what has already shipped'))

      { status: status, stdout: stdout, stderr: stderr, summary: read(summary),
        outputs: read(output).lines.to_h { |line| line.chomp.split('=', 2) } }
    end
  end

  def state_gh(tag, assets, version_commit)
    <<~BASH
      #!/usr/bin/env bash
      case "$2" in
        */git/ref/tags/*) #{gh_answer(tag)} ;;
        */releases/tags/*) #{assets.is_a?(Array) ? release_answer(assets) : gh_answer(assets)} ;;
        */commits*) #{gh_answer(version_commit)} ;;
        *) echo "unexpected gh $*" >&2; exit 1 ;;
      esac
    BASH
  end

  # Answers through the step's own `-q` filter, so the filter is what gets tested.
  def release_answer(assets)
    rows = assets.map { |asset| asset.is_a?(Hash) ? asset : { 'name' => asset, 'state' => 'uploaded', 'size' => 1024 } }

    %(printf '%s' '#{JSON.generate('assets' => rows)}' | jq -r "$4")
  end

  def gh_answer(value)
    case value
    when nil then 'echo "gh: Not Found (HTTP 404)" >&2; exit 1'
    when :error then 'echo "gh: Server Error (HTTP 502)" >&2; exit 1'
    else %(printf '%s\\n' "#{value}")
    end
  end

  def base_env(bin)
    { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'VERSION' => VERSION,
      'GITHUB_REPOSITORY' => 'o/r', 'GITHUB_SHA' => HEAD }
  end

  def stub(bin, name, body)
    path = File.join(bin, name)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end

  def read(path) = File.file?(path) ? File.read(path) : ''

  # Runs one step of `job` with curl answering `http`, and gem, sleep stubbed.
  def run_step(job, name, http:)
    Dir.mktmpdir('release-step') do |dir|
      bin = File.join(dir, 'bin')
      calls = File.join(dir, 'calls')
      FileUtils.mkdir_p(bin)
      stub(bin, 'curl', <<~BASH)
        #!/usr/bin/env bash
        case " $* " in *' -f'*) [ "#{http}" = 200 ] || exit 22 ;; esac
        case " $* " in *' -w '*) printf '%s' "#{http}" ;; esac
      BASH
      stub(bin, 'sleep', "#!/usr/bin/env bash\n")
      stub(bin, 'gem', %(#!/usr/bin/env bash\necho "gem $*" >> "#{calls}"\n))
      stdout, stderr, status = Open3.capture3(base_env(bin), 'bash', '-c', step_run(job, name), chdir: dir)

      [stdout, stderr, status, read(calls)]
    end
  end

  def run_tag_step(tag:, existing_release: nil)
    Dir.mktmpdir('release-tag') do |dir|
      bin = File.join(dir, 'bin')
      calls = File.join(dir, 'calls')
      FileUtils.mkdir_p([bin, File.join(dir, 'pkg')])
      stub(bin, 'gh', <<~BASH)
        #!/usr/bin/env bash
        echo "gh $*" >> "#{calls}"
        case "$1 $2" in
          api\\ */git/ref/tags/*) #{gh_answer(tag)} ;;
          api\\ */releases) printf '%s' "#{existing_release}" ;;
        esac
      BASH
      FileUtils.mkdir_p(File.join(dir, 'tool'))
      changelog = File.join(dir, 'tool', 'changelog-section')
      File.write(changelog, "#!/usr/bin/env bash\necho notes\n")
      FileUtils.chmod(0o755, changelog)
      script = step_run('release', 'tag & create GitHub Release').sub('bin/changelog-section', changelog)
      env = base_env(bin).merge('TAG' => TAG, 'RUNNER_TEMP' => dir, 'GH_TOKEN' => 'x')
      stdout, stderr, status = Open3.capture3(env, 'bash', '-c', script, chdir: dir)

      [stdout, stderr, status, read(calls)]
    end
  end

  # Runs the fetch step against a curl serving the version JSON and the .gem.
  def run_fetch(body:, published_sha:)
    Dir.mktmpdir('release-fetch') do |dir|
      bin = File.join(dir, 'bin')
      FileUtils.mkdir_p(bin)
      stub(bin, 'sleep', "#!/usr/bin/env bash\n")
      stub(bin, 'curl', <<~BASH)
        #!/usr/bin/env bash
        out=""
        prev=""
        for arg in "$@"; do
          [ "$prev" = "-o" ] && out="$arg"
          prev="$arg"
        done
        if [ -n "$out" ]; then printf '%s' '#{body}' > "$out"; else printf '{"sha":"#{published_sha}"}'; fi
      BASH
      run = step_run('release', 'fetch the published gem')
      stdout, stderr, status = Open3.capture3(base_env(bin), 'bash', '-c', run, chdir: dir)

      ["#{stdout}#{stderr}", status, read(File.join(dir, 'pkg', GEM_ASSET))]
    end
  end

  # GitHub's rules: a job with no status function in its `if:` gets an implicit
  # success(), which requires every ancestor to have succeeded; with one, only
  # the expression counts. A job not run is `skipped`. The run fails when any job
  # failed. Jobs are declared in dependency order.
  def simulate(publish:, finish:, failing:)
    results = { 'preflight' => failing.include?('preflight') ? 'failure' : 'success' }
    outputs = results['preflight'] == 'success' ? { 'publish' => publish, 'finish' => finish } : {}

    jobs.except('preflight').each do |name, job|
      runs = job_runs?(job, results, outputs)
      results[name] = if runs
                        failing.include?(name) ? 'failure' : 'success'
                      else
                        'skipped'
                      end
    end

    { ran: results.except('preflight').reject { |_, result| result == 'skipped' }.keys,
      conclusion: results.value?('failure') ? 'failure' : 'success' }
  end

  def job_runs?(job, results, outputs)
    expression = job.fetch('if', '').to_s
    return false if !expression.include?('cancelled()') && !ancestors(job).all? { |name| results[name] == 'success' }

    expression.empty? || evaluate(expression, results, outputs)
  end

  def ancestors(job)
    Array(job['needs']).flat_map { |name| [name, *(name == 'preflight' ? [] : ancestors(jobs.fetch(name)))] }.uniq
  end

  # The expressions use only needs.*, ==, &&, || and !cancelled(), which read the
  # same in Ruby once the contexts are spelled as lookups. Skipped jobs have no
  # outputs in this model beyond preflight's, which is the only job read.
  def evaluate(expression, results, outputs)
    source = expression.strip.delete_prefix('${{').delete_suffix('}}').gsub(/\s*\n\s*/, ' ')
                       .gsub('!cancelled()', 'true')
                       .gsub(/needs\.(\w+)\.result/) { "results.fetch('#{Regexp.last_match(1)}')" }
                       .gsub(/needs\.preflight\.outputs\.(\w+)/) { "outputs['#{Regexp.last_match(1)}']" }
    binding.eval(source) # rubocop:disable Security/Eval
  end
end
