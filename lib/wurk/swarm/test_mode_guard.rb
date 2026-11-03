# frozen_string_literal: true

module Wurk
  class Swarm
    # A worker in Sidekiq::Testing's fake or inline mode enqueues nothing: every
    # job its jobs and cron ticks push lands in an in-memory array and is gone.
    # The usual cause is rspec-sidekiq outside the Gemfile's test group, which turns
    # fake mode on as it loads, and the swarm's Bundler.require of the default group
    # is what loads it. Stock Sidekiq drops those jobs without a word; a worker has
    # no reason to run in a test mode, so this puts it back and says so.
    #
    # Except in a test environment. `disable!` is process-global, and a suite that
    # boots Embedded or the CLI in-process would lose fake mode for every test after.
    module TestModeGuard
      module_function

      def enforce!(logger)
        return if Testing.disabled? || test_environment?

        mode = Testing.mode
        Testing.disable!
        logger.error do
          "Sidekiq::Testing was in #{mode} mode in a worker process, where it would silently drop every " \
            'enqueue. Disabled it for this process. Move the gem or code that enables it (usually ' \
            'rspec-sidekiq) to the test group of your Gemfile.'
        end
      end

      def test_environment? = ENV['RAILS_ENV'] == 'test' || ENV['RACK_ENV'] == 'test'
    end
  end
end
