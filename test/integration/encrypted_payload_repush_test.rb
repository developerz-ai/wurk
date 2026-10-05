# frozen_string_literal: true

require_relative '../test_helper'

# Top-level so Processor's Object.const_get resolves them.
class EncRepushIterableWorker
  include Wurk::IterableJob

  sidekiq_options encrypt: true

  def build_enumerator(*_args, cursor:)
    Enumerator.new { |y| (cursor || 0).upto(2) { |i| y << [i, i + 1] } }
  end

  def each_iteration(_item, *_args)
    raise Wurk::Job::Interrupted
  end
end

class EncRepushFailingWorker
  include Wurk::Worker

  sidekiq_options encrypt: true

  def perform(*_args)
    raise ArgumentError, 'boom'
  end
end

class EncRepushOverLimitWorker
  include Wurk::Worker

  sidekiq_options encrypt: true

  LIMITER = Struct.new(:name, :type, :options).new('enc-repush', :bucket, { reschedule: 2 })

  def perform(*_args)
    raise Wurk::Limiter::OverLimit, LIMITER
  end
end

# E5 (ent §4.3): Encryption::ServerMiddleware decrypts the last arg into the
# job hash every middleware shares. Any layer that writes that hash back to
# Redis — InterruptHandler's re-push, the limiter's reschedule / poison brake,
# the retrier — must write the envelope, never the plaintext. Real Processor,
# real reliable fetcher, real Redis, server chain in production order
# (InterruptHandler prepended, Limiter at boot, Encryption added at enable).
class EncryptedPayloadRepushTest < Wurk::Test::UnitCase
  # Not parallelize_me!: Wurk::Encryption.enable is process-global.
  KEY = ("\x07" * 32).b
  SECRET = { 'pan' => '4111111111111111' }.freeze

  def setup
    super
    Wurk::Encryption.enable(active_version: 1) { |_v| KEY }
    @queue_name = "encrp-#{Process.pid}-#{object_id}"
    @public_queue = "queue:#{@queue_name}"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.server_middleware do |chain|
      chain.add(Wurk::Limiter::ServerMiddleware)
      chain.add(Wurk::Encryption::ServerMiddleware)
      chain.prepend(Wurk::Middleware::InterruptHandler)
    end
    @capsule = Wurk::Capsule.new('test', @config)
    @capsule.queues = [@queue_name]
    @capsule.fetcher = Wurk::Fetcher::Reliable.new(@capsule)
    @pool = @capsule.redis_pool
    @processor = Wurk::Processor.new(@capsule)
  end

  def teardown
    @pool.with { |c| c.call('DEL', @public_queue, "#{@public_queue}:private") }
  ensure
    Wurk::Encryption.disable!
    Wurk.configuration.client_middleware.remove(Wurk::Encryption::ClientMiddleware)
    Wurk.configuration.server_middleware.remove(Wurk::Encryption::ServerMiddleware)
    super
  end

  def test_an_interrupted_encrypted_iterable_job_is_repushed_with_its_envelope
    jid = enqueue(EncRepushIterableWorker)

    @processor.process_one

    raw = @pool.with { |c| c.call('LRANGE', @public_queue, 0, -1) }.find { |j| j.include?(jid) }

    refute_nil raw, 'the interrupted job must be re-pushed onto its queue'
    assert_sealed raw
  ensure
    @pool.with { |c| c.call('DEL', "it-#{jid}") }
  end

  # A host that reorders the chain so decryption wraps the handler hands it
  # plaintext args; the re-push must seal them itself.
  def test_the_interrupt_handler_reseals_args_it_receives_decrypted
    handler = Wurk::Middleware::InterruptHandler.new
    handler.config = @capsule
    job = { 'class' => 'X', 'jid' => SecureRandom.hex(12), 'args' => ['uid', SECRET.dup], 'encrypt' => true }

    assert_raises(Wurk::JobRetry::Skip) do
      handler.call(nil, job, @queue_name) { raise Wurk::Job::Interrupted }
    end

    assert_sealed(@pool.with { |c| c.call('LPOP', @public_queue) })
    assert_equal SECRET, job['args'].last, 'the in-flight hash is left as the caller had it'
  end

  def test_a_failing_encrypted_job_lands_in_retry_still_encrypted
    jid = enqueue(EncRepushFailingWorker, 'retry' => 3)

    @processor.process_one

    assert_sealed take_from(Wurk::Keys::RETRY, jid)
  end

  def test_a_failing_encrypted_job_without_retries_lands_in_dead_still_encrypted
    jid = enqueue(EncRepushFailingWorker, 'retry' => 0)

    @processor.process_one

    assert_sealed take_from(Wurk::Keys::DEAD, jid)
  end

  def test_a_rescheduled_over_limit_job_is_scheduled_still_encrypted
    jid = enqueue(EncRepushOverLimitWorker)

    @processor.process_one

    assert_sealed take_from(Wurk::Keys::SCHEDULE, jid)
  end

  def test_the_limiter_poison_brake_kills_the_job_still_encrypted
    jid = enqueue(EncRepushOverLimitWorker, 'overrated' => 1)

    @processor.process_one

    assert_sealed take_from(Wurk::Keys::DEAD, jid)
  end

  private

  def enqueue(klass, extra = {})
    jid = SecureRandom.hex(12)
    job = { 'class' => klass.name, 'jid' => jid, 'queue' => @queue_name,
            'args' => ['uid', SECRET], 'encrypt' => true }.merge(extra)
    Wurk::Encryption::ClientMiddleware.new.call(nil, job, @queue_name, @pool) { true }
    @pool.with { |c| c.call('LPUSH', @public_queue, Wurk.dump_json(job)) }
    jid
  end

  def take_from(zset, jid)
    raw = @pool.with { |c| c.call('ZRANGE', zset, 0, -1) }.find { |j| j.include?(jid) }
    @pool.with { |c| c.call('ZREM', zset, raw) } if raw
    raw
  end

  def assert_sealed(raw)
    refute_nil raw, 'expected the job payload in Redis'
    refute_includes raw, SECRET['pan'], 'plaintext secret written back to Redis'
    args = Wurk.load_json(raw)['args']

    assert_equal 'uid', args.first
    assert Wurk::Encryption.envelope?(args.last), "last arg must stay enveloped, got #{args.last.inspect}"
    assert_equal SECRET, Wurk::Encryption.decrypt(args.last)
  end
end
