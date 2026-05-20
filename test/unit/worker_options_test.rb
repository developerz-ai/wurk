# frozen_string_literal: true

require_relative '../test_helper'

class WorkerOptionsTest < Wurk::Test::UnitCase
  parallelize_me!

  # Bare include — no `sidekiq_options` calls. Verifies defaults flow through.
  class BareWorker
    include Wurk::Worker

    def perform; end
  end

  class ConfiguredWorker
    include Wurk::Worker

    sidekiq_options queue: 'critical', retry: 5, tags: %w[fast]

    def perform; end
  end

  class ChildWorker < ConfiguredWorker
    sidekiq_options retry: 2
  end

  class JobStyleWorker
    include Wurk::Job

    sidekiq_options queue: 'mail'

    def perform; end
  end

  # --- option storage --------------------------------------------------

  def test_bare_worker_inherits_default_job_options
    opts = BareWorker.get_sidekiq_options

    assert_equal 'default', opts['queue']
    assert opts['retry']
  end

  def test_sidekiq_options_returns_merged_hash
    opts = ConfiguredWorker.get_sidekiq_options

    assert_equal 'critical', opts['queue']
    assert_equal 5, opts['retry']
    assert_equal %w[fast], opts['tags']
  end

  def test_sidekiq_options_stringifies_keys
    ConfiguredWorker.get_sidekiq_options.each_key do |k|
      assert_kind_of String, k
    end
  end

  def test_sidekiq_options_hash_alias
    assert_same ConfiguredWorker.get_sidekiq_options, ConfiguredWorker.sidekiq_options_hash
  end

  def test_subclass_inherits_parent_options
    opts = ChildWorker.get_sidekiq_options

    assert_equal 'critical', opts['queue']
  end

  def test_subclass_overrides_parent_options
    assert_equal 2, ChildWorker.get_sidekiq_options['retry']
    assert_equal 5, ConfiguredWorker.get_sidekiq_options['retry']
  end

  def test_job_alias_module_behaves_like_worker
    assert_equal 'mail', JobStyleWorker.get_sidekiq_options['queue']
  end

  # --- queue_as --------------------------------------------------------

  def test_queue_as_sets_queue_option
    klass = Class.new do
      include Wurk::Worker

      queue_as :low
    end

    assert_equal 'low', klass.get_sidekiq_options['queue']
  end

  def test_queue_as_stringifies_symbols
    klass = Class.new do
      include Wurk::Worker

      queue_as :high
    end

    assert_equal 'high', klass.get_sidekiq_options['queue']
  end

  # --- retry blocks ----------------------------------------------------

  def test_sidekiq_retry_in_block_storage
    block = proc { |count, _ex, _job| count * 10 }
    klass = Class.new { include Wurk::Worker }
    klass.sidekiq_retry_in(&block)

    assert_same block, klass.sidekiq_retry_in_block
  end

  def test_sidekiq_retries_exhausted_block_storage
    block = proc { |_job, _ex| :dropped }
    klass = Class.new { include Wurk::Worker }
    klass.sidekiq_retries_exhausted(&block)

    assert_same block, klass.sidekiq_retries_exhausted_block
  end

  def test_subclass_inherits_retry_block
    parent = Class.new { include Wurk::Worker }
    parent.sidekiq_retry_in { 42 }
    child = Class.new(parent)

    assert_same parent.sidekiq_retry_in_block, child.sidekiq_retry_in_block
  end

  # --- delay removal ---------------------------------------------------

  def test_delay_raises_argument_error
    err = assert_raises(ArgumentError) { ConfiguredWorker.delay }

    assert_match(/delay is removed/, err.message)
  end

  def test_delay_for_raises_argument_error
    assert_raises(ArgumentError) { ConfiguredWorker.delay_for(60) }
  end

  def test_delay_until_raises_argument_error
    assert_raises(ArgumentError) { ConfiguredWorker.delay_until(Time.now + 60) }
  end

  # --- client_push -----------------------------------------------------

  def test_client_push_rejects_symbol_keys
    err = assert_raises(ArgumentError) do
      ConfiguredWorker.client_push(class: ConfiguredWorker, args: [])
    end

    assert_match(/string keys/, err.message)
  end

  def test_client_push_delegates_to_build_client_push
    captured = nil
    fake_client = Object.new
    fake_client.define_singleton_method(:push) do |item|
      captured = item
      'jid-1'
    end
    with_stub(ConfiguredWorker, :build_client, fake_client) do
      jid = ConfiguredWorker.client_push('class' => ConfiguredWorker, 'args' => [1])

      assert_equal 'jid-1', jid
    end

    assert_equal ConfiguredWorker, captured['class']
  end

  def test_build_client_returns_wurk_client
    assert_kind_of Wurk::Client, ConfiguredWorker.build_client
  end

  # --- set returns Setter ---------------------------------------------

  def test_set_returns_setter
    assert_kind_of Wurk::Worker::Setter, ConfiguredWorker.set(queue: 'urgent')
  end

  # --- perform_inline --------------------------------------------------

  class RecordingWorker
    include Wurk::Worker

    @ran = []
    class << self
      attr_reader :ran
    end

    def perform(*args)
      self.class.ran << args
    end
  end

  def test_perform_inline_runs_perform
    RecordingWorker.ran.clear
    RecordingWorker.perform_inline(1, 2)

    assert_equal [[1, 2]], RecordingWorker.ran
  end

  def test_perform_sync_is_alias_of_perform_inline
    RecordingWorker.ran.clear
    RecordingWorker.perform_sync(3)

    assert_equal [[3]], RecordingWorker.ran
  end

  # --- perform_async flows through client_push ------------------------

  class PushSpyWorker
    include Wurk::Worker

    sidekiq_options queue: 'spy'

    def perform(*); end
  end

  def test_perform_async_constructs_payload
    captured = nil
    fake_client = Object.new
    fake_client.define_singleton_method(:push) do |item|
      captured = item
      'spy-jid'
    end

    with_stub(PushSpyWorker, :build_client, fake_client) do
      assert_equal 'spy-jid', PushSpyWorker.perform_async('a', 'b')
    end

    assert_equal PushSpyWorker, captured['class']
    assert_equal %w[a b], captured['args']
  end

  # --- instance accessors ---------------------------------------------

  def test_jid_accessor_present
    worker = ConfiguredWorker.new
    worker.jid = 'abc'

    assert_equal 'abc', worker.jid
  end

  def test_context_accessor_present
    worker = ConfiguredWorker.new
    worker._context = :ctx

    assert_equal :ctx, worker._context
  end

  def test_interrupted_false_without_context
    refute_predicate ConfiguredWorker.new, :interrupted?
  end

  def test_interrupted_delegates_to_context_stopping
    worker = ConfiguredWorker.new
    worker._context = Struct.new(:stopping).new(true).tap { |s| s.define_singleton_method(:stopping?) { true } }

    assert_predicate worker, :interrupted?
  end

  def test_logger_returns_wurk_logger
    assert_same Wurk.logger, ConfiguredWorker.new.logger
  end

  private

  # Replace `klass.<method>` with a constant-return stub for the block
  # duration, then restore. Inline to avoid depending on minitest/mock
  # (not vendored on Ruby 4.x).
  def with_stub(klass, method, value)
    original = klass.singleton_class.instance_method(method)
    klass.singleton_class.send(:define_method, method) { value }
    yield
  ensure
    klass.singleton_class.send(:define_method, method, original)
  end
end
