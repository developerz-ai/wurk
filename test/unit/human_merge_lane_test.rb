# frozen_string_literal: true

require 'minitest/autorun'
require 'date'
require 'yaml'

# Pins the human-merge fence in the maintainer policy.
#
# The policy is fully AI-maintained: the agent triages, reviews and merges
# pull requests, and `pr.auto_merge` is `true`. The fence is the one place a
# human still signs: a pull request that touches CI or release automation,
# packaging, the release helpers, or the agent's own policy waits for a human
# approving review.
#
# A fence is only worth what it actually covers, so this test pins it from the
# real policy file rather than from a copy:
#
#   1. `pr.human_merge.paths` is exactly the six globs the fence is made of.
#   2. The three paths that must stay OUTSIDE the fence match none of them:
#      `lib/wurk/version.rb` (the release lane's version bump has to keep
#      auto-merging), `CHANGELOG.md` and `.github/dependabot.yml`.
#   3. `pr.auto_merge` is still `true` and `pr.auto_merge_scope` is still
#      `any` — the fence adds a lane, it does not turn auto-merge off.
#   4. The six required checks are unchanged, and the fence waives none of
#      them: a fenced pull request still needs every one of them green.
#   5. The `triage:`, `review:`, `release:` and `escalate:` blocks are
#      unchanged — the fence is a new lane, not a rewrite of the policy.
#   6. The merge-lane behaviour: a `.github/workflows/**` change is
#      human-merge-gated, a `lib/`-only change stays auto-eligible.
#   7. The glob semantics the fence is written against: `**` descends into
#      nested directories (so `.dz/**` really does fence the agent's own
#      policy file), `*` stays inside one path segment.
#
# Reads files only; touches no Redis and no shared state.
class HumanMergeLaneTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  POLICY = File.join(ROOT, '.dz', 'maintainer', 'maintainer.yml')

  # The fence, exactly. Order is part of the contract: the list is read as
  # written, so a reordering is a change to the policy, not a formatting nit.
  FENCE_PATHS = [
    '.github/workflows/**',
    '*.gemspec',
    '.dz/**',
    'Dockerfile',
    'bin/gem-*',
    'tasks/release_helpers.rb'
  ].freeze

  # The paths that must stay outside the fence. The version bump is the first
  # one for a reason: the release lane fires on `lib/wurk/version.rb` landing
  # on main, and a fence that held it would hold every release.
  UNFENCED_PATHS = [
    'lib/wurk/version.rb',
    'CHANGELOG.md',
    '.github/dependabot.yml'
  ].freeze

  # The `main-protection` ruleset's six. Unchanged by the fence: a fenced pull
  # request still needs all of them green.
  REQUIRED_CHECKS = [
    'test + coverage (latest ruby/rails)',
    'lint (rubocop)',
    'parity (oracle)',
    'spec docs (exist + non-empty)',
    'frontend (vitest)',
    'actionlint (workflow lint)'
  ].freeze

  # Two of the policy's `non_goals` are long enough to blow the line budget on
  # their own, so they live here rather than in the block below.
  NON_GOAL_WIRE_COMPAT =
    'Changing a Redis key, the job JSON format, or a sorted-set score format: ' \
    'wire compatibility with Sidekiq is the contract'
  NON_GOAL_PIPELINE =
    "Outside human contributors' changes to CI, release or publish automation " \
    '(.github/, bin/, release tasks, RELEASE.md, Wurk::VERSION): members own the gem pipeline'

  # The blocks the fence must not have moved. Recorded as the parsed shape of
  # each block, so a change to any value inside one fails here.
  UNCHANGED_BLOCKS = {
    'triage' => {
      'stale_after_days' => 30,
      'stale_action' => 'comment_then_close',
      'error_fix_confirm_environments' => ['demo'],
      'ask_for_repro' => true,
      'required_fields' => %w[steps expected actual version],
      'qualify_into' => %w[bug feature dupe question],
      'confidence_threshold' => 0.4,
      'close_unanswered_repro_after_days' => 14,
      'non_goals' => [
        NON_GOAL_WIRE_COMPAT,
        'MessagePack or any other non-JSON job format',
        'A license check, a paid tier, or a flag that gates a Pro or Enterprise feature',
        'Breaking a Sidekiq::* alias or diverging from the documented Sidekiq API',
        'Mocking Redis in integration or parity tests',
        'Sharing a Redis socket across forks',
        'Backwards-compatibility shims, dead-code comments, or speculative abstractions',
        NON_GOAL_PIPELINE
      ]
    },
    'review' => {
      'enabled' => true,
      'force' => true,
      'depth' => 'inline',
      'profile' => 'chill',
      'request_changes' => true,
      'approval' => false,
      'high_level_summary' => true,
      'learnings' => false,
      'chat_auto_reply' => true,
      'auto_review' => {
        'enabled' => true,
        'incremental' => true,
        'drafts' => false,
        'base_branches' => ['main'],
        'ignore_title_keywords' => ['WIP', 'DO NOT MERGE']
      },
      'anti_noise' => {
        'severity_floor' => 'minor',
        'max_comments' => 10,
        'dedupe' => true
      },
      'path_filters' => [],
      'path_instructions' => []
    },
    'release' => {
      'manager' => 'none',
      'channels' => []
    },
    'escalate' => {
      'ask_before_acting' => []
    }
  }.freeze

  def setup
    @policy = YAML.safe_load_file(POLICY, permitted_classes: [Date, Time], aliases: true)
    @pr = @policy.fetch('pr')
    @paths = @pr.fetch('human_merge').fetch('paths')
  end

  def test_the_policy_carries_the_fence
    assert_kind_of Hash, @policy, 'the maintainer policy must still parse as YAML'
    assert @pr.key?('human_merge'), 'the policy must carry a `pr.human_merge:` lane'
    assert_kind_of Array, @paths, '`pr.human_merge.paths` must be a list of globs'
  end

  def test_the_fence_is_exactly_the_six_globs
    assert_equal FENCE_PATHS, @paths,
                 'the fence must be exactly the six globs, in order; a path added ' \
                 'or dropped is a change to who signs for a merge'
  end

  def test_the_fence_covers_the_paths_that_run_beside_the_publish_path
    fenced = {
      '.github/workflows/release.yml' => '.github/workflows/**',
      'wurk.gemspec' => '*.gemspec',
      'Dockerfile' => 'Dockerfile',
      'bin/gem-push' => 'bin/gem-*',
      'tasks/release_helpers.rb' => 'tasks/release_helpers.rb'
    }

    fenced.each do |path, pattern|
      assert_includes fenced_paths(path), pattern,
                      "#{path} must be fenced by #{pattern.inspect}, got #{fenced_paths(path).inspect}"
    end
  end

  def test_the_paths_that_must_stay_unfenced_match_no_pattern
    UNFENCED_PATHS.each do |path|
      assert_empty fenced_paths(path),
                   "#{path} must match none of the fence patterns " \
                   "(#{FENCE_PATHS.join(', ')}); a fence that holds it would hold " \
                   'the release lane or ordinary maintenance'
    end
  end

  def test_a_double_star_glob_descends_into_nested_directories
    # `**` is RECURSIVE in a path-aware glob: it crosses directory
    # boundaries. That is the semantics the fence is written against, and the
    # reason the matcher above cannot be plain `File.fnmatch?` — under
    # `FNM_PATHNAME` Ruby's `**` matches exactly one path segment, so
    # `File.fnmatch?('.dz/**', '.dz/maintainer/maintainer.yml',
    # File::FNM_PATHNAME)` is false. A fence built on that reading would
    # leave the agent's own policy file unfenced, which is the one path the
    # policy's prose says it fences ("the agent's own policy is the file that
    # decides what the agent may do next").
    #
    # Pinned here so the next change to the fence is made with these
    # semantics in hand: `**` descends, `*` does not.
    assert fence_match?('.dz/**', '.dz/README.md'),
           '`.dz/**` matches a file directly in `.dz/`'
    assert fence_match?('.dz/**', '.dz/maintainer/maintainer.yml'),
           '`.dz/**` matches a nested file — `**` crosses directory boundaries'
    assert fence_match?('.dz/**', '.dz/schedules/coverage-gaps.md'),
           '`.dz/**` matches a file nested two levels down'

    refute File.fnmatch?('.dz/**', '.dz/maintainer/maintainer.yml', File::FNM_PATHNAME),
           'plain `File.fnmatch?` under `FNM_PATHNAME` does NOT descend — which ' \
           'is why the fence matcher above handles `**` itself'
  end

  def test_a_single_star_glob_stays_inside_one_path_segment
    # `*` does NOT cross a `/`: `*.gemspec` is the gemspec at the repo root,
    # not any gemspec anywhere.
    assert fence_match?('*.gemspec', 'wurk.gemspec'),
           '`*.gemspec` matches the gemspec at the repo root'
    refute fence_match?('*.gemspec', 'vendor/wurk.gemspec'),
           '`*.gemspec` does not match a gemspec in a subdirectory'
  end

  def test_auto_merge_is_still_on_for_everything_outside_the_fence
    assert_equal true, @pr['auto_merge'], # rubocop:disable Minitest/AssertTruthy
                 'the fence is a lane, not an off switch: `pr.auto_merge` must stay true'
    assert_equal 'any', @pr['auto_merge_scope'],
                 'the fence must not narrow whose pull requests the agent merges'
  end

  def test_the_six_required_checks_are_unchanged
    assert_equal REQUIRED_CHECKS, @pr['required_checks'],
                 'the fence adds a lane; it does not change which checks gate a merge'
  end

  def test_the_fence_waives_none_of_the_required_checks
    # A fenced pull request is still gated by every required check: the fence
    # adds a human approving review on top of the machine gates, it does not
    # replace them.
    assert_equal 6, @pr['required_checks'].size,
                 'all six required checks must still gate a merge, fenced or not'

    assert_equal 'test + coverage (latest ruby/rails)', @pr['required_checks'].first,
                 'the coverage-bearing check must still be one of the gates'
    assert_includes @pr['required_checks'], 'actionlint (workflow lint)',
                    'the workflow linter must still gate a merge — the fence ' \
                    'covers workflow edits, it does not excuse them'
  end

  def test_the_triage_review_release_and_escalate_blocks_are_unchanged
    UNCHANGED_BLOCKS.each do |name, expected|
      assert_equal expected, @policy[name],
                   "the `#{name}:` block must be unchanged — the fence is a new " \
                   'lane, not a rewrite of the policy'
    end
  end

  def test_a_workflow_change_is_human_merge_gated
    changed = ['.github/workflows/release.yml']

    assert human_merge_gated?(changed),
           'a pull request that touches .github/workflows/** must wait for a ' \
           'human approving review'
  end

  def test_a_change_to_the_agents_own_policy_is_human_merge_gated
    # The policy fences `.dz/**` for one stated reason: "the agent's own
    # policy is the file that decides what the agent may do next". That file
    # is `.dz/maintainer/maintainer.yml` — nested under `.dz/`, so the fence
    # only covers it if `**` descends. Pin the lane decision, not just the
    # glob: a pull request that edits the agent's own policy must wait for a
    # human approving review.
    assert human_merge_gated?(['.dz/maintainer/maintainer.yml']),
           'a pull request that touches the agent\'s own policy must wait for ' \
           'a human approving review'
    assert_includes fenced_paths('.dz/maintainer/maintainer.yml'), '.dz/**',
                    'the maintainer policy file is fenced by `.dz/**`'
  end

  def test_a_lib_only_change_stays_auto_eligible
    changed = ['lib/wurk/client.rb', 'test/unit/client_test.rb']

    refute human_merge_gated?(changed),
           'a pull request that touches only lib/ and test/ must stay ' \
           'auto-eligible'
  end

  private

  # The patterns that fence a path, under the matcher this repo checks with.
  #
  # `**` is RECURSIVE here: it crosses directory boundaries. That is the
  # standard path-aware glob (`gitignore`, GitHub Actions `paths:`, the
  # platform's own matcher) and it is what the policy's prose assumes when it
  # says `.dz/**` fences "the agent's own policy directory" — the policy file
  # is at `.dz/maintainer/maintainer.yml`, two levels down.
  #
  # Ruby's `File.fnmatch?` alone cannot express that: under `FNM_PATHNAME` its
  # `**` matches exactly ONE path segment, so `File.fnmatch?('.dz/**',
  # '.dz/maintainer/maintainer.yml', File::FNM_PATHNAME)` is false and a
  # matcher built on it would report the agent's own policy as UNFENCED —
  # the opposite of what the fence is for. So `**` is handled here, and every
  # other pattern is left to `File.fnmatch?`, which keeps `*` inside a single
  # path segment: `*.gemspec` matches `wurk.gemspec` but not `a/b.gemspec`.
  def fenced_paths(path)
    FENCE_PATHS.select { |pattern| fence_match?(pattern, path) }
  end

  # One pattern against one path.
  def fence_match?(pattern, path)
    return File.fnmatch?(pattern, path, File::FNM_PATHNAME) unless pattern.end_with?('/**')

    # `dir/**` fences `dir` itself and everything under it, at any depth.
    prefix = pattern.delete_suffix('/**')
    path == prefix || path.start_with?("#{prefix}/")
  end

  # The lane decision: a pull request is human-merge-gated when it touches at
  # least one fenced path.
  def human_merge_gated?(changed_paths)
    changed_paths.any? { |path| fenced_paths(path).any? }
  end
end
