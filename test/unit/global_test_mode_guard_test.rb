# frozen_string_literal: true

require 'minitest/autorun'
require 'ripper'

# `require 'sidekiq/testing'` (and `/inline`) turns a test mode on for the
# whole process when the file loads, as upstream does. In this suite every test
# file of a worker loads before any test runs, so one such require put every
# class dealt to that worker into fake mode: pushes went to in-memory queues and
# ~350 unrelated tests failed only in the full run. Tests that exercise the
# require do it in a subprocess (testing_require_test.rb, sidekiq_require_shims_test.rb).
#
# Reads files; touches no Redis.
class GlobalTestModeGuardTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  GLOBAL_MODE_REQUIRE = %r{\Asidekiq/testing(?:/inline)?\z}

  def test_no_test_file_requires_sidekiq_testing_at_load
    files = Dir[File.join(ROOT, 'test', '**', '*.rb')].reject { |f| f.include?('/.checkouts/') }
    offenders = files.filter_map do |path|
      rel = path.delete_prefix("#{ROOT}/")
      rel if top_level_requires(File.read(path)).any? { |lib| lib.match?(GLOBAL_MODE_REQUIRE) }
    end

    assert_empty offenders,
                 "these files require 'sidekiq/testing' in the test process, flipping every later test into a " \
                 "test mode; use Sidekiq::Testing (already loaded) or a subprocess: #{offenders.join(', ')}"
  end

  def test_the_scanner_sees_a_real_require_and_ignores_strings
    assert_equal ['sidekiq/testing'], top_level_requires("require 'sidekiq/testing'\n")
    assert_empty top_level_requires("x = \"require 'sidekiq/testing'\"\n")
  end

  private

  # `require '<literal>'` calls as Ruby code, not text inside strings or comments.
  def top_level_requires(source)
    tokens = Ripper.lex(source).reject { |(_, type, _)| %i[on_sp on_ignored_nl on_nl on_comment].include?(type) }
    tokens.each_cons(3).filter_map do |(_, t1, s1), (_, t2, _), (_, t3, s3)|
      s3 if t1 == :on_ident && s1 == 'require' && t2 == :on_tstring_beg && t3 == :on_tstring_content
    end
  end
end
