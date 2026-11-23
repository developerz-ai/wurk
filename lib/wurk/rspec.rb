# frozen_string_literal: true

require 'rspec/expectations'
require 'rspec/mocks'
require_relative '../wurk'

module Wurk
  # rspec-sidekiq 5.x's enqueue matchers, for an app that drops that gem (its
  # `add_dependency "sidekiq"` pulls real Sidekiq into the bundle). Opt in from a
  # spec helper; nothing in `require "wurk"` loads RSpec:
  #
  #   require "wurk/rspec"
  #
  #   expect(MyJob).to have_enqueued_sidekiq_job(id, kind_of(Integer))   # jobs already pushed
  #   expect { act }.to enqueue_sidekiq_job(MyJob).with(id).in(5.minutes) # jobs the block pushes
  #
  # Chains: with(*args), on(queue), at(time), in(interval), immediately,
  # once/twice/thrice, exactly(n)/at_least(n)/at_most(n) (+ .times), never.
  # Arguments match like a message expectation (anything, hash_including,
  # kind_of, ...); expected symbols and hash keys are stringified, as the JSON
  # round trip does to the job. `at`/`in` compare whole seconds against the
  # job's `at`; `immediately` means none.
  #
  # Both read the fake queues (`Sidekiq::Testing.fake!`, `MyJob.jobs`). This
  # file does not switch fake mode on; rspec-sidekiq's `require "sidekiq/testing"`
  # did. See docs/testing.md.
  #
  # Ported from the in-house replacement
  # an adopter wrote when it dropped rspec-sidekiq.
  module RSpecMatchers
    # Shared chain + matching logic. Subclasses set @klass/@actual_jobs and name the verb.
    class Base
      include ::RSpec::Matchers::Composable
      include ::RSpec::Mocks::ArgumentMatchers

      COUNT_WORDS = { once: 1, twice: 2, thrice: 3 }.freeze

      attr_reader :actual_jobs

      def initialize
        @expected_arguments = [any_args]
        @expected_options = {}
        @expected_count = [:positive, 1]
        @actual_jobs = []
      end

      def with(*expected_arguments)
        @expected_arguments = stringify(expected_arguments)
        self
      end

      def on(queue)
        @expected_options['queue'] = stringify(queue)
        self
      end

      def at(timestamp)
        @expected_options['at'] = ::RSpec::Matchers.is_a_matcher?(timestamp) ? timestamp : timestamp.to_time.to_i
        self
      end

      def in(interval)
        @expected_options['at'] =
          ::RSpec::Matchers.is_a_matcher?(interval) ? interval : (Time.now.to_f + interval.to_f).to_i
        self
      end

      def immediately
        @expected_options['at'] = nil
        self
      end

      def never = count(:exactly, 0)

      def once = count(:exactly, 1)

      def twice = count(:exactly, 2)

      def thrice = count(:exactly, 3)

      def exactly(number) = count(:exactly, number)

      def at_least(number) = count(:at_least, number)

      def at_most(number) = count(:at_most, number)

      def times = self
      alias time times

      def description
        "#{verb} #{count_phrase} #{@klass} #{job_noun} with arguments #{format(@expected_arguments)}"
      end

      def failure_message
        lines = ["expected to #{description}"]
        lines << "  with context: #{format(@expected_options)}" if @expected_options.any?
        lines << actual_jobs_lines
        lines.join("\n")
      end

      def failure_message_when_negated
        lines = ["expected not to #{description}, but #{matching_jobs.size} matched"]
        lines << "  with context: #{format(@expected_options)}" if @expected_options.any?
        lines << actual_jobs_lines(prefix: 'of')
        lines.join("\n")
      end

      private

      def count(relativity, number)
        @expected_count = [relativity, COUNT_WORDS.fetch(number, number)]
        raise ArgumentError, "count must be an Integer or :once/:twice/:thrice, got #{number.inspect}" unless
          @expected_count.last.is_a?(Integer)

        self
      end

      def jobs_of(klass)
        klass.jobs.map do |job|
          raise ArgumentError, "#{job['class']} is an ActiveJob wrapper; use have_enqueued_job" if
            job['class'] == 'Sidekiq::ActiveJob::Wrapper'

          job.dup
        end
      end

      def count_satisfied?
        matched = matching_jobs.size
        relativity, number = @expected_count
        case relativity
        when :exactly then matched == number
        when :at_least then matched >= number
        when :at_most then matched <= number
        else matched.positive?
        end
      end

      def matching_jobs
        @actual_jobs.select { |job| arguments_match?(job) && options_match?(job) }
      end

      def arguments_match?(job)
        ::RSpec::Mocks::ArgumentListMatcher.new(*@expected_arguments).args_match?(*job['args'])
      end

      def options_match?(job)
        @expected_options.all? do |key, expected|
          if key == 'at'
            at_matches?(job, expected)
          else
            job.key?(key) && ::RSpec::Support::FuzzyMatcher.values_match?(expected, job[key])
          end
        end
      end

      def at_matches?(job, expected)
        return expected.nil? if job['at'].to_s.empty?
        return expected.matches?(Time.at(job['at'])) if ::RSpec::Matchers.is_a_matcher?(expected)

        expected == Time.at(job['at']).to_i
      end

      def stringify(value)
        case value
        when Array then value.map { |item| stringify(item) }
        when Hash then value.to_h { |key, item| [key.to_s, stringify(item)] }
        when Symbol then value.to_s
        else value
        end
      end

      def count_phrase
        relativity, number = @expected_count
        case relativity
        when :positive then 'a'
        when :exactly then number.to_s
        else "#{relativity.to_s.tr('_', ' ')} #{number}"
        end
      end

      def job_noun = @expected_count.last == 1 ? 'job' : 'jobs'

      def actual_jobs_lines(prefix: 'but')
        return "#{prefix} enqueued 0 jobs" if @actual_jobs.empty?

        listed = @actual_jobs.map do |job|
          line = "  - JID:#{job['jid']} with arguments #{format(job['args'])}"
          line += " queue=#{job['queue'].inspect} at=#{job['at'].inspect}" if @expected_options.any?
          line
        end
        ["#{prefix} enqueued #{@actual_jobs.size} #{@klass} job(s):", *listed].join("\n")
      end

      def format(value) = ::RSpec::Support::ObjectFormatter.format(value)
    end

    # expect(JobClass).to have_enqueued_sidekiq_job(*args)
    class HaveEnqueuedSidekiqJob < Base
      def matches?(job_class)
        @klass = job_class
        @actual_jobs = jobs_of(job_class)
        count_satisfied?
      end

      private

      def verb = 'have enqueued'
    end

    # expect { ... }.to enqueue_sidekiq_job(JobClass) — only jobs the block pushed count.
    class EnqueueSidekiqJob < Base
      def initialize(job_class)
        super()
        @klass = job_class
      end

      def matches?(block)
        raise ArgumentError, 'enqueue_sidekiq_job supports block expectations only' unless block.is_a?(Proc)

        before_jids = jobs_of(@klass).to_set { |job| job['jid'] }
        block.call
        @actual_jobs = jobs_of(@klass).reject { |job| before_jids.include?(job['jid']) }
        count_satisfied?
      end

      def supports_block_expectations? = true

      private

      def verb = 'enqueue'
    end

    # No arguments means any arguments, as in rspec-sidekiq.
    def have_enqueued_sidekiq_job(*expected_arguments) # rubocop:disable Naming/PredicatePrefix -- rspec-sidekiq's name
      matcher = HaveEnqueuedSidekiqJob.new
      expected_arguments.empty? ? matcher : matcher.with(*expected_arguments)
    end

    # No class means every job class (Sidekiq::Worker.jobs spans them all).
    def enqueue_sidekiq_job(job_class = ::Sidekiq::Worker)
      EnqueueSidekiqJob.new(job_class)
    end
  end
end

RSpec.configure { |config| config.include(Wurk::RSpecMatchers) } if RSpec.respond_to?(:configure)
