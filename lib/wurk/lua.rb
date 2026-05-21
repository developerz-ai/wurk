# frozen_string_literal: true

require 'digest'

module Wurk
  # EVALSHA-cached Lua scripts. Loaded once per pool, never re-uploaded.
  # Bulk enqueue, multi-pop, atomic schedule promotion, batch ops.
  #
  # Source strings are intentionally bare — the SHA1 of each is computed
  # at load time and is the same value Redis reports from `SCRIPT LOAD`.
  # Whitespace edits change the SHA, which forces a re-upload at runtime.
  #
  # `:zpopbyscore` is reproduced verbatim from sidekiq-free.md §1.8 and
  # MUST NOT diverge — parity tests will fail on a single byte change.
  module Lua
    ZPOPBYSCORE = <<~LUA
      local key, now = KEYS[1], ARGV[1]
      local jobs = redis.call("zrange", key, "-inf", now, "byscore", "limit", 0, 1)
      if jobs[1] then
        redis.call("zrem", key, jobs[1])
        return jobs[1]
      end
    LUA

    # Bulk enqueue to a single queue.
    # KEYS = [queue_list, queues_set]
    # ARGV = [queue_name, job_json, ...]
    # Returns the number of jobs pushed.
    BULK_PUSH = <<~LUA
      redis.call("sadd", KEYS[2], ARGV[1])
      for i = 2, #ARGV do
        redis.call("lpush", KEYS[1], ARGV[i])
      end
      return #ARGV - 1
    LUA

    # Pro reliable scheduler: atomically promote all due jobs in a sorted
    # set to their target queues. Pure-Ruby promotion does ZRANGE → ZREM →
    # LPUSH non-atomically and can lose jobs on a mid-step crash.
    # KEYS = [sorted_set, queues_set]
    # ARGV = [now, queue_prefix]
    # Returns the number of jobs promoted.
    # Order matters: decode + push BEFORE zrem. Redis Lua has no rollback,
    # so a failed cjson.decode after a zrem would lose the job. Decode first;
    # push first; only then remove from the sorted set. Worst case is a
    # crash between lpush and zrem → at-least-once redelivery, never loss.
    RELIABLE_SCHEDULE_PROMOTE = <<~LUA
      local jobs = redis.call("zrangebyscore", KEYS[1], "-inf", ARGV[1])
      for i = 1, #jobs do
        local job = jobs[i]
        local q = cjson.decode(job)["queue"]
        redis.call("sadd", KEYS[2], q)
        redis.call("lpush", ARGV[2] .. q, job)
        redis.call("zrem", KEYS[1], job)
      end
      return #jobs
    LUA

    # Pro Batch: register a job into a batch and push it to its queue
    # atomically. Keeps total/pending in sync with the jids set.
    # KEYS = [b-<bid>, b-<bid>-jids, queue_list, queues_set]
    # ARGV = [queue_name, jid, job_json]
    # Returns 1.
    BATCH_PUSH = <<~LUA
      redis.call("hincrby", KEYS[1], "total", 1)
      redis.call("hincrby", KEYS[1], "pending", 1)
      redis.call("sadd", KEYS[2], ARGV[2])
      redis.call("sadd", KEYS[4], ARGV[1])
      redis.call("lpush", KEYS[3], ARGV[3])
      return 1
    LUA

    # Pro Batch: mark one job complete. Decrements pending iff the jid
    # was actually a member of the batch (prevents double-decrement on
    # retries that already succeeded).
    # KEYS = [b-<bid>, b-<bid>-jids]
    # ARGV = [jid]
    # Returns new pending count, or -1 if the jid was not in the batch.
    BATCH_COMPLETE = <<~LUA
      local removed = redis.call("srem", KEYS[2], ARGV[1])
      if removed == 1 then
        return redis.call("hincrby", KEYS[1], "pending", -1)
      end
      return -1
    LUA

    # Pro Batch: invalidate all pending jobs. The jobs themselves stay
    # in their queues — the server middleware short-circuits when it sees
    # the invalidated flag — but the jids set is cleared so the batch can
    # no longer accept completion callbacks.
    # KEYS = [b-<bid>, b-<bid>-jids]
    # ARGV = []
    # Returns 1.
    BATCH_INVALIDATE = <<~LUA
      redis.call("del", KEYS[2])
      redis.call("hset", KEYS[1], "invalidated", "1")
      return 1
    LUA

    SCRIPTS = {
      zpopbyscore: ZPOPBYSCORE,
      bulk_push: BULK_PUSH,
      reliable_schedule_promote: RELIABLE_SCHEDULE_PROMOTE,
      batch_push: BATCH_PUSH,
      batch_complete: BATCH_COMPLETE,
      batch_invalidate: BATCH_INVALIDATE
    }.freeze

    # SHA1 of each script source — matches what `SCRIPT LOAD` returns.
    # Precomputing keeps `eval_cached` allocation-free in the hot path.
    SHAS = SCRIPTS.transform_values { |src| Digest::SHA1.hexdigest(src) }.freeze
  end
end

require_relative 'lua/loader'
