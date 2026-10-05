# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Topology proof (#550 R7): the paths a deployment exercises on every job —
# push, reliable fetch, ACK, scheduled promotion, Lua — run against a real TLS
# server, a real ACL user and a real Sentinel set, plus a Sentinel failover
# while a fetcher is parked in BLMOVE. Each class talks to a server the CI
# `topology` job (.github/workflows/topology.yml) brings up and skips without
# its env var, so the default suite never needs Docker. Locally, the same
# servers on host networking (Linux):
#
#   openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=wurk-test-ca -keyout ca.key -out ca.crt
#   openssl req -newkey rsa:2048 -nodes -subj /CN=localhost -keyout redis.key -out redis.csr
#   printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > san.ext
#   openssl x509 -req -in redis.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -extfile san.ext -out redis.crt
#   chmod 644 *.key
#   docker run -d --network host -v "$PWD:/tls:ro" redis:7.4 redis-server --port 0 --tls-port 16380 \
#     --tls-cert-file /tls/redis.crt --tls-key-file /tls/redis.key --tls-ca-cert-file /tls/ca.crt --tls-auth-clients no
#   docker run -d --network host redis:7.4 redis-server --port 16381 --user default off \
#     --user wurk on '>s3cret' '~*' '&*' '+@all' '-@dangerous' '+info'
#   docker run -d --network host redis:7.4 redis-server --port 16382
#   docker run -d --network host redis:7.4 redis-server --port 16383 --replicaof 127.0.0.1 16382
#   docker run -d --network host redis:7.4 sh -c 'printf "port 26382\nsentinel monitor wurkmaster 127.0.0.1 16382 1\n\
#     sentinel down-after-milliseconds wurkmaster 1000\nsentinel failover-timeout wurkmaster 5000\n" > /tmp/s.conf \
#     && exec redis-sentinel /tmp/s.conf'
#
#   WURK_TEST_TLS_URL=rediss://localhost:16380/0 WURK_TEST_TLS_CA_FILE=$PWD/ca.crt \
#   WURK_TEST_ACL_URL=redis://wurk:s3cret@localhost:16381/0 \
#   WURK_TEST_SENTINEL_HOSTS=127.0.0.1:26382 WURK_TEST_SENTINEL_MASTER=wurkmaster \
#   bin/rake test TEST=test/integration/redis_topology_test.rb
#
# These servers are shared and not flushed: every key a test writes is
# namespaced to it and deleted in teardown.
class RedisTopologyJob
  include Wurk::Job

  def perform(*); end
end

module RedisTopologyChecks
  def setup
    super
    @ns = "topo-#{Process.pid}-#{SecureRandom.hex(4)}"
    @queue = "#{@ns}-q"
    @schedule_set = "#{@ns}-schedule"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = topology_redis
    @config.fetch_poll_interval = 1
    @capsule = @config.default_capsule
    @capsule.queues = [@queue]
    @fetcher = Wurk::Fetcher::Reliable.new(@capsule)
    @capsule.fetcher = @fetcher
    @client = Wurk::Client.new(config: @config)
  end

  def teardown
    @fetcher&.terminate
    cleanup_topology_keys
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_push_fetch_and_ack
    jid = @client.push('class' => RedisTopologyJob, 'queue' => @queue, 'args' => [1, 'two'])
    uow = fetch_one

    assert_equal jid, JSON.parse(uow.job)['jid']
    assert_equal 1, llen(uow.private_queue), 'reliable fetch must park the job on the private list'

    uow.acknowledge
    @fetcher.flush_pending_acks

    assert_equal 0, llen(uow.private_queue), 'ACK must remove the job from the private list'
    assert_equal 0, llen("queue:#{@queue}")
  end

  def test_push_bulk_round_trips_every_job
    jids = @client.push_bulk('class' => RedisTopologyJob, 'queue' => @queue, 'args' => [[1], [2], [3]])
    fetched = Array.new(3) { fetch_one.tap(&:acknowledge) }
    @fetcher.flush_pending_acks

    assert_equal jids.sort, fetched.map { |uow| JSON.parse(uow.job)['jid'] }.sort
    assert_equal 0, llen(fetched.first.private_queue)
  end

  def test_default_scheduler_promotes_a_due_job
    jid = schedule_due_job
    Wurk::Scheduled::Enq.new(@config).enqueue_jobs([@schedule_set])

    assert_promoted jid
  end

  def test_reliable_scheduler_promotes_a_due_job_through_lua
    jid = schedule_due_job
    Wurk::Scheduled::ReliableEnq.new(@config).enqueue_jobs([@schedule_set])

    assert_promoted jid
  end

  def test_lua_script_recovers_from_a_cold_script_cache
    key = "#{@ns}-zset"
    @config.redis do |conn|
      conn.call('ZADD', key, '1', 'due')
      # A SHA no server has seen forces the NOSCRIPT → SCRIPT LOAD → EVALSHA
      # recovery the first call on a fresh server (or a failed-over replica,
      # whose script cache is empty) takes.
      assert_raises(RedisClient::CommandError) { conn.call('EVALSHA', '0' * 40, 0) }
      assert_equal 'due', Wurk::Lua::Loader.eval_cached(conn, :zpopbyscore, keys: [key], argv: ['2'])
      conn.call('DEL', key)
    end
  end

  private

  # The CI topology job sets WURK_TEST_TOPOLOGY_REQUIRED, so a server that
  # never came up fails the job instead of skipping it green.
  def topology_missing(message)
    ENV['WURK_TEST_TOPOLOGY_REQUIRED'] ? flunk(message) : skip(message)
  end

  def fetch_one(deadline: 10)
    stop = monotonic + deadline
    loop do
      uow = @fetcher.retrieve_work
      return uow if uow

      flunk "no job fetched from #{@queue} within #{deadline}s" if monotonic > stop
    end
  end

  def schedule_due_job
    jid = @client.push('class' => RedisTopologyJob, 'queue' => @queue, 'args' => [], 'at' => Time.now.to_f + 60)
    # Client#push_scheduled writes the global `schedule` set; move the member
    # into this test's own set, due now, so no other poller can take it.
    @config.redis do |conn|
      member = conn.call('ZRANGE', 'schedule', '0', '-1').find { |m| JSON.parse(m)['jid'] == jid }
      conn.call('ZREM', 'schedule', member)
      conn.call('ZADD', @schedule_set, (Time.now.to_f - 1).to_s, member)
    end
    jid
  end

  def assert_promoted(jid)
    assert_equal 0, @config.redis { |c| c.call('ZCARD', @schedule_set) }, 'due member must leave the sorted set'
    uow = fetch_one

    assert_equal jid, JSON.parse(uow.job)['jid']
    uow.acknowledge
    @fetcher.flush_pending_acks
  end

  def llen(key)
    @config.redis { |c| c.call('LLEN', key) }
  end

  def cleanup_topology_keys
    @config&.redis do |conn|
      privs = private_list_keys(conn)
      conn.call('DEL', "queue:#{@queue}", @schedule_set, *privs)
      conn.call('SREM', 'queues', @queue)
    end
  rescue StandardError
    nil
  end

  # Every private list of this test's queue, across the whole SCAN: a single
  # page can come back short (or empty) on a big keyspace.
  def private_list_keys(conn)
    keys = []
    cursor = '0'
    loop do
      cursor, page = conn.call('SCAN', cursor, 'MATCH', "queue:#{@queue}|*", 'COUNT', '1000')
      keys.concat(page)
      break if cursor == '0'
    end
    keys.uniq
  end

  def monotonic
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end

class RedisTopologyTlsTest < Wurk::Test::UnitCase
  include RedisTopologyChecks

  parallelize_me!

  def setup
    unless tls_env?
      topology_missing 'set WURK_TEST_TLS_URL (rediss://…) and WURK_TEST_TLS_CA_FILE to run the TLS topology tests'
    end
    super
  end

  def test_rejects_a_server_whose_certificate_the_ca_did_not_sign
    config = Wurk::Configuration.new
    config.redis = { url: ENV.fetch('WURK_TEST_TLS_URL'), reconnect_attempts: 0 }
    error = assert_raises(RedisClient::CannotConnectError) { config.redis { |c| c.call('PING') } }
    assert_match(/certificate verify failed/i, error.message)
  ensure
    config&.reset_redis_pools!
  end

  private

  def tls_env?
    ENV.fetch('WURK_TEST_TLS_URL', nil) && ENV.fetch('WURK_TEST_TLS_CA_FILE', nil)
  end

  def topology_redis
    { url: ENV.fetch('WURK_TEST_TLS_URL'), ssl_params: { ca_file: ENV.fetch('WURK_TEST_TLS_CA_FILE') } }
  end
end

class RedisTopologyAclTest < Wurk::Test::UnitCase
  include RedisTopologyChecks

  parallelize_me!

  def setup
    unless ENV['WURK_TEST_ACL_URL']
      topology_missing 'set WURK_TEST_ACL_URL (redis://user:pass@host:port/db) to run the ACL topology tests'
    end
    super
  end

  def test_authenticates_as_the_named_acl_user
    assert_equal(URI(ENV.fetch('WURK_TEST_ACL_URL')).user, @config.redis { |c| c.call('ACL', 'WHOAMI') })
  end

  private

  def topology_redis
    { url: ENV.fetch('WURK_TEST_ACL_URL') }
  end
end

class RedisTopologySentinelTest < Wurk::Test::UnitCase
  include RedisTopologyChecks

  parallelize_me!

  JOBS_PER_SIDE = 20
  FAILOVER_DEADLINE = 30

  def setup
    unless ENV['WURK_TEST_SENTINEL_HOSTS'] && ENV['WURK_TEST_SENTINEL_MASTER']
      topology_missing 'set WURK_TEST_SENTINEL_HOSTS (host:port,…) and WURK_TEST_SENTINEL_MASTER ' \
                       'to run the Sentinel topology tests'
    end
    super
  end

  # A fetcher parked in BLMOVE when Sentinel promotes the replica: Sentinel's
  # reconfiguration kills the old primary's client connections, so the blocked
  # call fails mid-wait and the pool has to redial whichever server Sentinel
  # now names. Every job pushed on either side of the failover must be fetched
  # exactly once, from the new primary, with nothing stranded on a private list.
  def test_failover_mid_blmove_loses_and_duplicates_nothing
    @config.fetch_poll_interval = 3
    fetched = Queue.new
    errors = Queue.new
    stop = false
    worker = Thread.new do
      until stop
        begin
          uow = @fetcher.retrieve_work
          next unless uow

          fetched << JSON.parse(uow.job)['jid']
          uow.acknowledge
        rescue StandardError => e
          errors << e
          sleep 0.1
        end
      end
    end

    before = push_jobs
    drained = collect(fetched, before.size)
    old_master = master_addr
    wait_until("fetcher blocked in BLMOVE on #{old_master.join(':')}") { blocked_clients(old_master).positive? }
    direct(old_master) { |c| c.call('WAIT', '1', '2000') }

    sentinel { |c| c.call('SENTINEL', 'FAILOVER', ENV.fetch('WURK_TEST_SENTINEL_MASTER')) }
    wait_until('Sentinel to name a new primary') { master_addr != old_master }
    new_master = master_addr
    wait_until("old primary #{old_master.join(':')} to step down") { role(old_master) == 'slave' }

    after = push_jobs
    drained.concat(collect(fetched, after.size))
    stop = true
    worker.join(10)
    @fetcher.flush_pending_acks

    fetch_port = @capsule.fetch_redis { |c| server_port(c) }
    main_port = @config.redis { |c| server_port(c) }
    stranded = direct(new_master) { |c| private_list_lengths(c).sum }

    assert_equal (before + after).sort, drained.sort,
                 "every job fetched exactly once (fetch errors: #{drain(errors).map(&:class).tally})"
    assert_equal new_master.last.to_s, fetch_port, 'fetch pool must follow the failover'
    assert_equal new_master.last.to_s, main_port, 'main pool must follow the failover'
    assert_equal 0, stranded, 'no job left on a private list'
  ensure
    stop = true
    worker&.join(10)
  end

  private

  def topology_redis
    # Sidekiq's spelling: `name:` is the master next to `sentinels:`.
    { url: "redis://#{ENV.fetch('WURK_TEST_SENTINEL_MASTER')}/#{ENV.fetch('WURK_TEST_SENTINEL_DB', '0')}",
      name: ENV.fetch('WURK_TEST_SENTINEL_MASTER'), sentinels: sentinel_hosts, role: :master }
  end

  def sentinel_hosts
    ENV.fetch('WURK_TEST_SENTINEL_HOSTS').split(',').map do |hp|
      host, port = hp.split(':')
      { host: host, port: Integer(port) }
    end
  end

  def push_jobs
    Array.new(JOBS_PER_SIDE) { |i| @client.push('class' => RedisTopologyJob, 'queue' => @queue, 'args' => [i]) }
  end

  def collect(fetched, count)
    stop = monotonic + FAILOVER_DEADLINE
    Array.new(count) do
      remaining = stop - monotonic
      jid = remaining.positive? ? fetched.pop(timeout: remaining) : nil
      flunk "fetched fewer than #{count} jobs within #{FAILOVER_DEADLINE}s" unless jid
      jid
    end
  end

  def master_addr
    host, port = sentinel do |c|
      c.call('SENTINEL', 'GET-MASTER-ADDR-BY-NAME', ENV.fetch('WURK_TEST_SENTINEL_MASTER'))
    end
    [host, Integer(port)]
  end

  def sentinel(&)
    hp = sentinel_hosts.first
    client = RedisClient.config(host: hp[:host], port: hp[:port]).new_client
    yield client
  ensure
    client&.close
  end

  def direct(addr)
    client = RedisClient.config(host: addr.first, port: addr.last, db: ENV.fetch('WURK_TEST_SENTINEL_DB', '0').to_i)
                        .new_client
    yield client
  ensure
    client&.close
  end

  def role(addr)
    direct(addr) { |c| c.call('ROLE').first }
  rescue RedisClient::Error
    nil
  end

  def blocked_clients(addr)
    direct(addr) { |c| c.call('INFO', 'clients')[/blocked_clients:(\d+)/, 1].to_i }
  end

  def server_port(conn)
    conn.call('INFO', 'server')[/tcp_port:(\d+)/, 1]
  end

  def private_list_lengths(conn)
    private_list_keys(conn).map { |k| conn.call('LLEN', k) }
  end

  def wait_until(what)
    stop = monotonic + FAILOVER_DEADLINE
    until yield
      flunk "timed out after #{FAILOVER_DEADLINE}s waiting for #{what}" if monotonic > stop
      sleep 0.1
    end
  end

  def drain(queue)
    Array.new(queue.size) { queue.pop }
  end
end
