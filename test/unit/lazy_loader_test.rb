# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'open3'

# Load tiers (plan 101/06 L1-L4): `require "wurk"` loads the client tier and
# autoloads the rest; every `Sidekiq::*` alias stays the very object it names;
# `Wurk.eager_load!` leaves nothing for a forked child to load on its own.
#
# The cold-start cases run in a subprocess: this process has long since loaded
# every tier, so only a fresh interpreter can show what `require "wurk"` alone
# defines.
class LazyLoaderTest < Wurk::Test::UnitCase
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  LIB = File.join(ROOT, 'lib')

  # Every `Sidekiq::*` constant that names a Wurk module, and the Wurk constant
  # it must be. The oracle for the drop-in contract: completeness is asserted
  # below, so a new alias fails until it is listed here.
  ALIASES = {
    'Sidekiq::BasicFetch' => 'Wurk::Fetcher::Reliable', 'Sidekiq::Batch' => 'Wurk::Batch',
    'Sidekiq::BatchSet' => 'Wurk::BatchSet', 'Sidekiq::CLI' => 'Wurk::CLI', 'Sidekiq::Capsule' => 'Wurk::Capsule',
    'Sidekiq::Client' => 'Wurk::Client', 'Sidekiq::ClientMiddleware' => 'Wurk::Middleware::ClientMiddleware',
    'Sidekiq::Component' => 'Wurk::Component', 'Sidekiq::Config' => 'Wurk::Configuration',
    'Sidekiq::Context' => 'Wurk::Context', 'Sidekiq::CronParser' => 'Wurk::Cron::Parser',
    'Sidekiq::DeadSet' => 'Wurk::DeadSet', 'Sidekiq::Deploy' => 'Wurk::Deploy',
    'Sidekiq::Embedded' => 'Wurk::Embedded', 'Sidekiq::EmptyQueueError' => 'Wurk::Testing::EmptyQueueError',
    'Sidekiq::Encryption' => 'Wurk::Encryption', 'Sidekiq::Flow' => 'Wurk::Flow', 'Sidekiq::FlowSet' => 'Wurk::FlowSet',
    'Sidekiq::History' => 'Wurk::History', 'Sidekiq::IterableJob' => 'Wurk::IterableJob',
    'Sidekiq::IterableJobQuery' => 'Wurk::IterableJobQuery', 'Sidekiq::Job' => 'Wurk::Job',
    'Sidekiq::JobLogger' => 'Wurk::JobLogger', 'Sidekiq::JobRecord' => 'Wurk::JobRecord',
    'Sidekiq::JobRetry' => 'Wurk::JobRetry', 'Sidekiq::JobSet' => 'Wurk::JobSet', 'Sidekiq::JobUtil' => 'Wurk::JobUtil',
    'Sidekiq::Keys' => 'Wurk::Keys', 'Sidekiq::Launcher' => 'Wurk::Launcher', 'Sidekiq::Limiter' => 'Wurk::Limiter',
    'Sidekiq::Loader' => 'Wurk::Loader', 'Sidekiq::Logger' => 'Wurk::Logger', 'Sidekiq::Manager' => 'Wurk::Manager',
    'Sidekiq::Metrics' => 'Wurk::Metrics', 'Sidekiq::Middleware' => 'Wurk::Middleware',
    'Sidekiq::Paginator' => 'Wurk::Web::Paginator', 'Sidekiq::Periodic' => 'Wurk::Cron',
    'Sidekiq::Pro::BatchStatus' => 'Wurk::Web::BatchStatus', 'Sidekiq::Pro::Web' => 'Wurk::Web',
    'Sidekiq::Process' => 'Wurk::Process', 'Sidekiq::ProcessSet' => 'Wurk::ProcessSet',
    'Sidekiq::Processor' => 'Wurk::Processor', 'Sidekiq::ProfileRecord' => 'Wurk::ProfileRecord',
    'Sidekiq::ProfileSet' => 'Wurk::ProfileSet', 'Sidekiq::Profiler' => 'Wurk::Profiler',
    'Sidekiq::Queue' => 'Wurk::Queue', 'Sidekiq::Queues' => 'Wurk::Queues',
    'Sidekiq::RedisClientAdapter' => 'Wurk::RedisClientAdapter', 'Sidekiq::RedisConnection' => 'Wurk::RedisConnection',
    'Sidekiq::RetrySet' => 'Wurk::RetrySet', 'Sidekiq::Scheduled' => 'Wurk::Scheduled',
    'Sidekiq::ScheduledSet' => 'Wurk::ScheduledSet', 'Sidekiq::ServerMiddleware' => 'Wurk::Middleware::ServerMiddleware',
    'Sidekiq::Shutdown' => 'Wurk::Shutdown', 'Sidekiq::SortedEntry' => 'Wurk::SortedEntry',
    'Sidekiq::SortedSet' => 'Wurk::SortedSet', 'Sidekiq::Stats' => 'Wurk::Stats', 'Sidekiq::Testing' => 'Wurk::Testing',
    'Sidekiq::TransactionAwareClient' => 'Wurk::TransactionAwareClient', 'Sidekiq::Web' => 'Wurk::Web',
    'Sidekiq::WebHelpers' => 'Wurk::Web::Extension::Helpers', 'Sidekiq::Work' => 'Wurk::Work',
    'Sidekiq::WorkSet' => 'Wurk::WorkSet', 'Sidekiq::Worker' => 'Wurk::Worker', 'Sidekiq::Workers' => 'Wurk::Workers',
    'Sidekiq::Rails::Reloader' => 'Wurk::RailsReloader'
  }.freeze

  # Sidekiq::* constants that name a Wurk module, found by walking the namespace
  # once everything is loaded. `Sidekiq::Rails` is answered by const_missing, so
  # no walk finds it; the oracle lists it by hand.
  WALK = <<~RUBY
    def sidekiq_aliases(mod = Sidekiq, seen = {}, out = {})
      mod.constants(false).sort.each do |name|
        value = mod.const_get(name, false)
        next unless value.is_a?(Module)

        path = "\#{mod.name}::\#{name}"
        if value.name&.start_with?('Wurk::') then out[path] = value.name
        elsif value.name == path && !seen[value] then seen[value] = sidekiq_aliases(value, seen, out)
        end
      end
      out
    end
  RUBY

  # The file a `require` / `require_relative` line loads, without `.rb`, when it
  # is one of ours; nil for a gem or any other line.
  def required_file(file, line)
    case line
    when /\A\s*require_relative\s+['"]([^'"]+)['"]/ then File.expand_path(Regexp.last_match(1), File.dirname(file))
    when %r{\A\s*require\s+['"](wurk/[^'"]+)['"]} then File.join(LIB, Regexp.last_match(1))
    end&.delete_suffix('.rb')
  end

  def ruby(code)
    out, err, status = Open3.capture3(RbConfig.ruby, *Wurk::Test::SUBPROCESS_COVERAGE, '-I', LIB, '-e', code)

    assert_predicate status, :success?, "subprocess failed:\n#{err}"
    JSON.parse(out)
  end

  def test_require_wurk_leaves_every_lazy_constant_unloaded
    result = ruby(<<~RUBY)
      require 'json'
      require 'wurk'
      loaded = Wurk::LazyLoader.registered.reject { |ns, name| ns.autoload?(name) }.map { |ns, name| "\#{ns}::\#{name}" }
      lazy_files = %w[cli swarm launcher manager heartbeat web flow encryption limiter/concurrent]
      files = lazy_files.select { |f| $LOADED_FEATURES.any? { |l| l.end_with?("/lib/wurk/\#{f}.rb") } }
      print JSON.dump('loaded' => loaded, 'files' => files, 'rack' => !!defined?(::Rack),
                      'web_defined' => defined?(Wurk::Web), 'sidekiq_web_defined' => defined?(Sidekiq::Web))
    RUBY

    assert_empty result['loaded'], 'a cold require "wurk" must not resolve a lazy constant'
    assert_empty result['files']
    refute result['rack'], 'only the web tier needs rack'
    assert_equal 'constant', result['web_defined'], 'defined? must hold before the load, as gems expect'
    assert_equal 'constant', result['sidekiq_web_defined']
  end

  def test_every_alias_cold_from_its_sidekiq_name_is_the_wurk_object
    result = ruby(<<~RUBY)
      require 'json'
      require 'wurk'
      bad = #{ALIASES.to_a.inspect}.filter_map do |alias_name, target|
        rd, wr = IO.pipe
        pid = fork do
          rd.close
          same = Object.const_get(alias_name).equal?(Object.const_get(target))
          wr.write(same ? '' : "\#{alias_name} is not \#{target}")
        rescue NameError => e
          wr.write("\#{alias_name}: \#{e.message}")
        end
        wr.close
        Process.wait(pid)
        rd.read.then { |msg| msg unless msg.empty? }
      end
      print JSON.dump(bad)
    RUBY

    assert_empty result
  end

  def test_every_alias_resolves_after_its_target_was_loaded_by_its_wurk_name
    result = ruby(<<~RUBY)
      require 'json'
      require 'wurk'
      aliases = #{ALIASES.to_a.inspect}
      aliases.each { |_, target| Object.const_get(target) }
      print JSON.dump(aliases.reject { |a, t| Object.const_get(a).equal?(Object.const_get(t)) }.map(&:first))
    RUBY

    assert_empty result
  end

  def test_the_alias_oracle_lists_every_sidekiq_alias
    result = ruby(<<~RUBY)
      require 'json'
      require 'wurk'
      Wurk.eager_load!
      #{WALK}
      print JSON.dump(sidekiq_aliases)
    RUBY

    assert_equal ALIASES.except('Sidekiq::Rails::Reloader').keys.sort, result.keys.sort
  end

  # On Ruby 3.2 a plain `require` of an autoload's file does not take that
  # autoload's lock: a thread requiring launcher.rb (from cli.rb) and a thread
  # resolving Wurk::Launcher each wait on the other, and the process dies with
  # "No live threads left. Deadlock?". So nothing in lib/ or app/ requires an
  # autoload target; it names the constant and lets the autoload load it.
  # The concurrent case below hits that race only sometimes; this one always.
  def test_no_file_requires_an_autoload_target
    targets = ruby(<<~RUBY).to_set
      require 'json'
      require 'wurk'
      print JSON.dump(Wurk::LazyLoader.registered.map { |ns, name| ns.autoload?(name).delete_suffix('.rb') })
    RUBY
    offenders = Dir[File.join(ROOT, '{lib,app}/**/*.rb')].flat_map do |file|
      File.foreach(file).with_index(1).filter_map do |line, lineno|
        target = required_file(file, line)
        next unless target && targets.include?(target) && target != file.delete_suffix('.rb')

        "#{file.delete_prefix("#{ROOT}/")}:#{lineno}: #{line.strip}"
      end
    end

    assert_empty offenders, 'name the constant instead of requiring its autoload file'
  end

  def test_concurrent_first_references_share_one_object
    result = ruby(<<~RUBY)
      require 'json'
      require 'wurk'
      names = %w[Sidekiq::Web Wurk::Web Sidekiq::Paginator Sidekiq::Launcher Wurk::Launcher Sidekiq::Manager
                 Sidekiq::Encryption Wurk::Flow Sidekiq::FlowSet]
      gate = Queue.new
      threads = names.map { |n| Thread.new { gate.pop; Object.const_get(n) } }
      names.size.times { gate << true }
      got = names.zip(threads.map(&:value))
      print JSON.dump(got.reject { |n, v| v.equal?(Object.const_get(n)) }.map(&:first))
    RUBY

    assert_empty result
  end

  # Ruby's `autoload` lets two threads read the same file at once, and on some
  # Rubies that deadlocks: the process dies with "No live threads left.
  # Deadlock?" (bugs.ruby-lang.org/issues/18782 and #21719). Wurk reads each
  # lazy feature under its own lock, so one thread is inside a feature's file
  # at a time.
  def test_a_lazy_feature_is_read_by_one_thread_at_a_time
    result = ruby(<<~RUBY)
      require 'json'
      require 'wurk'
      feature = Wurk::LazyLoader.registered.map { |ns, name| ns.autoload?(name) }.compact.first
      order = []
      mutex = Mutex.new
      threads = 2.times.map do |i|
        Thread.new do
          Wurk::LazyLoader.load(feature) do
            mutex.synchronize { order << [:in, i] }
            sleep 0.2
            mutex.synchronize { order << [:out, i] }
          end
        end
      end
      threads.each(&:join)
      print JSON.dump(order)
    RUBY

    # The second thread waits its turn: in, out, in, out - never in, in.
    phases = result.map { |(phase, _thread)| phase }

    assert_equal %w[in out in out], phases
  end

  # sidekiq-cron prepends into `::Sidekiq::Launcher` from its own require, and
  # sidekiq-failures reopens Sidekiq classes; a lazy target must load first and
  # take the change, not leave a fresh class behind.
  def test_a_reopen_of_a_lazy_alias_reopens_the_wurk_class
    result = ruby(<<~RUBY)
      require 'json'
      require 'wurk'
      module Sidekiq
        class Launcher
          def reopened_here = true
        end
      end
      Sidekiq::Manager.prepend(Module.new { def prepended_here = true })
      print JSON.dump([Wurk::Launcher.method_defined?(:reopened_here), Wurk::Launcher.method_defined?(:run),
                       Wurk::Manager.method_defined?(:prepended_here)])
    RUBY

    assert_equal [true, true, true], result
  end

  # A lazy file required directly, rather than through its autoload, has its
  # subfiles reopen a class whose autoload is still pending: Ruby requires the
  # file again from inside itself. It works, but `-w` names it, and it is the
  # load order this tier split can get wrong.
  def test_lazy_entry_points_load_without_a_circular_require
    entries = ['require "sidekiq/web"', 'require "sidekiq/pro/web"', 'require "sidekiq/cli"',
               'require "sidekiq/job/iterable"', 'Wurk.configuration.web', 'Wurk.configuration.api_read_only = "no"',
               'require "wurk/api/app"', 'Wurk.eager_load!', 'Wurk.configure_embed']
    entries.each do |entry|
      _out, err, status = Open3.capture3(RbConfig.ruby, '-w', '-I', LIB, '-e', "require 'sidekiq'; #{entry}")

      assert_predicate status, :success?, "#{entry}:\n#{err}"
      refute_match(/circular require|to define .* but it didn't/, err, entry)
    end
  end

  def test_eager_load_leaves_no_autoload_pending
    result = ruby(<<~RUBY)
      require 'json'
      require 'wurk'
      Wurk.eager_load!
      pending = []
      walk = lambda do |mod, seen|
        next if seen[mod]

        seen[mod] = true
        mod.constants(false).each do |name|
          next pending << "\#{mod}::\#{name}" if mod.autoload?(name)

          value = mod.const_get(name, false)
          walk.call(value, seen) if value.is_a?(Module) && value.name&.start_with?('Wurk', 'Sidekiq')
        end
      end
      walk.call(Wurk, {})
      walk.call(Sidekiq, {})
      print JSON.dump(pending)
    RUBY

    assert_empty result
  end

  # A constant eager_load! adds to a namespace `require "wurk"` already loaded
  # must have been there cold, as itself or an autoload. Otherwise it resolves
  # only once some other file happens to load it: the load-order crash class.
  def test_a_cold_require_names_every_constant_eager_load_defines
    result = ruby(<<~RUBY)
      require 'json'
      require 'wurk'
      snapshot = lambda do
        seen = {}
        walk = lambda do |mod|
          next if seen.key?(mod)

          seen[mod] = mod.constants(false)
          mod.constants(false).each do |name|
            next if mod.autoload?(name)

            value = mod.const_get(name, false)
            walk.call(value) if value.is_a?(Module) && value.name&.start_with?('Wurk', 'Sidekiq')
          end
        end
        walk.call(Wurk)
        walk.call(Sidekiq)
        seen
      end
      cold = snapshot.call
      Wurk.eager_load!
      unnamed = snapshot.call.flat_map do |mod, names|
        cold.key?(mod) ? (names - cold[mod]).map { |n| "\#{mod}::\#{n}" } : []
      end
      print JSON.dump(unnamed)
    RUBY

    assert_empty result
  end

  def test_eager_load_resolves_every_registration_in_process
    assert_nil Wurk.eager_load!
    Wurk::LazyLoader.registered.each do |namespace, name|
      refute namespace.autoload?(name), "#{namespace}::#{name} still pending after eager_load!"
    end
  end

  def test_registered_is_a_copy
    Wurk::LazyLoader.registered.clear

    refute_empty Wurk::LazyLoader.registered
  end
end
