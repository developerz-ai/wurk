# frozen_string_literal: true

require 'socket'
require 'json'

module Wurk
  # Thin HTTP listener for k8s liveness/readiness probes. Optional, off by
  # default — opt in with `config.health_check(port: 7433)`.
  #
  # Endpoints:
  #   * GET /live  → 200 while the Launcher is running (not in quiet/stop).
  #   * GET /ready → 200 only when Redis is reachable AND the heartbeat has
  #                  fired within `ready_window` seconds. 503 otherwise.
  # Anything else returns 404 JSON.
  #
  # The server uses a raw TCPServer and one accept thread. No Rack, no
  # dependencies — it lives inside every worker process where Rails may or
  # may not exist (standalone CLI, Embedded, swarm child). Bound to a
  # dedicated port so it does not collide with the host application's HTTP.
  #
  # Spec: docs/target/sidekiq-ent.md §7.1.2 (`config.health_check`).
  module Health
    DEFAULT_PORT          = 7433
    DEFAULT_BIND          = '0.0.0.0'
    DEFAULT_READY_WINDOW  = 30

    # The HTTP listener. Owns one TCPServer + one accept thread. Idempotent
    # start/stop; safe to call from Launcher#run / Launcher#stop.
    class Server
      ACCEPT_TIMEOUT = 0.2
      # How often a non-owner child re-attempts the shared port. Short enough
      # that probes come back quickly after the owner dies, long enough not to
      # spin. See #start_retry_loop.
      RETRY_INTERVAL = 5

      attr_reader :port, :bind

      def initialize(launcher, port: DEFAULT_PORT, bind: DEFAULT_BIND,
                     ready_window: DEFAULT_READY_WINDOW, retry_interval: RETRY_INTERVAL)
        @launcher       = launcher
        @config         = launcher.instance_variable_get(:@config)
        @port           = port
        @bind           = bind
        @ready_window   = ready_window
        @retry_interval = retry_interval
        @server         = nil
        @thread         = nil
        @retry_thread   = nil
        @done           = false
      end

      def start
        # Idempotent (see class doc): a second start on a live instance would
        # re-bind the same port, hit EADDRINUSE, and null out @server/@thread —
        # leaking the original listener so stop could never close it.
        return self if running? || retrying?

        @done = false
        bind_and_serve || start_retry_loop
        self
      end

      def stop
        @done = true
        stop_retry_loop
        srv = @server
        @server = nil
        srv&.close
        @thread&.join(2)
        @thread = nil
      end

      def running?
        @thread&.alive? == true
      end

      # True while a non-owner child is still polling to take the shared port
      # over (see #start_retry_loop). Distinct from #running?, which reports the
      # accept thread specifically.
      def retrying?
        @retry_thread&.alive? == true
      end

      private

      # One bind attempt. On success spins the accept thread and returns true.
      # On EADDRINUSE — a sibling swarm child already owns the shared port —
      # returns false so the caller schedules a retry.
      def bind_and_serve
        @server = ::TCPServer.new(@bind, @port)
        # Capture the OS-assigned port when caller passed 0 (test pattern,
        # also lets the kernel pick a free port at boot).
        @port = @server.addr[1]
        @thread = ::Thread.new { run }
        @thread.name = 'wurk-health'
        true
      rescue ::Errno::EADDRINUSE
        @server = nil
        @thread = nil
        false
      end

      # Non-owner children poll the shared port instead of giving up. A single
      # bind-at-boot went dark to k8s the moment the owning child died —
      # nothing rebound until the pod restarted. Now a survivor takes the port
      # over within RETRY_INTERVAL of the owner's exit, so liveness/readiness
      # ride out ordinary child churn (crash-respawn, rolling restart, recycle).
      def start_retry_loop
        logger&.warn do
          "Wurk::Health: port #{@port} in use; polling every #{@retry_interval}s to take it over"
        end
        @retry_thread = ::Thread.new do
          ::Thread.current.name = 'wurk-health-retry'
          ::Thread.current.report_on_exception = false
          sleep @retry_interval until @done || bind_and_serve
        end
      end

      def stop_retry_loop
        thread = @retry_thread
        @retry_thread = nil
        return unless thread

        thread.wakeup if thread.alive?
        thread.join(@retry_interval + 1)
      rescue ThreadError
        nil
      end

      def run
        until @done
          next unless @server.wait_readable(ACCEPT_TIMEOUT)

          begin
            client, _addr = @server.accept_nonblock(exception: false)
            handle(client) if client
          rescue ::IO::WaitReadable
            next
          rescue ::StandardError => e
            logger&.error { "Wurk::Health accept: #{e.class}: #{e.message}" }
            next
          end
        end
      rescue ::IOError, ::Errno::EBADF
        # Server was closed during shutdown — expected.
      end

      def handle(client) # rubocop:disable Metrics/AbcSize
        return unless client.wait_readable(1.0)

        request_line = client.gets("\r\n")
        return if request_line.nil?

        method, path, = request_line.strip.split(' ', 3)
        # Drain remaining headers; ignore the body (probes don't send one).
        # Wait for readability before each gets so a stalled client can't
        # block the single accept thread mid-headers.
        loop do
          break unless client.wait_readable(1.0)

          line = client.gets("\r\n")
          break if line.nil? || line == "\r\n"
        end

        body, status = response_for(method, path)
        write_response(client, status, body)
      rescue ::StandardError => e
        logger&.error { "Wurk::Health request: #{e.class}: #{e.message}" }
      ensure
        client&.close
      end

      def response_for(method, path)
        return [json('error', message: 'method not allowed'), 405] unless method == 'GET'

        case path
        when '/live'  then live_response
        when '/ready' then ready_response
        else [json('error', message: 'not found', path: path), 404]
        end
      end

      def live_response
        if @launcher.stopping?
          [json('down', check: 'live', reason: 'stopping'), 503]
        else
          [json('ok', check: 'live'), 200]
        end
      end

      def ready_response
        redis_ok = ping_redis
        beat_fresh = heartbeat_fresh?

        if redis_ok && beat_fresh
          [json('ok', check: 'ready'), 200]
        else
          reason = redis_ok ? 'heartbeat stale' : 'redis unreachable'
          [json('down', check: 'ready', reason: reason), 503]
        end
      end

      def ping_redis
        @config.redis { |conn| conn.call('PING') } == 'PONG'
      rescue ::StandardError
        false
      end

      def heartbeat_fresh?
        hb = @launcher.instance_variable_get(:@heartbeat)
        return false unless hb.respond_to?(:last_beat_at)

        last = hb.last_beat_at
        return false if last.nil?

        (::Time.now.to_f - last) < @ready_window
      end

      def json(status, **extra)
        ::JSON.generate({ status: status }.merge(extra))
      end

      def write_response(client, status, body)
        reason = case status
                 when 200 then 'OK'
                 when 404 then 'Not Found'
                 when 405 then 'Method Not Allowed'
                 when 503 then 'Service Unavailable'
                 else 'Status'
                 end

        client.write(
          "HTTP/1.1 #{status} #{reason}\r\n" \
          "Content-Type: application/json\r\n" \
          "Content-Length: #{body.bytesize}\r\n" \
          "Connection: close\r\n\r\n" \
          "#{body}"
        )
      end

      def logger
        @config&.logger
      end
    end
  end
end
