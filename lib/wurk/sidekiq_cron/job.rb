# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'time'
require_relative 'arguments'
require_relative 'schedule'
require_relative 'job/store'
require_relative 'job/enqueue'

module Wurk
  module SidekiqCron
    # `Sidekiq::Cron::Job`, native. One named cron entry, stored where and how
    # sidekiq-cron 2.3/2.4 stores it, so a fleet can run the gem and this side
    # by side, or swap one for the other, with no data migration:
    #
    #   cron_jobs:<namespace>                    SET of the job hash keys
    #   cron_job:<namespace>:<name>              HASH, the `to_hash` fields below
    #   cron_job:<namespace>:<name>:enqueued     ZSET, one member per fired occurrence
    #   cron_job:<namespace>:<name>:jid_history  LIST, newest first
    #
    # State is keyed by name: `status` lives in the hash and only #enable! and
    # #disable! (or a `status` key in the loaded data) change it, so editing a
    # schedule keeps a hand-disabled job disabled.
    #
    # The `:enqueued` ZADD is the exactly-once gate, and the reason a gem pod and
    # a native pod never both fire one occurrence: both add the same member (the
    # occurrence as ISO-8601 UTC) and only the one that added it pushes.
    class Job
      extend Store
      include Enqueue

      JOBS_PREFIX = 'cron_jobs:'
      JOB_PREFIX = 'cron_job:'
      LEGACY_JOBS_KEY = 'cron_jobs'
      REMEMBER_THRESHOLD = 24 * 60 * 60
      LAST_ENQUEUE_TIME_FORMAT = '%Y-%m-%d %H:%M:%S %z'
      GLOBALID_KEY = Arguments::GLOBALID_KEY
      TRUE_FLAG = /\A(true|t|yes|y|1)\z/i

      attr_accessor :name, :namespace, :cron, :description, :klass, :message
      attr_reader :last_enqueue_time, :fetch_missing_args, :source, :args, :status

      def initialize(input_args = {})
        args = input_args.to_h.transform_keys(&:to_s)
        @fetch_missing_args = args.delete('fetch_missing_args')
        @fetch_missing_args = true if @fetch_missing_args.nil?
        assign_identity(args)
        assign_options(args)
        build_message(args)
        @queue_name_with_prefix = queue_name_with_prefix
      end

      # --- state -----------------------------------------------------------

      def enable!
        @status = 'enabled'
        save
      end

      def disable!
        @status = 'disabled'
        save
      end

      def enabled? = @status == 'enabled'

      def disabled? = !enabled?

      def errors
        @errors ||= []
      end

      def valid? # rubocop:disable Metrics/AbcSize -- the gem's checks, one line each
        @errors = []
        errors << "'name' must be set" if @name.nil? || @name.empty?
        errors << "'namespace' must be set" if @namespace.nil? || @namespace.empty?
        errors << "'namespace' cannot be '*'" if @namespace == '*'
        validate_cron
        errors << "'klass' (or class) must be set" unless klass_valid
        errors.empty?
      end

      def klass_valid
        @klass.is_a?(::Class) || (@klass.is_a?(::String) && !@klass.empty?)
      end

      # The gem's hash, field for field: a gem pod reads what this writes.
      def to_hash
        {
          name: @name, namespace: @namespace, klass: @klass.to_s, cron: @cron, description: @description,
          source: @source, args: @args.is_a?(::String) ? @args : ::JSON.generate(@args || []),
          date_as_argument: date_as_argument? ? '1' : '0',
          message: @message.is_a?(::String) ? @message : ::JSON.generate(@message || {}),
          status: @status, active_job: @active_job ? '1' : '0',
          queue_name_prefix: @active_job_queue_name_prefix, queue_name_delimiter: @active_job_queue_name_delimiter,
          retry: @retry.nil? || @retry.is_a?(::Numeric) ? @retry : @retry.to_s,
          last_enqueue_time: serialized_last_enqueue_time, symbolize_args: symbolize_args? ? '1' : '0'
        }
      end

      # Saving an entry the first time also marks its latest past occurrence as
      # fired, so a job added a minute after its slot does not run at once.
      def save # rubocop:disable Naming/PredicateMethod -- the gem's name; true or false as there
        return false unless valid?

        fields = to_hash.transform_values { |value| value || '' }.flatten
        redis do |conn|
          conn.sadd(self.class.jobs_key(@namespace), [redis_key])
          conn.hset(redis_key, *fields)
          mark_created(conn) unless [true, 1].include?(conn.exists(job_enqueued_key))
        end
        true
      end

      def destroy # rubocop:disable Naming/PredicateMethod -- the gem's name
        redis do |conn|
          conn.srem(self.class.jobs_key(@namespace), [redis_key])
          conn.del(job_enqueued_key)
          conn.del(jid_history_key)
          conn.del(redis_key)
        end
        ::Sidekiq.logger.info { "Cron Jobs - deleted job with name #{@name} from namespace #{@namespace}" }
        true
      end

      def exists? = self.class.exists?(@name, @namespace)

      def status_from_redis
        return 'enabled' unless fetch_missing_args

        redis { |conn| conn.hget(redis_key, 'status') } || 'enabled'
      end

      def last_enqueue_time_from_redis
        return nil unless fetch_missing_args

        parse_enqueue_time(redis { |conn| conn.hget(redis_key, 'last_enqueue_time') })
      end

      # --- schedule --------------------------------------------------------

      def schedule
        @schedule = [@cron, Schedule.new(@cron)] unless @schedule&.first == @cron
        @schedule.last
      end

      # The occurrence a poll at `now` would fire (fugit's `previous_time`).
      # Looks back as far as a save needs; the poller asks only for the grace
      # window (#due_slot).
      def last_time(now = ::Time.now.utc)
        schedule.previous_time(now, Schedule::CREATION_LOOKBACK)
      end

      def formatted_enqueue_time(now = ::Time.now.utc) = last_time(now).to_f.to_s

      def formatted_last_time(now = ::Time.now.utc) = last_time(now).iso8601

      def human_cron = @cron

      def cron_expression_string = [schedule.crontab, schedule.zone_name].compact.join(' ')

      def pretty_message
        ::JSON.pretty_generate(@message.is_a?(::String) ? ::JSON.parse(@message) : @message)
      rescue ::JSON::ParserError
        @message
      end

      def sort_name = "#{enabled? ? 0 : 1}_#{name}".downcase

      def args=(args)
        @args = Arguments.parse(args, @symbolize_args)
      end

      def redis_key = self.class.redis_key(@name, @namespace)

      def job_enqueued_key = self.class.job_enqueued_key(@name, @namespace)

      def jid_history_key = self.class.jid_history_key(@name, @namespace)

      private

      def redis(&) = ::Sidekiq.redis(&)

      def flag?(value) = value == true || TRUE_FLAG.match?(value.to_s)

      # Status and last enqueue time come from Redis when the data has none,
      # which is how a reload keeps a hand-set status.
      def assign_identity(args)
        @name = args['name']
        @cron = args['cron']
        @description = args['description'] if args['description']
        @source = args['source'] == 'schedule' ? 'schedule' : 'dynamic'
        @namespace = resolve_namespace(args['namespace'])
        @klass = args['klass'] || args['class']
        @status = args['status'] || status_from_redis
        @last_enqueue_time = initial_last_enqueue_time(args['last_enqueue_time'])
      end

      def assign_options(args)
        @symbolize_args = flag?(args['symbolize_args'])
        @args = Arguments.parse(args['args'], @symbolize_args)
        @date_as_argument = flag?(args['date_as_argument'])
        @active_job = flag?(args['active_job'])
        @active_job_queue_name_prefix = args['queue_name_prefix']
        @active_job_queue_name_delimiter = args['queue_name_delimiter']
        warn_symbolize_args if @symbolize_args && !@active_job
      end

      def resolve_namespace(requested)
        default = SidekiqCron.configuration.default_namespace
        namespace = requested || default
        return namespace unless Namespace.available_namespaces_provided? && !Namespace.all.include?(namespace)

        ::Sidekiq.logger.warn do
          "Cron Jobs - unexpected namespace #{namespace} encountered. Assigning to default namespace."
        end
        default
      end

      def initial_last_enqueue_time(given)
        return parse_enqueue_time(given) if given.is_a?(::String) && !given.empty?

        last_enqueue_time_from_redis
      end

      def warn_symbolize_args
        ::Sidekiq.logger.warn do
          "Cron Jobs - 'symbolize_args' is gonna be ignored, as it is only used when 'active_job' is true"
        end
      end

      # `message` comes back from Redis as the JSON the gem stored; built here
      # it is the class's sidekiq_options with the entry's queue/retry on top.
      def build_message(args) # rubocop:disable Metrics/AbcSize -- the gem's precedence, kept in one place
        if args['message']
          @message = args['message']
          data = ::JSON.parse(@message) || {}
          @queue = data['queue'] || 'default'
          @retry = data['retry']
        elsif @klass
          data = job_options(@klass, @args).merge('class' => @klass.to_s, 'args' => @args)
          @queue = data['queue'] = args['queue'] || data['queue'] || 'default'
          data['retry'] = args['retry'] unless args['retry'].nil?
          @retry = data['retry']
          @message = data
        end
      end

      def job_options(klass, args)
        klass = constantize(klass) unless klass.is_a?(::Class)
        return { 'queue' => 'default' } if klass.nil?
        return { 'queue' => klass.new(args).queue_name } if is_active_job?(klass)

        klass.get_sidekiq_options.dup
      end

      def constantize(name)
        ::Object.const_get(name)
      rescue ::NameError
        nil
      end

      def validate_cron
        return errors << "'cron' must be set" if @cron.nil? || @cron.empty?

        schedule
      rescue ArgumentError => e
        errors << "'cron' -> #{@cron.inspect} -> #{e.class}: #{e.message}"
      end

      def mark_created(conn)
        now = ::Time.now.utc
        slot = last_time(now)
        conn.zadd(job_enqueued_key, now.to_f.to_s, slot.iso8601) if slot
        ::Sidekiq.logger.info { "Cron Jobs - added job with name #{@name} in the namespace #{@namespace}" }
      end

      def serialized_last_enqueue_time
        @last_enqueue_time&.strftime(LAST_ENQUEUE_TIME_FORMAT)
      end

      def parse_enqueue_time(timestamp)
        return nil if timestamp.nil? || timestamp.empty?

        ::Time.strptime(timestamp, LAST_ENQUEUE_TIME_FORMAT).utc
      rescue ArgumentError
        ::Time.parse(timestamp).utc
      end
    end
  end
end
