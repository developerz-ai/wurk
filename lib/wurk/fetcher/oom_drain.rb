# frozen_string_literal: true

require_relative '../keys'
require_relative '../lua'

module Wurk
  class Fetcher
    # The way out of a full Redis.
    #
    # LMOVE and ZADD are `denyoom` commands, so at `maxmemory` under the
    # `noeviction` policy Wurk requires, every worker would be refused its next
    # job and could therefore never free the memory that is refusing it. A
    # Redis 7 script flagged `allow-oom` runs those commands anyway, and moving a
    # job between two lists grows nothing but a small key.
    #
    # Deliberately not under lib/wurk/lua/: everything there is uploaded at boot,
    # and Dragonfly refuses to compile a `#!lua` shebang, so one script in that
    # directory would crash every child at boot. The same refusal is why these
    # go by EVAL and not EVALSHA: a path taken only while Redis is full has no
    # use for a NOSCRIPT recovery arm. A server that refuses the script raises
    # the original OOM, which is exactly the behaviour without this class.
    module OomDrain
      HEADER = "#!lua flags=allow-oom\n"

      # Heartbeat::TTL_SECONDS. Spelled out because the fetcher loads without the
      # heartbeat, which pulls in the Processor.
      HEARTBEAT_TTL = 60

      # Claiming proves this process alive, and it has to say so itself: the
      # heartbeat's own HSET is refused too. The hash then lapses (a booting
      # process never gets one), other hosts' reapers drain the jobs it is
      # running, and the swarm's liveness check sees its beat stand still.
      #
      # KEYS = [processes, identity, public, private, public, private, ...]
      # ARGV = [info_json, beat, ttl_seconds]
      # Returns {n, payload} for the n-th queue, nil when all were empty.
      CLAIM = <<~LUA.freeze
        #{HEADER}if redis.call('EXISTS', KEYS[2]) == 0 then
          redis.call('HSET', KEYS[2], 'info', ARGV[1])
          redis.call('SADD', KEYS[1], KEYS[2])
        end
        redis.call('HSET', KEYS[2], 'beat', ARGV[2])
        redis.call('EXPIRE', KEYS[2], ARGV[3])
        for i = 3, #KEYS, 2 do
          local job = redis.call('LMOVE', KEYS[i], KEYS[i + 1], 'RIGHT', 'LEFT')
          if job then
            return { (i - 1) / 2, job }
          end
        end
        return nil
      LUA

      REQUEUE = (HEADER + Lua::RELIABLE_REQUEUE).freeze

      # KEYS = [lock], ARGV = [ttl_ms]. The reaper's sweep lock: refused, no sweep
      # would ever run past maxmemory. Same reply as the SET it stands in for.
      LOCK = <<~LUA.freeze
        #{HEADER}return redis.call('SET', KEYS[1], '1', 'NX', 'PX', ARGV[1])
      LUA

      # KEYS = [sorted_set], ARGV = [score, member]
      ZADD = <<~LUA.freeze
        #{HEADER}return redis.call('ZADD', KEYS[1], ARGV[1], ARGV[2])
      LUA

      module_function

      # `error` is the OOM that sent the caller here, raised again if the server
      # cannot run the script. Returns [queue_index, payload] or nil.
      def claim(conn, error, keys:, info:, beat:)
        run(conn, error, CLAIM, [Keys::PROCESSES, Component.identity, *keys], [info, beat, HEARTBEAT_TTL])
      end

      # Returns 1 when moved, 0 when the job has left the private list since.
      def requeue(conn, error, private_list, public_q, job)
        run(conn, error, REQUEUE, [private_list, public_q], [job])
      end

      def lock(conn, error, key, ttl_ms)
        run(conn, error, LOCK, [key], [ttl_ms])
      end

      def zadd(conn, error, key, score, member)
        run(conn, error, ZADD, [key], [score, member])
      end

      def run(conn, error, script, keys, argv)
        conn.call('EVAL', script, keys.size, *keys, *argv)
      rescue RedisClient::ConnectionError
        raise
      rescue RedisClient::CommandError
        raise error
      end
      private_class_method :run
    end
  end
end
