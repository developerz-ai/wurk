# frozen_string_literal: true

require 'yaml'
require 'optparse'
require 'erb'

require_relative 'version'
require_relative 'configuration'
require_relative 'component'
require_relative 'capsule'
require_relative 'launcher'

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
    COMMANDS = %w[api].freeze

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
      setup_options(args)
      initialize_logger
      validate!
      self
    end

    # `boot_app:` / `warmup:` are test seams. Production always passes true.
    def run(boot_app: true, warmup: true)
      # Mark server mode BEFORE the app loads so `configure_server` blocks in
      # the required initializer actually fire (they gate on `config.server?`).
      # Matches Sidekiq, which sets `Sidekiq.server = true` before requiring
      # the app in its CLI. Skipping this silently drops server middleware,
      # error handlers, and lifecycle hooks registered via configure_server.
      enter_server_mode
      boot_application if boot_app
      self_read, self_write = ::IO.pipe
      begin
        trap_signals(self_write)
        validate_redis!
        validate_pool_sizes!
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
    # `SIDEKIQ_PRELOAD_APP` whole-app eager-load) and boots `Process.warmup`
    # before the fork so children share warmed pages (copy-on-write). Spec §7.
    def run_swarm(boot_app: true, warmup: true)
      raise ArgumentError, "the swarm runner takes no subcommand; run `wurk #{@command}` instead" if @command

      # Server mode before the app loads — see #run. The flag rides through the
      # fork into every child (the config object is copied), so configure_server
      # blocks registered in the parent take effect in the workers.
      enter_server_mode
      if boot_app
        preload_bundler_groups
        boot_application
        eager_load_application
      end
      validate_redis!
      validate_pool_sizes!
      @config[:identity] = identity
      warm_up_process if warmup
      @swarm = Wurk::Swarm.new(topology: @config.topology, config: @config,
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
      raise ArgumentError, NO_API_TOKEN_MESSAGE unless @config.api_enabled?

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

    def enter_server_mode
      Wurk.enter_server_mode(@config)
    end

    # Pre-fault and compact the heap before workers start — in `run_swarm` that
    # happens before the fork, so children share the warmed pages copy-on-write.
    # RUBY_DISABLE_WARMUP=1 is the escape hatch for hosts that already warmed up.
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
      raise ArgumentError, "wurk api could not start a web server (#{e.message}). Add one to your Gemfile " \
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
      %w[INT TERM TSTP TTIN INFO USR2]
    end

    def reopen_logs
      log = logger
      log.reopen if log.respond_to?(:reopen)
    rescue StandardError
      nil
    end

    def validate_redis!
      info = redis_info
      ver = ::Gem::Version.new(info['redis_version'])
      if ver < ::Gem::Version.new(MIN_REDIS_VERSION)
        raise "You are connected to Redis #{ver}, Wurk requires Redis #{MIN_REDIS_VERSION} or greater"
      end

      maxmemory_policy = info['maxmemory_policy']
      return if maxmemory_policy.nil? || maxmemory_policy.empty? || maxmemory_policy == 'noeviction'

      logger.warn { <<~WARN }


        WARNING: Your Redis instance will evict Wurk data under heavy load.
        The 'noeviction' maxmemory policy is recommended (current policy: '#{maxmemory_policy}').

      WARN
    end

    def redis_info
      @config.redis_pool.info
    end

    def validate_pool_sizes!
      @config.capsules.each_pair do |name, cap|
        raise ArgumentError, "Pool size too small for #{name}" if cap.redis_pool.size < cap.concurrency
      end
    end

    # --- options + config-file --------------------------------------------

    # Pulled off before OptionParser sees argv, so the banner and the flag
    # table can depend on which command was named. A bare word OptionParser
    # doesn't recognize would otherwise survive `parse!` and be silently
    # ignored, which is how `wurk api` would look like it worked.
    def extract_command!(args)
      COMMANDS.include?(args.first) ? args.shift : nil
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
      raise ArgumentError, "No such file #{path}" unless ::File.exist?(path)

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
      opts
    end

    def option_parser(opts)
      ::OptionParser.new do |o|
        o.banner = @command ? "wurk #{@command} [options]" : 'wurk [options]'
        define_value_flags(o, opts, OPTION_FLAGS)
        define_value_flags(o, opts, API_OPTION_FLAGS) if @command == 'api'
        define_meta_flags(o, opts)
      end
    end

    def define_value_flags(parser, opts, flags)
      flags.each do |short, long, key, desc, transform|
        parser.on(short, long, desc) { |arg| assign_flag(opts, key, arg, transform) }
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
        puts parser
        exit(0)
      end
    end

    # --- application bootstrap --------------------------------------------

    # Spec §7.2/§7.3. Before the swarm parent forks, `Bundler.require` the
    # configured groups so their gems are resident in the parent and paged
    # copy-on-write into every child. Comma-separated group list; the native
    # `WURK_PRELOAD` wins over the `SIDEKIQ_PRELOAD` drop-in alias. Defaults to
    # the `default` group; an explicit empty value (`WURK_PRELOAD=`) disables
    # the preload. Runs before `boot_application` so groups load before the app.
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
      require_path = @config[:require]
      bad_path = !::File.exist?(require_path.to_s)
      bad_rails = ::File.directory?(require_path.to_s) &&
                  !::File.exist?(::File.join(require_path, 'config/application.rb'))
      return print_help_and_die if bad_path || bad_rails

      %i[concurrency timeout].each do |opt|
        raise ArgumentError, "#{opt}: #{@config[opt]} is not a valid value" if @config[opt].to_i <= 0
      end
    end

    def print_help_and_die
      logger.info '=================================================================='
      logger.info '  Please point Wurk to a Rails application or a Ruby file'
      logger.info '  to load your job classes with -r [DIR|FILE].'
      logger.info '=================================================================='
      logger.info @parser
      exit(1)
    end
  end
end
