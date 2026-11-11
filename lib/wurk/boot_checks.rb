# frozen_string_literal: true

require_relative 'keys'
require_relative 'queue_consumers'
require_relative 'capsule'

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
    UNIQUE_OPTIONS = %w[unique_for unique_until].freeze
    STRICT_ENV = 'WURK_STRICT'

    module_function

    # `info` is nil when there is no Redis to ask (`wurk boot-check` without
    # `--redis`): only the checks that read the loaded app run then.
    def run(config, info)
      if info
        log_backend(config.logger, info)
        warn_on_foreign_processes(config)
      end
      warn_on_ignored_locks(config.logger)
      warn_on_ignored_unique(config.logger)
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

    # Only the middleware `unique!` installs reads these options, so without it
    # every push enqueues. Turning it on for the app is a human call, not a
    # boot check's: this only says so.
    def warn_on_ignored_unique(logger)
      return if Wurk::Unique.enabled?

      classes = job_classes_setting(UNIQUE_OPTIONS)
      return if classes.empty?

      logger.warn do
        'These jobs set `unique_for:` or `unique_until:` but unique jobs are not enabled, so the options do ' \
          "nothing and duplicates enqueue: #{listing(classes)}. Enable them once at boot, in an initializer: " \
          '`Sidekiq::Enterprise.unique!`.'
      end
    end

    def locked_job_classes = job_classes_setting(%w[lock])

    # Workers, and ActiveJob classes that take `sidekiq_options` (Wurk::Job::Options).
    # A walk over every class meets classes that redefine these with other arguments
    # (Faker::Travel::Airport.name takes required keywords), and one such class must
    # not cost the app this check.
    def job_classes_setting(options)
      ::ObjectSpace.each_object(::Class).filter_map do |klass|
        next unless SUBCLASS.bind_call(klass, Wurk::Worker) || SUBCLASS.bind_call(klass, Wurk::Job::Options)

        name = NAME.bind_call(klass)
        name if name && klass.get_sidekiq_options.values_at(*options).any?
      end.sort
    end

    # The real gem next to Wurk loads both: `Sidekiq::*` is then partly theirs,
    # partly ours. Gems that depend on `sidekiq` pull it in unless the shim gem,
    # which depends on Wurk instead, satisfies the dependency. Runs as Wurk loads.
    def flag_real_sidekiq_gem(logger, specs: ::Gem.loaded_specs, strict: ENV[STRICT_ENV] == '1')
      message = real_sidekiq_message(specs, logger)
      return unless message
      raise Wurk::Error, message if strict

      logger.error { "#{message} Set #{STRICT_ENV}=1 to refuse to boot instead." }
    end

    def real_sidekiq_message(specs, logger)
      real = specs['sidekiq']
      return if real.nil? || real.dependencies.any? { |dep| dep.name == 'wurk' }

      "The bundle holds the real sidekiq #{real.version} gem, so it loads next to Wurk and the process runs " \
        "half on each. Pulled in by: #{sidekiq_dependents(specs)}. Replace it with the shim in the Gemfile: " \
        "gem 'sidekiq', github: 'developerz-ai/wurk', tag: 'v#{Wurk::VERSION}', " \
        "glob: 'ecosystem/sidekiq-shim/*.gemspec'."
    rescue StandardError => e
      logger.warn { "wurk: could not check the bundle for the real sidekiq gem: #{e.class}: #{e.message}" }
      nil
    end

    def sidekiq_dependents(specs)
      names = specs.each_value.select { |spec| spec.dependencies.any? { |dep| dep.name == 'sidekiq' } }.map(&:name)
      names.empty? ? 'the Gemfile itself' : listing(names.sort)
    end

    # The role line of a process that forks the topology's children and runs no
    # jobs itself. Its children each run the threads of one slot.
    def log_swarm_role(config, role, ar_pool: active_record_pool)
      slots = config.topology.slots.map do |slot|
        ["#{slot.count} #{slot.count == 1 ? 'process' : 'processes'}", slot.concurrency]
      end
      log_role(config, role, slots, per_process: slots.map(&:last).max, ar_pool: ar_pool)
    rescue StandardError => e
      role_skipped(config.logger, e)
    end

    # The role line of a process that runs every capsule's threads itself.
    def log_process_role(config, role, ar_pool: active_record_pool)
      capsules = config.capsules.values
      slots = capsules.map { |cap| [capsules.size > 1 ? "capsule #{cap.name}" : '1 process', cap.concurrency] }
      log_role(config, role, slots, per_process: slots.sum(&:last), ar_pool: ar_pool)
    rescue StandardError => e
      role_skipped(config.logger, e)
    end

    def role_skipped(logger, error)
      logger.warn { "wurk role line skipped: #{error.class}: #{error.message}" }
    end

    # One line per process: what it is, and how big. `per_process` is the most
    # job threads one process runs, which is what its Active Record pool covers.
    def log_role(config, role, slots, per_process:, ar_pool:)
      sizes = slots.map do |label, threads|
        "#{label} × #{threads} threads (redis pool #{redis_pool_size(config, threads)}, fetch #{threads})"
      end
      config.logger.info { "wurk: #{role}; #{sizes.join(' + ')}#{"; AR pool #{ar_pool}" if ar_pool}" }
      warn_on_small_ar_pool(config.logger, ar_pool, per_process)
    end

    # DEBUG, not INFO: Wurk logs to stdout, and every `rails runner`, rake task
    # and `wurk preflight --app` boots the app; their stdout is someone's output.
    def log_client_only(logger, reason)
      logger.debug { "wurk: client only (#{reason}); this process enqueues and runs no jobs" }
    end

    # Capsule#main_pool_size, without building a pool: a swarm parent describes
    # slots whose pools only its children build.
    def redis_pool_size(config, threads)
      config.redis_config[:size] || [threads + Capsule::POOL_HEADROOM, Capsule::MIN_POOL_SIZE].max
    end

    # Every job thread that touches the database holds a connection; with fewer
    # in the pool the rest wait, then fail with ActiveRecord::ConnectionTimeoutError.
    def warn_on_small_ar_pool(logger, ar_pool, threads)
      return unless ar_pool && ar_pool < threads

      logger.warn do
        "The Active Record pool holds #{ar_pool} connections but this process runs up to #{threads} job threads, " \
          'so jobs that use the database wait for a connection and then fail on a timeout. Set `pool:` in ' \
          "config/database.yml to at least #{threads} (plus the web server's threads when jobs run in the web process)."
      end
    end

    # The pool size the app configured, read without opening a connection; nil
    # without Active Record or a configured database. Rails 8.1 renamed `pool`.
    def active_record_pool
      return unless defined?(::ActiveRecord::Base)

      db = ::ActiveRecord::Base.connection_db_config
      db.respond_to?(:max_connections) ? db.max_connections : db.pool
    rescue ::ActiveRecord::ActiveRecordError
      nil
    end

    def listing(names)
      extra = names.size - MAX_LISTED
      names.first(MAX_LISTED).join(', ') + (extra.positive? ? " and #{extra} more" : '')
    end
  end
end
