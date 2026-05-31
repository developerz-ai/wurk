# frozen_string_literal: true

require_relative '../test_helper'

class EncryptionTest < Wurk::Test::UnitCase
  # NOT parallelize_me! — these tests flip the process-wide
  # `Wurk::Encryption.enabled?` flag and install client/server middleware
  # on the global config. Running in parallel would let one test's
  # `enable` leak into another's "should be a no-op" assertion.

  ENABLE_MUTEX = ::Mutex.new

  KEY_V1 = ("\x01" * 32).b
  KEY_V2 = ("\x02" * 32).b

  def teardown
    Wurk::Encryption.disable!
    Wurk.configuration.client_middleware.remove(Wurk::Encryption::ClientMiddleware)
    Wurk.configuration.server_middleware.remove(Wurk::Encryption::ServerMiddleware)
  ensure
    super
  end

  # ---- enable / disable ------------------------------------------------

  def test_disabled_by_default
    refute_predicate Wurk::Encryption, :enabled?
    refute_predicate Sidekiq::Enterprise::Crypto, :enabled?
  end

  def test_enable_requires_active_version
    assert_raises(ArgumentError) do
      Wurk::Encryption.enable(active_version: nil) { |_v| KEY_V1 }
    end
  end

  def test_enable_requires_block
    assert_raises(ArgumentError) do
      Wurk::Encryption.enable(active_version: 1)
    end
  end

  def test_enable_via_sidekiq_enterprise_crypto
    ENABLE_MUTEX.synchronize do
      Sidekiq::Enterprise::Crypto.enable(active_version: 1) { |_v| KEY_V1 }

      assert_predicate Sidekiq::Enterprise::Crypto, :enabled?
      assert_predicate Wurk::Encryption, :enabled?
      assert_equal 1, Wurk::Encryption.active_version
    end
  end

  def test_enable_installs_both_middleware
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }

      assert Wurk.configuration.client_middleware.exists?(Wurk::Encryption::ClientMiddleware)
      assert Wurk.configuration.server_middleware.exists?(Wurk::Encryption::ServerMiddleware)
    end
  end

  def test_enable_is_idempotent
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }

      client_count = Wurk.configuration.client_middleware.entries.count { |e| e.klass == Wurk::Encryption::ClientMiddleware }
      server_count = Wurk.configuration.server_middleware.entries.count { |e| e.klass == Wurk::Encryption::ServerMiddleware }

      assert_equal 1, client_count
      assert_equal 1, server_count
    end
  end

  # ---- key validation --------------------------------------------------

  def test_key_for_raises_when_resolver_returns_nil
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| nil }

      assert_raises(Wurk::Encryption::KeyMissingError) do
        Wurk::Encryption.key_for(1)
      end
    end
  end

  def test_key_for_raises_on_wrong_size
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| 'shorty' }

      assert_raises(Wurk::Encryption::Error) do
        Wurk::Encryption.key_for(1)
      end
    end
  end

  def test_key_for_caches_resolver_calls
    ENABLE_MUTEX.synchronize do
      calls = 0
      Wurk::Encryption.enable(active_version: 1) do |_v|
        calls += 1
        KEY_V1
      end

      Wurk::Encryption.key_for(1)
      Wurk::Encryption.key_for(1)

      assert_equal 1, calls
    end
  end

  def test_key_for_without_enable_raises
    refute_predicate Wurk::Encryption, :enabled?

    assert_raises(Wurk::Encryption::Error) do
      Wurk::Encryption.key_for(1)
    end
  end

  # ---- encrypt / decrypt round-trip -----------------------------------

  def test_encrypt_returns_envelope_shape # rubocop:disable Minitest/MultipleAssertions
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      env = Wurk::Encryption.encrypt('hello')

      assert_kind_of Hash, env
      assert_equal 1, env['v']
      assert env.key?('iv')
      assert env.key?('ct')
      assert env.key?('tag')
      assert Wurk::Encryption.envelope?(env)
    end
  end

  def test_encrypt_decrypt_roundtrip_string
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      env = Wurk::Encryption.encrypt('top secret')

      assert_equal 'top secret', Wurk::Encryption.decrypt(env)
    end
  end

  def test_encrypt_decrypt_roundtrip_hash
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      payload = { 'cc' => '4111111111111111', 'cvv' => '123' }
      env = Wurk::Encryption.encrypt(payload)

      assert_equal payload, Wurk::Encryption.decrypt(env)
    end
  end

  def test_encrypt_decrypt_roundtrip_array
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      payload = [1, 'two', { 'three' => 3 }]
      env = Wurk::Encryption.encrypt(payload)

      assert_equal payload, Wurk::Encryption.decrypt(env)
    end
  end

  def test_each_encrypt_produces_unique_iv_and_ct
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      a = Wurk::Encryption.encrypt('same')
      b = Wurk::Encryption.encrypt('same')

      refute_equal a['iv'], b['iv']
      refute_equal a['ct'], b['ct']
    end
  end

  def test_tampered_ciphertext_raises_cipher_error
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      env = Wurk::Encryption.encrypt('payload')
      env['ct'] = ::Base64.strict_encode64(::Base64.strict_decode64(env['ct']).succ)

      assert_raises(::OpenSSL::Cipher::CipherError) do
        Wurk::Encryption.decrypt(env)
      end
    end
  end

  def test_wrong_key_version_raises_cipher_error
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      env = Wurk::Encryption.encrypt('payload')
      # Rebind v=1 → KEY_V2 so the tag fails to authenticate.
      Wurk::Encryption.disable!
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V2 }

      assert_raises(::OpenSSL::Cipher::CipherError) do
        Wurk::Encryption.decrypt(env)
      end
    end
  end

  # ---- key rotation ----------------------------------------------------

  def test_rotation_decrypts_legacy_envelopes # rubocop:disable Minitest/MultipleAssertions
    ENABLE_MUTEX.synchronize do
      keys = { 1 => KEY_V1, 2 => KEY_V2 }
      Wurk::Encryption.enable(active_version: 1) { |v| keys[v] }
      legacy = Wurk::Encryption.encrypt('old data')

      assert_equal 1, legacy['v']

      Wurk::Encryption.disable!
      Wurk::Encryption.enable(active_version: 2) { |v| keys[v] }
      fresh = Wurk::Encryption.encrypt('new data')

      assert_equal 2, fresh['v']
      assert_equal 'old data', Wurk::Encryption.decrypt(legacy)
      assert_equal 'new data', Wurk::Encryption.decrypt(fresh)
    end
  end

  # #18 "Done when": enable v1, push, rotate to v2, push, both decrypt cleanly
  # — exercised end-to-end through the real client + server middleware pair.
  def test_rotation_decrypts_both_versions_through_middleware # rubocop:disable Minitest/MultipleAssertions,Metrics/AbcSize
    ENABLE_MUTEX.synchronize do
      keys = { 1 => KEY_V1, 2 => KEY_V2 }

      Wurk::Encryption.enable(active_version: 1) { |v| keys[v] }
      v1_job = { 'class' => 'X', 'args' => ['uid', { 'pan' => '4111' }], 'encrypt' => true }
      invoke_client(v1_job)

      assert_equal 1, v1_job['args'].last['v'], 'first push encrypts under v1'

      # Rotate: bump active_version, keep returning the old key for in-flight jobs.
      Wurk::Encryption.disable!
      Wurk::Encryption.enable(active_version: 2) { |v| keys[v] }
      v2_job = { 'class' => 'X', 'args' => ['uid', { 'pan' => '5500' }], 'encrypt' => true }
      invoke_client(v2_job)

      assert_equal 2, v2_job['args'].last['v'], 'post-rotation push encrypts under v2'

      invoke_server(v1_job) { :ok }
      invoke_server(v2_job) { :ok }

      assert_equal({ 'pan' => '4111' }, v1_job['args'].last, 'legacy v1 job decrypts')
      assert_equal({ 'pan' => '5500' }, v2_job['args'].last, 'fresh v2 job decrypts')
    end
  end

  # ---- envelope? -------------------------------------------------------

  def test_envelope_predicate_recognizes_real_envelope
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }

      assert Wurk::Encryption.envelope?(Wurk::Encryption.encrypt('x'))
    end
  end

  def test_envelope_predicate_rejects_plain_hash # rubocop:disable Minitest/MultipleAssertions
    refute Wurk::Encryption.envelope?({ 'v' => 1, 'iv' => 'a', 'ct' => 'b', 'tag' => 'c' })
    refute Wurk::Encryption.envelope?({ Wurk::Encryption::ENVELOPE_MARKER => true })
    refute Wurk::Encryption.envelope?('string')
    refute Wurk::Encryption.envelope?(nil)
    refute Wurk::Encryption.envelope?([1, 2])
  end

  # ---- ClientMiddleware ------------------------------------------------

  def test_client_middleware_skips_when_disabled
    job = { 'class' => 'X', 'args' => [1, 'secret'], 'encrypt' => true }
    ran = invoke_client(job)

    assert ran
    assert_equal 'secret', job['args'].last
  end

  def test_client_middleware_skips_without_opt_in
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      job = { 'class' => 'X', 'args' => [1, 'secret'] }
      invoke_client(job)

      assert_equal 'secret', job['args'].last
    end
  end

  def test_client_middleware_encrypts_last_arg
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      job = { 'class' => 'X', 'args' => ['public', { 'secret' => 'shh' }], 'encrypt' => true }
      invoke_client(job)

      assert_equal 'public', job['args'].first
      assert Wurk::Encryption.envelope?(job['args'].last)
    end
  end

  def test_client_middleware_leaves_already_encrypted_arg_alone
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      env = Wurk::Encryption.encrypt('precomputed')
      job = { 'class' => 'X', 'args' => [1, env], 'encrypt' => true }
      invoke_client(job)

      assert_equal env, job['args'].last
    end
  end

  def test_client_middleware_handles_empty_args
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      job = { 'class' => 'X', 'args' => [], 'encrypt' => true }
      invoke_client(job)

      assert_equal [], job['args']
    end
  end

  def test_client_middleware_chain_continues
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      job = { 'class' => 'X', 'args' => [1, 'secret'], 'encrypt' => true }

      assert_equal :done, invoke_client(job) { :done }
    end
  end

  # ---- ServerMiddleware ------------------------------------------------

  def test_server_middleware_skips_when_disabled
    env = { Wurk::Encryption::ENVELOPE_MARKER => true, 'v' => 1, 'iv' => 'a', 'ct' => 'b', 'tag' => 'c' }
    job = { 'class' => 'X', 'args' => [1, env], 'encrypt' => true }
    invoke_server(job) { :ok }

    assert_equal env, job['args'].last
  end

  def test_server_middleware_skips_without_opt_in
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      env = Wurk::Encryption.encrypt('shh')
      job = { 'class' => 'X', 'args' => [1, env] }
      invoke_server(job) { :ok }

      assert_equal env, job['args'].last
    end
  end

  def test_server_middleware_decrypts_last_arg
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      payload = { 'secret' => 'value' }
      job = { 'class' => 'X', 'args' => ['public', Wurk::Encryption.encrypt(payload)], 'encrypt' => true }
      invoke_server(job) { :ok }

      assert_equal 'public', job['args'].first
      assert_equal payload, job['args'].last
    end
  end

  def test_server_middleware_no_op_when_last_arg_is_plain
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      job = { 'class' => 'X', 'args' => [1, 'already plain'], 'encrypt' => true }
      invoke_server(job) { :ok }

      assert_equal 'already plain', job['args'].last
    end
  end

  def test_server_middleware_propagates_perform_return
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      job = { 'class' => 'X', 'args' => [Wurk::Encryption.encrypt('x')], 'encrypt' => true }

      assert_equal :result, invoke_server(job) { :result }
    end
  end

  # #18: a tampered/undecryptable envelope is terminal, not retryable — the
  # server middleware routes it straight to the dead set (tagged
  # encryption_error) and ACKs via JobRetry::Skip rather than letting the
  # CipherError bubble into the 25× retry loop.
  def test_server_middleware_routes_bad_tag_to_dead_set # rubocop:disable Minitest/MultipleAssertions,Metrics/AbcSize
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      env = Wurk::Encryption.encrypt('x')
      env['tag'] = ::Base64.strict_encode64("\x00" * 16)
      job = { 'class' => 'X', 'args' => [nil, env], 'encrypt' => true, 'jid' => jid }

      perform_ran = false
      assert_raises(Wurk::JobRetry::Skip) do
        invoke_server(job) { perform_ran = true }
      end

      refute perform_ran, 'perform must not run on a decryption failure'
      record = dead_record(jid)

      refute_nil record, 'job should be in the dead set'
      assert_equal Wurk::Encryption::DECRYPTION_ERROR_CLASS, record['error_class']
      assert_includes record['error_message'], Wurk::Encryption::DEAD_REASON
      assert_equal 0, retry_count_for(jid), 'must skip the retry pipeline entirely'
    ensure
      drain_dead(jid)
    end
  end

  # #18 "Done when": missing-key job lands in dead with encryption_error in <1s.
  def test_missing_key_routes_to_dead_under_one_second # rubocop:disable Minitest/MultipleAssertions,Metrics/AbcSize
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      env = Wurk::Encryption.encrypt('secret')
      # Operator dropped the v1 key during rotation: resolver no longer has it.
      Wurk::Encryption.disable!
      Wurk::Encryption.enable(active_version: 2) { |v| v == 2 ? KEY_V2 : nil }
      job = { 'class' => 'PrivJob', 'args' => ['uid', env], 'encrypt' => true, 'jid' => jid }

      started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      assert_raises(Wurk::JobRetry::Skip) { invoke_server(job) { :unreached } }
      elapsed = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started

      assert_operator elapsed, :<, 1.0, 'must dead-letter in under a second'
      record = dead_record(jid)

      refute_nil record
      assert_equal 'uid', record['args'].first, 'plaintext args stay visible for triage'
      assert Wurk::Encryption.envelope?(record['args'].last), 'undecryptable envelope is preserved'
    ensure
      drain_dead(jid)
    end
  end

  def test_decryption_failure_fires_death_handlers # rubocop:disable Metrics/AbcSize
    ENABLE_MUTEX.synchronize do
      fired = []
      Wurk.configuration.death_handlers << ->(j, ex) { fired << [j['jid'], ex.class] }
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      env = Wurk::Encryption.encrypt('x')
      Wurk::Encryption.disable!
      Wurk::Encryption.enable(active_version: 1) { |_v| nil } # key gone
      job = { 'class' => 'X', 'args' => [env], 'encrypt' => true, 'jid' => jid }

      assert_raises(Wurk::JobRetry::Skip) { invoke_server(job) { :unreached } }
      assert_equal [[jid, Wurk::Encryption::KeyMissingError]], fired
    ensure
      Wurk.configuration.death_handlers.clear
      drain_dead(jid)
    end
  end

  def test_decryption_failure_emits_statsd_counter
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      env = Wurk::Encryption.encrypt('x')
      env['tag'] = ::Base64.strict_encode64("\x00" * 16)
      job = { 'class' => 'CardJob', 'args' => [env], 'encrypt' => true, 'jid' => jid }

      metrics = capture_statsd do
        assert_raises(Wurk::JobRetry::Skip) { invoke_server(job) { :unreached } }
      end

      assert_includes metrics, ['jobs.encryption_error', ['worker:CardJob']]
    ensure
      drain_dead(jid)
    end
  end

  # ---- end-to-end pair -------------------------------------------------

  def test_pair_roundtrip_through_both_middleware
    ENABLE_MUTEX.synchronize do
      Wurk::Encryption.enable(active_version: 1) { |_v| KEY_V1 }
      secret = { 'card' => '4111', 'cvv' => '999' }
      job = { 'class' => 'X', 'args' => [42, secret], 'encrypt' => true }
      invoke_client(job)

      refute_equal secret, job['args'].last
      assert Wurk::Encryption.envelope?(job['args'].last)

      invoke_server(job) { :ok }

      assert_equal [42, secret], job['args']
    end
  end

  # ---- Web UI redaction (§4.7) -----------------------------------------

  def test_redact_args_passthrough_when_not_encrypted
    job = { 'args' => [1, 'two'] }

    assert_equal [1, 'two'], Wurk::Encryption.redact_args(job)
  end

  def test_redact_args_replaces_last_arg_when_encrypted
    job = { 'args' => [1, { 'secret' => 'x' }], 'encrypt' => true }

    assert_equal [1, '<encrypted>'], Wurk::Encryption.redact_args(job)
  end

  def test_redact_args_handles_empty_args
    job = { 'args' => [], 'encrypt' => true }

    assert_equal [], Wurk::Encryption.redact_args(job)
  end

  def test_redact_args_supports_symbol_keys
    job = { args: [1, 'secret'], encrypt: true }

    assert_equal [1, '<encrypted>'], Wurk::Encryption.redact_args(job)
  end

  # ---- helpers ---------------------------------------------------------

  private

  def invoke_client(job, &)
    block = block_given? ? proc(&) : proc { true }
    pool = Wurk.configuration.redis_pool
    Wurk::Encryption::ClientMiddleware.new.call(nil, job, job['queue'], pool, &block)
  end

  def invoke_server(job, &)
    mw = Wurk::Encryption::ServerMiddleware.new
    mw.config = Wurk.configuration
    mw.call(nil, job, job['queue'], &)
  end

  def jid
    @jid ||= "enc-#{Process.pid}-#{object_id}-#{rand(1_000_000)}"
  end

  def dead_record(target_jid)
    raw = Wurk.redis { |c| c.call('ZRANGE', Wurk::Keys::DEAD, 0, -1) }
              .find { |m| JSON.parse(m)['jid'] == target_jid }
    raw && JSON.parse(raw)
  end

  def retry_count_for(target_jid)
    Wurk.redis { |c| c.call('ZRANGE', Wurk::Keys::RETRY, 0, -1) }
        .count { |m| JSON.parse(m)['jid'] == target_jid }
  end

  def drain_dead(target_jid)
    Wurk.redis do |c|
      mine = c.call('ZRANGE', Wurk::Keys::DEAD, 0, -1).select { |m| JSON.parse(m)['jid'] == target_jid }
      c.call('ZREM', Wurk::Keys::DEAD, *mine) unless mine.empty?
    end
  end

  # Records jobs.* statsd increments for the duration of the block. The
  # increment method is a process-global singleton; encryption_test runs in
  # its own fork with no parallel threads, but we still guard with the shared
  # mutex to match the rest of the suite's convention.
  def capture_statsd
    Wurk::Test::STATSD_MUTEX.synchronize do
      calls = []
      real = Wurk::Metrics::Statsd.method(:increment)
      Wurk::Metrics::Statsd.singleton_class.send(:define_method, :increment) do |metric, tags: nil, **_|
        calls << [metric, tags]
        nil
      end
      begin
        yield
        calls
      ensure
        Wurk::Metrics::Statsd.singleton_class.send(:define_method, :increment, real)
      end
    end
  end
end
