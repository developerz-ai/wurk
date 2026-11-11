# frozen_string_literal: true

require_relative '../test_helper'

# Chain::Entry's opt-in for Wurk's stateless built-ins: one instance per entry
# instead of one per job. Everything else — host middleware, a host subclass of
# a built-in, `retrieve` — keeps Sidekiq's fresh instance per job.
class MiddlewareSharedInstanceTest < Wurk::Test::UnitCase
  class Shared
    include Wurk::Middleware::ServerMiddleware

    def self.shared_instance? = true

    def initialize(log = [])
      @log = log
    end

    def call(*)
      @log << self
      yield
    end
  end

  class HostSubclass < Shared; end

  class DeclinesSharing < Shared
    def self.shared_instance? = false
  end

  BUILTINS = [Wurk::Middleware::InterruptHandler, Wurk::Middleware::Expiry,
              Wurk::Middleware::Timeout, Wurk::Middleware::Status,
              Wurk::Batch::ServerMiddleware, Wurk::Limiter::ServerMiddleware,
              Wurk::Metrics::Statsd, Wurk::Metrics::History].freeze

  def test_a_shared_class_runs_every_job_on_one_instance_bound_to_the_chain_config
    seen = []
    config = Wurk::Configuration.new
    chain = Wurk::Middleware::Chain.new(config)
    chain.add(Shared, seen)
    3.times { chain.invoke('arg') { :ok } }

    assert_equal 1, seen.uniq.size
    assert_same config, seen.first.config
  end

  def test_a_host_subclass_of_a_shared_class_gets_a_fresh_instance_per_job
    seen = []
    chain = Wurk::Middleware::Chain.new(Wurk::Configuration.new)
    chain.add(HostSubclass, seen)
    2.times { chain.invoke('arg') { :ok } }

    assert_equal 2, seen.uniq.size
  end

  def test_a_class_answering_false_is_not_shared
    seen = []
    chain = Wurk::Middleware::Chain.new(Wurk::Configuration.new)
    chain.add(DeclinesSharing, seen)
    2.times { chain.invoke('arg') { :ok } }

    assert_equal 2, seen.uniq.size
  end

  def test_retrieve_and_make_new_still_build_fresh_instances_of_a_shared_class
    chain = Wurk::Middleware::Chain.new(Wurk::Configuration.new)
    chain.add(Shared)
    entry = chain.entries.first

    refute_same chain.retrieve.first, chain.retrieve.first
    refute_same entry.make_new, entry.instance
  end

  def test_copy_for_rebinds_the_shared_instance_to_the_capsule
    config = Wurk::Configuration.new
    capsule = config.capsule('shared-test')
    chain = Wurk::Middleware::Chain.new(config)
    chain.add(Shared)
    copy = chain.copy_for(capsule)

    assert_same capsule, copy.entries.first.instance.config
    assert_same config, chain.entries.first.instance.config
  end

  def test_an_entry_never_bound_to_a_config_falls_back_to_fresh_instances
    entry = Wurk::Middleware::Chain::Entry.new(Shared)

    refute_same entry.instance, entry.instance
  end

  def test_the_audited_builtins_are_the_shared_ones_in_the_default_server_chain
    shared = Wurk.configuration.server_middleware.entries.map(&:klass).select do |klass|
      klass.singleton_class.method_defined?(:shared_instance?, false) && klass.shared_instance?
    end

    assert_equal BUILTINS.sort_by(&:name), shared.sort_by(&:name)
  end

  # The property sharing depends on, checked at runtime for the audit's word:
  # running jobs through a shared built-in leaves no state on it beyond the
  # config the chain bound.
  def test_shared_builtins_keep_no_per_job_state
    chain = Wurk::Middleware::Chain.new(Wurk.configuration)
    BUILTINS.each { |klass| chain.add(klass) }
    jobs = [
      { 'class' => 'Plain', 'jid' => 'j1', 'args' => [] },
      { 'class' => 'Bounded', 'jid' => 'j2', 'args' => [], 'expiry' => Time.now.to_f + 60,
        'deadline_at' => Time.now.to_f + 60, 'timeout' => 30 }
    ]
    jobs.each { |job| chain.invoke(Object.new, job, 'default') { :ok } }

    chain.entries.each do |entry|
      assert_equal [:@config], entry.instance.instance_variables, entry.klass.name
    end
  end
end
