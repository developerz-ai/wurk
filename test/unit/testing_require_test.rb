# frozen_string_literal: true

require_relative '../test_helper'

# `require "sidekiq/testing"` must flip the process into fake mode, exactly as
# upstream does — without it a migrated suite silently enqueues into real Redis
# while every `MyJob.jobs` assertion comes back empty.
#
# Every case runs in a subprocess: the require's side effect is process-global
# and one-way by design, so asserting it in-process would leak fake mode into
# every other test class sharing this fork.
class TestingRequireTest < Wurk::Test::UnitCase
  parallelize_me!

  LIB = File.expand_path('../../lib', __dir__)

  def ruby(code)
    IO.popen([RbConfig.ruby, '-I', LIB, '-e', code], err: %i[child out], &:read)
  end

  def test_require_sidekiq_testing_enables_fake_mode
    out = ruby('require "sidekiq/testing"; print "MODE=" + Sidekiq::Testing.mode.to_s')

    assert_includes out, 'MODE=fake'
  end

  def test_require_sidekiq_testing_warns_that_it_is_deprecated
    out = ruby('require "sidekiq/testing"')

    assert_includes out, 'deprecated'
  end

  def test_deprecation_warning_points_at_the_replacement_api
    out = ruby('require "sidekiq/testing"')

    assert_includes out, 'Sidekiq.testing!'
  end

  def test_require_does_not_override_an_explicitly_chosen_mode
    out = ruby('require "sidekiq"; Sidekiq::Testing.disable!; require "sidekiq/testing"; ' \
               'print "MODE=" + Sidekiq::Testing.mode.to_s')

    assert_includes out, 'MODE=disable'
  end

  def test_require_does_not_warn_when_a_mode_was_chosen_explicitly
    out = ruby('require "sidekiq"; Sidekiq::Testing.fake!; require "sidekiq/testing"')

    refute_includes out, 'deprecated'
  end

  def test_warning_is_emitted_once_per_process
    out = ruby('require "sidekiq/testing"; Wurk::Testing.deprecated_require!; ' \
               'Wurk::Testing.deprecated_require!')

    assert_equal 1, out.scan('deprecated').size
  end
end
