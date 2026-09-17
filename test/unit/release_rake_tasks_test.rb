# frozen_string_literal: true

require_relative '../test_helper'

# Guard the contract that this PR created: the in-repo Rakefile no longer
# lets a local command tag, push, or otherwise step on CI's release lane.
# Three failure modes the test pins down, each with a tool result of its own:
#
#   1. `rake release`, `rake release:source_control_push`, and
#      `rake release:rubygem_push` each SystemExit with a message naming
#      `RELEASE.md` — the file the README / operator's eye reads.
#   2. `rake -T | grep '^rake release'` lists ONLY `release:check`,
#      `release:package`, and `release` (the aborting top-level one). The
#      deleted `release:full` stays gone. The namespaced aborters have NO
#      `desc` (which is what keeps them out of `rake -T`); they are
#      invokable, abort, but are not advertised.
#   3. `bin/gem-push` runs `bundle exec rake release:check` before
#      `gem push` — the script's gate is the same one CI runs.
#
# Reads files (and a few `rake` invocations under `bundle exec`); touches no
# Redis, no global state. Each `rake` call is in its own `bundle exec`, so it
# cannot pick up the tests' $LOAD_PATH or other work in progress.
class ReleaseRakeTasksTest < Wurk::Test::UnitCase
  parallelize_me!

  REPO_ROOT = File.expand_path('../..', __dir__).freeze
  BIN_GEM_PUSH = File.join(REPO_ROOT, 'bin', 'gem-push').freeze

  # Each task that must abort with the canonical message.
  ABORTING_TASKS = %w[release release:source_control_push release:rubygem_push].freeze

  # Runs `bundle exec rake <task>` in the repo root and returns
  # [status, combined_output]. Status is the conventional exit code; SystemExit
  # from the task's `abort` is a regular non-zero exit under bundler.
  def rake_invoke(task)
    require 'open3'
    out, status = Open3.capture2e(
      { 'REDIS_URL' => Wurk::Test.redis_url },
      'bundle', 'exec', 'rake', task,
      chdir: REPO_ROOT
    )
    [status, out]
  end

  # `rake -T` lists the tasks whose `desc` strings this test wants to gate on.
  # Splitting on `^rake release` keeps the test focused on the release namespace
  # only — the suite runner's task list is long and growing.
  def rake_t_release_lines
    _status, out = rake_invoke('-T')
    out.each_line.filter_map do |line|
      stripped = line.chomp
      stripped if stripped.start_with?('rake release')
    end
  end

  # --- 1. aborting tasks --------------------------------------------------

  # Sanity check on the loader: the repo's Rakefile must load cleanly in this
  # process — if it doesn't, the `rake <task>` calls below would fail for the
  # wrong reason.
  def test_rakefile_loads_cleanly
    require 'rake'
    Rake.application = Rake::Application.new
    Rake.load_rakefile(File.expand_path('Rakefile', REPO_ROOT))
    tasks = Rake.application.tasks.map(&:name).sort
    ABORTING_TASKS.each do |task|
      assert_includes tasks, task, "Rakefile must define `#{task}` (it must abort, not no-op)"
    end
  end

  def test_top_level_release_task_aborts_with_release_md_message
    status, out = rake_invoke('release')
    refute status.success?, "rake release must exit non-zero — got #{status.inspect} with:\n#{out}"
    assert_match(/RELEASE\.md/, out, "rake release abort must name RELEASE.md; got:\n#{out}")
  end

  def test_release_source_control_push_aborts_with_release_md_message
    status, out = rake_invoke('release:source_control_push')
    refute status.success?,
           "rake release:source_control_push must exit non-zero — got #{status.inspect} with:\n#{out}"
    assert_match(/RELEASE\.md/, out,
                 "rake release:source_control_push abort must name RELEASE.md; got:\n#{out}")
  end

  def test_release_rubygem_push_aborts_with_release_md_message
    status, out = rake_invoke('release:rubygem_push')
    refute status.success?,
           "rake release:rubygem_push must exit non-zero — got #{status.inspect} with:\n#{out}"
    assert_match(/RELEASE\.md/, out,
                 "rake release:rubygem_push abort must name RELEASE.md; got:\n#{out}")
  end

  # The three aborts are the same canonical message: a future edit that
  # diverges them is the same kind of drift as the `release:full` reminder this
  # whole PR is about — copy divergence between "things that say they did the
  # right thing". Pin the symmetry so a future change has to think about it.
  def test_all_three_aborting_tasks_share_their_message
    messages = ABORTING_TASKS.map do |task|
      _status, out = rake_invoke(task)
      out
    end
    unique = messages.map(&:strip).uniq
    assert_equal 1, unique.size,
                 "all aborting release tasks must share the same message; got divergences:\n" \
                 "#{messages.zip(ABORTING_TASKS).map { |m, n| "#{n}: #{m.inspect}" }.join("\n")}"
  end

  # --- 2. rake -T listing --------------------------------------------------

  # The task inventory this test pins down. Namespaced check / package stay,
  # the deleted `full` is gone, and the top-level `release` is the aborting
  # one. `release:source_control_push` / `release:rubygem_push` are still
  # defined (and they still abort) but they have no `desc`, so `rake -T` does
  # not advertise them.
  EXPECTED_RELEASE_TASKS = %w[release release:check release:package].freeze

  def test_rake_T_lists_only_release_check_release_package_and_release
    # `rake -T` lines look like:
    #   rake release:check    # Pre-release gate: ...
    # The task name (with the `rake ` prefix already) ends at the first run
    # of whitespace followed by `#`, so split on ` # ` and re-strip. The
    # strings include the leading `rake `; strip it for an apples-to-apples
    # comparison with EXPECTED_RELEASE_TASKS.
    names = rake_t_release_lines.map do |line|
      line.split(/\s+#\s+/, 2).first.to_s.strip.delete_prefix('rake ').strip
    end
    assert_equal EXPECTED_RELEASE_TASKS.sort, names.sort,
                 "rake -T must list only #{EXPECTED_RELEASE_TASKS.join(', ')} under `release`; got:\n" \
                 "#{rake_t_release_lines.join("\n")}\n"
  end

  # Without this guard, deleting every entry above would let the comparison
  # pass vacuously (deleted == deleted). This is the same anti-vacuity pattern
  # bin_check_frontend_parity_test.rb uses for its parity gate.
  def test_release_full_is_not_listed
    names = rake_t_release_lines.map do |line|
      line.split(/\s+#\s+/, 2).first.to_s.strip.delete_prefix('rake ').strip
    end
    refute_includes names, 'release:full',
                    "rake -T must not list `release:full` (it was deleted because it let " \
                    'local checkouts publish with an API key, bypassing CI)'
  end

  # --- 3. bin/gem-push's gate ---------------------------------------------

  # The unit test pins what `bin/gem-push`'s header promises:
  # `bundle exec rake release:check` runs before `gem push`. Read the file
  # rather than executing it — touching rubygems.org from a unit test is not
  # a contract anyone wants reviewed.
  def test_bin_gem_push_runs_release_check_before_gem_push
    # Look at non-comment, executable lines only. The script header mentions
    # `gem push` and `rake release:check` in prose to explain the gate, and
    # matching on raw substrings would find those first.
    exec_lines = File.read(BIN_GEM_PUSH).each_line.reject { |l| l.lstrip.start_with?('#') }
    check_idx = exec_lines.index { |l| l.include?('rake release:check') }
    refute_nil check_idx,
               "bin/gem-push must call `bundle exec rake release:check` (the CI gate); got:\n#{exec_lines.join}"
    push_idx = exec_lines.index { |l| l.include?('gem push') }
    refute_nil push_idx,
               'bin/gem-push must still call `gem push`; got: ' + exec_lines.join
    assert_operator check_idx, :<, push_idx,
                    'rake release:check must run BEFORE gem push ' \
                    "(a failing gate has to abort before the irreversible push); got:\n#{exec_lines.join}"
  end
end
