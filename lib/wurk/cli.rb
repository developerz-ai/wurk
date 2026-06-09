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
      'INFO' => BACKTRACE_DUMPER
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

    attr_accessor :launcher, :environment, :config

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
    end

    # `parse` is split from `run` so tests can drive option parsing without
    # touching Redis or booting the host app.
    def parse(args = ARGV.dup)
      @config ||= Wurk.default_configuration
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
      trap_signals(self_write)
      validate_redis!
      validate_pool_sizes!
      @config[:identity] = identity
      # Force lazy server-middleware chain so worker threads don't race
      # against each other constructing it. Spec: Sidekiq::CLI line 104.
      @config.server_middleware
      ::Process.warmup if warmup && ::Process.respond_to?(:warmup) && ENV['RUBY_DISABLE_WARMUP'] != '1'
      fire_event(:startup, reverse: false, reraise: true)
      launch(self_read)
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
      ::Process.warmup if warmup && ::Process.respond_to?(:warmup) && ENV['RUBY_DISABLE_WARMUP'] != '1'
      @swarm = Wurk::Swarm.new(topology: @config.topology, config: @config)
      @swarm.boot(install_signals: true)
      @swarm.supervise
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
        ::Signal.trap(sig) { self_write.puts(sig) }
      rescue ArgumentError
        # JRuby and platforms without certain signals — log and move on.
        warn("Signal #{sig} not supported")
      end
    end

    def signal_names
      %w[INT TERM TSTP TTIN INFO]
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
        o.banner = 'wurk [options]'
        define_value_flags(o, opts)
        define_meta_flags(o, opts)
      end
    end

    def define_value_flags(parser, opts)
      OPTION_FLAGS.each do |short, long, key, desc, transform|
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
      require ::File.expand_path("#{require_path}/config/environment.rb")
      @config[:tag] ||= default_tag(::Rails.root) if defined?(::Rails) && ::Rails.respond_to?(:root)
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
