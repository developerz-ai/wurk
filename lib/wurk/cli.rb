# frozen_string_literal: true

# yaml, optparse and erb are required inside the two methods that use them
# (#parse_config and #option_parser) rather than here. Together they cost ~45ms
# of the ~290ms `require "wurk"` spends, and only `exe/wurk` ever reaches them —
# a Rails app that enqueues and processes jobs pays that on every boot for a
# command-line parser it never runs. `require` is idempotent, so the lazy call
# is a $LOADED_FEATURES hash lookup on every invocation after the first.
require 'rbconfig'
require_relative 'version'
require_relative 'configuration'
require_relative 'component'
require_relative 'capsule'
require_relative 'boot_checks'

module Wurk
  # Standalone CLI. Loads from `exe/wurk` — never loads `wurk/rails` so the
  # binary works without the Rails engine (the host app might not be Rails).
  # Singleton because there is exactly one process-wide CLI; tests construct
  # fresh `.new` instances to keep state isolated.
  #
  # Spec: docs/target/sidekiq-free.md §21 (Sidekiq::CLI).
  class CLI # rubocop:disable Metrics/ClassLength
    include Component

    # Minimum Redis version Wurk supports — same as Sidekiq 8.x. The job JSON
    # format and Lua scripts rely on commands introduced in Redis 7.
    MIN_REDIS_VERSION = '7.0.0'

    # Subcommands. Bare `wurk` runs the worker — the historical shape, and the
    # only one the swarm binaries accept — so a subcommand is never anything
    # but the first argument, and every argument after it is that command's.
    COMMANDS = %w[api boot-check health].freeze
    # Set only across the one re-exec of #load_rails_framework, and removed on arrival.
    PRELOAD_FIRST_ENV = 'WURK_BOOT_PRELOAD_FIRST'
    # `bundle exec` loads the binstub in-process, so argv0 is Bundler's executable, and
    # `ruby -e "load Gem.bin_path(...)"` has `-e` there: the running program can't name it.
    SWARM_EXECUTABLE = ::File.expand_path('../../exe/wurkswarm', __dir__)
    WURK_EXECUTABLE = ::File.expand_path('../../exe/wurk', __dir__)

    # A refusal this file raises itself, with nothing a trace would add.
    class StartupError < ArgumentError; end

    # `wurk api` defaults. 0.0.0.0 because the point of the machine API is for
    # another service to reach it; it is bearer-gated, and answers 404 to
    # everything until a token exists. `--bind 127.0.0.1` narrows it.
    DEFAULT_API_BIND = '0.0.0.0'
    DEFAULT_API_PORT = 7433

    # Serving the API with nothing registered would bind a port and 404 every
    # request — the surface is off until a token exists, so say so at boot
    # rather than leaving an operator to diagnose it over HTTP.
    NO_API_TOKEN_MESSAGE = <<~MSG
      No API token is registered, so every request would answer 404.
      Register one where the app loaded by -r configures wurk:

          Wurk.configuration.api_token(ENV.fetch('WURK_API_TOKEN'), scopes: %i[enqueue read])
    MSG

    # Thread-backtrace dumper used by both TTIN and INFO. Same body — INFO is
    # the modern name, TTIN is kept for parity with older Sidekiq users.
    BACKTRACE_DUMPER = lambda do |cli|
      Thread.list.each do |thread|
        cli.logger.warn "Thread TID-#{(thread.object_id ^ ::Process.pid).to_s(36)} #{thread.name}"
        if thread.backtrace
          cli.logger.warn thread.backtrace.join("\n")
        else
          cli.logger.warn '<no backtrace available>'
        end
      end
    end

    SIGNAL_HANDLERS = {
      'INT' => ->(_cli) { raise Interrupt },
      'TERM' => ->(_cli) { raise Interrupt },
      'TSTP' => lambda do |cli|
        cli.logger.info 'Received TSTP, no longer accepting new work'
        cli.launcher.quiet
      end,
      'TTIN' => BACKTRACE_DUMPER,
      'INFO' => BACKTRACE_DUMPER,
      'USR2' => lambda do |cli|
        cli.logger.info 'Received USR2, reopening logs'
        # reopen_logs is private — an explicit receiver needs __send__.
        cli.__send__(:reopen_logs)
      end
    }.freeze

    # Table-driven so adding a flag doesn't grow `define_value_flags`'s ABC
    # size and the surface matches the Sidekiq docs row-for-row. The 5th
    # column is the assignment transform: `:to_i` parses as Integer, `:append`
    # pushes onto a list (only `-q` uses that), nil = assign as-is.
    OPTION_FLAGS = [
      ['-c', '--concurrency INT',      :concurrency, 'processor threads to use', :to_i],
      ['-e', '--environment ENV',      :environment, 'Application environment'],
      ['-g', '--tag TAG',              :tag,         'Process tag for procline'],
      ['-q', '--queue QUEUE[,WEIGHT]', :queues,      'Queues to process with optional weights', :append],
      ['-r', '--require [PATH|DIR]',   :require,     'Location of Rails app or .rb file to require'],
      ['-t', '--timeout NUM',          :timeout,     'Shutdown timeout', :to_i],
      ['-v', '--verbose',              :verbose,     'Print more verbose output'],
      ['-C', '--config PATH',          :config_file, 'path to YAML config file']
    ].freeze

    # Same table shape, offered only when `api` is the subcommand: none of it
    # means anything to a worker process, and `wurk --help` stays the worker's.
    API_OPTION_FLAGS = [
      ['-b', '--bind ADDRESS', :api_bind,   "Address to bind (default #{DEFAULT_API_BIND})"],
      ['-p', '--port PORT',    :api_port,   "Port to listen on (default #{DEFAULT_API_PORT})", :to_i],
      ['-s', '--server NAME',  :api_server, 'Rack handler to serve with (default: the first installed)']
    ].freeze

    BOOT_CHECK_OPTION_FLAGS = [
      ['-R', '--redis', :boot_check_redis, 'Also read Redis: version, eviction policy, live peers (read-only)'],
      ['-n', '--runner NAME', :boot_check_runner, 'Boot as wurkswarm (default) or wurk, the runner you deploy']
    ].freeze
    BOOT_CHECK_RUNNERS = %w[wurkswarm wurk].freeze

    HEALTH_OPTION_FLAGS = [
      ['-w', '--window SECONDS', :health_window, 'A heartbeat older than this does not count (default 60)', :to_i],
      ['-m', '--min COUNT', :health_min, 'Processes on this host that must be beating (default 1)', :to_i],
      ['-u', '--redis-url URL', :health_redis_url, 'Redis to read (default REDIS_URL)'],
      ['-s', '--strict', :health_strict, 'Fail when Redis cannot be read, rather than passing'],
      ['-a', '--max-job-age SECONDS', :health_max_job_age, 'Also fail when a job here has run this long (off)', :to_i]
    ].freeze

    HELP_COMMANDS = "\nCommands:\n    " \
                    "boot-check Boot as wurkswarm (or --runner wurk) would, then exit; no fork, no fetch (CI)\n    " \
                    "health    Exit 0 if this host's workers are heartbeating\n    " \
                    "preflight Read a live Redis: what will carry over to Wurk (read-only)\n    " \
                    "verify    Post-cutover check of a live fleet (read-only)\n\nOptions:"
    HELP_API_NOTE = "\nThe worker flags -c, -g, -q and -t are accepted here and have no effect.\n\nOptions:"
    HELP_SWARM_NOTE = "\nForks WURK_COUNT worker processes from a preloaded parent and supervises them.\n\nOptions:"
    HELP_FOOTER = "\nEnvironment:\n    REDIS_URL         Redis to use (default redis://localhost:6379/0)\n    " \
                  "WURK_COUNT        Worker processes for wurkswarm\n\n" \
                  'Docs: https://github.com/developerz-ai/wurk#readme'

    attr_accessor :launcher, :environment, :config

    # The subcommand `parse` pulled off argv, or nil for the worker runner.
    # The binary picks the mode from it — `exe/wurk` runs the API for `api`.
    attr_reader :command

    def self.instance
      @instance ||= new
    end

    # Test seam: parallel suites can't share the singleton.
    def self.reset_instance!
      @instance = nil
    end

    def initialize
      @config = nil
      @launcher = nil
      @environment = nil
      @parser = nil
      @command = nil
    end

    # `parse` is split from `run` so tests can drive option parsing without
    # touching Redis or booting the host app.
    def parse(args = ARGV.dup)
      @config ||= Wurk.default_configuration
      @command = extract_command!(args)
      return parse_health_options(args) if @command == 'health'

      setup_options(args)
      initialize_logger
      validate!
      self
    end

    # What the binaries print for a failed start. Only errors this file fully
    # understands drop the trace. Anything else may be a bug in the host app, whose
    # file and line are the point, and asking for -v means changing a deployed command.
    def self.report_failure(program, error, argv: ARGV)
      warn "#{program}: #{error.message}"
      hint = failure_hint(error)
      warn "#{program}: #{hint}" if hint
      return unless error.backtrace
      return unless failure_trace_wanted?(error, hint) || argv.intersect?(%w[-v --verbose])

      warn error.backtrace.join("\n")
    end

    def self.failure_trace_wanted?(error, hint) = hint.nil? && !error.is_a?(StartupError)
    private_class_method :failure_trace_wanted?

    def self.failure_hint(error)
      case error
      when ::RedisClient::ConnectionError
        'could not reach Redis; check REDIS_URL'
      when ->(e) { defined?(::OptionParser::ParseError) && e.is_a?(::OptionParser::ParseError) }
        'see --help'
      end
    end
    private_class_method :failure_hint

    # `boot_app:` / `warmup:` are test seams. Production always passes true.
    def run(boot_app: true, warmup: true) # rubocop:disable Metrics/AbcSize
      exit(run_health) if @command == 'health'

      # Mark server mode BEFORE the app loads so `configure_server` blocks in
      # the required initializer actually fire (they gate on `config.server?`).
      # Matches Sidekiq, which sets `Sidekiq.server = true` before requiring
      # the app in its CLI. Each configure_server block the app's load reaches
      # before it would be kept and run only here, after the app's own code.
      enter_server_mode
      boot_application if boot_app
      Swarm::TestModeGuard.enforce!(@config.logger)
      self_read, self_write = ::IO.pipe
      begin
        trap_signals(self_write)
        info = validate_redis!
        validate_pool_sizes!
        BootChecks.run(@config, info)
        BootChecks.warn_on_ignored_topology(@config, 'wurk')
        BootChecks.log_process_role(@config, 'wurk')
        @config[:identity] = identity
        # Force lazy server-middleware chain so worker threads don't race
        # against each other constructing it. Spec: Sidekiq::CLI line 104.
        @config.server_middleware
        warm_up_process if warmup
        fire_event(:startup, reverse: false, reraise: true)
        launch(self_read)
      ensure
        # Every exit path — clean return, a raise out of validate/startup, and
        # the SystemExit that `launch` unwinds on Interrupt. Embedded and test
        # callers survive `run`, so a leaked pair is a real FD leak.
        self_read.close
        self_write.close
      end
    end

    # Standalone multi-process boot — the `sidekiqswarm` entry point (Ent §7).
    # The parent loads the app once, forks N worker children per the configured
    # topology, then supervises them (respawn on crash, rolling restart on
    # SIGUSR1, memory-based recycling). The parent itself never fetches.
    #
    # This is the only way to get fork-based parallelism without Rails — the
    # railtie auto-boot path is Rails-only. Honors the swarm preload knobs
    # (`WURK_PRELOAD`/`SIDEKIQ_PRELOAD` Bundler groups, `WURK_PRELOAD_APP`/
    # `SIDEKIQ_PRELOAD_APP` whole-app eager-load); Swarm#boot warms the heap
    # before the fork so children share its pages (Swarm::Prefork). Spec §7.
    def run_swarm(boot_app: true) # rubocop:disable Metrics/AbcSize
      raise StartupError, "the swarm runner takes no subcommand; run `wurk #{@command}` instead" if @command

      # Server mode before the app loads — see #run. The flag rides through the
      # fork into every child (the config object is copied), so configure_server
      # blocks registered in the parent take effect in the workers.
      enter_server_mode
      # Only the children read it. Rejected here, a typo fails this boot instead of
      # crash-looping the fleet until the crash-loop exit.
      Health.options_from_env
      boot_swarm_application if boot_app
      info = validate_redis!
      validate_pool_sizes!
      BootChecks.run(@config, info)
      log_swarm_role
      @config[:identity] = identity
      @swarm = Wurk::Swarm.new(topology: @config.topology, config: @config, exit_on_crash_loop: true,
                               shutdown_timeout: @config[:timeout] || Swarm::DEFAULT_SHUTDOWN_TIMEOUT)
      begin
        @swarm.boot(install_signals: true)
        @swarm.supervise
      ensure
        # A fork failure part-way through `boot`, or anything raising out of
        # `supervise`, otherwise leaves live children behind with no supervisor.
        # A no-op once the loop already drained (no children, pipe closed).
        @swarm.shutdown
      end
      exit(1) if @swarm.crash_looped?
    end

    # `wurk boot-check` — the boot of the runner named by --runner up to where it
    # would fork or fetch: #run_swarm's (the default) or #run's, with the same
    # require order, config file and checks, plus what a worker reaches only later
    # (every constant, the routes), so a CI step finds what would crash-loop a
    # deploy. `configure_server` blocks run, since their load errors are the point;
    # no lifecycle event fires (`:startup` included) and periodic loops are never
    # applied. Wurk's Redis pools refuse every command without --redis and every
    # write with it (Preflight::RedisGuard), so boot-time app code cannot touch a
    # real server. Returns the exit code; a boot that raises is the binary's
    # failure report.
    def run_boot_check(boot_app: true)
      require_relative 'preflight/redis_guard'
      Preflight::RedisGuard.install(@config[:boot_check_redis] ? :read_only : :closed, label: 'wurk boot-check')
      enter_server_mode
      boot_check_runner == 'wurk' ? boot_check_as_wurk(boot_app) : boot_check_as_swarm(boot_app)
      logger.info { "wurk boot-check: #{@config[:require]} booted as #{boot_check_runner} would" }
      0
    ensure
      Preflight::RedisGuard.uninstall
    end

    # `wurk health` — see Wurk::HealthProbe. Boots nothing; returns the exit code.
    def run_health
      require_relative 'health_probe'
      opts = @health_options
      @config.redis = { url: opts[:health_redis_url] } if opts[:health_redis_url]
      HealthProbe.new(@config, window: opts[:health_window] || HealthProbe::DEFAULT_WINDOW,
                               min: opts[:health_min] || 1, strict: opts[:health_strict] == true,
                               max_job_age: opts[:health_max_job_age]).call
    end

    # `wurk api` — serve the machine-facing HTTP API and nothing else: no
    # fetcher, no heartbeat, no job ever runs here. This is mount mode 3, the
    # standalone one: the same Rack app the engine nests and a host can mount
    # itself, served without Rails.
    #
    # Server mode is entered for the reason #run does it — a host that
    # registers its token inside a `configure_server` block would otherwise
    # boot an API with no credential and 404 every request. Nothing starts as a
    # side effect: no lifecycle event fires and no Launcher is ever built.
    #
    # `handler:` is a test seam; production resolves one from the installed
    # gems.
    def run_api(boot_app: true, handler: nil)
      enter_server_mode
      boot_application if boot_app
      validate_redis!
      # Load the app here, not on the first request: a broken load should fail
      # the boot an operator is watching, not the first client to call.
      require_relative 'api/app'
      raise StartupError, NO_API_TOKEN_MESSAGE unless @config.api_enabled?

      handler ||= api_handler(@config[:api_server])
      logger.info { "Wurk API listening on http://#{api_bind}:#{api_port}#{Wurk::API::VERSION_PREFIX}" }
      handler.run(Wurk::API, Host: api_bind, Port: api_port)
    end

    def handle_signal(sig)
      logger.debug { "Got #{sig} signal" }
      handler = SIGNAL_HANDLERS[sig]
      return logger.warn("No #{sig} signal handler registered, ignoring") unless handler

      handler.call(self)
    end

    private

    # --- run helpers ----------------------------------------------------

    # Claim the worker boot before the host app loads, so the railtie's
    # after_initialize hook knows this process already has a worker and does
    # not fork a second one on top of it (#worker_boot_claimed?).
    def enter_server_mode
      Wurk.claim_worker_boot!
      Wurk.enter_server_mode(@config)
    end

    # Pre-fault and compact the heap before workers start (the swarm does its
    # own, before the fork: Swarm::Prefork). RUBY_DISABLE_WARMUP=1 is the escape
    # hatch for hosts that already warmed up.
    def warm_up_process
      return unless ::Process.respond_to?(:warmup) && ENV['RUBY_DISABLE_WARMUP'] != '1'

      ::Process.warmup
    end

    def api_bind = @config[:api_bind] || DEFAULT_API_BIND
    def api_port = @config[:api_port] || DEFAULT_API_PORT

    # Rack 3 moved the server handlers out to the `rackup` gem; rack 2 still
    # ships them itself. Neither is a wurk dependency — the web server is the
    # host's choice here exactly as it is for the app this sits next to — so
    # resolve one at run time and name the fix when there is none.
    def api_handler(name)
      registry = handler_registry
      name ? registry.get(name) : registry.default
    rescue ::LoadError, ::NameError, ::ArgumentError => e
      raise StartupError, "wurk api could not start a web server (#{e.message}). Add one to your Gemfile " \
                          '— puma, falcon, or rackup + webrick — or name an installed one with --server.'
    end

    def handler_registry
      require 'rackup/handler'
      ::Rackup::Handler
    rescue ::LoadError
      require 'rack/handler'
      ::Rack::Handler
    end

    def launch(self_read)
      @launcher = Wurk::Launcher.new(@config)
      begin
        @launcher.run
        while self_read.wait_readable
          signal = self_read.gets&.strip
          break if signal.nil?

          handle_signal(signal)
        end
      rescue Interrupt
        logger.info 'Shutting down'
        @launcher.stop
        logger.info 'Bye!'
        exit(0)
      end
    end

    # Self-pipe signal pattern — handlers must be async-signal-safe, so we
    # forward the signal name through a pipe and let the main thread loop
    # over `self_read` in `launch`. Same approach as Sidekiq.
    def trap_signals(self_write)
      signal_names.each do |sig|
        ::Signal.trap(sig) { emit_signal(self_write, sig) }
      rescue ArgumentError
        # JRuby and platforms without certain signals — log and move on.
        warn("Signal #{sig} not supported")
      end
    end

    # Non-blocking write from trap context (same shape as Swarm#emit_signal): a
    # blocking `puts` can stall signal delivery once the pipe fills, and the
    # traps outlive `run`'s ensure — a signal landing after the pipe is closed
    # would otherwise raise IOError out of a trap and into the main thread.
    def emit_signal(pipe, sig)
      pipe.write_nonblock("#{sig}\n", exception: false)
    rescue ::IOError, ::Errno::EPIPE, ::Errno::EBADF
      nil
    end

    def signal_names
      # INFO exists on BSD and macOS only; asking for it on Linux just warned at every boot.
      %w[INT TERM TSTP TTIN INFO USR2].select { |name| ::Signal.list.key?(name) }
    end

    def reopen_logs
      log = logger
      log.reopen if log.respond_to?(:reopen)
    rescue StandardError => e
      warn "wurk: USR2 log reopen failed, still writing to the previous log: #{e.class}: #{e.message}"
    end

    # Returns the INFO it read, so a boot pays one round trip for the version
    # check and BootChecks together.
    def validate_redis!
      info = redis_info
      ver = ::Gem::Version.new(info['redis_version'])
      if ver < ::Gem::Version.new(MIN_REDIS_VERSION)
        raise "You are connected to Redis #{ver}, Wurk requires Redis #{MIN_REDIS_VERSION} or greater"
      end

      maxmemory_policy = info['maxmemory_policy']
      return info if maxmemory_policy.nil? || maxmemory_policy.empty? || maxmemory_policy == 'noeviction'

      logger.warn { <<~WARN }


        WARNING: Your Redis instance will evict Wurk data under heavy load.
        The 'noeviction' maxmemory policy is recommended (current policy: '#{maxmemory_policy}').

      WARN
      info
    end

    def redis_info
      @config.redis_pool.info
    end

    def validate_pool_sizes!
      @config.capsules.each_pair do |name, cap|
        size = cap.redis_pool.size
        next if size >= cap.concurrency

        raise StartupError, "the Redis pool for capsule #{name} holds #{size} connections, fewer than its " \
                            "concurrency of #{cap.concurrency}. Set `config.redis = { size: #{cap.concurrency} }` " \
                            'or more, or drop `size:` and Wurk sizes the pool itself (concurrency + 5).'
      end
    end

    def boot_check_runner = @config[:boot_check_runner] || BOOT_CHECK_RUNNERS.first

    def boot_check_as_swarm(boot_app)
      Health.options_from_env
      if boot_app
        boot_swarm_application
        boot_check_reach
      end
      validate_pool_sizes!
      BootChecks.run(@config, boot_check_redis_info)
      log_swarm_role
    end

    def boot_check_as_wurk(boot_app)
      if boot_app
        boot_application
        boot_check_reach
      end
      validate_pool_sizes!
      BootChecks.run(@config, boot_check_redis_info)
      BootChecks.warn_on_ignored_topology(@config, 'wurk')
      BootChecks.log_process_role(@config, 'boot-check (as wurk)')
    end

    # What a worker loads only later: every constant, and the routes.
    def boot_check_reach
      Wurk.eager_load!
      eager_load_rails
      draw_routes
    end

    def boot_check_redis_info
      return unless @config[:boot_check_redis]

      validate_redis!
    end

    def log_swarm_role
      BootChecks.log_swarm_role(@config, @command ? "#{@command} (as wurkswarm parent)" : 'wurkswarm parent')
    end

    # --- options + config-file --------------------------------------------

    # Pulled off before OptionParser sees argv, so the banner and the flag
    # table can depend on which command was named. A bare word OptionParser
    # doesn't recognize would otherwise survive `parse!` and be silently
    # ignored, which is how `wurk api` would look like it worked.
    def extract_command!(args)
      COMMANDS.include?(args.first) ? args.shift : nil
    end

    def boot_swarm_application
      load_rails_framework
      preload_bundler_groups
      boot_application
      eager_load_application
    end

    # Rails may draw routes only on the first request; a `mount` of a constant
    # only the web process loads must fail here, not on that request.
    def draw_routes
      app = rails_application
      app.reload_routes! if app.respond_to?(:reload_routes!)
    end

    def parse_health_options(args)
      @health_options = {}
      parser = option_parser(@health_options)
      @parser = parser
      parser.parse!(args)
      self
    end

    def setup_options(args)
      opts = parse_options(args)
      set_environment(opts[:environment])
      opts[:config_file] ||= discover_config_file(opts[:require] || @config[:require])
      opts = parse_config(opts[:config_file]).merge(opts) if opts[:config_file]
      apply_defaults!(opts)
      apply_options(opts)
    end

    def apply_defaults!(opts)
      opts[:queues] ||= ['default']
      return if opts[:concurrency] || ENV['RAILS_MAX_THREADS'].nil?

      opts[:concurrency] = Integer(ENV.fetch('RAILS_MAX_THREADS'))
    end

    def apply_options(opts)
      @config.merge!(opts.except(:capsules))
      cap = @config.default_capsule
      cap.queues = opts[:queues]
      cap.concurrency = opts[:concurrency] || @config[:concurrency]
      apply_capsules(opts[:capsules])
    end

    def apply_capsules(capsule_configs)
      capsule_configs&.each do |name, cap_config|
        @config.capsule(name.to_s) do |cap|
          cap.queues = cap_config[:queues] if cap_config[:queues]
          cap.concurrency = cap_config[:concurrency] if cap_config[:concurrency]
        end
      end
    end

    def discover_config_file(require_path)
      base = ::File.directory?(require_path.to_s) ? require_path.to_s : @config[:require].to_s
      config_dir = ::File.join(base, 'config')
      %w[wurk.yml wurk.yml.erb sidekiq.yml sidekiq.yml.erb].each do |name|
        candidate = ::File.join(config_dir, name)
        return candidate if ::File.exist?(candidate)
      end
      nil
    end

    def parse_config(path)
      raise StartupError, "No such file #{path}" unless ::File.exist?(path)

      require 'erb'
      require 'yaml'

      erb = ::ERB.new(::File.read(path), trim_mode: '-')
      erb.filename = ::File.expand_path(path)
      opts = ::YAML.safe_load(erb.result, permitted_classes: [Symbol], aliases: true) || {}
      symbolize_keys_deep!(opts)
      # Environment overlay: `production:` / `staging:` etc.
      overlay = opts.delete(@environment.to_sym) if @environment
      opts.merge!(overlay) if overlay.is_a?(Hash)
      opts.delete(:strict) # Sidekiq parity — strict_fetch removed in 8.x
      opts
    end

    def symbolize_keys_deep!(hash)
      hash.keys.each do |k|
        sym = k.respond_to?(:to_sym) ? k.to_sym : k
        hash[sym] = hash.delete(k)
        symbolize_keys_deep!(hash[sym]) if hash[sym].is_a?(Hash)
      end
      hash
    end

    def set_environment(cli_env) # rubocop:disable Naming/AccessorMethodName
      @environment = cli_env || ENV['APP_ENV'] || ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'development'
      @config[:environment] = @environment
    end

    def parse_options(argv)
      opts = {}
      parser = option_parser(opts)
      @parser = parser
      parser.parse!(argv)
      warn "wurk: ignoring #{argv.join(' ')}: not a command or a flag (see --help)" unless argv.empty?
      opts
    end

    def option_parser(opts)
      require 'optparse'

      ::OptionParser.new do |o|
        o.banner = help_banner
        o.separator help_intro if help_intro
        define_value_flags(o, opts, @command == 'health' ? HEALTH_OPTION_FLAGS : OPTION_FLAGS)
        define_value_flags(o, opts, API_OPTION_FLAGS) if @command == 'api'
        define_value_flags(o, opts, BOOT_CHECK_OPTION_FLAGS) if @command == 'boot-check'
        define_meta_flags(o, opts)
      end
    end

    def swarm_binary? = ::File.basename($PROGRAM_NAME).include?('swarm')

    def help_banner
      return "wurk #{@command} [options]" if @command
      return "#{::File.basename($PROGRAM_NAME)} [options]" if swarm_binary?

      "wurk [options]\nwurk COMMAND [options]"
    end

    def help_intro
      return HELP_API_NOTE if @command == 'api'
      return if @command

      swarm_binary? ? HELP_SWARM_NOTE : HELP_COMMANDS
    end

    def define_value_flags(parser, opts, flags)
      flags.each do |short, long, key, desc, transform|
        parser.on(short, long, desc) do |arg|
          assign_flag(opts, key, arg, transform)
        rescue ArgumentError
          raise StartupError, "#{long.split.first}: #{arg.inspect} is not a number"
        end
      end
    end

    def assign_flag(opts, key, arg, transform)
      case transform
      when :to_i   then opts[key] = Integer(arg)
      when :append then (opts[key] ||= []) << arg
      else              opts[key] = arg
      end
    end

    def define_meta_flags(parser, _opts)
      parser.on('-V', '--version', 'Print version and exit') do
        puts "Wurk #{Wurk::VERSION}"
        exit(0)
      end
      parser.on_tail('-h', '--help', 'Show help') do
        puts parser, HELP_FOOTER
        exit(0)
      end
    end

    # --- application bootstrap --------------------------------------------

    # A Rails target has two shapes that need opposite orders. A gem may need Rails
    # loaded while it requires: `config/application.rb` requires the framework and
    # only then calls `Bundler.require`, so running the app's first half before the
    # group preload suits it. An app may instead use a gem it expects the swarm to have
    # preloaded, as stock sidekiqswarm's order (spec §7.3) gives it, and then that
    # file raises NameError here. Only the file can tell us which it is, and by then
    # its class body may have half-run, registering initializers and middleware that a
    # second load in this process would register again. So the retry is a fresh process:
    # same pid, same environment as before the attempt, preload first. Once only, so a
    # genuine bug surfaces with its own message.
    def load_rails_framework
      root = rails_app_root(@config[:require])
      return unless root

      restart = restart_state
      first_error = ENV.delete(PRELOAD_FIRST_ENV)
      ENV['RACK_ENV'] = ENV['RAILS_ENV'] = @environment
      require 'rails'
      define_active_job_adapter
      return note_preload_first(first_error) if first_error

      begin
        require ::File.join(root, 'config/application.rb')
      rescue ::NameError => e
        restart_with_preload_first(restart, e)
      end
    end

    def restart_state
      { env: ::ENV.to_h, argv: [restart_executable, *::ARGV], dir: ::Dir.pwd }
    end

    def note_preload_first(first_error)
      logger.warn do
        "config/application.rb raised before the preload (#{first_error}), so this boot preloads first. " \
          'If it fails too, that first error may be the one to fix.'
      end
    end

    # Bundler may have arrived only inside the failed attempt (`config/boot.rb`), and the
    # snapshot predates it, so the fresh process is told about it explicitly. If the
    # exec itself fails, the app's error is still the one worth reporting.
    def restart_with_preload_first(state, error)
      env = state[:env].merge(PRELOAD_FIRST_ENV => error.message.lines.first.to_s.strip[0, 300])
      env['BUNDLE_GEMFILE'] ||= ::Bundler.default_gemfile.to_s if defined?(::Bundler)
      ruby = [::RbConfig.ruby, *('-rbundler/setup' if defined?(::Bundler))]
      ::Process.exec(env, *ruby, *state[:argv], unsetenv_others: true, chdir: state[:dir])
    rescue ::SystemCallError
      raise error
    end

    # The binary that was run: only `wurk boot-check` reaches this with a command.
    def restart_executable = @command ? WURK_EXECUTABLE : SWARM_EXECUTABLE

    # The app root for a `-r` that is the app directory or its environment file.
    def rails_app_root(require_path)
      path = ::File.expand_path(require_path.to_s)
      path = ::File.dirname(path, 2) if ::File.basename(path) == 'environment.rb'
      path if ::File.directory?(path) && ::File.exist?(::File.join(path, 'config/application.rb'))
    end

    # Spec §7.2/§7.3. Before the swarm parent forks, `Bundler.require` the
    # configured groups so their gems are resident in the parent and paged
    # copy-on-write into every child. Comma-separated group list; the native
    # `WURK_PRELOAD` wins over the `SIDEKIQ_PRELOAD` drop-in alias. Defaults to
    # the `default` group; an explicit empty value (`WURK_PRELOAD=`) disables
    # the preload. Runs before `boot_application`, so before the initializers; see
    # #load_rails_framework for where `config/application.rb` falls.
    def preload_bundler_groups
      return unless defined?(::Bundler)

      groups = preload_groups
      ::Bundler.require(*groups) unless groups.empty?
    end

    def preload_groups
      raw = ENV['WURK_PRELOAD'] || ENV['SIDEKIQ_PRELOAD'] || 'default'
      raw.split(',').map(&:strip).reject(&:empty?).map(&:to_sym)
    end

    # Spec §7.2. `WURK_PRELOAD_APP=1` (alias `SIDEKIQ_PRELOAD_APP=1`) eager-loads
    # the whole Rails app in the parent before forking, so the entire object
    # space — not just the constants autoload happened to touch — is shared
    # copy-on-write, trading parent boot time for child RSS savings (~20–30%).
    #
    # Intentional divergence from Sidekiq's default-0: wurk's swarm forks
    # children from a preloaded parent — they inherit the app rather than
    # re-requiring it — so the app entrypoint (`-r`) is always loaded in the
    # parent regardless of this flag. PRELOAD_APP only toggles the extra Rails
    # eager-load; for a non-Rails `-r` file there is nothing further to load.
    def eager_load_application
      return unless preload_app?

      eager_load_rails
    end

    def eager_load_rails
      app = rails_application
      app.eager_load! if app.respond_to?(:eager_load!)
    end

    def rails_application
      return unless defined?(::Rails) && ::Rails.respond_to?(:application)

      ::Rails.application
    end

    def preload_app?
      (ENV['WURK_PRELOAD_APP'] || ENV.fetch('SIDEKIQ_PRELOAD_APP', nil)) == '1'
    end

    # Standalone mode must NOT load wurk/rails — even when pointed at a Rails
    # app, that's the host's call to wire the railtie. The CLI only `require`s
    # the host's entrypoint and reads the resulting classes.
    def boot_application
      ENV['RACK_ENV'] = ENV['RAILS_ENV'] = @environment
      require_path = @config[:require]
      if ::File.directory?(require_path.to_s)
        boot_rails_application(require_path)
      else
        require ::File.expand_path(require_path)
        @config[:tag] ||= default_tag
      end
    end

    def boot_rails_application(require_path)
      require 'rails'
      define_active_job_adapter
      # No railtie here (see boot_application), and a host's after_initialize hook
      # may wrap the reloader, so it has to be the Rails one by then.
      ::ActiveSupport.on_load(:after_initialize, yield: true) { |app| RailsBoot.install_reloader(app) }
      require ::File.expand_path("#{require_path}/config/environment.rb")
      @config[:tag] ||= default_tag(::Rails.root) if defined?(::Rails) && ::Rails.respond_to?(:root)
    end

    # Standalone mode never loads the engine, so the ActiveJob `:wurk` /
    # `:sidekiq` adapters it normally defines are absent. Define them BEFORE the
    # app boots — an app with `config.active_job.queue_adapter = :wurk` resolves
    # the adapter during environment boot, which otherwise raises `uninitialized
    # constant WurkAdapter` (#253). `require` no-ops for a mounted-engine app
    # that already loaded it, and the adapter file itself rescues a missing
    # ActiveJob gem, so a non-ActiveJob app is unaffected.
    def define_active_job_adapter
      require_relative '../active_job/queue_adapters/wurk_adapter'
    end

    def initialize_logger
      return unless @config[:verbose] || ENV['DEBUG_INVOCATION'] == '1'

      @config.logger.level = ::Logger::DEBUG
    end

    def validate!
      reason = require_path_problem(@config[:require].to_s)
      return print_help_and_die(reason) if reason

      runner = @config[:boot_check_runner]
      if runner && !BOOT_CHECK_RUNNERS.include?(runner)
        raise StartupError, "--runner: #{runner.inspect} is not one of #{BOOT_CHECK_RUNNERS.join(', ')}"
      end

      %i[concurrency timeout].each do |opt|
        raise StartupError, "#{opt}: #{@config[opt]} is not a valid value" if @config[opt].to_i <= 0
      end
    end

    def require_path_problem(path)
      return 'no such file or directory' unless ::File.exist?(path)

      return unless ::File.directory?(path) && !::File.exist?(::File.join(path, 'config/application.rb'))

      'it has no config/application.rb'
    end

    def print_help_and_die(reason)
      logger.error '=================================================================='
      logger.error "  Wurk cannot load job classes from #{@config[:require]}: #{reason}."
      logger.error '  Please point Wurk to a Rails application or a Ruby file'
      logger.error '  to load your job classes with -r [DIR|FILE].'
      logger.error '=================================================================='
      logger.error @parser.to_s
      exit(1)
    end
  end
end
