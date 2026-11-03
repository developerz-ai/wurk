# frozen_string_literal: true

require_relative 'keys'
require_relative 'queue_consumers'

module Wurk
  # What a standalone runner says once at boot, after the app loaded. Log only,
  # and never allowed to stop a boot: none of this changes behaviour by backend,
  # version or peers.
  module BootChecks
    # Oldest version each non-Redis backend has been run against.
    TESTED_FLOORS = { 'dragonfly' => '1.34.0', 'valkey' => '8.0.0' }.freeze
    MAX_LISTED = 20
    SUBCLASS = ::Module.instance_method(:<)
    NAME = ::Module.instance_method(:name)

    module_function

    def run(config, info)
      log_backend(config.logger, info)
      warn_on_foreign_processes(config)
      warn_on_ignored_locks(config.logger)
    rescue StandardError => e
      config.logger.warn { "wurk boot checks skipped: #{e.class}: #{e.message}" }
    end

    def backend(info)
      return ['dragonfly', info['dragonfly_version'].to_s.delete_prefix('df-v')] if info['dragonfly_version']
      return ['valkey', info['valkey_version'].to_s] if info['valkey_version']

      ['redis', info['redis_version'].to_s]
    end

    def log_backend(logger, info)
      name, version = backend(info)
      logger.info { "Wurk #{Wurk::VERSION} on #{name} #{version}" }
      floor = TESTED_FLOORS[name]
      return unless floor && ::Gem::Version.correct?(version) && ::Gem::Version.new(version) < ::Gem::Version.new(floor)

      logger.warn { "#{name} #{version} is older than the oldest version Wurk is tested against (#{floor})." }
    end

    # Both runtimes share `processes` and the same queues, so a mix is safe only
    # if it is deliberate. Wurk's heartbeat always carries `cores`; stock does not.
    def warn_on_foreign_processes(config)
      foreign = process_infos(config).reject { |_, info| info.nil? || ::JSON.parse(info).key?('cores') }.map(&:first)
      return if foreign.empty?

      config.logger.warn do
        "Live processes that are not Wurk share this Redis: #{listing(foreign)}. " \
          'They fetch from the same queues. If this is not a deliberate rolling cutover, stop them.'
      end
    end

    def process_infos(config)
      config.redis(idempotent: true) do |conn|
        ids = conn.call('SMEMBERS', Keys::PROCESSES)
        ids.empty? ? [] : ids.zip(conn.pipelined { |pipe| ids.each { |id| pipe.call('HGET', id, 'info') } })
      end
    end

    # Without the gem's middleware the option does nothing: the "unique" job
    # simply enqueues twice. Only classes the app has loaded by now are seen.
    def warn_on_ignored_locks(logger)
      return if defined?(::SidekiqUniqueJobs)

      classes = locked_job_classes
      return if classes.empty?

      logger.warn do
        'These jobs set `lock:` but sidekiq-unique-jobs is not loaded, so the option does nothing and ' \
          "duplicates will run: #{listing(classes)}. Keep the gem, or move them to `unique_for:`."
      end
    end

    # A walk over every class meets classes that redefine these with other arguments
    # (Faker::Travel::Airport.name takes required keywords), and one such class must
    # not cost the app this check.
    def locked_job_classes
      ::ObjectSpace.each_object(::Class).filter_map do |klass|
        next unless SUBCLASS.bind_call(klass, Wurk::Worker)

        name = NAME.bind_call(klass)
        name if name && klass.get_sidekiq_options.key?('lock')
      end.sort
    end

    def listing(names)
      extra = names.size - MAX_LISTED
      names.first(MAX_LISTED).join(', ') + (extra.positive? ? " and #{extra} more" : '')
    end
  end
end
