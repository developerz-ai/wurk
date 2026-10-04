# frozen_string_literal: true

require_relative '../test_helper'
require 'open3'

# A release is merging a lib/wurk/version.rb bump: release.yml publishes the gem
# and cuts the tag afterwards (RELEASE.md). Bundler's gem_tasks would tag and
# push from a workstation instead, so the Rakefile redefines those tasks to
# refuse. Driven through a real `rake` subprocess, because what matters is what
# a maintainer typing the command gets — exit status and message included.
class RakefileReleaseTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  REFUSED = %w[release release:source_control_push release:rubygem_push].freeze

  def rake(*)
    Open3.capture3(RbConfig.ruby, Gem.bin_path('rake', 'rake'), *, chdir: ROOT)
  end

  REFUSED.each do |task|
    define_method("test_#{task.tr(':', '_')}_refuses_and_points_at_release_md") do
      out, err, status = rake(task)

      refute_predicate status, :success?, "rake #{task} must not succeed:\n#{out}#{err}"
      assert_includes err, 'RELEASE.md'
      assert_includes err, 'lib/wurk/version.rb'
      refute_match(/Tagged|Pushed|pushed/, out + err)
    end
  end

  # release:full chained frontend:build → build → push, and `push` was never a
  # task, so it could not run at all; it is gone rather than refused.
  def test_task_table_has_no_release_full_and_keeps_the_real_lane_tasks
    out, err, status = rake('-P')

    assert_predicate status, :success?, err
    tasks = out.lines.grep(/\Arake /).map { |l| l.split[1] }

    refute_includes tasks, 'release:full'
    %w[release:check release:package release:relock_demo].each { |t| assert_includes tasks, t }
  end
end
