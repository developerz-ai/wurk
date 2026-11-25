# frozen_string_literal: true

module Wurk
  module SidekiqCron
    class Job
      # Firing an entry: the gates a poll applies, and the push itself, shaped
      # as sidekiq-cron shapes it (class options, then the entry's queue/retry).
      module Enqueue
        # The gem's three gates in its order: enabled, the occurrence due now is
        # within `reschedule_grace_period`, and this object has not fired it.
        # Then the ZADD decides between every poller that got this far.
        def should_enqueue?(time)
          return false unless enabled?

          slot = due_slot(time)
          return false if slot.nil?
          return false if @last_enqueue_time && @last_enqueue_time.to_i >= slot.to_i

          added = redis { |conn| conn.zadd(job_enqueued_key, slot.to_f.to_s, slot.iso8601) }
          [true, 1].include?(added)
        end

        def remove_previous_enqueues(time)
          redis { |conn| conn.zremrangebyscore(job_enqueued_key, 0, "(#{time.to_f - REMEMBER_THRESHOLD}") }
        end

        def test_and_enqueue_for_time!(time)
          return unless should_enqueue?(time)

          if constantize(@klass.to_s).nil?
            skip_unknown_class
            remove_previous_enqueues(time)
            return
          end

          enqueue!
          remove_previous_enqueues(time)
        end

        # The occurrence is already claimed, so it will not fire again until
        # the next one. Warn on every skipped occurrence and report once per
        # entry per process, as Wurk::Cron does: a by-name push here would drop
        # the worker's sidekiq_options and fail under the entry's retries.
        def skip_unknown_class
          message = "[sidekiq-cron] class #{@klass} is not defined in this process entry=#{@name} " \
                    'occurrence skipped; retire the entry to stop the reports'
          ::Sidekiq.logger.warn(message)

          key = [@namespace, @name]
          return unless self.class.unknown_worker_classes.add?(key)

          Wurk.configuration.handle_exception(
            UnknownWorkerClass.new(message),
            { context: 'sidekiq-cron', name: @name, namespace: @namespace, klass: @klass.to_s }
          )
        end

        def enqueue!(time = ::Time.now.utc)
          @last_enqueue_time = time
          klass_const = constantize(@klass.to_s)
          jid = if klass_const.nil?
                  ::Sidekiq::Client.push(@active_job ? active_job_message : sidekiq_worker_message)
                elsif is_active_job?(klass_const)
                  provider_job_id(enqueue_active_job(klass_const))
                else
                  enqueue_sidekiq_worker(klass_const)
                end
          save_last_enqueue_time
          add_jid_history(jid)
          ::Sidekiq.logger.debug { "enqueued #{@name}: #{@message}" }
          jid
        end

        def is_active_job?(klass = nil) # rubocop:disable Naming/PredicatePrefix -- sidekiq-cron's name
          return true if @active_job
          return false unless defined?(::ActiveJob::Base)

          klass ||= constantize(@klass.to_s)
          klass.is_a?(::Class) && klass < ::ActiveJob::Base
        end

        def date_as_argument? = @date_as_argument

        def symbolize_args? = @symbolize_args

        def enqueue_args
          Arguments.deserialize(date_as_argument? ? @args + [::Time.now.to_f] : @args)
        end

        def enqueue_active_job(klass_const)
          klass_const.set(queue: @queue).perform_later(*enqueue_args)
        end

        def enqueue_sidekiq_worker(klass_const)
          klass_const.set(queue: queue_name_with_prefix, retry: @retry).perform_async(*enqueue_args)
        end

        def sidekiq_worker_message
          message = @message.is_a?(::String) ? ::JSON.parse(@message) : @message.dup
          message['args'] = enqueue_args
          message
        end

        def active_job_message
          {
            'class' => 'ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper',
            'wrapped' => @klass,
            'queue' => @queue_name_with_prefix,
            'description' => @description,
            'args' => [{ 'job_class' => @klass, 'job_id' => ::SecureRandom.uuid,
                         'queue_name' => @queue_name_with_prefix, 'arguments' => enqueue_args }]
          }
        end

        def queue_name_with_prefix
          return @queue unless is_active_job?

          prefix = active_job_setting(@active_job_queue_name_prefix, :queue_name_prefix)
          return @queue if prefix.empty?

          "#{prefix}#{active_job_setting(@active_job_queue_name_delimiter, :queue_name_delimiter, '_')}#{@queue}"
        end

        def jid_history_from_redis
          redis { |conn| conn.lrange(jid_history_key, 0, -1) }.map { |raw| ::JSON.parse(raw) }
        end

        def save_last_enqueue_time
          redis { |conn| conn.hset(redis_key, 'last_enqueue_time', serialized_last_enqueue_time) }
        end

        def add_jid_history(jid)
          entry = ::JSON.generate(jid: jid, enqueued: @last_enqueue_time)
          keep = SidekiqCron.configuration.cron_history_size.to_i - 1
          redis do |conn|
            conn.lpush(jid_history_key, entry)
            conn.ltrim(jid_history_key, 0, keep)
          end
        end

        private

        def active_job_setting(own, setting, fallback = '')
          return own.to_s unless own.to_s.empty?
          return fallback unless defined?(::ActiveJob::Base) && ::ActiveJob::Base.respond_to?(setting)

          value = ::ActiveJob::Base.public_send(setting).to_s
          value.empty? ? fallback : value
        end

        def provider_job_id(job)
          job.provider_job_id if job.respond_to?(:provider_job_id)
        end

        # The newest occurrence, or nil when it is older than the grace period
        # (the gem's `past_scheduled_time?`). Measured to the newest one only, so
        # the search never needs to look back further than the grace.
        def due_slot(time)
          grace = SidekiqCron.configuration.reschedule_grace_period.to_i
          slot = schedule.previous_time(time, grace + 60)
          slot if slot && time.to_i - slot.to_i <= grace
        end
      end
    end
  end
end
