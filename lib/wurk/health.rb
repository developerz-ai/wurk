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
  # The server uses a raw TCPServer, one accept thread and a short-lived
  # thread per connection (bounded, deadline-capped). No Rack, no
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
      # Overall budget for one request head. A kubelet probe sends its head in
      # one segment; anything slower is broken or hostile.
      REQUEST_TIMEOUT   = 1.0
      MAX_REQUEST_BYTES = 8192
      MAX_CONNECTIONS   = 16
      REASONS = { 200 => 'OK', 404 => 'Not Found', 405 => 'Method Not Allowed',
                  503 => 'Service Unavailable' }.freeze

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
        @slots          = ::Mutex.new
        @connections    = 0
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
            dispatch(client) if client
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

      # Each connection gets its own short-lived thread so a client that
      # dribbles bytes (slowloris) cannot hold the accept loop — and with it
      # every kubelet probe — hostage. Past MAX_CONNECTIONS the socket is
      # closed unanswered rather than queued: a probe that loses that race
      # retries, an attacker gains nothing.
      def dispatch(client)
        return client.close unless claim_slot

        spawn_handler(client)
      rescue ::ThreadError
        release_slot
        client.close
      end

      def spawn_handler(client)
        ::Thread.new(client) do |sock|
          ::Thread.current.name = 'wurk-health-conn'
          ::Thread.current.report_on_exception = false
          handle(sock)
        ensure
          release_slot
        end
      end

      def claim_slot
        @slots.synchronize do
          return false if @connections >= MAX_CONNECTIONS

          @connections += 1
          true
        end
      end

      def release_slot
        @slots.synchronize { @connections -= 1 }
      end

      def handle(client)
        request_line = read_request_line(client)
        return if request_line.nil?

        method, path, = request_line.strip.split(' ', 3)
        body, status = response_for(method, path)
        write_response(client, status, body)
      rescue ::StandardError => e
        logger&.error { "Wurk::Health request: #{e.class}: #{e.message}" }
      ensure
        client&.close
      end

      # Reads the head under one overall deadline and a MAX_REQUEST_BYTES cap.
      # Headers are read only to drain them (closing a socket with unread bytes
      # makes the kernel answer RST, which can eat the response); the answer
      # depends on the request line alone, so a client that sends that line
      # and then stalls is still answered when the deadline expires.
      def read_request_line(client)
        buffer = +''
        deadline = monotonic + REQUEST_TIMEOUT
        until buffer.include?("\r\n\r\n") || buffer.bytesize >= MAX_REQUEST_BYTES
          chunk = read_chunk(client, MAX_REQUEST_BYTES - buffer.bytesize, deadline)
          break unless chunk

          buffer << chunk
        end
        buffer[/\A[^\r\n]*(?=\r\n)/]
      end

      # nil once the deadline passes or the peer closes.
      def read_chunk(client, max_bytes, deadline)
        remaining = deadline - monotonic
        return unless remaining.positive? && client.wait_readable(remaining)

        chunk = client.read_nonblock(max_bytes, exception: false)
        chunk == :wait_readable ? '' : chunk
      end

      def monotonic
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
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
        reason = REASONS.fetch(status, 'Status')
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
