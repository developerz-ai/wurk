# frozen_string_literal: true

require 'logger'
require 'optparse'
require_relative '../preflight'
require_relative 'verify'

module Wurk
  module Preflight
    # The command line for `wurk preflight` and `wurk verify`.
    # Exit status: 0 clean, 1 findings, 2 could not run.
    class Command
      CLEAN_RUN_FAILED = 2

      def self.run(argv, config: Wurk.configuration, out: $stdout, err: $stderr)
        new(argv, config, out, err).call
      end

      def initialize(argv, config, out, err)
        @name = argv.first
        @argv = argv.drop(1)
        @config = config
        @out = out
        @err = err
        @opts = { limit: DEFAULT_LIMIT, sample: DEFAULT_SAMPLE, pause_ms: 5 }
      end

      def call # rubocop:disable Metrics/AbcSize
        parser.parse!(@argv)
        boot_app if @opts[:app]
        report = run_command(read_config)
        @out.puts(redact(@opts[:json] ? report.to_json : report.to_text))
        report.exit_status
      rescue ::OptionParser::ParseError => e
        fail_with("#{e.message}\n#{parser}")
      rescue ::RedisClient::Error => e
        fail_with("cannot read Redis: #{e.class}: #{e.message}")
      rescue ::StandardError, ::ScriptError => e
        fail_with("#{e.class}: #{e.message}")
      end

      private

      # A CLI URL gets its own configuration: the app's may be frozen, and a read-only
      # command has no business changing it.
      def read_config
        return @config unless @opts[:redis_url]

        ::Wurk::Configuration.new.tap do |config|
          config.logger = ::Logger.new(::IO::NULL)
          config.redis = { url: @opts[:redis_url] }
        end
      end

      def run_command(config)
        return run_verify(config) if @name == 'verify'

        run_preflight(config)
      end

      def fail_with(message)
        @err.puts("wurk #{@name}: #{redact(message)}")
        CLEAN_RUN_FAILED
      end

      # Every error path goes through here. Whole URLs first, since a malformed one may
      # not match the pattern; then anything URL-shaped an app's error carried.
      def redact(text)
        out = text.to_s.dup.force_encoding(::Encoding::UTF_8).scrub('?')
        secrets.each { |secret| out = out.gsub(secret, '[redacted]') }
        out.gsub(%r{(\b[a-z][a-z0-9+.-]*://)[^\s/@]*@}i, '\1[redacted]@')
      end

      def secrets
        configured = @config.redis_config
        urls = [@opts[:redis_url], ::ENV.fetch('REDIS_URL', nil), configured[:url]].compact.map(&:to_s)
        urls.select { |url| url.include?('@') } + [configured[:password].to_s].reject(&:empty?)
      rescue ::StandardError
        []
      end

      def run_preflight(config)
        Preflight.run(config, limit: @opts[:limit], sample: @opts[:sample], pause: pause, progress: progress,
                              app: @opts[:app] ? true : false)
      end

      def run_verify(config)
        Verify.run(config, canary: @opts[:canary], limit: @opts[:limit], pause: pause, progress: progress)
      end

      def pause = @opts[:pause_ms] / 1000.0
      def progress = @opts[:json] ? nil : ->(message) { @err.puts(message) }

      # WURK_DISABLED keeps the railtie from forking a swarm in this process. Server
      # mode makes `configure_server` blocks run, so the Redis read is the one this
      # app's workers would use.
      def boot_app
        path = ::File.expand_path(@opts[:app])
        @err.puts("wurk #{@name}: --app boots #{path} and runs its initializers. Anything they do is not read-only, " \
                  "and an enqueue goes to the app's Redis, whatever --redis-url says.")
        ::ENV['WURK_DISABLED'] = '1'
        @config.enter_server_mode
        ::Kernel.require(::File.directory?(path) ? ::File.join(path, 'config/environment') : path)
        ::Rails.application.eager_load! if defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application
      end

      def parser
        @parser ||= ::OptionParser.new do |o|
          o.banner = "wurk #{@name} [options]"
          o.on('-u', '--redis-url URL', 'Redis to read (default REDIS_URL)') { |v| @opts[:redis_url] = v }
          o.on('--json', 'Machine-readable output') { @opts[:json] = true }
          o.on('--limit KEYS', Integer, "Stop scanning at this many keys (default #{DEFAULT_LIMIT})") do |v|
            @opts[:limit] = v
          end
          o.on('--pause-ms MS', Integer, 'Sleep between SCAN pages (default 5)') { |v| @opts[:pause_ms] = v }
          @name == 'verify' ? verify_options(o) : preflight_options(o)
        end
      end

      def preflight_options(opts)
        opts.on('--sample N', Integer, "Payloads read per queue or set (default #{DEFAULT_SAMPLE})") do |v|
          @opts[:sample] = v
        end
        opts.on('--app PATH',
                'Boot this app (a directory or file) to inspect job classes. Runs its initializers') do |v|
          @opts[:app] = v
        end
      end

      def verify_options(opts)
        opts.on('--canary CLASS', 'WRITES: push this job class to every subscribed queue') { |v| @opts[:canary] = v }
      end
    end
  end
end
