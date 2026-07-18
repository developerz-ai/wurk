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
  module Lua # rubocop:disable Metrics/ModuleLength
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
    #
    # Each promoted payload is restamped with a fresh `enqueued_at` (ARGV[3],
    # epoch ms): that field marks arrival on an *immediate* queue, so a job
    # leaving `schedule`/`retry` must get a new one at promotion rather than
    # keep its stale scheduled-origin value (or none). This matches the default
    # Ruby scheduler, whose push path restamps `enqueued_at` too
    # (Client#push_plain / #push_batched) — so both schedulers emit
    # wire-identical promoted payloads (spec §7.1).
    #
    # The restamp is a surgical string patch, NOT a cjson.decode -> cjson.encode
    # round-trip: cjson maps every JSON number to a Lua double, so re-encoding
    # would silently corrupt integer args past 2^53 (snowflake IDs, 64-bit
    # counters) and reformat 15+ digit numbers into scientific notation --
    # breaking wire-compat AND diverging from the loss-free Ruby scheduler,
    # whose Ruby-side JSON keeps big integers exact. So the stored member is
    # preserved byte-for-byte and only its top-level `enqueued_at` is rewritten:
    # replaced in place when present (retry members keep theirs), inserted after
    # the opening brace when absent (schedule members are stored stripped of it,
    # via Client#push_scheduled). cjson.decode is still called -- but only to
    # read the `queue` string and test for a top-level `enqueued_at`, never to
    # re-serialize, so a lossy decode never reaches the payload. (Residual: a
    # retry member whose user args embed a numeric key literally named
    # `enqueued_at` ahead of the top-level one patches the arg instead --
    # vanishingly rare, and still strictly safer than round-tripping every arg.)
    # KEYS = [sorted_set, queues_set]
    # ARGV = [now, queue_prefix, now_ms]
    # Returns the number of jobs promoted.
    # Order matters: decode + push BEFORE zrem. Redis Lua has no rollback,
    # so a failed cjson.decode after a zrem would lose the job. Decode first;
    # push first; only then remove from the sorted set — and zrem the ORIGINAL
    # member, not the restamped copy. Worst case is a crash between lpush and
    # zrem → at-least-once redelivery, never loss.
    # ARGV[4] caps members per call: Lua is atomic and single-threaded in
    # Redis, so an unbatched promote of a post-outage backlog (100k+ due
    # members) would block every client for the whole sweep. The Ruby caller
    # loops until a short batch comes back.
    RELIABLE_SCHEDULE_PROMOTE = <<~LUA
      local jobs = redis.call("zrangebyscore", KEYS[1], "-inf", ARGV[1], "LIMIT", 0, tonumber(ARGV[4]))
      for i = 1, #jobs do
        local job = jobs[i]
        local decoded = cjson.decode(job)
        local q = decoded["queue"]
        local stamped
        if decoded["enqueued_at"] == nil then
          stamped = string.gsub(job, "^{", '{"enqueued_at":' .. ARGV[3] .. ",", 1)
        else
          stamped = string.gsub(job, '"enqueued_at":%-?%d[%d.eE+-]*', '"enqueued_at":' .. ARGV[3], 1)
        end
        redis.call("sadd", KEYS[2], q)
        redis.call("lpush", ARGV[2] .. q, stamped)
        redis.call("zrem", KEYS[1], job)
      end
      return #jobs
    LUA

    # Reliable fetch (Pro super_fetch §3) shutdown requeue: atomically move
    # one in-flight job from a per-process private list back to its public
    # queue. The LREM guard is the whole point — RPUSH runs only when the job
    # was still in the private list (LREM removed exactly 1). A job the
    # Processor ACKed in the window between hard_shutdown's cross-thread `job`
    # read and this move (LREM removes 0) is NOT re-pushed, so the job lands in
    # exactly one place and can't double-execute. RPUSH (public tail) not LPUSH
    # so the reclaimed job is fetched next — LMOVE pops the tail — ahead of
    # fresh LPUSH'd enqueues.
    # KEYS = [private_list, public_queue]
    # ARGV = [job_json]
    # Returns 1 when the job was moved, 0 when it was already acked.
    RELIABLE_REQUEUE = <<~LUA
      if redis.call("lrem", KEYS[1], 1, ARGV[1]) == 1 then
        redis.call("rpush", KEYS[2], ARGV[1])
        return 1
      end
      return 0
    LUA

    # Pro Batch: register a job into a batch and push it to its queue
    # atomically. Keeps total/pending in sync with the jids set.
    #
    # SADD into the live jids set is the registration guard: total/pending
    # increment only when the jid is genuinely new (SADD == 1). A jid already
    # live is a re-push — a retry or scheduled promotion re-enqueueing a job
    # that never left the batch — so it re-LPUSHes the payload but must NOT
    # recount, or pending inflates past the acks and `:success` never fires
    # (spec §2.3/§2.5: total = distinct jobs added, pending = not-yet-succeeded).
    #
    # A jid found in `b-<bid>-died` is a manual retry of a dead job (morgue
    # "retry" / "add to queue") — it rejoins the live set without recounting:
    # total and pending already include it, because a death never decrements
    # pending. When that drains the died set the batch is no longer dead, so
    # the durable `death` success-suppression flag clears and the bid leaves
    # `dead-batches` — a later full drain can then fire `:success` (spec §2.4:
    # success after the dead job is manually retried to success). The
    # `b-<bid>-death` notify dedup key is untouched, so `:death` cannot
    # re-fire.
    # KEYS = [b-<bid>, b-<bid>-jids, queue_list, queues_set, b-<bid>-died, dead-batches]
    # ARGV = [queue_name, jid, job_json, bid]
    # Returns 1.
    BATCH_PUSH = <<~LUA
      if redis.call("srem", KEYS[5], ARGV[2]) == 1 then
        redis.call("sadd", KEYS[2], ARGV[2])
        if redis.call("scard", KEYS[5]) == 0 then
          redis.call("hdel", KEYS[1], "death")
          redis.call("zrem", KEYS[6], ARGV[4])
        end
      else
        if redis.call("sadd", KEYS[2], ARGV[2]) == 1 then
          redis.call("hincrby", KEYS[1], "total", 1)
          redis.call("hincrby", KEYS[1], "pending", 1)
        end
      end
      redis.call("sadd", KEYS[4], ARGV[1])
      redis.call("lpush", KEYS[3], ARGV[3])
      return 1
    LUA

    # Pro Batch: register a scheduled (`at`) job into a batch AND ZADD it onto
    # the `schedule` set, atomically. This is the deferred sibling of BATCH_PUSH:
    # same SADD-guarded total/pending counting, but the enqueue action is a ZADD
    # (schedule for later) instead of an LPUSH (queue now). A `perform_in` inside
    # `batch.jobs` must move `total`/`pending` at *creation* — otherwise the
    # empty-marker check (batch.rb) sees no counter movement and fires
    # `:complete`/`:success` while real jobs still sit in `schedule`.
    #
    # No died / dead-batches handling (unlike BATCH_PUSH): a job scheduled at
    # creation time is always new to the batch. When the scheduler later promotes
    # it, the re-push routes through BATCH_PUSH, whose guard finds the jid already
    # live (SADD == 0) → pure LPUSH, no recount. So registration happens exactly
    # once, here, at enqueue.
    # KEYS = [schedule, b-<bid>, b-<bid>-jids]
    # ARGV = [at_score, job_json, jid]
    # Returns 1.
    BATCH_SCHEDULE = <<~LUA
      if redis.call("sadd", KEYS[3], ARGV[3]) == 1 then
        redis.call("hincrby", KEYS[2], "total", 1)
        redis.call("hincrby", KEYS[2], "pending", 1)
      end
      redis.call("zadd", KEYS[1], ARGV[1], ARGV[2])
      return 1
    LUA

    # Pro Batch: ACK a job that completed successfully. SREM from the live
    # jids set and decrement pending iff the jid was a member (idempotent
    # against double-success on a flaky retry). A success also clears any
    # outstanding "currently failing" record for the jid (a retry that finally
    # passed), decrementing `failures` so it converges to the count of jobs
    # *still* failing — Sidekiq Pro semantics, spec §2.5. The failed-set clear
    # runs *before* the live-jids check so an invalidated batch (BATCH_INVALIDATE
    # deletes the jids set) still converges failures to 0 on its short-circuited
    # success ack, instead of stranding the jid in failed forever.
    # KEYS = [b-<bid>, b-<bid>-jids, b-<bid>-failed]
    # ARGV = [jid]
    # Returns [new_pending, live_jids_remaining], or [-1, -1] when the jid
    # was not a member (treat as already acked).
    BATCH_ACK_SUCCESS = <<~LUA
      if redis.call("srem", KEYS[3], ARGV[1]) == 1 then
        redis.call("hincrby", KEYS[1], "failures", -1)
      end
      local removed = redis.call("srem", KEYS[2], ARGV[1])
      if removed == 1 then
        local pending = redis.call("hincrby", KEYS[1], "pending", -1)
        return { pending, redis.call("scard", KEYS[2]) }
      end
      return { -1, -1 }
    LUA

    # Pro Batch: record a job that failed and will retry (transient failure).
    # SADDs the jid to the `failed` set and bumps `failures` only on the first
    # add, so `failures` == SCARD(b-<bid>-failed) == the number of jobs
    # currently in a failing/retrying state. Re-failures of the same jid are
    # idempotent. Cleared by BATCH_ACK_SUCCESS (retry passed) or
    # BATCH_ACK_COMPLETE (job died). Spec §2.5, §2.8.
    # KEYS = [b-<bid>, b-<bid>-failed]
    # ARGV = [jid]
    # Returns 1.
    BATCH_ACK_FAILED = <<~LUA
      if redis.call("sadd", KEYS[2], ARGV[1]) == 1 then
        redis.call("hincrby", KEYS[1], "failures", 1)
      end
      return 1
    LUA

    # Pro Batch: ACK a job that exhausted retries and died. Moves the jid from
    # "currently failing" to "died": SREMs from the failed set (decrementing
    # `failures` if it was recorded as failing), SADDs to died, and SREMs from
    # live jids so the batch can fire `:complete` even with terminally failed
    # jobs. `b-<bid>-failed` holds only currently-retrying jids; `b-<bid>-died`
    # holds terminally-dead ones (spec §2.8 — the two sets are distinct).
    # KEYS = [b-<bid>, b-<bid>-jids, b-<bid>-died, b-<bid>-failed]
    # ARGV = [jid]
    # Returns [live_jids_remaining, died_count, first_death]. `first_death`
    # is 1 the first time *any* jid is SADDed into the died set, 0 thereafter
    # — caller uses it to fire `:death` exactly once per batch.
    BATCH_ACK_COMPLETE = <<~LUA
      local was_pre_existing_death = redis.call("scard", KEYS[3])
      redis.call("srem", KEYS[2], ARGV[1])
      if redis.call("srem", KEYS[4], ARGV[1]) == 1 then
        redis.call("hincrby", KEYS[1], "failures", -1)
      end
      local died_added = redis.call("sadd", KEYS[3], ARGV[1])
      local first_death = 0
      if was_pre_existing_death == 0 and died_added == 1 then
        first_death = 1
      end
      return { redis.call("scard", KEYS[2]), redis.call("scard", KEYS[3]), first_death }
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

    # Pro Batch (§2.4): atomically append one callback triple to the
    # `callbacks` JSON array on the batch hash. Server-side append (vs a
    # Ruby read-modify-write) so two processes registering callbacks on the
    # same reopened batch cannot lose each other's writes. Refuses to write
    # when the batch hash is gone — resurrecting a bare hash would create a
    # batch that can never fire anything.
    # KEYS = [b-<bid>]
    # ARGV = [callback triple JSON, event name]
    # Returns -1 when the batch hash does not exist; otherwise the event's
    # fired flag ("1", or nil when it has not fired yet).
    BATCH_APPEND_CALLBACK = <<~LUA
      if redis.call("exists", KEYS[1]) == 0 then
        return -1
      end
      local raw = redis.call("hget", KEYS[1], "callbacks")
      local list
      if raw and raw ~= "" then
        list = cjson.decode(raw)
      else
        list = {}
      end
      list[#list + 1] = cjson.decode(ARGV[1])
      redis.call("hset", KEYS[1], "callbacks", cjson.encode(list))
      return redis.call("hget", KEYS[1], ARGV[2])
    LUA

    # Ent Unique (§3): atomic compare-and-delete of a lock key. Replaces the
    # two-command GET-then-DEL — between those calls the key can expire and a
    # fresh enqueue can grab it, and the bare DEL would then drop the new
    # owner's lock. Shared by `Unique::ServerMiddleware#release` (normal
    # success/start release) and `Unique::DEATH_HANDLER` (automatic-death
    # release) so the two paths cannot drift.
    # KEYS = [unique:<sha256>]
    # ARGV = [owning jid]
    # Returns 1 when the key was deleted, 0 otherwise.
    RELEASE_IF_OWNER = <<~LUA
      if redis.call("get", KEYS[1]) == ARGV[1] then
        return redis.call("del", KEYS[1])
      end
      return 0
    LUA

    # Pro Fast API (§11): server-side LRANGE+LREM to delete a single job by
    # jid from a queue list. Pure-Ruby Queue#find_job + JobRecord#delete is
    # O(N) round-trips; this is O(1) round-trip with O(N) Lua work.
    # KEYS = [queue:<name>]
    # ARGV = [jid]
    # Returns the number of payloads removed (0 or 1; can be >1 in pathological
    # duplicate-jid corruption — caller doesn't rely on the value).
    FAST_DELETE_JOB = <<~LUA
      local items = redis.call("lrange", KEYS[1], 0, -1)
      local removed = 0
      for i = 1, #items do
        if string.find(items[i], '"jid":"' .. ARGV[1] .. '"', 1, true) then
          removed = removed + redis.call("lrem", KEYS[1], 1, items[i])
        end
      end
      return removed
    LUA

    # Pro Fast API (§11): server-side LRANGE+LREM removing every payload whose
    # `"class":"<klass>"` field matches. Plain-text scan (no JSON parse) so
    # it tolerates partial corruption — caller drops only well-formed matches.
    # KEYS = [queue:<name>]
    # ARGV = [klass]
    # Returns the number of payloads removed.
    FAST_DELETE_BY_CLASS = <<~LUA
      local items = redis.call("lrange", KEYS[1], 0, -1)
      local removed = 0
      local needle = '"class":"' .. ARGV[1] .. '"'
      for i = 1, #items do
        if string.find(items[i], needle, 1, true) then
          removed = removed + redis.call("lrem", KEYS[1], 1, items[i])
        end
      end
      return removed
    LUA

    # Limiter scripts live in `lib/wurk/lua/limiter_*.lua` — one file per
    # type. Loaded at boot, the file's basename (minus `.lua`) becomes the
    # SCRIPTS key as a symbol. Keeping them as separate files makes diffing
    # individual rate-limiter changes painless and keeps each script self-
    # contained for the `redis-cli --eval` debug workflow.
    LUA_DIR = File.expand_path('lua', __dir__)
    FILE_SCRIPTS = Dir.glob(File.join(LUA_DIR, '*.lua')).each_with_object({}) do |path, h|
      h[File.basename(path, '.lua').to_sym] = File.read(path)
    end.freeze

    SCRIPTS = {
      zpopbyscore: ZPOPBYSCORE,
      bulk_push: BULK_PUSH,
      reliable_schedule_promote: RELIABLE_SCHEDULE_PROMOTE,
      reliable_requeue: RELIABLE_REQUEUE,
      batch_push: BATCH_PUSH,
      batch_schedule: BATCH_SCHEDULE,
      batch_ack_success: BATCH_ACK_SUCCESS,
      batch_ack_failed: BATCH_ACK_FAILED,
      batch_ack_complete: BATCH_ACK_COMPLETE,
      batch_invalidate: BATCH_INVALIDATE,
      batch_append_callback: BATCH_APPEND_CALLBACK,
      fast_delete_job: FAST_DELETE_JOB,
      fast_delete_by_class: FAST_DELETE_BY_CLASS,
      release_if_owner: RELEASE_IF_OWNER
    }.merge(FILE_SCRIPTS).freeze

    # SHA1 of each script source — matches what `SCRIPT LOAD` returns.
    # Precomputing keeps `eval_cached` allocation-free in the hot path.
    SHAS = SCRIPTS.transform_values { |src| Digest::SHA1.hexdigest(src) }.freeze
  end
end

require_relative 'lua/loader'
