# frozen_string_literal: true

require_relative '../test_helper'
require 'open3'
require 'rbconfig'
require 'wurk/rspec'

# `require "wurk/rspec"`: rspec-sidekiq 5.x's have_enqueued_sidekiq_job and
# enqueue_sidekiq_job, driven through rspec-expectations' own `expect` so the
# chains, argument matchers, negation and messages are what a spec sees.
class RSpecMatchersTest < Wurk::Test::UnitCase
  include RSpec::Matchers
  include RSpec::Mocks::ArgumentMatchers
  include Wurk::RSpecMatchers

  parallelize_me!

  NotMet = RSpec::Expectations::ExpectationNotMetError

  class MailJob
    include Sidekiq::Job

    sidekiq_options queue: 'mail'
  end

  class OtherJob
    include Sidekiq::Job
  end

  def setup
    super
    @mode = Wurk::Testing.mode
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
  end

  def teardown
    Sidekiq::Worker.clear_all
    Wurk::Testing.__set_test_mode(@mode)
  ensure
    super
  end

  def test_have_enqueued_matches_arguments_like_a_message_expectation
    MailJob.perform_async(42, 'to' => 'a@b.c', 'cc' => nil)

    expect(MailJob).to have_enqueued_sidekiq_job
    expect(MailJob).to have_enqueued_sidekiq_job(42, { 'to' => 'a@b.c', 'cc' => nil })
    expect(MailJob).to have_enqueued_sidekiq_job(kind_of(Integer), hash_including('to' => 'a@b.c'))
    # A matcher sees the job as JSON left it: string keys.
    expect(MailJob).not_to have_enqueued_sidekiq_job(anything, hash_including(to: 'a@b.c'))
    expect(MailJob).to have_enqueued_sidekiq_job(anything, anything)
    expect(MailJob).not_to have_enqueued_sidekiq_job(43, anything)
    expect(OtherJob).not_to have_enqueued_sidekiq_job
  end

  def test_expected_symbols_are_stringified_as_the_json_round_trip_does
    OtherJob.perform_async('pending', { 'state' => 'open' })

    expect(OtherJob).to have_enqueued_sidekiq_job(:pending, { state: :open })
  end

  def test_a_wrong_argument_fails_with_the_jobs_it_saw
    MailJob.perform_async(42)

    error = assert_raises(NotMet) { expect(MailJob).to have_enqueued_sidekiq_job(41) }

    assert_match(/expected to have enqueued a .*MailJob job with arguments \[41\]/, error.message)
    assert_match(/but enqueued 1 .*MailJob job\(s\):\n  - JID:\h+ with arguments \[42\]/, error.message)
  end

  def test_queue_and_time
    MailJob.perform_async(1)
    MailJob.set(queue: 'bulk').perform_in(300, 2)
    at = Time.now + 3600
    MailJob.perform_at(at, 3)

    expect(MailJob).to have_enqueued_sidekiq_job(1).on('mail').immediately
    # Whole seconds on both sides: a second boundary between the push and the
    # matcher would fail `.in(300)`, so the exact form is shown with `.at`.
    expect(MailJob).to have_enqueued_sidekiq_job(2).on(:bulk).in(be_within(2).of(Time.now + 300))
    expect(MailJob).to have_enqueued_sidekiq_job(3).at(at)
    expect(MailJob).to have_enqueued_sidekiq_job(3).at(be_within(5).of(at))
    expect(MailJob).not_to have_enqueued_sidekiq_job(2).immediately
    expect(MailJob).not_to have_enqueued_sidekiq_job(1).on('bulk')
  end

  def test_counts
    3.times { MailJob.perform_async(7) }

    expect(MailJob).to have_enqueued_sidekiq_job(7).thrice
    expect(MailJob).to have_enqueued_sidekiq_job(7).exactly(3).times
    expect(MailJob).to have_enqueued_sidekiq_job(7).exactly(:thrice)
    expect(MailJob).to have_enqueued_sidekiq_job(7).at_least(:twice)
    expect(MailJob).to have_enqueued_sidekiq_job(7).at_most(4).times
    expect(MailJob).to have_enqueued_sidekiq_job(8).never
    assert_raises(NotMet) { expect(MailJob).to have_enqueued_sidekiq_job(7).once }
    assert_raises(ArgumentError) { have_enqueued_sidekiq_job.exactly(:often) }
  end

  def test_enqueue_counts_only_what_the_block_pushed
    MailJob.perform_async(1)

    expect { MailJob.perform_async(2) }.to enqueue_sidekiq_job(MailJob).with(2).once
    expect { MailJob.perform_async(3) }.not_to enqueue_sidekiq_job(MailJob).with(1)
    expect { OtherJob.perform_async }.not_to enqueue_sidekiq_job(MailJob)
    expect { OtherJob.perform_async }.to enqueue_sidekiq_job
    expect { MailJob.perform_in(60, 4) }.to enqueue_sidekiq_job(MailJob).with(4).in(be_within(2).of(Time.now + 60))
  end

  def test_negation_says_how_many_matched
    expect_block = -> { expect { MailJob.perform_async(1) }.not_to enqueue_sidekiq_job(MailJob) }

    error = assert_raises(NotMet, &expect_block)

    assert_match(/expected not to enqueue a .*MailJob job with arguments .*, but 1 matched/, error.message)
  end

  def test_enqueue_takes_a_block_only
    assert_raises(ArgumentError) { enqueue_sidekiq_job(MailJob).matches?(MailJob) }
    assert_predicate enqueue_sidekiq_job(MailJob), :supports_block_expectations?
  end

  def test_an_active_job_wrapper_is_refused
    Sidekiq::Queues.push('default', 'Sidekiq::ActiveJob::Wrapper',
                         'class' => 'Sidekiq::ActiveJob::Wrapper', 'args' => [{}], 'jid' => 'aj', 'queue' => 'default')

    error = assert_raises(ArgumentError) { expect(Sidekiq::Worker).to have_enqueued_sidekiq_job }

    assert_match(/use have_enqueued_job/, error.message)
  end

  # What an app gets from the require alone, in a real RSpec run.
  def test_the_require_includes_the_matchers_in_every_example_group
    spec = <<~RUBY
      require 'rspec/core'
      require 'wurk/rspec'
      Sidekiq::Testing.fake!
      class RequireOnlyJob; include Sidekiq::Job; end
      RSpec.describe('a spec with no include') do
        it('sees both matchers') do
          expect { RequireOnlyJob.perform_async(1) }.to enqueue_sidekiq_job(RequireOnlyJob).with(1)
          expect(RequireOnlyJob).to have_enqueued_sidekiq_job(1)
        end
      end
      exit RSpec::Core::Runner.run([])
    RUBY
    out, err, status = Open3.capture3({ 'BUNDLE_GEMFILE' => File.expand_path('../../Gemfile', __dir__) },
                                      RbConfig.ruby, '-rbundler/setup', '-I', File.expand_path('../../lib', __dir__),
                                      '-e', spec)

    assert_predicate status, :success?, "#{out}\n#{err}"
    assert_match(/1 example, 0 failures/, out)
  end

  def test_composes_and_describes
    MailJob.perform_async(1)

    expect(MailJob).to have_enqueued_sidekiq_job(1).and have_enqueued_sidekiq_job(kind_of(Integer))
    matcher = have_enqueued_sidekiq_job(1).twice
    matcher.matches?(MailJob)

    assert_match(/have enqueued 2 .*MailJob jobs with arguments \[1\]/, matcher.description)
  end
end
