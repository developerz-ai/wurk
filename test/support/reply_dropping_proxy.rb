# frozen_string_literal: true

require 'socket'
require 'uri'

module Wurk
  module Test
    # A TCP relay in front of real Redis that loses replies on demand: a client
    # chunk matching an armed pattern reaches the server and is applied, then the
    # connection drops without the reply ever coming back. That is what a Redis
    # restart, a stall past the read timeout or a reset socket does to a client,
    # confined to one test's own connections.
    class ReplyDroppingProxy
      def initialize(upstream_url)
        uri = URI.parse(upstream_url)
        @upstream = [uri.host, uri.port]
        @db = uri.path.delete_prefix('/')
        @server = TCPServer.new('127.0.0.1', 0)
        @lock = ::Mutex.new
        @armed = []
        @dropped = 0
        @threads = [Thread.new { accept_loop }]
      end

      def url
        "redis://127.0.0.1:#{@server.addr(false)[1]}/#{@db}"
      end

      # Lose the reply to the next `times` chunks matching `pattern`.
      def drop_reply_to(pattern, times: 1)
        @lock.synchronize { @armed << [pattern, times] }
      end

      def dropped
        @lock.synchronize { @dropped }
      end

      def stop!
        @threads.each(&:kill)
        @server.close
      rescue IOError
        nil
      end

      private

      def accept_loop
        loop do
          client = @server.accept
          @lock.synchronize { @threads << Thread.new { relay(client) } }
        end
      end

      def relay(client)
        upstream = TCPSocket.new(*@upstream)
        replies = Thread.new { pump(upstream, client) }
        while (chunk = client.readpartial(65_536))
          if consume_rule?(chunk)
            replies.kill
            replies.join
            upstream.write(chunk)
            confirm_applied(upstream)
            return
          end
          upstream.write(chunk)
        end
      rescue IOError, SystemCallError
        nil
      ensure
        replies&.kill
        [client, upstream].compact.each { |socket| close_quietly(socket) }
      end

      # The server has applied the chunk once it has answered: read the reply and
      # throw it away.
      def confirm_applied(upstream)
        upstream.wait_readable(2) && upstream.readpartial(65_536)
      end

      def pump(source, sink)
        while (bytes = source.readpartial(65_536))
          sink.write(bytes)
        end
      rescue IOError, SystemCallError
        nil
      end

      def consume_rule?(chunk)
        @lock.synchronize do
          rule = @armed.find { |pattern, times| times.positive? && chunk.match?(pattern) }
          next false unless rule

          rule[1] -= 1
          @dropped += 1
          true
        end
      end

      def close_quietly(socket)
        socket.close
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
