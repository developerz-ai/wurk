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

      attr_reader :port, :bind

      def initialize(launcher, port: DEFAULT_PORT, bind: DEFAULT_BIND, ready_window: DEFAULT_READY_WINDOW)
        @launcher     = launcher
        @config       = launcher.instance_variable_get(:@config)
        @port         = port
        @bind         = bind
        @ready_window = ready_window
        @server       = nil
        @thread       = nil
        @done         = false
      end

      def start
        @server = ::TCPServer.new(@bind, @port)
        # Capture the OS-assigned port when caller passed 0 (test pattern,
        # also lets the kernel pick a free port at boot).
        @port = @server.addr[1]
        @done = false
        @thread = ::Thread.new { run }
        @thread.name = 'wurk-health'
        self
      rescue ::Errno::EADDRINUSE => e
        # Swarm children all try to bind the same port — only the first wins.
        # Don't crash the worker; just log and skip.
        logger&.warn { "Wurk::Health: port #{@port} in use; health server NOT started (#{e.message})" }
        @server = nil
        @thread = nil
        self
      end

      def stop
        @done = true
        srv = @server
        @server = nil
        srv&.close
        @thread&.join(2)
        @thread = nil
      end

      def running?
        @thread&.alive? == true
      end

      private

      def run
        until @done
          ready = ::IO.select([@server], nil, nil, ACCEPT_TIMEOUT)
          next unless ready

          begin
            client, _addr = @server.accept_nonblock(exception: false)
            handle(client) if client
          rescue ::IO::WaitReadable
            next
          end
        end
      rescue ::IOError, ::Errno::EBADF
        # Server was closed during shutdown — expected.
      rescue ::StandardError => e
        logger&.error { "Wurk::Health accept loop: #{e.class}: #{e.message}" }
      end

      def handle(client)
        request_line = client.gets("\r\n")
        return if request_line.nil?

        method, path, = request_line.strip.split(' ', 3)
        # Drain remaining headers; ignore the body (probes don't send one).
        while (line = client.gets("\r\n")) && line != "\r\n"
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
          reason = !redis_ok ? 'redis unreachable' : 'heartbeat stale'
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
        return false unless hb&.respond_to?(:last_beat_at)

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
