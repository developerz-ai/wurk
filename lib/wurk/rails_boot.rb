# frozen_string_literal: true

module Wurk
  # Coordinates how Wurk boots inside a Rails host: whether this process should
  # boot at all, whether it may fork the swarm, and the boot itself. The Railtie
  # owns only the Rails hooks (config namespace + server_mode initializer +
  # after_initialize) and delegates every decision and side effect here, so the
  # boot policy stays pure and unit-testable without the Railtie DSL.
  # See docs/idea/03-process-model.md for the exact ordering.
  module RailsBoot
    # What `at_exit` waits for the supervise thread on top of the swarm's own
    # drain budget: one supervise tick to notice the request, plus slack for
    # the final reap.
    DRAIN_JOIN_SLACK = 1

    module_function

    # Invoked from the `wurk.server_mode` initializer, before config/initializers
    # load. This Rails process forks the workers, so it IS the server. Enter
    # server mode now — otherwise the app's `Sidekiq.configure_server` blocks
    # gate on `config.server?` (still false) and are silently dropped. A process
    # that won't run workers (skip_boot?, or one that refuses to boot under a
    # preforking web server) is not a server.
    def enter_server_mode_if_serving(app = ::Rails.application)
      return if skip_boot?
      return if boot_action(app) == :refuse

      Wurk.enter_server_mode
    end

    # Invoked from after_initialize, once the host app has fully initialized.
    def boot(app = ::Rails.application)
      return if skip_boot?

      case boot_action(app)
      when :fork   then boot_swarm
      when :embed  then boot_embedded
      when :refuse then refuse_preforking_boot
      end
    end

    # A process that won't run workers isn't a server: skip both server mode
    # and the swarm boot. Console mode is detected reliably here — the console
    # command file defines ::Rails::Console before initializers run.
    #
    # `Wurk.worker_boot_claimed?` covers the CLI: `bundle exec wurk` boots the
    # host app itself and then runs a Launcher in this very process, so forking
    # a swarm here as well would put two independent workers on one queue and
    # run every job — every cron tick included — twice.
    def skip_boot?
      ENV['WURK_DISABLED'] == '1' ||
        Wurk.worker_boot_claimed? ||
        building? ||
        defined?(::Rails::Console) ||
        ::Rails.env.test?
    end

    # What boot should do once skip_boot? is false. Pure — reads env / loaded
    # constants / host config, no side effects — so the boot decision is
    # unit-testable without forking:
    #   :fork   — safe to fork the swarm in the background (the default).
    #   :refuse — a preforking web server owns process forking here; don't.
    #   :embed  — host opted into in-process threads-only via embed_in_web.
    def boot_action(app = ::Rails.application)
      return :fork unless preforking_web_server?

      embed_in_web?(app) ? :embed : :refuse
    end

    # Preforking / clustered web servers (Puma cluster, Unicorn, Passenger)
    # fork their own worker processes. Forking the swarm from `after_initialize`
    # in one of them is the highest-risk boot path: without app preloading every
    # server-worker re-runs the hook and forks its own full swarm (N×
    # oversubscription); with preloading the swarm supervisor ends up entangled
    # with the server's own fork/signal supervision. Detect the common three.
    def preforking_web_server?
      return true if defined?(::PhusionPassenger)
      return true if defined?(::Unicorn)

      puma_cluster?
    end

    # Puma only preforks in cluster mode (workers > 0); single mode is threaded
    # and safe to co-host the swarm. Best-effort: a missed cluster falls through
    # to the historical fork path; an over-eager match is escapable via
    # embed_in_web / WURK_DISABLED / running the swarm as its own process.
    def puma_cluster?
      return false unless defined?(::Puma)

      count = puma_worker_count
      count.is_a?(Integer) && count.positive?
    end

    # Worker count from Puma's parsed CLI config when the server booted it, else
    # from WEB_CONCURRENCY (the near-universal convention for Puma workers).
    # Guarded — the accessor and options shape vary across Puma versions.
    def puma_worker_count
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
    def embed_in_web?(app = ::Rails.application)
      app.config.wurk&.embed_in_web == true
    rescue StandardError
      false
    end

    def boot_swarm
      timeout = Wurk.configuration[:timeout] || Swarm::DEFAULT_SHUTDOWN_TIMEOUT
      swarm = Wurk::Swarm.new(topology: Wurk.configuration.topology, shutdown_timeout: timeout)
      supervisor = nil
      # Registered BEFORE boot, which forks the children one slot at a time: a
      # fork that raises partway through would otherwise leave the children it
      # already spawned with nothing to drain them on host exit. Children
      # inherit the hook — stop_swarm no-ops off the process that forked them.
      at_exit { stop_swarm(swarm, supervisor, timeout + Swarm::SHUTDOWN_GRACE + DRAIN_JOIN_SLACK) }
      # Co-hosted in the web process (e.g. Puma single mode): the host owns the
      # process-wide TERM/INT traps. Installing the swarm's own would hijack
      # them — a deploy TERM would drain the swarm but never stop the HTTP
      # server. Let the host keep signal ownership and drain the swarm on its
      # graceful exit (same contract as boot_embedded).
      swarm.boot(install_signals: false)
      # supervise must still run somewhere or crashed children never respawn and
      # memory checks never fire. A background thread keeps the host's main
      # thread free to serve HTTP.
      supervisor = Thread.new do
        swarm.supervise
      rescue StandardError => e
        logger.error { "wurk supervisor thread died: #{e.class}: #{e.message}" }
      end
    end

    # at_exit fires on the host's main thread, but the supervise thread owns the
    # child table and two threads inside `shutdown` race on it — so request the
    # drain and wait for the supervisor to run it. Draining here is the fallback
    # for when no live supervisor will: it never started (boot raised) or it
    # died early; after one that drained it finds no children and no-ops. A
    # supervisor still alive past the join is wedged mid-drain — leave it be
    # rather than race it; its children self-terminate (OrphanGuard) once this
    # process is gone.
    def stop_swarm(swarm, supervisor, drain_wait)
      return unless swarm.owner?

      swarm.request_shutdown
      supervisor&.join(drain_wait)
      swarm.shutdown unless supervisor&.alive?
    end

    # Sidekiq-embedded parity: a threads-only worker inside the web process, no
    # fork. Redis validation failure keeps the host serving HTTP (log + carry
    # on). at_exit drains on the graceful shutdown the web server runs on TERM.
    def boot_embedded(embedded = Wurk::Embedded)
      instance = embedded.new(Wurk.configuration)
      # Registered BEFORE run, for the reason boot_swarm registers before the
      # fork: run brings the heartbeat, pollers, managers and health listener up
      # one at a time, and a raise partway through would otherwise leave the ones
      # already running with nothing to drain them on host exit.
      at_exit { instance.stop }
      instance.run
      logger.info { 'wurk: running embedded in the web process (config.wurk.embed_in_web) — threads only, no fork' }
      instance
    rescue StandardError => e
      logger.error { "wurk: embedded boot failed: #{e.class}: #{e.message}" }
      instance&.stop
      nil
    end

    def refuse_preforking_boot
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

    def logger
      Wurk.configuration.logger
    end

    # A build/precompile step must never fork the swarm (#247). The default
    # Rails Dockerfile runs `SECRET_KEY_BASE_DUMMY=1 ./bin/rails
    # assets:precompile`; that loads `:environment` → fires after_initialize,
    # but there's no Redis during `docker build`, so a fork would hang/fail the
    # build. Same for other env-loading rake tasks (db:prepare, db:migrate).
    # The real server path is unaffected: `rails server` / `puma` boot through
    # Rails::Command, not Rake, and don't set the dummy secret.
    def building?
      return true if ENV.key?('SECRET_KEY_BASE_DUMMY')

      defined?(::Rake) && ::Rake.application.top_level_tasks.any?
    rescue StandardError
      false
    end
  end
end
