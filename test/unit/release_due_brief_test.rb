# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'open3'
require 'tmpdir'

# Guards the Window/Do table in .dz/briefs/release-due.md the same way
# claude_md_claims_test.rb gates CLAUDE.md: a steering brief the day of
# "Decide" runs without an object store must not silently collapse a
# missing window to "empty -> nothing". The Day loop runs the brief on
# worktree-only checkouts too; if the git commands cannot run there, the
# verdict is "unknown", and that hidden absence is the regression this gate
# pins. Reads files and touches no Redis or shared state.
class ReleaseDueBriefTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  BRIEF = File.join(ROOT, '.dz', 'briefs', 'release-due.md')

  # A row's cells are `|`-separated; the second cell is the "Do" verdict.
  # The header separator (`|---|`) is excluded by requiring at least one
  # letter on each side of the second `|`.
  ROW_RE = /\A\| (?<window>[^|]+) \|(?<do>[^|]+) \|\z/

  def setup
    @text = File.read(BRIEF)
  end

  def test_unknown_row_present_for_unreadable_window
    unknown_rows = unknown_rows_in_table

    refute_empty unknown_rows,
                 '.dz/briefs/release-due.md Window/Do table must contain a row whose ' \
                 'Do cell starts with the word "unknown" so a failure to read the ' \
                 'window is surfaced instead of collapsed to "nothing"'

    missing_window_rows = unknown_rows.reject do |row|
      row[:window].match?(/worktree-only|no object store|cannot run|fail/i)
    end

    assert_empty missing_window_rows,
                 'these rows say "unknown" without naming the unreadable-window case ' \
                 '(worktree-only .git / no object store): ' \
                 "#{missing_window_rows.map { |r| r[:raw] }.join('; ')}"
  end

  def test_unknown_row_does_not_say_nothing
    unknown_rows = unknown_rows_in_table

    saying_nothing = unknown_rows.select { |row| row[:do].match?(/\bnothing\b/) }

    assert_empty saying_nothing,
                 'the unknown-verdict row must not also say "nothing"; ' \
                 'otherwise the missing-window case is silently collapsed: ' \
                 "#{saying_nothing.map { |r| r[:raw] }.join('; ')}"
  end

  def test_unknown_row_is_not_the_empty_row
    empty_row_with_unknown = parse_table_rows.find do |row|
      row[:window] == 'empty' && row[:do].start_with?('unknown')
    end

    assert_nil empty_row_with_unknown,
               'the empty-window row must keep its "nothing" verdict; an ' \
               '"unknown" verdict belongs on its own row, not on the empty row'
  end

  def test_unknown_token_lives_on_a_single_stable_table_row
    # grep -n "unknown" must point at the unknown-verdict row, not at
    # prose elsewhere in the brief. A future edit that drops the row
    # (or scatters the token across multiple lines) breaks this gate.
    occurrences = @text.lines.each_with_index.select { |line, _| line.include?('unknown') }

    assert_equal 1, occurrences.size,
                 '"unknown" must appear exactly once in the brief; found ' \
                 "#{occurrences.size} at line(s) #{occurrences.map { |_, i| i + 1 }.join(', ')}"

    line, lineno = occurrences.first
    line_no = lineno + 1

    assert line.strip.match?(ROW_RE) && table_line?(line_no),
           "the single \"unknown\" occurrence (line #{line_no}) must be the " \
           'unknown-verdict table row, not prose elsewhere'
  end

  # The brief must peel `$last` to a commit SHA before computing the diff
  # window. The ref object behind $last is either a tag object (annotated
  # tag: the commit lives under the tag object's .object.sha) or the
  # commit itself (lightweight tag: object.type=commit and .object.sha IS
  # the commit SHA), and a non-commit ref (a tree, blob, or stray
  # non-commit object) leaves the peel unresolved. The peel branches on
  # .object.type because /git/tags/<commit sha> 404s — resolving a
  # lightweight tag through the tag-object endpoint would reject a valid
  # release base. The `gh release view` verify and the Compare fetch both
  # happen AFTER the peel, so a failed peel aborts the Decide script
  # before either runs.
  def test_brief_peels_tag_ref_to_commit
    decide_block = extract_decide_block

    assert_match(
      %r{git/ref/tags/\$last},
      decide_block,
      'the brief must call `gh api "repos/.../git/ref/tags/$last"` to peel the tag ref'
    )
    assert_match(
      %r{git/tags/},
      decide_block,
      'the brief must follow the ref peel with a `gh api "repos/.../git/tags/$tag_sha"` ' \
      'to resolve to a commit'
    )

    # The peel must branch on `.object.type`: a lightweight tag's
    # `.object.sha` IS the commit and must be reused directly (a
    # `/git/tags/<commit sha>` call 404s), while an annotated tag peels
    # through the tag object. A jq-fallback regex cannot pin this —
    # `.object.sha` matches `/\.sha\b/` too, so dropping the lightweight
    # path kept that assertion green — hence the branch-shape matches
    # below plus the executable lightweight case
    # (`test_lightweight_tag_peel_reaches_local_fast_path`).
    assert_match(/\.object\.type/, decide_block,
                 'the peel must branch on the ref object `.object.type`')
    assert_match(/\.object\.sha/, decide_block,
                 'the jq filter must reference `.object.sha` (the ref or tag object SHA)')
    assert_match(/commit_sha=\$tag_sha/, decide_block,
                 'the lightweight path (object.type=commit) must reuse `$tag_sha` as the commit SHA directly')

    # The peel must abort (not silently continue) when it cannot resolve
    # to a commit, with a `::error::` GitHub Actions diagnostic so the
    # abort is visible in the workflow log.
    assert_match(/::error::tag/, decide_block,
                 'a failed tag-peel must emit `::error::tag ...` so the abort surfaces in the workflow log')
    assert_match(/exit\s+1/, decide_block,
                 'the tag-peel guard must `exit 1` so the abort propagates to the Decide script')
  end

  # The brief must verify that `$last` is a real, gem-bearing release —
  # the gem-less marker is `author=developerz-ai[bot]` (the maintainer
  # agent's auto-cut) AND/OR `assets.length=0` (RELEASE.md:167-174). The
  # marker arose in the past when a stray tag was reused by the
  # maintainer agent and the GitHub Release was created gem-less. Without
  # this guard, the diff window would be computed against a non-release
  # anchor and the agent would file a `Release <next>` ask on top of
  # work that was never actually shipped.
  def test_brief_verifies_release_gem_less_marker
    decide_block = extract_decide_block

    assert_match(
      /gh\s+release\s+view\s+"\$last"\s+--json\s+author,assets/,
      decide_block,
      'the brief must call `gh release view "$last" --json author,assets` to fetch the release marker'
    )
    assert_match(/\.author\.login/, decide_block,
                 'the release author must be extracted via `.author.login`')
    assert_match(/\.assets\s*\|\s*length/, decide_block,
                 'the assets count must be extracted via `.assets | length`')

    # The bot's GitHub login is the gem-less author marker; pin it as a
    # literal so a future refactor cannot replace the literal with a
    # variable without explicit thought.
    assert_match(/developerz-ai\[bot\]/, decide_block,
                 'the gem-less author marker must be the literal `developerz-ai[bot]`')

    # And the guard must abort (not silently continue) when the release
    # is gem-less, with a `::error::` GitHub Actions diagnostic.
    assert_match(/::error::release/, decide_block,
                 'a gem-less release must emit `::error::release ...` so the abort surfaces in the workflow log')
  end

  # In the new brief, the Compare request (`gh api "repos/.../compare/$last...main"`)
  # is un-captured — there is no `|| { ... exit 1; }` guard, and the diff
  # window itself comes from the local fast path's `git log`. So a Compare
  # failure is NOT an abort path: the script falls through to the local
  # fast path, which uses local git data against `$last..origin/main`.
  # This test pins that contract — a regression that re-adds the OURS-era
  # Compare guard would either change the script's exit status (the
  # guard's `exit 1`) or skip the local fast path (the guard's `exit 1`
  # happens before `git describe`), both of which this test catches. The
  # name retains the OURS-era "aborts" framing as a historical reference;
  # the actual contract pinned here is the OPPOSITE — Compare failure
  # must NOT abort, and the local fast path must still be reached.
  def test_compare_request_failure_aborts_decision_before_local_fast_path
    run_decide_under_stubs(compare_failing_stub_gh) do |(out, err, status), tmpdir|
      fast_path_marker = File.join(tmpdir, 'local_fast_path_reached')

      assert_predicate status, :success?,
                       'Compare failure must fall through to the local fast path ' \
                       "(status=#{status.inspect}, stdout=#{out.inspect}, " \
                       "stderr=#{err.inspect}); the new brief does not guard Compare, " \
                       'so a Compare failure is not an abort path'

      assert fast_path_reached?(fast_path_marker),
             'Compare failure must reach the local fast path (marker not set); ' \
             'the stub `git describe` should have been reached. ' \
             "stdout=#{out.inspect} stderr=#{err.inspect}"
    end
  end

  # End-to-end execution check that pins the tag-peel guard the text-pattern
  # assertions in `test_brief_peels_tag_ref_to_commit` cannot: a regression
  # that pipes `commit_sha` through some shell construct where `exit 1`
  # would only exit the subshell would let the Decide script continue into
  # the release-marker and Compare steps. Run the extracted Bash against
  # stub `gh` and `git` binaries, point the tag-peel stub at failure, and
  # assert the script aborts BEFORE the local fast path's first git command.
  def test_tag_peel_failure_aborts_decision_before_local_fast_path
    assert_decide_aborts_before_local_fast_path(
      stub_gh: tag_peel_failing_stub_gh,
      failing_curl: 'the tag-peel `gh api git/ref/tags/<last>` stub fails',
      failure_message: 'tag-peel failure must abort the Decide script',
      expected_output: '::error::tag v1.8.0 does not resolve to a commit'
    )
  end

  # Same contract for the release gem-less marker: if the release at $last
  # is gem-less (author=developerz-ai[bot] OR assets.length=0), the script
  # must abort BEFORE the local fast path — not let the diff window be
  # computed against a non-release anchor and silently emit a stale ask.
  def test_release_gem_less_failure_aborts_decision_before_local_fast_path
    assert_decide_aborts_before_local_fast_path(
      stub_gh: gem_less_stub_gh,
      failing_curl: 'the gem-less `gh release view <last>` stub returns author=developerz-ai[bot]',
      failure_message: 'gem-less release must abort the Decide script',
      expected_output: '::error::release v1.8.0 is gem-less (author=developerz-ai[bot], assets=0)'
    )
  end

  # The peel guard's success path for a LIGHTWEIGHT tag: the ref object is
  # the commit itself (object.type=commit), so the brief must reuse its
  # `.object.sha` directly — peeling through `/git/tags/<commit sha>`
  # would 404 and reject a valid release base. The stub returns the real
  # `GET /repos/{owner}/{repo}/git/ref/{ref}` payload shape for a
  # lightweight tag and turns any `/git/tags/` call into a tripwire, so a
  # regression that takes the annotated branch fails here with a non-zero
  # exit and no fast-path marker instead of passing.
  def test_lightweight_tag_peel_reaches_local_fast_path
    run_decide_under_stubs(lightweight_tag_stub_gh) do |(out, err, status), tmpdir|
      fast_path_marker = File.join(tmpdir, 'local_fast_path_reached')

      assert_predicate status, :success?,
                       'a lightweight tag (ref object.type=commit) is a valid release base: ' \
                       'the peel must reuse its `.object.sha` directly ' \
                       "(status=#{status.inspect}, stdout=#{out.inspect}, " \
                       "stderr=#{err.inspect})"

      assert fast_path_reached?(fast_path_marker),
             'lightweight-tag peel must reach the local fast path (marker not set); ' \
             'the stub `git describe` should have been reached. ' \
             "stdout=#{out.inspect} stderr=#{err.inspect}"
    end
  end

  # A failed `gh release view` (missing release, rate limit) must abort:
  # with `rel` empty, `.author.login` and `.assets | length` both extract
  # empty, so `author != developerz-ai[bot]` and `nassets != 0` would both
  # hold vacuously and the unverified tag would anchor the decision.
  def test_release_lookup_failure_aborts_decision_before_local_fast_path
    assert_decide_aborts_before_local_fast_path(
      stub_gh: release_lookup_failing_stub_gh,
      failing_curl: 'the `gh release view <last>` stub fails with no stdout',
      failure_message: 'release lookup failure must abort the Decide script',
      expected_output: '::error::release lookup for v1.8.0 failed'
    )
  end

  # The gem-less marker is an OR (author=developerz-ai[bot] OR
  # assets.length=0, RELEASE.md:167-174), but the shared gem-less fixture
  # sets BOTH markers — a guard reduced to either half alone would still
  # pass it. Each fixture below sets exactly one marker and pins that it
  # alone aborts before the local fast path.
  def test_release_bot_author_with_assets_aborts_decision_before_local_fast_path
    assert_decide_aborts_before_local_fast_path(
      stub_gh: bot_author_with_assets_stub_gh,
      failing_curl: 'the `gh release view <last>` stub returns author=developerz-ai[bot] with 1 asset',
      failure_message: 'bot-author release must abort the Decide script',
      expected_output: '::error::release v1.8.0 is gem-less (author=developerz-ai[bot], assets=1)'
    )
  end

  def test_release_non_bot_author_without_assets_aborts_decision_before_local_fast_path
    assert_decide_aborts_before_local_fast_path(
      stub_gh: non_bot_author_no_assets_stub_gh,
      failing_curl: 'the `gh release view <last>` stub returns author=octocat with 0 assets',
      failure_message: 'asset-less release must abort the Decide script',
      expected_output: '::error::release v1.8.0 is gem-less (author=octocat, assets=0)'
    )
  end

  # The window scan is the decision's only window (the Compare call above
  # it is display-only), so the fetch that refreshes BOTH the tag and
  # origin/main must abort on failure: against a stale ref, newly merged
  # shipping commits are invisible and the window collapses to empty.
  # Compare fails first in this stub and must be non-fatal — the abort
  # the test pins comes from the fetch.
  def test_main_fetch_failure_aborts_decision_before_local_fast_path
    assert_decide_aborts_before_local_fast_path(
      stub_gh: compare_failing_stub_gh,
      stub_git: fetch_failing_stub_git,
      failing_curl: 'the `git fetch` stub fails after a non-fatal Compare failure',
      failure_message: 'origin/main fetch failure must abort the Decide script',
      expected_output: '::error::git fetch of tag v1.8.0 / origin main failed'
    )
  end

  # Text-pattern pin: the brief's Decide block MUST detect (or
  # always-unshallow) a shallow checkout, else a depth-1 clone walks
  # `git log "$last"..origin/main` against the existing shallow
  # boundary and silently omits every shipping commit before it — the
  # window reads empty when a release is due, with no error. The
  # sibling tests pin the runtime shape (called on shallow, skipped
  # on complete); this one pins that the brief mentions `--unshallow`
  # at all. A regression that drops the flag passes neither.
  def test_brief_unshallows_when_checkout_is_shallow
    decide_block = extract_decide_block

    assert_match(/--unshallow/, decide_block,
                 'the brief must `git fetch --unshallow origin` when the checkout is shallow, ' \
                 'else the window scan against a depth-1 clone reads from a stale boundary and ' \
                 'misses every shipping commit older than it (the regression in review thread ' \
                 'PRRT_kwDOSi_O686uoG3j)')
  end

  # Runtime pin on the shallow branch: when the checkout pretends to
  # be shallow (`git rev-parse --is-shallow-repository` returns true),
  # the brief MUST call `git fetch --unshallow origin` BEFORE the
  # directed fetch, and the directed fetch must still reach the local
  # fast path's `git describe`. The stub records the `--unshallow`
  # call in a separate marker file so a regression that drops the
  # conditional (or always-unshallows, which errors on a complete
  # repo and is the wrong shape) fails this test.
  def test_brief_unshallows_on_shallow_checkout
    run_decide_under_stubs(lightweight_tag_stub_gh, stub_git: SHALLOW_STUB_GIT) do |(out, err, status), tmpdir|
      fast_path_marker = File.join(tmpdir, 'local_fast_path_reached')
      unshallow_marker = File.join(tmpdir, 'local_fast_path_reached.unshallow')
      combined = out + err

      assert_predicate status, :success?,
                       'shallow checkout + must-reach-fetch+describe: status=' \
                       "#{status.inspect}, stdout=#{out.inspect}, stderr=#{err.inspect}"

      assert File.exist?(unshallow_marker) && File.read(unshallow_marker).include?('UNSHALLOW_REACHED'),
             'a shallow checkout must trigger `git fetch --unshallow origin` BEFORE the directed fetch; ' \
             'marker not set, stderr=' \
             "#{err.inspect}"

      assert fast_path_reached?(fast_path_marker),
             'shallow checkout + --unshallow + directed fetch must reach the local fast path; ' \
             "marker not set, stdout=#{out.inspect}, stderr=#{err.inspect}"

      refute_includes combined, '--unshallow origin failed',
                      'an unshallow failure must NOT print on the success path; ' \
                      "stdout=#{out.inspect}, stderr=#{err.inspect}"
    end
  end

  # Runtime pin on the complete-branch: when the checkout pretends
  # to be complete (`git rev-parse --is-shallow-repository` returns
  # false), the brief MUST NOT call `git fetch --unshallow origin` —
  # the command errors on a complete repo ("on a complete repository
  # does not make sense"), so unconditional unshallow regresses the
  # script on every non-depth-1 checkout. The stub rejects any
  # `--unshallow` invocation; a regression that always-unshallows
  # errors here before the local fast path's first git command.
  def test_brief_skips_unshallow_on_complete_checkout
    run_decide_under_stubs(lightweight_tag_stub_gh, stub_git: NON_SHALLOW_STUB_GIT) do |(out, err, status), tmpdir|
      fast_path_marker = File.join(tmpdir, 'local_fast_path_reached')
      combined = out + err

      assert_predicate status, :success?,
                       'complete checkout must NOT call --unshallow (it errors on a complete repo); ' \
                       "status=#{status.inspect}, stdout=#{out.inspect}, stderr=#{err.inspect}"

      assert fast_path_reached?(fast_path_marker),
             'complete checkout must reach the local fast path; marker not set; ' \
             "stdout=#{out.inspect}, stderr=#{err.inspect}"

      refute_includes combined, '--unshallow origin failed',
                      'complete checkout must not print the unshallow-failure diagnostic; ' \
                      "stdout=#{out.inspect}, stderr=#{err.inspect}"
    end
  end

  # Symmetric failure pin: a shallow checkout whose `--unshallow`
  # call itself fails must abort BEFORE the local fast path (the
  # undirected fetch is not optional on a shallow clone), and the
  # directed fetch must NOT be reached — a regression that ignores
  # the unshallow failure and falls through to the directed fetch
  # surfaces here as the stub's "must not be called" stderr line.
  def test_unshallow_failure_aborts_decision_before_local_fast_path
    assert_decide_aborts_before_local_fast_path(
      stub_gh: lightweight_tag_stub_gh,
      stub_git: UNSHALLOW_FAILING_STUB_GIT,
      failing_curl: 'the `git fetch --unshallow origin` stub fails on a shallow checkout',
      failure_message: 'unshallow failure must abort the Decide script',
      expected_output: '::error::git fetch --unshallow origin failed'
    )
  end

  # The fetch is the only line that refreshes BOTH bounds of the
  # window (`$last` and `origin/main`). Stubs that do not inspect
  # fetch args accept ANY fetch and silently mask a regression that
  # drops the main refspec (so `origin/main` is stale, every shipping
  # commit is invisible, the script returns 0) or drops the tag (so
  # the left bound fails to resolve, `git log` aborts on a different
  # axis). Success-path stub (STUB_GIT_REQUIRES_BOTH_REFSPECS)
  # requires BOTH args; a brief that drops either fails it.
  def test_main_fetch_must_include_tag_and_main_refspec
    run_decide_under_stubs(lightweight_tag_stub_gh,
                           stub_git: STUB_GIT_REQUIRES_BOTH_REFSPECS) do |(out, err, status), tmpdir|
      fast_path_marker = File.join(tmpdir, 'local_fast_path_reached')

      assert_predicate status, :success?,
                       '`git fetch` must include BOTH the tag (v1.8.0) AND the main refspec ' \
                       '(`+refs/heads/main:refs/remotes/origin/main`); without either, the ' \
                       'stale-main regression the stub is meant to catch: ' \
                       "status=#{status.inspect}, stderr=#{err.inspect}"

      assert fast_path_reached?(fast_path_marker),
             'the brief must reach the local fast path when both fetch args are present; ' \
             "marker not set; stdout=#{out.inspect}, stderr=#{err.inspect}"
    end
  end

  # End-to-end check that the brief's window-scan actually filters
  # by pathspec: shipping commits touch `lib/` (or other shipped
  # paths) and appear in the window; docs-only commits touch only
  # `README.md` (or other non-shipped paths) and are excluded;
  # change-then-revert commits both touch `lib/` and BOTH appear
  # because `git log -- <pathspec>` does not net them. The stub-based
  # tests above catch the brief's bash shape; this one catches the
  # git-command shape itself, which the stubs cannot (review thread
  # PRRT_kwDOSi_O686uoG3r).
  def test_window_scan_with_real_repo_filters_shipping_paths_excludes_docs_keeps_revert_pair
    Dir.mktmpdir('wurk-window-repo-') do |tmpdir|
      build_window_repo(tmpdir)
      env = hermetic_git_env(tmpdir)

      window = query_brief_window_log(env)

      assert_predicate window[:status], :success?, window[:message]
      assert_match(/shipping commit on lib/, window[:stdout],
                   "shipping commit (lib/foo.rb) must be in the window: #{window[:stdout].inspect}")
      refute_match(/docs-only commit/, window[:stdout],
                   'docs-only commit (README.md) must NOT be in the window when the brief\'s ' \
                   "shipping pathspecs are applied: #{window[:stdout].inspect}")
      assert_match(/bar add commit/, window[:stdout],
                   'the change half of a change+revert pair (lib/bar.rb add) must be in the ' \
                   'window: ' + window[:stdout].inspect)
      assert_match(/bar revert commit/, window[:stdout],
                   'the revert half of a change+revert pair (lib/bar.rb revert) must be in the ' \
                   'window too — `git log -- <pathspec>` does not net a change against its revert, ' \
                   'so dropping the revert from the listing would require using `git diff` instead, ' \
                   "and the brief uses `git log`: #{window[:stdout].inspect}")
    end
  end

  private

  # Stub `gh` whose Compare `gh api .../compare/<last>...main` call always
  # fails. The matching-refs/tags list, the tag-peel, the commit-resolve,
  # and the release-marker fetch all succeed with non-gem-less output, so
  # the Decide script reaches Compare without aborting. Compare's failure
  # is silent (no `||` guard) — the script falls through to the local fast
  # path. The marker-writing `git describe` stub fires and the script
  # exits 0, which is what `test_compare_request_failure_aborts_decision_
  # before_local_fast_path` pins. A regression that re-adds a Compare
  # `|| { ... exit 1; }` guard would either flip the exit status (caught
  # by the `status.success?` assertion) or skip the marker (caught by the
  # `fast_path_reached?` assertion), so the test catches both.
  COMPARE_FAILING_STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    case "$1" in
      api)
        shift
        url="${1:-}"
        case "$url" in
          *git/matching-refs/tags/*)
            printf '%s\n' '[{"ref":"refs/tags/v1.8.0"}]'
            ;;
          *git/ref/tags/v1.8.0)
            printf '%s\n' '{"object":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","type":"tag"}}'
            ;;
          *git/tags/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
            printf '%s\n' '{"object":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","type":"commit"}}'
            ;;
          *compare/v1.8.0...main)
            printf 'ERROR: stub gh api compare/v1.8.0...main failed (rate-limited or 4xx)\n' >&2
            exit 1
            ;;
          *)
            printf 'ERROR: stub gh api: unexpected URL: %s\n' "$url" >&2
            exit 1
            ;;
        esac
        ;;
      release)
        # Non-gem-less: author is not developerz-ai[bot], assets is non-empty.
        printf '%s\n' '{"author":{"login":"octocat"},"assets":[{"name":"wurk-1.8.0.gem"}]}'
        ;;
      *)
        printf 'ERROR: stub gh: unexpected command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
  SHELL
  private_constant :COMPARE_FAILING_STUB_GH

  # Stub `gh` whose tag-peel `gh api .../git/ref/tags/<last>` call always
  # fails. The matching-refs/tags list succeeds (so $last=v1.8.0), but the
  # peel gets no ref JSON — empty `.object.type` and `.object.sha` — so
  # the guard fires WITHOUT a second, doomed `/git/tags/` call and the
  # script aborts with `::error::tag v1.8.0 does not resolve to a commit`
  # BEFORE the local fast path's first git command. The release and
  # Compare endpoints must NOT be reached — a regression that lets the
  # script continue past the guard would surface here as either the
  # stub's "must not be called" stderr line OR the local-fast-path
  # marker, both of which the test catches.
  TAG_PEEL_FAILING_STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    case "$1" in
      api)
        shift
        url="${1:-}"
        case "$url" in
          *git/matching-refs/tags/*)
            printf '%s\n' '[{"ref":"refs/tags/v1.8.0"}]'
            ;;
          *git/ref/tags/v1.8.0)
            printf 'ERROR: stub gh api git/ref/tags/v1.8.0 failed (rate-limited or 4xx)\n' >&2
            exit 1
            ;;
          *git/tags/*)
            printf 'ERROR: stub gh api git/tags/* must not be called when the ref-peel fails\n' >&2
            exit 1
            ;;
          *compare/*)
            printf 'ERROR: stub gh api compare/* must not be called when the ref-peel fails\n' >&2
            exit 1
            ;;
          *)
            printf 'ERROR: stub gh api: unexpected URL: %s\n' "$url" >&2
            exit 1
            ;;
        esac
        ;;
      release)
        # Must NOT be called: the tag-peel abort fires before the release
        # verify runs. Returning `{}` would still let the gem-less check
        # pass (author=null, nassets=0) and emit the wrong `::error::`
        # diagnostic if the test ever regresses past the peel guard.
        printf 'ERROR: stub gh release must not be called when the ref-peel fails\n' >&2
        exit 1
        ;;
      *)
        printf 'ERROR: stub gh: unexpected command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
  SHELL
  private_constant :TAG_PEEL_FAILING_STUB_GH

  # Stub `gh` whose `gh release view <last>` returns the gem-less marker:
  # author=developerz-ai[bot] AND assets=[]. The matching-refs/tags list,
  # the tag-peel, and the commit-resolve all succeed (so $last=v1.8.0 and
  # the peel produces a valid commit SHA), but the release-marker check
  # fires and the script aborts with
  # `::error::release v1.8.0 is gem-less (author=developerz-ai[bot], assets=0)`
  # BEFORE the local fast path's first git command. The Compare endpoint
  # must NOT be reached — a regression that lets the script continue past
  # the gem-less guard would surface here as either the stub's "must not
  # be called" stderr line OR the local-fast-path marker, both of which
  # the test catches.
  GEM_LESS_STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    case "$1" in
      api)
        shift
        url="${1:-}"
        case "$url" in
          *git/matching-refs/tags/*)
            printf '%s\n' '[{"ref":"refs/tags/v1.8.0"}]'
            ;;
          *git/ref/tags/v1.8.0)
            printf '%s\n' '{"object":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","type":"tag"}}'
            ;;
          *git/tags/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
            printf '%s\n' '{"object":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","type":"commit"}}'
            ;;
          *compare/*)
            printf 'ERROR: stub gh api compare/* must not be called when the release is gem-less\n' >&2
            exit 1
            ;;
          *)
            printf 'ERROR: stub gh api: unexpected URL: %s\n' "$url" >&2
            exit 1
            ;;
        esac
        ;;
      release)
        # gem-less marker: author=developerz-ai[bot], assets=[] (RELEASE.md:167-174).
        printf '%s\n' '{"author":{"login":"developerz-ai[bot]"},"assets":[]}'
        ;;
      *)
        printf 'ERROR: stub gh: unexpected command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
  SHELL
  private_constant :GEM_LESS_STUB_GH

  # Stub `gh` whose `git/ref/tags/<last>` response is a LIGHTWEIGHT tag:
  # the ref object IS the commit (object.type=commit), in the real
  # `GET /repos/{owner}/{repo}/git/ref/{ref}` payload shape. A
  # `/git/tags/` call is a tripwire — a lightweight tag has no tag object
  # to peel and the real endpoint would 404 — so a brief that takes the
  # annotated branch exits non-zero instead of reaching the local fast
  # path. The release is non-gem-less and Compare succeeds, so the whole
  # Decide script runs through to the window scan.
  LIGHTWEIGHT_TAG_STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    case "$1" in
      api)
        shift
        url="${1:-}"
        case "$url" in
          *git/matching-refs/tags/*)
            printf '%s\n' '[{"ref":"refs/tags/v1.8.0"}]'
            ;;
          *git/ref/tags/v1.8.0)
            printf '%s\n' '{"ref":"refs/tags/v1.8.0","node_id":"MDM6UmVmcmVmcz10YWdzL3YxLjguMA","url":"https://api.github.com/repos/developerz-ai/wurk/git/refs/tags/v1.8.0","object":{"sha":"cccccccccccccccccccccccccccccccccccccccc","type":"commit","url":"https://api.github.com/repos/developerz-ai/wurk/git/commits/cccccccccccccccccccccccccccccccccccccccc"}}'
            ;;
          *git/tags/*)
            printf 'ERROR: stub gh api git/tags/* must not be called for a lightweight tag (its ref object is already the commit)\n' >&2
            exit 1
            ;;
          *compare/v1.8.0...main)
            printf '%s\n' '{"status":"diverged","ahead_by":3,"behind_by":0,"total_commits":3}'
            ;;
          *)
            printf 'ERROR: stub gh api: unexpected URL: %s\n' "$url" >&2
            exit 1
            ;;
        esac
        ;;
      release)
        # Non-gem-less: author is not developerz-ai[bot], assets is non-empty.
        printf '%s\n' '{"author":{"login":"octocat"},"assets":[{"name":"wurk-1.8.0.gem"}]}'
        ;;
      *)
        printf 'ERROR: stub gh: unexpected command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
  SHELL
  private_constant :LIGHTWEIGHT_TAG_STUB_GH

  # Stub `gh` whose `gh release view <last>` FAILS with no stdout (a
  # missing release). Everything before it succeeds, so the failure is
  # the lookup itself: with `rel` empty, both extracted fields are empty
  # and both gem-less marker comparisons would pass vacuously. The brief
  # must abort on the lookup; Compare must NOT be reached.
  RELEASE_LOOKUP_FAILING_STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    case "$1" in
      api)
        shift
        url="${1:-}"
        case "$url" in
          *git/matching-refs/tags/*)
            printf '%s\n' '[{"ref":"refs/tags/v1.8.0"}]'
            ;;
          *git/ref/tags/v1.8.0)
            printf '%s\n' '{"object":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","type":"tag"}}'
            ;;
          *git/tags/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
            printf '%s\n' '{"object":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","type":"commit"}}'
            ;;
          *compare/*)
            printf 'ERROR: stub gh api compare/* must not be called when the release lookup fails\n' >&2
            exit 1
            ;;
          *)
            printf 'ERROR: stub gh api: unexpected URL: %s\n' "$url" >&2
            exit 1
            ;;
        esac
        ;;
      release)
        printf 'ERROR: stub gh release view: release v1.8.0 not found\n' >&2
        exit 1
        ;;
      *)
        printf 'ERROR: stub gh: unexpected command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
  SHELL
  private_constant :RELEASE_LOOKUP_FAILING_STUB_GH

  # Exactly ONE gem-less marker: bot author WITH an asset. The shared
  # GEM_LESS_STUB_GH sets both markers, so a guard reduced to the assets
  # half alone would still pass it; here only the author half may fire.
  BOT_AUTHOR_WITH_ASSETS_STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    case "$1" in
      api)
        shift
        url="${1:-}"
        case "$url" in
          *git/matching-refs/tags/*)
            printf '%s\n' '[{"ref":"refs/tags/v1.8.0"}]'
            ;;
          *git/ref/tags/v1.8.0)
            printf '%s\n' '{"object":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","type":"tag"}}'
            ;;
          *git/tags/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
            printf '%s\n' '{"object":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","type":"commit"}}'
            ;;
          *compare/*)
            printf 'ERROR: stub gh api compare/* must not be called when the release is gem-less\n' >&2
            exit 1
            ;;
          *)
            printf 'ERROR: stub gh api: unexpected URL: %s\n' "$url" >&2
            exit 1
            ;;
        esac
        ;;
      release)
        # One marker: author=developerz-ai[bot] but assets is non-empty.
        printf '%s\n' '{"author":{"login":"developerz-ai[bot]"},"assets":[{"name":"wurk-1.8.0.gem"}]}'
        ;;
      *)
        printf 'ERROR: stub gh: unexpected command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
  SHELL
  private_constant :BOT_AUTHOR_WITH_ASSETS_STUB_GH

  # The other single marker: human author with ZERO assets — only the
  # assets half may fire.
  NON_BOT_AUTHOR_NO_ASSETS_STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    case "$1" in
      api)
        shift
        url="${1:-}"
        case "$url" in
          *git/matching-refs/tags/*)
            printf '%s\n' '[{"ref":"refs/tags/v1.8.0"}]'
            ;;
          *git/ref/tags/v1.8.0)
            printf '%s\n' '{"object":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","type":"tag"}}'
            ;;
          *git/tags/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
            printf '%s\n' '{"object":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","type":"commit"}}'
            ;;
          *compare/*)
            printf 'ERROR: stub gh api compare/* must not be called when the release is gem-less\n' >&2
            exit 1
            ;;
          *)
            printf 'ERROR: stub gh api: unexpected URL: %s\n' "$url" >&2
            exit 1
            ;;
        esac
        ;;
      release)
        # One marker: assets=[] but author is not developerz-ai[bot].
        printf '%s\n' '{"author":{"login":"octocat"},"assets":[]}'
        ;;
      *)
        printf 'ERROR: stub gh: unexpected command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
  SHELL
  private_constant :NON_BOT_AUTHOR_NO_ASSETS_STUB_GH

  # Stub `git` whose `fetch` fails — the brief must abort on it instead
  # of scanning the window against a stale origin/main. `describe` still
  # writes the fast-path marker, so a brief that ignores the fetch
  # failure is caught by the marker assertion.
  FETCH_FAILING_STUB_GIT = <<~'SHELL'
    #!/usr/bin/env bash
    if [[ "$1" == "fetch" ]]; then
      printf 'ERROR: stub git fetch failed (network down / stale checkout)\n' >&2
      exit 1
    fi
    if [[ "$1" == "describe" ]]; then
      printf 'LOCAL_FAST_PATH_REACHED\n' > "$WURK_TEST_FAST_PATH_MARKER"
    fi
    exit 0
  SHELL
  private_constant :FETCH_FAILING_STUB_GIT

  # Stub `git` whose `describe` invocation writes a marker file. Every
  # other subcommand is a silent success — the brief's bash reads only
  # `describe`/`fetch`/`log`, and the marker is the signal the test
  # uses to detect whether the Decide script reached the local fast
  # path before aborting.
  STUB_GIT = <<~'SHELL'
    #!/usr/bin/env bash
    if [[ "$1" == "describe" ]]; then
      printf 'LOCAL_FAST_PATH_REACHED\n' > "$WURK_TEST_FAST_PATH_MARKER"
    fi
    exit 0
  SHELL
  private_constant :STUB_GIT

  # Pretends the checkout is a shallow clone (depth-1 from
  # `actions/checkout` with `fetch-depth: 1`). `git rev-parse
  # --is-shallow-repository` prints `true`, so the brief's
  # conditional MUST fire and call `git fetch --unshallow origin`
  # BEFORE the directed fetch. The unshallow call writes a separate
  # UNSHALLOW_REACHED marker so a regression that drops the
  # conditional — or rewrites it as always-unshallow, which errors
  # on a complete repo — is caught by both the marker presence and
  # the follow-up fast-path marker. The directed fetch succeeds
  # silently and `git describe` writes the fast-path marker.
  SHALLOW_STUB_GIT = <<~'SHELL'
    #!/usr/bin/env bash
    if [[ "$1" == "rev-parse" && "$2" == "--is-shallow-repository" ]]; then
      printf 'true\n'
      exit 0
    fi
    if [[ "$1" == "fetch" ]]; then
      if [[ "$*" == *"--unshallow"* ]]; then
        printf 'UNSHALLOW_REACHED\n' > "${WURK_TEST_FAST_PATH_MARKER}.unshallow"
      fi
    fi
    if [[ "$1" == "describe" ]]; then
      printf 'LOCAL_FAST_PATH_REACHED\n' > "$WURK_TEST_FAST_PATH_MARKER"
    fi
    exit 0
  SHELL
  private_constant :SHALLOW_STUB_GIT

  # Pretends the checkout is complete (non-shallow). `git rev-parse
  # --is-shallow-repository` prints `false`, so the brief's
  # conditional MUST skip; the stub rejects any `--unshallow`
  # invocation, so a regression that always-unshallows (which
  # errors on a complete repo) is caught here before the local fast
  # path's first git command. Directed fetch succeeds silently.
  NON_SHALLOW_STUB_GIT = <<~'SHELL'
    #!/usr/bin/env bash
    if [[ "$1" == "rev-parse" && "$2" == "--is-shallow-repository" ]]; then
      printf 'false\n'
      exit 0
    fi
    if [[ "$1" == "fetch" ]]; then
      if [[ "$*" == *"--unshallow"* ]]; then
        printf 'ERROR: stub git must not call --unshallow on a complete checkout\n' >&2
        exit 1
      fi
    fi
    if [[ "$1" == "describe" ]]; then
      printf 'LOCAL_FAST_PATH_REACHED\n' > "$WURK_TEST_FAST_PATH_MARKER"
    fi
    exit 0
  SHELL
  private_constant :NON_SHALLOW_STUB_GIT

  # Pretends the checkout is shallow AND the unshallow fetch fails.
  # Every other subcommand is silent: a regression that lets the
  # script continue past the unshallow failure would surface here
  # as the directed fetch's `git fetch` would still succeed (the
  # stub's narrow tripwire) — so the fast-path marker would be
  # written, and the test catches it via the
  # `assert_decide_aborts_before_local_fast_path` helper's third
  # assertion.
  UNSHALLOW_FAILING_STUB_GIT = <<~'SHELL'
    #!/usr/bin/env bash
    if [[ "$1" == "rev-parse" && "$2" == "--is-shallow-repository" ]]; then
      printf 'true\n'
      exit 0
    fi
    if [[ "$1" == "fetch" ]]; then
      if [[ "$*" == *"--unshallow"* ]]; then
        printf 'ERROR: stub git fetch --unshallow origin failed (network down)\n' >&2
        exit 1
      fi
    fi
    if [[ "$1" == "describe" ]]; then
      printf 'LOCAL_FAST_PATH_REACHED\n' > "$WURK_TEST_FAST_PATH_MARKER"
    fi
    exit 0
  SHELL
  private_constant :UNSHALLOW_FAILING_STUB_GIT

  # Success-path stub for the directed fetch: every subcommand is a
  # silent success EXCEPT `git fetch`, which requires BOTH the tag
  # arg (v1.8.0) AND the explicit main refspec
  # (`+refs/heads/main:refs/remotes/origin/main`). The stub failure
  # message names the missing arg in either case so a regression
  # reading the test output knows which one was dropped. The
  # `STUB_GIT` default would accept any fetch and silently mask a
  # drop of either arg — that is the regression this stub exists
  # to catch.
  STUB_GIT_REQUIRES_BOTH_REFSPECS = <<~'SHELL'
    #!/usr/bin/env bash
    if [[ "$1" == "fetch" ]]; then
      args="$*"
      case "$args" in
        *v1.8.0*'+refs/heads/main:refs/remotes/origin/main'*|*'+refs/heads/main:refs/remotes/origin/main'*v1.8.0*)
          # success — both tag and refspec present, in any order
          ;;
        *)
          printf 'ERROR: stub git fetch must include BOTH the tag arg (v1.8.0) AND the main refspec (+refs/heads/main:refs/remotes/origin/main); got: %s\n' "$args" >&2
          exit 1
          ;;
      esac
    fi
    if [[ "$1" == "describe" ]]; then
      printf 'LOCAL_FAST_PATH_REACHED\n' > "$WURK_TEST_FAST_PATH_MARKER"
    fi
    exit 0
  SHELL
  private_constant :STUB_GIT_REQUIRES_BOTH_REFSPECS

  def compare_failing_stub_gh
    COMPARE_FAILING_STUB_GH
  end

  def tag_peel_failing_stub_gh
    TAG_PEEL_FAILING_STUB_GH
  end

  def gem_less_stub_gh
    GEM_LESS_STUB_GH
  end

  def lightweight_tag_stub_gh
    LIGHTWEIGHT_TAG_STUB_GH
  end

  def release_lookup_failing_stub_gh
    RELEASE_LOOKUP_FAILING_STUB_GH
  end

  def bot_author_with_assets_stub_gh
    BOT_AUTHOR_WITH_ASSETS_STUB_GH
  end

  def non_bot_author_no_assets_stub_gh
    NON_BOT_AUTHOR_NO_ASSETS_STUB_GH
  end

  def fetch_failing_stub_git
    FETCH_FAILING_STUB_GIT
  end

  # End-to-end execution helper. Writes the given `stub_gh` and `stub_git`
  # (default: the marker-writing STUB_GIT) into a temp bin dir, prepends
  # that bin dir to PATH, and runs the Decide block as a stand-alone Bash
  # script. The script is NOT prefixed with `set -euo pipefail` — the
  # brief does not enable any shell options, and injecting them would mask
  # a regression that pipes a guard's `exit 1` through a subshell
  # construct (the inner pipeline's `exit 1` would propagate via
  # `pipefail`, hiding the fact that the subshell exit only reached the
  # subshell). Yields the captured (out, err, status) tuple and the temp
  # dir so callers can assert on stdout, stderr, exit status, and the
  # local-fast-path marker file inside the same `Dir.mktmpdir` scope (the
  # marker is auto-cleaned at block end, so post-yield marker checks
  # would see a deleted file).
  def run_decide_under_stubs(stub_gh, stub_git: STUB_GIT)
    decide_block = extract_decide_block
    skip 'no Decide block' if decide_block.empty?

    Dir.mktmpdir('wurk-brief-stub-') do |tmpdir|
      bin_dir = File.join(tmpdir, 'bin')
      Dir.mkdir(bin_dir)

      gh_path = File.join(bin_dir, 'gh')
      git_path = File.join(bin_dir, 'git')
      File.write(gh_path, stub_gh)
      File.write(git_path, stub_git)
      File.chmod(0o755, gh_path, git_path)

      script_path = File.join(tmpdir, 'decide.sh')
      File.write(script_path, "#!/usr/bin/env bash\n#{decide_block}\n")
      File.chmod(0o755, script_path)

      env = {
        'PATH' => "#{bin_dir}:#{ENV.fetch('PATH', '')}",
        'WURK_TEST_FAST_PATH_MARKER' => File.join(tmpdir, 'local_fast_path_reached')
      }

      result = Open3.capture3(env, script_path)
      yield(result, tmpdir)
    end
  end

  # Drives an abort-path test: the script must exit non-zero AND emit
  # the abort path's diagnostic AND not reach the local fast path's
  # `git describe`. The diagnostic substring pin prevents an unrelated
  # early exit (a regression that drops the abort path entirely, or
  # one where a downstream step fails) from satisfying
  # `refute status.success?` — only the abort path prints this line.
  # The brief's `::error::` guards use bare `echo` (no `>&2`), so the
  # diagnostic goes to stdout; we match against `out + err` so the
  # helper works whether the brief redirects or not.
  def assert_decide_aborts_before_local_fast_path(stub_gh:, failing_curl:, failure_message:,
                                                  expected_output:, stub_git: STUB_GIT)
    run_decide_under_stubs(stub_gh, stub_git: stub_git) do |(out, err, status), tmpdir|
      fast_path_marker = File.join(tmpdir, 'local_fast_path_reached')
      combined = out + err

      refute_predicate status, :success?,
                       "#{failure_message} (status=#{status.inspect}, " \
                       "failing_curl=#{failing_curl}); " \
                       "stdout=#{out.inspect}; stderr=#{err.inspect}"

      assert_includes combined, expected_output,
                      "#{failure_message}: the abort path's expected " \
                      "diagnostic `#{expected_output.inspect}` must be present " \
                      'so an unrelated early exit cannot satisfy this assertion; ' \
                      "got stdout=#{out.inspect}; stderr=#{err.inspect}"

      refute fast_path_reached?(fast_path_marker),
             "#{failure_message} before the local fast path; " \
             'the stub `git describe` was reached, which means the script ran on ' \
             'past its abort — the abort path did not fire, or its `exit 1` was ' \
             'confined to a subshell or pipeline and never reached the Decide script'
    end
  end

  def fast_path_reached?(marker)
    File.exist?(marker) && File.read(marker).include?('LOCAL_FAST_PATH_REACHED')
  end

  def extract_decide_block
    return @extract_decide_block if defined?(@extract_decide_block)

    lines = @text.lines
    decide_idx = lines.index { |l| l.strip == '## Decide' }
    return @extract_decide_block = '' unless decide_idx

    open_idx = lines[decide_idx..].index { |l| l.start_with?('```bash') }
    return @extract_decide_block = '' unless open_idx

    abs_open = decide_idx + open_idx
    close_idx = lines[(abs_open + 1)..].index { |l| l.strip == '```' }
    return @extract_decide_block = '' unless close_idx

    abs_close = abs_open + 1 + close_idx
    @extract_decide_block = lines[(abs_open + 1)...abs_close].join
  end

  def parse_table_rows
    return @parse_table_rows if defined?(@parse_table_rows)

    lines = @text.lines
    header_idx = lines.index { |l| l.strip == '| Window | Do |' }
    @parse_table_rows =
      if header_idx
        rows = []
        lines.drop(header_idx + 1).each do |line|
          stripped = line.strip
          break if stripped.empty?

          match = ROW_RE.match(stripped)
          next unless match

          rows << {
            window: match[:window].strip,
            do: match[:do].strip,
            line: lines.index(line) + 1,
            raw: stripped
          }
        end
        rows
      else
        []
      end
  end

  def unknown_rows_in_table
    parse_table_rows.select { |row| row[:do].start_with?('unknown') }
  end

  def find_table_line_numbers
    parse_table_rows.map { |row| row[:line] }
  end

  def table_line?(line_no)
    find_table_line_numbers.include?(line_no)
  end

  # Execute the brief's command verbatim so its pathspecs, not a test-owned
  # copy, determine the window. Only the release base comes from the fixture.
  def query_brief_window_log(env)
    command = extract_decide_block.lines.find { |line| line.start_with?('git log ') }

    refute_nil command, 'the Decide block must contain a window-scan command'

    stdout, stderr, status = Open3.capture3(
      env.merge('last' => 'v1.0.0'), 'bash', '-c', command,
      chdir: env.fetch('GIT_WORK_TREE')
    )

    {
      stdout: stdout,
      stderr: stderr,
      status: status,
      message: 'extracted brief window command must succeed on a real repo; ' \
               "stderr=#{stderr.inspect}"
    }
  end

  # `refs/remotes/origin/main` points to whatever the local-checkout
  # brief calls `origin/main`. The real-repo test below synthesizes
  # this ref from HEAD so the brief's
  # `git log "$last"..origin/main` walks the same range the brief
  # would on a real fetch: the initial-commit tag is the left bound,
  # every commit since is in the window.
  REMOTE_MAIN_REF = 'refs/remotes/origin/main'
  private_constant :REMOTE_MAIN_REF

  # End-to-end window-scan repo. Materializes a fresh git repo with
  # four commits after the v1.0.0 tag: a shipping commit (lib/foo.rb
  # change), a docs-only commit (README.md change), and a
  # change-then-revert pair on lib/bar.rb. Together they exercise
  # the three shapes the brief's pathspec filter must handle.
  #
  # Uses an isolated env (HOME = tmpdir, GIT_CONFIG_NOSYSTEM = 1,
  # no shared work tree) so no inherited user's git config, hooks,
  # or system gitconfig rewrites the author/committer or short-
  # circuits the test on a host that happens to have `core.hooksPath`
  # pointing at global hooks. Tags v1.0.0 at the initial commit, then
  # creates `REMOTE_MAIN_REF` pointing at HEAD so the brief-style
  # `git log v1.0.0..origin/main` resolves both bounds.
  def build_window_repo(tmpdir)
    env = hermetic_git_env(tmpdir)

    run_git(env, 'init', '--quiet', '--initial-branch=main', tmpdir)
    run_git(env, 'config', 'user.email', 'release-due-brief-test@example.com')
    run_git(env, 'config', 'user.name', 'release-due-brief-test')
    run_git(env, 'config', 'commit.gpgsign', 'false')
    run_git(env, 'config', 'tag.gpgsign', 'false')

    FileUtils.mkdir_p(File.join(tmpdir, 'lib'))
    File.write(File.join(tmpdir, 'README.md'), "Initial README.\n")
    File.write(File.join(tmpdir, 'lib', 'seed.rb'), "# seed line — pre-$last, present at the tag\n")
    run_git(env, 'add', 'README.md', 'lib/seed.rb')
    run_git(env, 'commit', '--quiet', '-m', 'initial commit, tagged as v1.0.0')
    run_git(env, 'tag', 'v1.0.0')

    # Shipping commit: lib/foo.rb change (matches the brief's
    # `lib/**/*.rb` pathspec).
    File.write(File.join(tmpdir, 'lib', 'foo.rb'), "puts 'shipping'\n")
    run_git(env, 'add', 'lib/foo.rb')
    run_git(env, 'commit', '--quiet', '-m', 'shipping commit on lib/foo.rb')

    # Docs-only commit: README.md only (does NOT match the brief's
    # pathspec list).
    File.write(File.join(tmpdir, 'README.md'), "Updated prose only.\n")
    run_git(env, 'add', 'README.md')
    run_git(env, 'commit', '--quiet', '-m', 'docs-only commit on README.md')

    # Change + revert pair: lib/bar.rb added, then removed.
    # `git log -- <pathspec>` lists BOTH commits because the
    # pathspec is "did this commit touch the path", not "is the
    # file different at the tip of this commit". The brief relies
    # on the asker to recognize a no-op pair; this fixture pins that
    # both halves stay in the listing.
    File.write(File.join(tmpdir, 'lib', 'bar.rb'), "puts 'bar'\n")
    run_git(env, 'add', 'lib/bar.rb')
    run_git(env, 'commit', '--quiet', '-m', 'bar add commit')
    run_git(env, 'rm', '--quiet', 'lib/bar.rb')
    run_git(env, 'commit', '--quiet', '-m', 'bar revert commit')

    head_sha = Open3.capture2(env, 'git', 'rev-parse', 'HEAD').first.to_s.strip
    raise 'build_window_repo: empty HEAD SHA' if head_sha.empty?

    run_git(env, 'update-ref', REMOTE_MAIN_REF, head_sha)
  end

  # Env used by every `git` invocation in the real-repo tests.
  # `HOME` is pointed at the temp dir so the test never reads the
  # developer's `~/.gitconfig` and `~/.config/git/attributes` (and
  # never inherits an untrusted `core.hooksPath`), and
  # `GIT_CONFIG_NOSYSTEM=1` blocks `/etc/gitconfig`. Without these
  # a developer-side `core.attributesfile` or a global pre-commit
  # hook could short-circuit the test in ways that pass when the
  # developer's setup is benign and fail (or worse, silently
  # rewrite the repo) when it isn't.
  def hermetic_git_env(tmpdir)
    {
      'GIT_DIR' => File.join(tmpdir, '.git'),
      'GIT_WORK_TREE' => tmpdir,
      'GIT_CONFIG_NOSYSTEM' => '1',
      'HOME' => tmpdir
    }
  end

  def run_git(env, *args)
    stdout, stderr, status = Open3.capture3(env, 'git', *args)
    return stdout if status.success?

    raise "git #{args.inspect} failed in build_window_repo: status=#{status.exitstatus} " \
          "stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
  end
end
