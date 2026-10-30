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
# pins. It also pins the ask section's evidence contract: a `Release <next>`
# ask's body must carry the Decide block's own evidence (verified baseline,
# window list with the oldest commit's date, [Unreleased] contents, <next>
# derivation), never health-checkup items. Reads files and touches no Redis
# or shared state.
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

  # The brief must verify the release's STATE before it uses the release as
  # the diff-window anchor. The state is read from `gh release view
  # "$last" --json author,assets`: the ASSET COUNT is the defect trigger
  # (zero assets => gem-less => abort), and the author is read for context
  # only — a `developerz-ai[bot]`-authored Release that CARRIES the .gem is
  # the sanctioned break-glass manual publish, not a defect, so the brief
  # must NOT treat the author as a gem-less marker (RELEASE.md:180-194).
  # Without this guard, the diff window would be computed against a
  # non-release anchor and the agent would file a `Release <next>` ask on
  # top of work that was never actually shipped.
  #
  # The trigger is pinned BEHAVIOURALLY by the stub-driven tests below
  # (a zero-asset Release aborts; a bot-authored Release carrying the .gem
  # reaches the window scan). No text pin demands the author literal in
  # the Decide block: the author is context there, and a literal pin would
  # re-introduce the rule this change retires.
  def test_brief_verifies_release_state_before_using_it_as_the_anchor
    decide_block = extract_decide_block

    assert_match(
      /gh\s+release\s+view\s+"\$last"\s+--json\s+author,assets/,
      decide_block,
      'the brief must call `gh release view "$last" --json author,assets` to fetch the release state'
    )
    assert_match(/\.author\.login/, decide_block,
                 'the release author must be extracted via `.author.login`')
    assert_match(/\.assets\s*\|\s*length/, decide_block,
                 'the assets count must be extracted via `.assets | length`')

    # The assets count is the trigger: the guard must compare it against 0
    # and abort when it IS 0.
    assert_match(/\[ "\$nassets" != "0" \]/, decide_block,
                 'the gem-less guard must trigger on the ASSET COUNT (`nassets` == 0), ' \
                 'not on the author — a bot-authored Release carrying the .gem is a real release')

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

  # Same contract for the gem-less state: if the release at $last carries
  # ZERO assets (the gem-less marker), the script must abort BEFORE the
  # local fast path — not let the diff window be computed against a
  # non-release anchor and silently emit a stale ask. The author is
  # context in the diagnostic, not the trigger.
  def test_release_gem_less_failure_aborts_decision_before_local_fast_path
    assert_decide_aborts_before_local_fast_path(
      stub_gh: gem_less_stub_gh,
      failing_curl: 'the gem-less `gh release view <last>` stub returns zero assets',
      failure_message: 'gem-less release must abort the Decide script',
      expected_output: '::error::release v1.8.0 is gem-less (assets=0, author=developerz-ai[bot])'
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
  # empty, so the asset comparison would pass vacuously and the unverified
  # tag would anchor the decision. The diagnostic must CLASSIFY the
  # absent-Release state instead of reporting one undifferentiated error:
  # no Release read means the state is unclassified, and the three open
  # possibilities (a release.yml preflight no-op, a break-glass
  # publication, a failure before the Release was created) all stay open
  # until the RubyGems probe and the last release.yml run corroborate
  # which one it was. RubyGems is the authority, not the absence of a
  # Release.
  def test_release_lookup_failure_aborts_decision_before_local_fast_path
    assert_decide_aborts_before_local_fast_path(
      stub_gh: release_lookup_failing_stub_gh,
      failing_curl: 'the `gh release view <last>` stub fails with no stdout',
      failure_message: 'release lookup failure must abort the Decide script',
      expected_output: '::error::release lookup for v1.8.0 failed'
    )
  end

  # The classified diagnostic must name what the absent-Release state can
  # be, and point at the evidence that settles it — otherwise the abort is
  # an undifferentiated error and the reader is left to guess whether
  # anything shipped.
  def test_release_lookup_failure_diagnostic_classifies_the_absent_release_state
    decide_block = extract_decide_block

    assert_match(/release lookup for \$\{?last\}? failed/, decide_block,
                 'the release lookup failure must name the tag it failed for')

    ['preflight', 'break-glass', 'failure before the Release was created'].each do |possibility|
      assert_includes decide_block, possibility,
                      'the absent-Release diagnostic must name the possibility ' \
                      "#{possibility.inspect} — an undifferentiated error leaves the " \
                      'reader guessing whether anything shipped'
    end

    assert_includes decide_block, 'rubygems.org/api/v2/rubygems/wurk/versions/',
                    'the absent-Release diagnostic must point at the RubyGems per-version ' \
                    'probe: RubyGems is the authority on publication, not the absence of a Release'

    assert_match(/release\.yml/, decide_block,
                 'the absent-Release diagnostic must point at the last release.yml run as the ' \
                 'other half of the corroboration')

    assert_includes decide_block, 'Release states',
                    "the absent-Release diagnostic must point at RELEASE.md's 'Release states' " \
                    'section, which classifies each state and names the destructive-recovery ' \
                    'runbook — a reader who hits this abort needs to know where the states are ' \
                    'defined'
  end

  # Zero assets is the gem-less MARKER, but not by itself proof that no gem
  # shipped: release.yml pushes the gem BEFORE it creates the Release and
  # uploads the `.gem` asset, so a succeeded push followed by a failed
  # asset upload leaves a zero-asset Release on a version RubyGems has
  # already burned. The deletion runbook's own safety argument ("only safe
  # because no gem was ever published") therefore needs the per-version
  # RubyGems probe to confirm non-publication first — the precondition
  # RELEASE.md's "Release states" table puts on the zero-asset row (review
  # thread PRRT_kwDOSi_O686v4LZ6). A diagnostic that names the runbook on
  # the asset count alone directs the reader at a destructive recovery a
  # published version must never take.
  def test_gem_less_diagnostic_requires_rubygems_probe_before_the_deletion_runbook
    decide_block = extract_decide_block

    guard_line = decide_block.lines.find do |line|
      line.include?('::error::release') && line.include?('is gem-less')
    end

    refute_nil guard_line, 'the Decide block must keep the gem-less guard'

    assert_includes guard_line, 'rubygems.org/api/v2/rubygems/wurk/versions/',
                    'the gem-less diagnostic must require the per-version RubyGems probe: ' \
                    'zero assets is also the shape of a succeeded gem push whose Release ' \
                    'asset upload failed, so the destructive runbook needs non-publication ' \
                    'confirmed before it is named'

    assert_match(/never published|shows no gem|not been published/, guard_line,
                 'the gem-less diagnostic must make confirmed non-publication — not the ' \
                 'asset count alone — the runbook precondition')
  end

  # The prose carries the same precondition: zero assets is the marker the
  # checkup aborts on, while the deletion runbook it points at stays gated
  # behind probe-confirmed non-publication. The retired sentence ("zero
  # assets is the gem-less marker: no gem shipped") asserted the very
  # inference the push-then-failed-upload window breaks.
  def test_prose_gates_the_deletion_runbook_behind_probe_confirmed_non_publication
    after_fence = @text.split(/^```\s*$/, 2)[1] || ''
    paragraph = after_fence.split(/\n\s*\n/).find { |p| p.include?('release-deletion runbook') }

    refute_nil paragraph,
               'the brief\'s prose must keep the paragraph naming the release-deletion runbook'

    assert_match(/not proof|not by itself proof|not evidence/i, paragraph,
                 'the prose must state that zero assets alone does not establish that no ' \
                 'gem shipped: release.yml pushes the gem before it creates the Release and ' \
                 'uploads the asset, so a succeeded push with a failed upload leaves zero ' \
                 'assets on a version RubyGems has already burned')

    assert_match(/probe/i, paragraph,
                 'the prose must gate the release-deletion runbook behind the per-version ' \
                 'RubyGems probe')

    assert_match(/never published|not been published|no gem was published/, paragraph,
                 'the prose must require the probe to confirm non-publication before the ' \
                 'release-deletion runbook applies')
  end

  # The gem-less trigger is the ASSET COUNT alone. A Release authored by
  # `developerz-ai[bot]` that CARRIES the .gem is the sanctioned break-glass
  # manual publish — a real release — so it must NOT abort: the script has
  # to go on to the local fast path and compute the window against it. An
  # earlier rule treated the author as a marker of its own and aborted here,
  # filing a false "gem-less" defect over a perfectly good release and
  # hiding the window behind it.
  def test_release_bot_author_with_assets_reaches_the_window_scan
    run_decide_under_stubs(bot_author_with_assets_stub_gh) do |(out, err, status), tmpdir|
      combined = out + err

      assert_predicate status, :success?,
                       'a bot-authored Release that carries the .gem is a sanctioned manual ' \
                       'release, not a defect: it must NOT abort the Decide script ' \
                       "(status=#{status.inspect}, stdout=#{out.inspect}, stderr=#{err.inspect})"

      refute_includes combined, '::error::release',
                      'a bot-authored Release carrying the .gem must not be reported as ' \
                      "gem-less; stdout=#{out.inspect} stderr=#{err.inspect}"

      assert window_scan_reached?(File.join(tmpdir, 'local_fast_path_reached.log')),
             'a bot-authored Release carrying the .gem must reach the window scan; the stub ' \
             "`git log` was not reached (stdout=#{out.inspect}, stderr=#{err.inspect})"
    end
  end

  def test_release_non_bot_author_without_assets_aborts_decision_before_local_fast_path
    assert_decide_aborts_before_local_fast_path(
      stub_gh: non_bot_author_no_assets_stub_gh,
      failing_curl: 'the `gh release view <last>` stub returns author=octocat with 0 assets',
      failure_message: 'asset-less release must abort the Decide script',
      expected_output: '::error::release v1.8.0 is gem-less (assets=0, author=octocat)'
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

  # The tag listing is PAGINATED, and the pagination — not a page size —
  # is the resolver's completeness argument. `git/matching-refs` serves
  # its refs in pages; `gh api --paginate` follows the API's link
  # headers through every page and merges them into one array, so a
  # matching tag that sits on a later page is still enumerated before
  # `sort -V | tail -1` picks the highest version. Without the flag only
  # the first page comes back, and the highest version SEEN is then only
  # the highest version on that page.
  #
  # This is a BEHAVIOURAL pin, not a text-shape check: the stub's
  # listing depends on whether `--paginate` was passed, and its peel
  # branch answers ONLY for the newer tag. A resolver that lost the flag
  # selects the stale first-page tag, the peel of that tag is refused,
  # and the Decide script aborts before the window scan — so the test
  # fails. The stub returns the already-merged page set, so this pin
  # proves that pagination is requested; it does not independently
  # prove that a resolver merges pages returned by a different client.
  def test_tag_listing_is_paginated_so_a_later_page_highest_tag_is_found
    run_decide_under_stubs(paginated_tags_stub_gh) do |(out, err, status), tmpdir|
      combined = out + err
      window_marker = File.join(tmpdir, 'local_fast_path_reached.log')

      refute_match(/v1\.8\.0/, combined,
                   'the resolver must request the paginated tag listing and select its ' \
                   'highest tag; it selected the stale first-page tag, so the tag listing ' \
                   "was not paginated: stdout=#{out.inspect}, stderr=#{err.inspect}")

      assert_predicate status, :success?,
                       'the paginated tag listing must let the Decide script reach the ' \
                       "window scan (status=#{status.inspect}, stdout=#{out.inspect}, " \
                       "stderr=#{err.inspect})"

      assert window_scan_reached?(window_marker),
             'the Decide script must compute the window on the newest tag, which is ' \
             'only reachable when the tag listing is paginated (marker not set); ' \
             "stdout=#{out.inspect}, stderr=#{err.inspect}"
    end
  end

  # Structural companion to the behavioural pin above: the resolver's
  # listing call must carry `--paginate`, and its completeness must NOT
  # rest on a fixed page size. `per_page` bounds one page, never the
  # number of refs the repository holds, so a listing that asks for a
  # large page is still an incomplete listing — the flag is what makes
  # the walk reach the end of the list.
  def test_brief_resolves_last_through_a_paginated_tag_listing
    decide_block = extract_decide_block

    assert_match(%r{gh\s+api\s+--paginate\s+repos/developerz-ai/wurk/git/matching-refs/tags/},
                 decide_block,
                 'the tag listing must be fetched with `gh api --paginate` so every page ' \
                 'of matching refs is enumerated')

    resolver_line = decide_block.lines.find { |line| line.include?('matching-refs/tags/') }

    refute_nil resolver_line,
               'the Decide block must resolve $last from the matching-refs listing'

    refute_match(/per_page/, resolver_line,
                 'a fixed page size is not a completeness argument: the listing is complete ' \
                 'because it is paginated, not because it asks for a large page')
  end

  # The brief's own prose must carry the same argument: completeness of
  # the tag listing comes from the pagination, and a fixed page size is
  # explicitly not what makes it complete.
  def test_brief_attributes_tag_listing_completeness_to_pagination
    assert_match(/completeness[^.]*paginat/i, @text,
                 'the brief must state that the tag listing is complete because it is ' \
                 'paginated, not because of a page size')

    refute_match(/per_page=[^\s`]*[^.]*proves/i, @text,
                 'the brief must not claim that a fixed page size proves every matching ' \
                 'tag was considered')
  end

  # The release baseline: the peeled commit must BE the release commit for
  # the tag's version. A tag alone proves little — a re-used or hand-cut tag
  # points at a commit that never shipped a version, and a window computed
  # from it is a window since the wrong anchor. The baseline check therefore
  # runs BEFORE any window work and aborts the block when it does not
  # verify: the version's dated CHANGELOG heading must be present at the
  # peeled commit, carry that commit's own committer date, and be absent at
  # the commit's first parent (the commit introduced it).
  #
  # These tests RUN the extracted Decide block against stub `gh`/`git`
  # binaries. The window scan is the decision's only window, so the stub
  # `git log` marker is the signal that a window was computed at all: on
  # every abort path it must stay unset.
  def test_baseline_verified_reaches_window_for_annotated_tag
    assert_baseline_reaches_window(baseline_stub_gh, shape: 'annotated')
  end

  # The same baseline, on the LIGHTWEIGHT tag shape: the ref object is the
  # commit itself, so the check has to run on the commit the lightweight
  # peel produced — a check pinned to the annotated path would leave this
  # shape unverified.
  def test_baseline_verified_reaches_window_for_lightweight_tag
    assert_baseline_reaches_window(lightweight_tag_stub_gh, shape: 'lightweight')
  end

  # The heading's date and the commit's committer date must be the same
  # day: a heading dated for another day means the commit is not the
  # release commit the version was cut on.
  def test_baseline_commit_date_mismatch_aborts_before_window_scan
    assert_baseline_abort_before_window_scan(
      mode: 'date-mismatch',
      expected_output: '::error::baseline 1.8.0 heading date 2026-10-05 does not match ' \
                       'the committer date 2026-10-06'
    )
  end

  # The version's dated heading must be AT the peeled commit — a commit
  # without it never shipped the version.
  def test_baseline_heading_missing_at_commit_aborts_before_window_scan
    assert_baseline_abort_before_window_scan(
      mode: 'missing-heading',
      expected_output: 'has no dated heading for 1.8.0'
    )
  end

  # ...and it must be ABSENT at the commit's first parent: a heading that
  # is already there means the tagged commit did not introduce the
  # release, so it is not the release commit.
  def test_baseline_heading_already_present_at_parent_aborts_before_window_scan
    assert_baseline_abort_before_window_scan(
      mode: 'parent-has-it',
      expected_output: '::error::baseline 1.8.0 heading is already present at the first parent'
    )
  end

  # A read that cannot run is a failed baseline, not a passed one: the
  # check must abort rather than treat an unreadable CHANGELOG as a
  # verified release commit.
  def test_baseline_unreadable_changelog_aborts_before_window_scan
    assert_baseline_abort_before_window_scan(
      mode: 'unreadable',
      expected_output: '::error::baseline CHANGELOG.md at'
    )
  end

  # The baseline check must sit between the gem-less guard and the window
  # work: a baseline that does not verify has to abort BEFORE the Compare
  # call and the local fast path, so no window is computed on it — and a
  # gem-less release must never get to establish a baseline at all.
  def test_brief_verifies_the_baseline_before_any_window_work
    decide_block = extract_decide_block

    gemless_idx = decide_block.index('::error::release')
    baseline_idx = decide_block.index('::error::baseline')
    compare_idx = decide_block.index('compare/$last...main')
    window_idx = decide_block.index('git log ')

    refute_nil baseline_idx,
               'the Decide block must guard the release baseline with an ' \
               '`::error::baseline ...` diagnostic'
    refute_nil gemless_idx, 'the Decide block must keep the gem-less guard'
    refute_nil compare_idx, 'the Decide block must keep the Compare call'
    refute_nil window_idx, 'the Decide block must keep the window scan'

    assert_operator gemless_idx, :<, baseline_idx,
                    'the baseline check must run AFTER the gem-less guard: a gem-less release ' \
                    'must never establish the baseline'
    assert_operator baseline_idx, :<, compare_idx,
                    'the baseline check must run BEFORE the Compare call'
    assert_operator baseline_idx, :<, window_idx,
                    'the baseline check must run BEFORE the window scan: no window may be ' \
                    'computed on an unverified baseline'
  end

  # The baseline is resolved and verified at RUN TIME: the brief names no
  # concrete release tag, so a stale literal cannot pin the check to a
  # version that was never released.
  def test_brief_names_no_concrete_release_tag
    matches = @text.scan(/\bv\d+\.\d+\.\d+\b/)

    assert_empty matches,
                 'the brief must resolve the release tag at run time, not name a ' \
                 "concrete one: found #{matches.inspect}"
  end

  # The check READS the release; it never repairs it. A tag deletion (or
  # any other remote-tag write) in the brief would turn a read-only
  # checkup into a mutation of the release lane's own output.
  def test_brief_adds_no_tag_deletion_or_remote_tag_operation
    forbidden = ['gh release delete', '--cleanup-tag', 'git tag -d', 'git push --delete',
                 'git push origin :refs/tags', 'git push --force']

    found = forbidden.select { |operation| @text.include?(operation) }

    assert_empty found,
                 "the brief must not delete or rewrite a release tag: found #{found.inspect}"
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
  # The ask section ('## The ask, when due') must state what a
  # `Release <next>` ask's BODY carries: the Decide block's own evidence, so
  # the release actor re-grades the decision without re-running it — the
  # verified baseline (the resolved tag and its peeled commit), the window
  # commit list with the oldest shipping commit's date (the figure the 24 h
  # row grades), the [Unreleased] contents the derivation read, and <next>
  # with the rule that derived it (### Added / feat -> minor, else patch).
  # Health-checkup items (CI verdicts, a RubyGems probe of the current
  # version, demo state) are other briefs' evidence and must be ruled out.
  def test_ask_section_pins_the_release_ask_body_evidence_contract
    ask_section = extract_ask_section

    refute_empty ask_section,
                 '.dz/briefs/release-due.md must keep its "## The ask, when due" section'

    assert_match(/body/i, ask_section,
                 'the ask section must state what the Release <next> ask\'s body carries')

    assert_match(/\$last.*peeled|peeled.*\$last|\$last.*baseline|baseline.*\$last/im,
                 ask_section,
                 'the body must carry the verified baseline: the resolved $last tag and ' \
                 'its peeled release commit')

    assert_match(/oldest[^.]*(?:commit)[^.]*(?:timestamp|date)|(?:timestamp|date)[^.]*oldest/i,
                 ask_section,
                 'the body must carry the window commit list with the oldest shipping ' \
                 'commit\'s date — the figure the 24 h row grades')

    contract = extract_ask_body_contract

    refute_empty contract,
                 '.dz/briefs/release-due.md must keep its "The ask\'s body carries" ' \
                 'evidence contract paragraph'

    # Tied to CHANGELOG and scoped to the contract bullets: step 3 and the
    # <next> derivation rule mention [Unreleased] too, so a section-wide
    # /\[Unreleased\]/ match would survive the bullet being deleted.
    assert_match(/\[Unreleased\][^.\n]*CHANGELOG|CHANGELOG[^.\n]*\[Unreleased\]/im, contract,
                 'the body must carry the [Unreleased] CHANGELOG contents the <next> ' \
                 'derivation read')

    assert_match(/### Added.*(?:feat|minor)|(?:feat|minor).*### Added/im, ask_section,
                 'the body must carry <next> with its derivation rule: ### Added or a ' \
                 'feat subject -> minor, anything else -> patch')

    # Scoped to the contract bullets: step 3 already says "`wurk.gemspec` IS
    # one of the seven paths, so a Dependabot PR", so a section-wide match
    # would survive the bullet being deleted.
    assert_match(/dependabot[^.]*wurk\.gemspec|wurk\.gemspec[^.]*dependabot/im,
                 contract,
                 'the body must carry any in-window merged Dependabot PR that touched ' \
                 'wurk.gemspec, with the ### Changed line it owes')

    assert_match(/not ask evidence|never substitute|do not belong|ruled? out/i,
                 ask_section,
                 'the ask section must rule out health-checkup items as ask evidence')

    assert_match(/CI|main[^.]*green|green[^.]*main/i, ask_section,
                 'CI verdicts on main are health-checkup evidence and must be named ' \
                 'among the ruled-out items')

    assert_match(/rubygems/i, ask_section,
                 'a RubyGems probe of the current version is health-checkup evidence ' \
                 'and must be named among the ruled-out items')

    # Scoped to the health-checkup ruling paragraph: step 4's
    # `release:relock_demo` would satisfy a section-wide /demo/i match even
    # with demo state dropped from the ruled-out items.
    assert_match(/demo/i, extract_health_checkup_ruling,
                 'demo state is health-checkup evidence and must be named among the ' \
                 'ruled-out items')
  end

  # The pre-flight guard (ask step 1) carries the lane's credential
  # contract, and this file machine-gates brief contracts the way it
  # gates the --unshallow flag (test_brief_unshallows_when_checkout_is_shallow),
  # the --paginate listing (test_brief_resolves_last_through_a_paginated_tag_listing)
  # and the forbidden tag operations
  # (test_brief_adds_no_tag_deletion_or_remote_tag_operation): deleting
  # the credential sentence — or growing it into a credential fixture —
  # must fail here. Positive pins run against the pre-flight step ALONE:
  # the ask section and the Decide block mention `gh` for other reasons,
  # so a section-wide match would survive the sentence's deletion. The
  # negative pins scan the whole brief, because a leaked value anywhere
  # in it is a leak.
  def test_pre_flight_guard_names_gh_token_interface_and_stays_credential_free
    pre_flight = extract_pre_flight_guard

    refute_empty pre_flight,
                 '.dz/briefs/release-due.md must keep its "Pre-flight guard" ask step'

    # The surface check stays: eligibility is verified with
    # `gh auth status` before the ask is filed at all.
    assert_includes pre_flight, 'gh auth status',
                    'the pre-flight guard must still verify capability with `gh auth status`'

    # GH_TOKEN is the named credential interface.
    assert_match(/credential interface[^.\n]{0,80}GH_TOKEN/i, pre_flight,
                 'the pre-flight guard must name `GH_TOKEN` as `gh`\'s standard credential interface')

    # ...and the non-Actions executor must have it injected SECURELY,
    # at the point of use — not read from a file, a dotfile or a
    # provisioning step the brief might otherwise grow.
    assert_match(/non-Actions executor[^.\n]*GH_TOKEN[^.\n]*securely injected[^.\n]*point of use/i,
                 pre_flight,
                 'the pre-flight guard must require a non-Actions executor to have `GH_TOKEN` ' \
                 'securely injected at its point of use')

    # The paragraph keeps its own scope statement: the variable name
    # only, never a token value, a storage location, or a provisioning
    # mechanism.
    assert_match(/never a token value[^.\n]*storage[^.\n]*provisioning/i, pre_flight,
                 'the pre-flight guard must keep its scope statement: it documents the ' \
                 'variable name only')

    # No token value: a GitHub token literal — classic `ghp_`/`gho_`/
    # `ghu_`/`ghs_`/`ghr_` or fine-grained `github_pat_` — anywhere in
    # the brief is a leaked credential, whatever sentence carries it.
    refute_match(/gh[posur]_[0-9a-zA-Z]{16,}/, @text,
                 'the brief must not carry a classic GitHub token literal (ghp_/gho_/ghu_/ghs_/ghr_)')
    refute_match(/github_pat_[0-9a-zA-Z_]{20,}/, @text,
                 'the brief must not carry a fine-grained GitHub token literal (github_pat_)')

    # No credential-dumping command: a line that prints the token would
    # make the brief the exfiltration step.
    refute_match(/(?:echo|printf|printenv)[^;`\n]*\bGH_TOKEN\b/, @text,
                 'the brief must not carry a command that echoes or prints GH_TOKEN')
    refute_match(/gh auth token\b/, @text,
                 'the brief must not carry `gh auth token`, which prints the stored credential')
    refute_match(/\b(?:env|set)\b[^;`\n]*\|\s*(?:grep|rg|awk)\b[^;`\n]*GH_TOKEN/i, @text,
                 'the brief must not filter the environment through a command that prints GH_TOKEN')

    # No storage or commit instruction: the credential stays the
    # executor's to supply, at the point of use.
    refute_match(/(?:store|save|persist|write|commit)[^.;\n]*(?:token|credential|GH_TOKEN)s?\s+(?:in|to|into)\b/i,
                 @text,
                 'the brief must not instruct a reader to store, persist, or commit a credential')
    refute_match(/\.env\b|\.netrc\b|keychain|secrets?\s+file/i, @text,
                 'the brief must not name a storage location for the credential')
  end

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
                   "window: #{window[:stdout].inspect}")
      assert_match(/bar revert commit/, window[:stdout],
                   'the revert half of a change+revert pair (lib/bar.rb revert) must be in the ' \
                   'window too — `git log -- <pathspec>` does not net a change against its revert, ' \
                   'so dropping the revert from the listing would require using `git diff` instead, ' \
                   "and the brief uses `git log`: #{window[:stdout].inspect}")
    end
  end

  # The brief's window pathspec (.dz/briefs/release-due.md:53) must cover
  # every source path whose change reaches the gem. The dashboard is the
  # trap: `frontend/index.html` (Vite turns it into
  # vendor/assets/dashboard/index.html) and `frontend/public/**` (copied
  # verbatim: favicon, og-image, apple-touch-icon, wurk-logo) both ship in
  # the gem (wurk.gemspec ships vendor/assets/dashboard/**/*), and neither
  # sits under `frontend/src/**`. While the pathspec named only
  # `frontend/src/**`, a window whose only shipping commit was one of them
  # scanned EMPTY, and the Window/Do table grades an empty window "nothing"
  # — no release ask for a gem that changed. Both windows below are
  # checked: one where the frontend commits share the window with lib/
  # changes, one where they are all the window holds.
  #
  # This gate holds that pathspec in place: drop `frontend/index.html` or
  # `frontend/public/**` from it and the test goes red again, because the
  # brief's OWN `git log` command is what runs here — a test-owned
  # pathspec would prove nothing about the brief.
  def test_window_scan_includes_the_frontend_paths_that_reach_the_gem
    problems = []

    Dir.mktmpdir('wurk-window-repo-') do |tmpdir|
      build_window_repo(tmpdir)
      window = query_brief_window_log(hermetic_git_env(tmpdir))

      assert_predicate window[:status], :success?, window[:message]
      problems.concat(window_listing_problems(window[:stdout], 'the full window'))
    end

    Dir.mktmpdir('wurk-frontend-window-repo-') do |tmpdir|
      build_window_repo(tmpdir, frontend_only: true)
      window = query_brief_window_log(hermetic_git_env(tmpdir))

      assert_predicate window[:status], :success?, window[:message]
      problems.concat(window_listing_problems(window[:stdout], 'the frontend-only window'))
    end

    assert_empty problems,
                 'the brief\'s window pathspec (.dz/briefs/release-due.md:53) must list every ' \
                 'commit whose change reaches the gem: `frontend/index.html` and ' \
                 '`frontend/public/**` reach it (Vite builds them into vendor/assets/dashboard/**, ' \
                 'which wurk.gemspec ships), so a frontend-only window must not scan empty — the ' \
                 "Window/Do table grades it \"nothing\":\n- #{problems.join("\n- ")}"
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
        # The endpoint URL is the first NON-FLAG argument after `api`: a
        # flag such as `--paginate` may precede it, and a header value
        # may follow it.
        url=""
        for arg in "$@"; do
          case "$arg" in
            -*) ;;
            *) url="$arg"; break ;;
          esac
        done
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
          *commits/bbbb*)
            printf '%s\n' '{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","commit":{"committer":{"date":"2026-10-05T09:00:00Z"}},"parents":[{"sha":"dddddddddddddddddddddddddddddddddddddddd"}]}'
            ;;
          *contents/CHANGELOG.md*)
            case "$url" in
              *ref=bbbb*)
                printf '%s\n' '## [Unreleased]' '' '## [1.8.0] - 2026-10-05' '' '- the release commit'
                ;;
              *ref=dddd*)
                printf '%s\n' '## [Unreleased]' '' '## [1.7.9] - 2026-09-30' '' '- an older release'
                ;;
              *)
                printf 'ERROR: stub gh api: unexpected CHANGELOG ref: %s\n' "$url" >&2
                exit 1
                ;;
            esac
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
        # The endpoint URL is the first NON-FLAG argument after `api`: a
        # flag such as `--paginate` may precede it, and a header value
        # may follow it.
        url=""
        for arg in "$@"; do
          case "$arg" in
            -*) ;;
            *) url="$arg"; break ;;
          esac
        done
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

  # Stub `gh` whose `gh release view <last>` returns the gem-less state:
  # ZERO assets, authored by developerz-ai[bot]. The matching-refs/tags
  # list, the tag-peel, and the commit-resolve all succeed (so $last=v1.8.0
  # and the peel produces a valid commit SHA), but the gem-less guard
  # fires on the asset count and the script aborts with
  # `::error::release v1.8.0 is gem-less (assets=0, author=developerz-ai[bot])`
  # BEFORE the local fast path's first git command. The baseline reads and
  # the Compare endpoint must NOT be reached — a regression that lets the
  # script continue past the gem-less guard would surface here as either
  # the stub's "must not be called" stderr line OR the local-fast-path
  # marker, both of which the test catches.
  GEM_LESS_STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    case "$1" in
      api)
        shift
        # The endpoint URL is the first NON-FLAG argument after `api`: a
        # flag such as `--paginate` may precede it, and a header value
        # may follow it.
        url=""
        for arg in "$@"; do
          case "$arg" in
            -*) ;;
            *) url="$arg"; break ;;
          esac
        done
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
          *commits/*|*contents/CHANGELOG.md*)
            printf 'ERROR: stub gh api: the release baseline must not be read when the release is gem-less\n' >&2
            exit 1
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
        # gem-less state: zero assets (RELEASE.md:180-194).
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
        # The endpoint URL is the first NON-FLAG argument after `api`: a
        # flag such as `--paginate` may precede it, and a header value
        # may follow it.
        url=""
        for arg in "$@"; do
          case "$arg" in
            -*) ;;
            *) url="$arg"; break ;;
          esac
        done
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
          *commits/cccc*)
            printf '%s\n' '{"sha":"cccccccccccccccccccccccccccccccccccccccc","commit":{"committer":{"date":"2026-10-05T09:00:00Z"}},"parents":[{"sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}]}'
            ;;
          *contents/CHANGELOG.md*)
            case "$url" in
              *ref=cccc*)
                printf '%s\n' '## [Unreleased]' '' '## [1.8.0] - 2026-10-05' '' '- the release commit'
                ;;
              *ref=eeee*)
                printf '%s\n' '## [Unreleased]' '' '## [1.7.9] - 2026-09-30' '' '- an older release'
                ;;
              *)
                printf 'ERROR: stub gh api: unexpected CHANGELOG ref: %s\n' "$url" >&2
                exit 1
                ;;
            esac
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

  # One stub, five baseline outcomes, selected by $WURK_TEST_BASELINE_MODE:
  #   ok              the baseline verifies (the tagged commit IS the release commit)
  #   date-mismatch   the CHANGELOG heading's date != the commit's committer date
  #   missing-heading the commit carries no dated heading for the version
  #   parent-has-it   the heading is already present at the commit's first parent
  #   unreadable      the CHANGELOG read at the commit fails
  # The tag shape here is ANNOTATED (the ref object is a tag object, peeled
  # through /git/tags/); the LIGHTWEIGHT shape is covered by
  # LIGHTWEIGHT_TAG_STUB_GH, which carries the same baseline reads for the
  # commit its lightweight peel produces.
  BASELINE_STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    mode="${WURK_TEST_BASELINE_MODE:-ok}"
    case "$1" in
      api)
        shift
        # The endpoint URL is the first NON-FLAG argument after `api`: a
        # flag such as `--paginate` may precede it, and a header value
        # may follow it.
        url=""
        for arg in "$@"; do
          case "$arg" in
            -*) ;;
            *) url="$arg"; break ;;
          esac
        done
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
          *commits/bbbb*)
            case "$mode" in
              date-mismatch)
                printf '%s\n' '{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","commit":{"committer":{"date":"2026-10-06T09:00:00Z"}},"parents":[{"sha":"dddddddddddddddddddddddddddddddddddddddd"}]}'
                ;;
              *)
                printf '%s\n' '{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","commit":{"committer":{"date":"2026-10-05T09:00:00Z"}},"parents":[{"sha":"dddddddddddddddddddddddddddddddddddddddd"}]}'
                ;;
            esac
            ;;
          *contents/CHANGELOG.md*)
            case "$url" in
              *ref=bbbb*)
                if [ "$mode" = "unreadable" ]; then
                  printf 'ERROR: stub gh api: CHANGELOG.md at bbbb... is unreadable (rate-limited or 4xx)\n' >&2
                  exit 1
                fi
                if [ "$mode" = "missing-heading" ]; then
                  printf '%s\n' '## [Unreleased]' '' '## [1.7.9] - 2026-09-30' '' '- an older release'
                else
                  printf '%s\n' '## [Unreleased]' '' '## [1.8.0] - 2026-10-05' '' '- the release commit'
                fi
                ;;
              *ref=dddd*)
                if [ "$mode" = "parent-has-it" ]; then
                  printf '%s\n' '## [Unreleased]' '' '## [1.8.0] - 2026-10-05' '' '- the release commit'
                else
                  printf '%s\n' '## [Unreleased]' '' '## [1.7.9] - 2026-09-30' '' '- an older release'
                fi
                ;;
              *)
                printf 'ERROR: stub gh api: unexpected CHANGELOG ref: %s\n' "$url" >&2
                exit 1
                ;;
            esac
            ;;
          *compare/v1.8.0...main)
            printf '%s\n' '{"status":"ahead","ahead_by":3,"behind_by":0,"total_commits":3}'
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
  private_constant :BASELINE_STUB_GH

  # Stub `gh` whose `gh release view <last>` FAILS with no stdout (a
  # missing release). Everything before it succeeds, so the failure is
  # the lookup itself: with `rel` empty, both extracted fields are empty
  # and the asset comparison would pass vacuously. The brief must abort
  # on the lookup and classify the absent-Release state; Compare must NOT
  # be reached.
  RELEASE_LOOKUP_FAILING_STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    case "$1" in
      api)
        shift
        # The endpoint URL is the first NON-FLAG argument after `api`: a
        # flag such as `--paginate` may precede it, and a header value
        # may follow it.
        url=""
        for arg in "$@"; do
          case "$arg" in
            -*) ;;
            *) url="$arg"; break ;;
          esac
        done
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

  # A bot-authored Release that CARRIES the .gem: the sanctioned
  # break-glass manual publish, and a real release. The asset count is
  # non-zero, so the brief's guard must let it through — the whole point
  # of the stub is that the script goes on to read the baseline and reach
  # the window scan, so the baseline reads (commit, CHANGELOG at the
  # commit and at its first parent) succeed here. The Compare endpoint
  # succeeds too. A regression that reintroduces the author as a trigger
  # aborts here with a gem-less diagnostic instead of reaching the window.
  BOT_AUTHOR_WITH_ASSETS_STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    case "$1" in
      api)
        shift
        # The endpoint URL is the first NON-FLAG argument after `api`: a
        # flag such as `--paginate` may precede it, and a header value
        # may follow it.
        url=""
        for arg in "$@"; do
          case "$arg" in
            -*) ;;
            *) url="$arg"; break ;;
          esac
        done
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
          *commits/bbbb*)
            printf '%s\n' '{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","commit":{"committer":{"date":"2026-10-05T09:00:00Z"}},"parents":[{"sha":"dddddddddddddddddddddddddddddddddddddddd"}]}'
            ;;
          *contents/CHANGELOG.md*)
            case "$url" in
              *ref=bbbb*)
                printf '%s\n' '## [Unreleased]' '' '## [1.8.0] - 2026-10-05' '' '- the release commit'
                ;;
              *ref=dddd*)
                printf '%s\n' '## [Unreleased]' '' '## [1.7.9] - 2026-09-30' '' '- an older release'
                ;;
              *)
                printf 'ERROR: stub gh api: unexpected CHANGELOG ref: %s\n' "$url" >&2
                exit 1
                ;;
            esac
            ;;
          *compare/v1.8.0...main)
            printf '%s\n' '{"status":"ahead","ahead_by":3,"behind_by":0,"total_commits":3}'
            ;;
          *)
            printf 'ERROR: stub gh api: unexpected URL: %s\n' "$url" >&2
            exit 1
            ;;
        esac
        ;;
      release)
        # A bot-authored Release that CARRIES the .gem: a sanctioned manual
        # release, not a defect.
        printf '%s\n' '{"author":{"login":"developerz-ai[bot]"},"assets":[{"name":"wurk-1.8.0.gem"}]}'
        ;;
      *)
        printf 'ERROR: stub gh: unexpected command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
  SHELL
  private_constant :BOT_AUTHOR_WITH_ASSETS_STUB_GH

  # The other gem-less shape: human author with ZERO assets — the assets
  # half alone fires.
  NON_BOT_AUTHOR_NO_ASSETS_STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    case "$1" in
      api)
        shift
        # The endpoint URL is the first NON-FLAG argument after `api`: a
        # flag such as `--paginate` may precede it, and a header value
        # may follow it.
        url=""
        for arg in "$@"; do
          case "$arg" in
            -*) ;;
            *) url="$arg"; break ;;
          esac
        done
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
          *commits/*|*contents/CHANGELOG.md*)
            printf 'ERROR: stub gh api: the release baseline must not be read when the release is gem-less\n' >&2
            exit 1
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
        # gem-less state: assets=[] but author is not developerz-ai[bot].
        printf '%s\n' '{"author":{"login":"octocat"},"assets":[]}'
        ;;
      *)
        printf 'ERROR: stub gh: unexpected command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
  SHELL
  private_constant :NON_BOT_AUTHOR_NO_ASSETS_STUB_GH

  # Stub `gh` whose TAG LISTING depends on whether `--paginate` was
  # passed — the behavioural pin on the resolver's completeness
  # argument. `git/matching-refs` is a PAGINATED endpoint: `gh api
  # --paginate` follows the API's link headers through every page and
  # merges the pages into one array, so a matching tag that sits on a
  # later page is enumerated too. Without the flag only the FIRST page
  # comes back, the highest version SEEN is the older tag, and the peel
  # is asked for a tag this stub refuses to answer — the Decide script
  # aborts and the window scan is never reached. The peel branch
  # therefore answers ONLY for the newer tag: an unpaginated resolver
  # cannot fall back onto the stale one and pass by accident.
  PAGINATED_TAGS_STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    case "$1" in
      api)
        shift
        paginated=0
        # The endpoint URL is the first NON-FLAG argument after `api`;
        # `--paginate` is a flag and precedes it.
        url=""
        for arg in "$@"; do
          case "$arg" in
            --paginate) paginated=1 ;;
            -*) ;;
            *) url="$arg"; break ;;
          esac
        done
        case "$url" in
          *git/matching-refs/tags/*)
            if [ "$paginated" = "1" ]; then
              # Every page merged: the newest tag lives on a later page.
              printf '%s\n' '[{"ref":"refs/tags/v1.8.0"},{"ref":"refs/tags/v1.9.0"}]'
            else
              # First page only: the newest tag is NOT in this page.
              printf '%s\n' '[{"ref":"refs/tags/v1.8.0"}]'
            fi
            ;;
          *git/ref/tags/v1.9.0)
            printf '%s\n' '{"object":{"sha":"ffffffffffffffffffffffffffffffffffffffff","type":"tag"}}'
            ;;
          *git/ref/tags/v1.8.0)
            printf 'ERROR: stub gh api git/ref/tags/v1.8.0 must not be called: an unpaginated listing selected the stale tag\n' >&2
            exit 1
            ;;
          *git/tags/ffffffffffffffffffffffffffffffffffffffff)
            printf '%s\n' '{"object":{"sha":"1234567890abcdef1234567890abcdef12345678","type":"commit"}}'
            ;;
          *commits/1234567890abcdef*)
            printf '%s\n' '{"sha":"1234567890abcdef1234567890abcdef12345678","commit":{"committer":{"date":"2026-10-07T09:00:00Z"}},"parents":[{"sha":"5678901234abcdef5678901234abcdef56789012"}]}'
            ;;
          *contents/CHANGELOG.md*)
            case "$url" in
              *ref=1234567890abcdef*)
                printf '%s\n' '## [Unreleased]' '' '## [1.9.0] - 2026-10-07' '' '- the release commit'
                ;;
              *ref=5678901234abcdef*)
                printf '%s\n' '## [Unreleased]' '' '## [1.8.0] - 2026-10-05' '' '- an older release'
                ;;
              *)
                printf 'ERROR: stub gh api: unexpected CHANGELOG ref: %s\n' "$url" >&2
                exit 1
                ;;
            esac
            ;;
          *compare/v1.9.0...main)
            printf '%s\n' '{"status":"ahead","ahead_by":3,"behind_by":0,"total_commits":3}'
            ;;
          *compare/*)
            printf 'ERROR: stub gh api compare/* must not be called with a stale tag\n' >&2
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
        printf '%s\n' '{"author":{"login":"octocat"},"assets":[{"name":"wurk-1.9.0.gem"}]}'
        ;;
      *)
        printf 'ERROR: stub gh: unexpected command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
  SHELL
  private_constant :PAGINATED_TAGS_STUB_GH

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
    if [[ "$1" == "log" ]]; then
      printf 'WINDOW_SCAN_REACHED\n' > "${WURK_TEST_FAST_PATH_MARKER}.log"
    fi
    exit 0
  SHELL
  private_constant :FETCH_FAILING_STUB_GIT

  # Stub `git` whose `describe` invocation writes a marker file, and whose
  # `log` invocation (the window scan) writes a second one. Every other
  # subcommand is a silent success — the brief's bash reads only
  # `describe`/`fetch`/`log`. The two markers are the signals the tests
  # use: `describe` says the Decide script reached the local fast path,
  # `log` says a release window was actually computed.
  STUB_GIT = <<~'SHELL'
    #!/usr/bin/env bash
    if [[ "$1" == "describe" ]]; then
      printf 'LOCAL_FAST_PATH_REACHED\n' > "$WURK_TEST_FAST_PATH_MARKER"
    fi
    if [[ "$1" == "log" ]]; then
      printf 'WINDOW_SCAN_REACHED\n' > "${WURK_TEST_FAST_PATH_MARKER}.log"
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
    if [[ "$1" == "log" ]]; then
      printf 'WINDOW_SCAN_REACHED\n' > "${WURK_TEST_FAST_PATH_MARKER}.log"
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
    if [[ "$1" == "log" ]]; then
      printf 'WINDOW_SCAN_REACHED\n' > "${WURK_TEST_FAST_PATH_MARKER}.log"
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
    if [[ "$1" == "log" ]]; then
      printf 'WINDOW_SCAN_REACHED\n' > "${WURK_TEST_FAST_PATH_MARKER}.log"
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
    if [[ "$1" == "log" ]]; then
      printf 'WINDOW_SCAN_REACHED\n' > "${WURK_TEST_FAST_PATH_MARKER}.log"
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

  def baseline_stub_gh
    BASELINE_STUB_GH
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

  def paginated_tags_stub_gh
    PAGINATED_TAGS_STUB_GH
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
  def run_decide_under_stubs(stub_gh, stub_git: STUB_GIT, env: {})
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

      run_env = {
        'PATH' => "#{bin_dir}:#{ENV.fetch('PATH', '')}",
        'WURK_TEST_FAST_PATH_MARKER' => File.join(tmpdir, 'local_fast_path_reached')
      }.merge(env)

      result = Open3.capture3(run_env, script_path)
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
      window_marker = File.join(tmpdir, 'local_fast_path_reached.log')
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

      assert_no_window_scan(window_marker, failure_message)
    end
  end

  # The window scan must not have run: a window computed after an abort —
  # or on a baseline that never verified — is a window since the wrong
  # anchor, and the decision would grade it as a real one.
  def assert_no_window_scan(window_marker, failure_message)
    refute window_scan_reached?(window_marker),
           "#{failure_message} before the window scan; " \
           'the stub `git log` was reached, so a release window was computed on ' \
           'an unverified baseline'
  end

  # A verified baseline must let the Decide script reach the window: the
  # stub `git log` has to run (a window was computed) and no baseline
  # diagnostic may be printed.
  def assert_baseline_reaches_window(stub_gh, shape:)
    run_decide_under_stubs(stub_gh) do |(out, err, status), tmpdir|
      combined = out + err

      assert_predicate status, :success?,
                       "a verified release baseline must let the #{shape} tag reach the " \
                       "window (status=#{status.inspect}, stdout=#{out.inspect}, " \
                       "stderr=#{err.inspect})"

      refute_includes combined, '::error::baseline',
                      'a verified release baseline must not print a baseline diagnostic; ' \
                      "stdout=#{out.inspect}, stderr=#{err.inspect}"

      assert window_scan_reached?(File.join(tmpdir, 'local_fast_path_reached.log')),
             'a verified release baseline must reach the window scan; the stub `git log` ' \
             "was not reached (stdout=#{out.inspect}, stderr=#{err.inspect})"
    end
  end

  # A baseline that cannot be verified must abort the Decide script with a
  # `::error::baseline` diagnostic BEFORE the window scan: the window is the
  # decision's only window, so a window computed on an unverified baseline is
  # a window since the wrong anchor. The stub `git log` must stay unset.
  def assert_baseline_abort_before_window_scan(mode:, expected_output:)
    env = { 'WURK_TEST_BASELINE_MODE' => mode }

    run_decide_under_stubs(baseline_stub_gh, env: env) do |(out, err, status), tmpdir|
      combined = out + err

      refute_predicate status, :success?,
                       "the baseline check must abort the Decide script (mode=#{mode}, " \
                       "status=#{status.inspect}, stdout=#{out.inspect}, stderr=#{err.inspect})"

      assert_includes combined, '::error::baseline',
                      'the baseline check must print a `::error::baseline` diagnostic so the ' \
                      "abort surfaces in the workflow log (mode=#{mode}, " \
                      "stdout=#{out.inspect}, stderr=#{err.inspect})"

      assert_includes combined, expected_output,
                      'the baseline check must name the violation it found (mode=' \
                      "#{mode}, stdout=#{out.inspect}, stderr=#{err.inspect})"

      assert_no_window_scan(File.join(tmpdir, 'local_fast_path_reached.log'),
                            "the baseline check (#{mode})")

      refute fast_path_reached?(File.join(tmpdir, 'local_fast_path_reached')),
             'the baseline check must abort before the local fast path (mode=' \
             "#{mode}, stdout=#{out.inspect}, stderr=#{err.inspect})"
    end
  end

  def fast_path_reached?(marker)
    File.exist?(marker) && File.read(marker).include?('LOCAL_FAST_PATH_REACHED')
  end

  def window_scan_reached?(marker)
    File.exist?(marker) && File.read(marker).include?('WINDOW_SCAN_REACHED')
  end

  # Everything from the '## The ask, when due' heading to the end of the
  # file: the numbered ask steps, the evidence contract, and the closing
  # prohibition. Empty when the heading is gone.
  def extract_ask_section
    ask_idx = @text.index('## The ask, when due')

    ask_idx ? @text[ask_idx..] : ''
  end

  # The evidence contract proper: from the "The ask's body carries" paragraph
  # through the closing prohibition, with the numbered ask steps excluded.
  # Contract assertions must run against this, not the whole ask section —
  # the steps already mention [Unreleased], Dependabot/wurk.gemspec and the
  # demo, so a section-wide match cannot fail when the bullet it pins is
  # deleted.
  def extract_ask_body_contract
    section = extract_ask_section
    idx = section.index("The ask's body carries")

    idx ? section[idx..] : ''
  end

  # The health-checkup ruling paragraph (from "Health-checkup" to EOF). Only
  # this paragraph names demo state as ruled-out evidence; the ask steps'
  # `release:relock_demo` mentions the demo for another reason entirely.
  def extract_health_checkup_ruling
    contract = extract_ask_body_contract
    idx = contract.index('Health-checkup')

    idx ? contract[idx..] : ''
  end

  # The ask section's first numbered step: from the "**Pre-flight guard"
  # paragraph to the next numbered ask step (or EOF). Credential
  # assertions run against this step alone — later ask steps and the
  # Decide block mention `gh` for other reasons, so a section-wide match
  # would survive the credential sentence's deletion.
  def extract_pre_flight_guard
    section = extract_ask_section
    start_idx = section.index('**Pre-flight guard')
    return '' unless start_idx

    next_step_idx = section.index(/\n2\. /, start_idx)
    next_step_idx ? section[start_idx...next_step_idx] : section[start_idx..]
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

  # A window listing that omits a shipping commit is as wrong as an
  # empty one: the brief reads that listing twice — the "empty | nothing"
  # row and the "otherwise | one ask" row — and an empty listing files
  # no release ask at all. Returns the problems found so one test can
  # report every window it built.
  def window_listing_problems(stdout, label)
    problems = []
    empty_message = "#{label}: the listing is empty, so the brief's \"empty | nothing\" row fires"
    problems << empty_message if stdout.strip.empty?

    FRONTEND_WINDOW_SUBJECTS.each do |subject|
      next if stdout.include?(subject)

      problems << "#{label}: the commit #{subject.inspect} is missing from the listing"
    end

    problems
  end

  # `refs/remotes/origin/main` points to whatever the local-checkout
  # brief calls `origin/main`. The real-repo test below synthesizes
  # this ref from HEAD so the brief's
  # `git log "$last"..origin/main` walks the same range the brief
  # would on a real fetch: the initial-commit tag is the left bound,
  # every commit since is in the window.
  REMOTE_MAIN_REF = 'refs/remotes/origin/main'
  private_constant :REMOTE_MAIN_REF

  # The frontend paths that reach the gem and that the brief's window
  # pathspec must therefore cover: `frontend/index.html` becomes the
  # built dashboard shell, `frontend/public/**` is copied verbatim into
  # the bundle. Neither sits under `frontend/src/**`.
  FRONTEND_INDEX_SUBJECT = 'frontend index commit on frontend/index.html'
  FRONTEND_FAVICON_SUBJECT = 'frontend favicon commit on frontend/public/favicon.png'
  FRONTEND_WINDOW_SUBJECTS = [FRONTEND_INDEX_SUBJECT, FRONTEND_FAVICON_SUBJECT].freeze
  private_constant :FRONTEND_INDEX_SUBJECT, :FRONTEND_FAVICON_SUBJECT, :FRONTEND_WINDOW_SUBJECTS

  # End-to-end window-scan repo. Materializes a fresh git repo whose
  # window holds a shipping commit (lib/foo.rb change), a docs-only
  # commit (README.md change), a change-then-revert pair on lib/bar.rb,
  # and the two frontend commits that reach the gem
  # (frontend/index.html, frontend/public/favicon.png). Together they
  # exercise the shapes the brief's pathspec filter must handle.
  #
  # `frontend_only: true` drops the lib-shaped commits, so the window's
  # only shipping commit is a frontend one — the window the brief grades
  # "empty" when its pathspec misses the frontend paths.
  #
  # Uses an isolated env (HOME = tmpdir, GIT_CONFIG_NOSYSTEM = 1,
  # no shared work tree) so no inherited user's git config, hooks,
  # or system gitconfig rewrites the author/committer or short-
  # circuits the test on a host that happens to have `core.hooksPath`
  # pointing at global hooks. Tags v1.0.0 at the initial commit, then
  # creates `REMOTE_MAIN_REF` pointing at HEAD so the brief-style
  # `git log v1.0.0..origin/main` resolves both bounds.
  def build_window_repo(tmpdir, frontend_only: false)
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

    build_lib_window_commits(env, tmpdir) unless frontend_only

    # Frontend commits: the dashboard shell and a copied public asset.
    # Both reach the gem — Vite builds frontend/index.html into
    # vendor/assets/dashboard/index.html and copies frontend/public/**
    # verbatim, and wurk.gemspec ships vendor/assets/dashboard/**/* — so
    # the brief's pathspec must name both.
    FileUtils.mkdir_p(File.join(tmpdir, 'frontend', 'public'))
    File.write(File.join(tmpdir, 'frontend', 'index.html'), "<!doctype html>\n")
    run_git(env, 'add', 'frontend/index.html')
    run_git(env, 'commit', '--quiet', '-m', FRONTEND_INDEX_SUBJECT)
    verify_frontend_commit_touches_only(env, FRONTEND_INDEX_SUBJECT, 'frontend/index.html')

    File.write(File.join(tmpdir, 'frontend', 'public', 'favicon.png'), "favicon bytes\n")
    run_git(env, 'add', 'frontend/public/favicon.png')
    run_git(env, 'commit', '--quiet', '-m', FRONTEND_FAVICON_SUBJECT)
    verify_frontend_commit_touches_only(env, FRONTEND_FAVICON_SUBJECT, 'frontend/public/favicon.png')

    head_sha = Open3.capture2(env, 'git', 'rev-parse', 'HEAD').first.to_s.strip
    raise 'build_window_repo: empty HEAD SHA' if head_sha.empty?

    run_git(env, 'update-ref', REMOTE_MAIN_REF, head_sha)
  end

  # The frontend commits' premise: each changes exactly ONE frontend file
  # and nothing else — no lib/, app/, config/, exe/ or wurk.gemspec path.
  # The defect this gate pins is "a commit whose only shipping change is
  # a frontend file is invisible to the brief's pathspec", so a frontend
  # commit that also touched a lib/ file would turn the empty
  # frontend-only window into a fixture artifact instead of a pathspec
  # defect. Checked, not assumed.
  def verify_frontend_commit_touches_only(env, subject, expected_path)
    sha = run_git(env, 'rev-parse', 'HEAD').strip
    touched = run_git(env, 'show', '--pretty=format:', '--name-only', sha).lines.map(&:strip).reject(&:empty?)

    return if touched == [expected_path]

    raise "#{subject.inspect} must touch only #{expected_path.inspect} (no lib/, app/, " \
          "config/, exe/ or wurk.gemspec path), but it touched #{touched.inspect}"
  end

  # The lib-shaped window commits: a shipping commit on lib/foo.rb, a
  # docs-only commit on README.md, and a change+revert pair on
  # lib/bar.rb. Together they exercise the three shapes the brief's
  # pathspec filter must handle.
  def build_lib_window_commits(env, tmpdir)
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

    raise "git #{args.inspect} failed in the window fixture: status=#{status.exitstatus} " \
          "stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
  end
end
