# frozen_string_literal: true

require 'openssl'

module Wurk
  module UniqueJobs
    # The class named by a payload, and the options it declares. Each reader
    # below resolves an option the way the gem does, field by field, because the
    # digest and the TTL a gem-run process computes have to come out the same here.
    module JobOptions
      attr_reader :job_class

      def job_class=(name)
        @original_job_class = name
        @job_class = UniqueJobs.safe_constantize(name)
      end

      def job_method_defined?(name) = job_class.respond_to?(name)
      def sidekiq_job_class? = job_method_defined?(:get_sidekiq_options)

      def job_options
        return {} unless sidekiq_job_class?

        UniqueJobs.deep_stringify(job_class.get_sidekiq_options)
      end

      def default_job_options = Wurk.default_job_options

      # `after_unlock` on the job class, called with the payload when it takes one.
      def after_unlock_hook
        owner = [@original_job_class, job_class].find { |klass| klass.respond_to?(:after_unlock) }
        lambda do
          next unless owner

          owner.method(:after_unlock).arity.positive? ? owner.after_unlock(item) : owner.after_unlock
        end
      end
    end

    class LockType
      include JobOptions

      def self.call(item) = new(item).call

      def initialize(item)
        @item = item
        self.job_class = item[CLASS]
      end

      def call = @item[LOCK] || job_options[LOCK] || default_job_options[LOCK]
    end

    class LockTimeout
      include JobOptions

      def self.calculate(item) = new(item).calculate

      def initialize(item)
        @item = item
        self.job_class = item[CLASS]
      end

      def calculate
        timeout = default_job_options[LOCK_TIMEOUT]
        timeout = UniqueJobs.config.lock_timeout if UniqueJobs.config.lock_timeout
        options = job_options
        timeout = options[LOCK_TIMEOUT] if options.key?(LOCK_TIMEOUT)
        timeout
      end
    end

    # Seconds the lock lives: the option, plus the wait until `at` for a
    # scheduled job, computed at push time as the gem does.
    class LockTTL
      include JobOptions

      def self.calculate(item) = new(item).calculate

      def initialize(item)
        @item = item
        self.job_class = item[CLASS]
      end

      def calculate
        ttl = fetch_ttl
        return unless ttl

        timing = calculate_timing(ttl)
        return unless timing

        timing.to_i + time_until_scheduled
      end

      def time_until_scheduled
        at = @item[AT]
        return 0 unless at

        [0, at.to_i - ::Time.now.utc.to_i].max
      end

      private

      def fetch_ttl
        options = job_options
        @item[LOCK_TTL] || options[LOCK_TTL] || @item[LOCK_EXPIRATION] || options[LOCK_EXPIRATION] ||
          UniqueJobs.config.lock_ttl
      end

      def calculate_timing(ttl)
        case ttl
        when ::String, ::Numeric then ttl
        when ::Proc then ttl.call(@item[ARGS])
        when ::Symbol then job_class.send(ttl, @item[ARGS])
        else
          raise ArgumentError, "#{ttl.class} is not supported for lock_ttl" unless ttl.respond_to?(:to_i)

          ttl
        end
      end
    end

    # The arguments the digest covers: `lock_args_method` (a Proc, or a Symbol
    # naming a class method), else a `lock_args` / `unique_args` class method,
    # else every argument. The method sees the arguments after a JSON round trip.
    class LockArgs
      include JobOptions

      def self.call(item) = new(item).lock_args

      def initialize(item)
        @item = item
        @args = item[ARGS]
        self.job_class = item[CLASS]
      end

      def lock_args = filtered_args || []

      def lock_args_method
        @lock_args_method ||= job_options.slice(LOCK_ARGS_METHOD, UNIQUE_ARGS_METHOD).values.first
        @lock_args_method ||= :lock_args if job_method_defined?(:lock_args)
        @lock_args_method ||= :unique_args if job_method_defined?(:unique_args)
        @lock_args_method ||= default_job_options[LOCK_ARGS_METHOD] || default_job_options[UNIQUE_ARGS_METHOD]
      end

      private

      def filtered_args
        method = lock_args_method
        return @args unless method

        json_args = Wurk.load_json(Wurk.dump_json(@args))
        case method
        when ::Proc then method.call(json_args)
        when ::Symbol then filter_by_symbol(method, json_args)
        end
      end

      def filter_by_symbol(method, args)
        return args unless job_method_defined?(method)

        job_class.send(method, args)
      rescue ArgumentError
        raise InvalidUniqueArguments.new(given: args, job_class: job_class, lock_args_method: method)
      end
    end

    # `uniquejobs:<hex>`: MD5 (`:legacy`, the default) or SHA3-256 (`:modern`)
    # of the sorted `class`/`queue`/`lock_args`/`apartment` pairs, as JSON.
    class LockDigest
      include JobOptions

      def self.call(item) = new(item).lock_digest

      attr_reader :item, :lock_args, :lock_prefix

      def initialize(item)
        @item = item
        @lock_args = item[LOCK_ARGS] || item[UNIQUE_ARGS]
        @lock_prefix = item[LOCK_PREFIX] || item[UNIQUE_PREFIX]
        self.job_class = item[CLASS]
      end

      def lock_digest = @lock_digest ||= create_digest

      def create_digest
        json = Wurk.dump_json(digestable_hash.sort)
        hex = if UniqueJobs.config.digest_algorithm == :legacy
                ::OpenSSL::Digest::MD5.hexdigest(json)
              else
                ::OpenSSL::Digest.new('SHA3-256', json).hexdigest
              end
        "#{lock_prefix}:#{hex}"
      end

      def digestable_hash
        @item.slice(CLASS, QUEUE, LOCK_ARGS, APARTMENT).tap do |hash|
          hash.delete(QUEUE) if unique_across_queues?
          hash.delete(CLASS) if unique_across_workers?
        end
      end

      def unique_across_queues? = @item[UNIQUE_ACROSS_QUEUES] || job_options[UNIQUE_ACROSS_QUEUES]
      def unique_across_workers? = @item[UNIQUE_ACROSS_WORKERS] || job_options[UNIQUE_ACROSS_WORKERS]
    end

    # Fills a payload with what every lock reads, as the gem's `Job.prepare`.
    module Job
      module_function

      def prepare(item)
        item[ON_CONFLICT] = UniqueJobs.deep_stringify(item[ON_CONFLICT]) if item[ON_CONFLICT].is_a?(::Hash)
        item[LOCK] ||= LockType.call(item)
        item[LOCK_TIMEOUT] = LockTimeout.calculate(item)
        item[LOCK_TTL] = LockTTL.calculate(item)
        add_digest(item)
      end

      def add_digest(item)
        item[LOCK_PREFIX] ||= UniqueJobs.config.lock_prefix
        item[LOCK_ARGS] = LockArgs.call(item)
        item[LOCK_DIGEST] = LockDigest.call(item)
        item
      end
    end
  end
end
