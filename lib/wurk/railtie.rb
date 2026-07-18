# frozen_string_literal: true

require 'rails/railtie'
require 'active_support/ordered_options'

module Wurk
  # Boot the swarm after the host app has fully initialized.
  # Skip when: WURK_DISABLED=1, Rails console mode, or Rails test env.
  # See docs/idea/03-process-model.md for the exact ordering.
  class Railtie < ::Rails::Railtie
    # Host-facing config namespace. Pre-created so a host can write
    # `config.wurk.embed_in_web = true` in config/application.rb without a
    # NoMethodError — the setter needs the OrderedOptions to already exist.
    # Shared with the application config via Rails' Railtie::Configuration
    # @@options, so `Rails.application.config.wurk` reads back the same object.
    config.wurk = ::ActiveSupport::OrderedOptions.new

    # This Rails process forks the workers, so it IS the server. Enter server
    # mode BEFORE config/initializers load — otherwise the app's
    # `Sidekiq.configure_server` blocks gate on `config.server?` (still false)
    # and are silently dropped. A process that won't run workers (disabled /
    # console / test, or one that refuses to boot under a preforking web
    # server) is not a server.
    initializer 'wurk.server_mode', before: :load_config_initializers do |app|
      next if Wurk::Railtie.skip_boot?

      Wurk.enter_server_mode unless Wurk::Railtie.boot_action(app) == :refuse
    end

    config.after_initialize do |app|
      next if Wurk::Railtie.skip_boot?

      case Wurk::Railtie.boot_action(app)
      when :fork   then Wurk::Railtie.boot_swarm
      when :embed  then Wurk::Railtie.boot_embedded
      when :refuse then Wurk::Railtie.refuse_preforking_boot
      end
    end

    # A process that won't run workers isn't a server: skip both server mode
    # and the swarm boot. Console mode is detected reliably here — the console
    # command file defines ::Rails::Console before initializers run.
    def self.skip_boot?
      ENV['WURK_DISABLED'] == '1' ||
        building? ||
        defined?(::Rails::Console) ||
        ::Rails.env.test?
    end

    # What after_initialize should do once skip_boot? is false. Pure — reads
    # env / loaded constants / host config, no side effects — so the boot
    # decision is unit-testable without forking:
    #   :fork   — safe to fork the swarm in the background (the default).
    #   :refuse — a preforking web server owns process forking here; don't.
    #   :embed  — host opted into in-process threads-only via embed_in_web.
    def self.boot_action(app = ::Rails.application)
      return :fork unless preforking_web_server?

      embed_in_web?(app) ? :embed : :refuse
    end

    # Preforking / clustered web servers (Puma cluster, Unicorn, Passenger)
    # fork their own worker processes. Forking the swarm from `after_initialize`
    # in one of them is the highest-risk boot path: without app preloading every
    # server-worker re-runs the hook and forks its own full swarm (N×
    # oversubscription); with preloading the swarm supervisor ends up entangled
    # with the server's own fork/signal supervision. Detect the common three.
    def self.preforking_web_server?
      return true if defined?(::PhusionPassenger)
      return true if defined?(::Unicorn)

      puma_cluster?
    end

    # Puma only preforks in cluster mode (workers > 0); single mode is threaded
    # and safe to co-host the swarm. Best-effort: a missed cluster falls through
    # to the historical fork path; an over-eager match is escapable via
    # embed_in_web / WURK_DISABLED / running the swarm as its own process.
    def self.puma_cluster?
      return false unless defined?(::Puma)

      count = puma_worker_count
      count.is_a?(Integer) && count.positive?
    end

    # Worker count from Puma's parsed CLI config when the server booted it, else
    # from WEB_CONCURRENCY (the near-universal convention for Puma workers).
    # Guarded — the accessor and options shape vary across Puma versions.
    def self.puma_worker_count
      cfg = ::Puma.cli_config if ::Puma.respond_to?(:cli_config)
      workers = cfg&.options&.[](:workers)
      return workers.to_i if workers

      ENV['WEB_CONCURRENCY']&.to_i
    rescue StandardError
      nil
    end

    # Host opt-in (config/application.rb): run workers as in-process threads
    # instead of forking, like Sidekiq embedded. Set it in application.rb, not
    # an initializer — server mode is decided before initializers load.
    def self.embed_in_web?(app = ::Rails.application)
      app.config.wurk&.embed_in_web == true
    rescue StandardError
      false
    end

    def self.boot_swarm
      swarm = Wurk::Swarm.new(topology: Wurk.configuration.topology)
      swarm.boot
      # Embedded in the Rails process: supervise must run somewhere or queued
      # signals never drain, crashed children never respawn, and memory checks
      # never fire. A background thread keeps the host's main thread free.
      Thread.new do
        swarm.supervise
      rescue StandardError => e
        logger.error { "wurk supervisor thread died: #{e.class}: #{e.message}" }
      end
    end

    # Sidekiq-embedded parity: a threads-only worker inside the web process, no
    # fork. Redis validation failure keeps the host serving HTTP (log + carry
    # on). at_exit drains on the graceful shutdown the web server runs on TERM.
    def self.boot_embedded
      instance = Wurk::Embedded.new(Wurk.configuration)
      instance.run
      at_exit { instance.stop }
      logger.info { 'wurk: running embedded in the web process (config.wurk.embed_in_web) — threads only, no fork' }
      instance
    rescue StandardError => e
      logger.error { "wurk: embedded boot failed: #{e.class}: #{e.message}" }
      nil
    end

    def self.refuse_preforking_boot
      logger.warn { <<~MSG }
        wurk: preforking web server detected (Puma cluster / Unicorn / Passenger).
        Refusing to fork the worker swarm from a process that forks its own workers.
        Run the swarm as its own process instead:

            bundle exec wurkswarm    # forked swarm, real parallelism
            bundle exec wurk         # single process, thread pool

        Or run workers inside this web process (threads only, no fork):

            # config/application.rb
            config.wurk.embed_in_web = true

        Already running workers elsewhere? Set WURK_DISABLED=1 here to silence this.
      MSG
    end

    def self.logger
      Wurk.configuration.logger
    end

    # A build/precompile step must never fork the swarm (#247). The default
    # Rails Dockerfile runs `SECRET_KEY_BASE_DUMMY=1 ./bin/rails
    # assets:precompile`; that loads `:environment` → fires after_initialize,
    # but there's no Redis during `docker build`, so a fork would hang/fail the
    # build. Same for other env-loading rake tasks (db:prepare, db:migrate).
    # The real server path is unaffected: `rails server` / `puma` boot through
    # Rails::Command, not Rake, and don't set the dummy secret.
    def self.building?
      return true if ENV.key?('SECRET_KEY_BASE_DUMMY')

      defined?(::Rake) && ::Rake.application.top_level_tasks.any?
    rescue StandardError
      false
    end
  end
end
