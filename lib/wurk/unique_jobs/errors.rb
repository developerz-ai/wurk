# frozen_string_literal: true

module Wurk
  module UniqueJobs
    # The gem's error hierarchy, by name, so `rescue SidekiqUniqueJobs::Conflict`
    # and friends keep compiling and keep catching what they caught.
    class UniqueJobsError < ::RuntimeError; end

    # `on_conflict: :raise`: the push meets a lock held by another job.
    class Conflict < UniqueJobsError
      def initialize(item)
        super("Item with the key: #{item[LOCK_DIGEST]} is already scheduled or processing")
      end
    end

    class NoBlockGiven < UniqueJobsError; end
    class NoSuchNotificationError < UniqueJobsError; end
    class DuplicateLock < UniqueJobsError; end
    class DuplicateStrategy < UniqueJobsError; end
    class InvalidArgument < UniqueJobsError; end
    class UnknownLock < UniqueJobsError; end

    class InvalidWorker < UniqueJobsError
      def initialize(lock_config)
        super(<<~MESSAGE)
          Expected #{lock_config.job} to have valid sidekiq options but found the following problems:
          #{lock_config.errors_as_string}
        MESSAGE
      end
    end

    class InvalidUniqueArguments < UniqueJobsError
      def initialize(given:, job_class:, lock_args_method:)
        method = job_class.method(lock_args_method)
        super("#{job_class}##{lock_args_method} takes #{method.arity} arguments, received #{given.inspect}" \
              "\n\n   #{Array(method.source_location).join(':')}")
      end
    end

    class NotUniqueWorker < UniqueJobsError
      def initialize(options)
        super("#{options[:class] || options['class']} is not configured for uniqueness. " \
              "Missing the key `:lock` in #{options.inspect}")
      end
    end

    module Script
      class Misconfiguration < ::RuntimeError; end

      # A lock script refused by the server. The gem raises it for its Lua; here
      # it wraps a RedisClient error from one of the scripts in `lib/wurk/lua/`,
      # so an app's `rescue SidekiqUniqueJobs::Script::LuaError` still sees a
      # script failure rather than a raw Redis error class.
      class LuaError < ::RuntimeError
        PATTERN = /ERR Error (compiling|running) script \(.*?\): .*?:(\d+): (.*)/

        attr_reader :error, :file, :content

        def self.intercepts?(error) = PATTERN.match?(error.message)

        def initialize(error, script)
          @error = error
          @file = script.path
          @content = script.source
          super(error.message)
          set_backtrace(error.backtrace) if error.backtrace
        end
      end
    end
  end
end
