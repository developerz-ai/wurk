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
  # `:zpopbyscore` implements the pop-one-due-entry step in sidekiq-free.md
  # §1.8. It is the minimal expression of that step — range by score, take one,
  # remove it, return it — and there is no room to write it differently without
  # changing what it does.
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
    # A member that is not a JSON object naming a string `queue` (garbage bytes,
    # a bare scalar, a nil/numeric queue) can never be promoted. Raising on it
    # would abort the script at the same lowest-scored member on every sweep —
    # and since one Ruby call drains `retry` before `schedule`, a single poison
    # retry would starve the whole cluster's scheduled jobs. It is moved to the
    # dead set (scored `now`, like a kill) so it stays inspectable, and the
    # sweep continues. pcall keeps a failed decode from raising out of the script.
    # KEYS = [sorted_set, queues_set, dead_set]
    # ARGV = [now, queue_prefix, now_ms, batch]
    # Returns the number of members handled (promoted or moved to dead).
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
        local ok, decoded = pcall(cjson.decode, job)
        local q = ok and type(decoded) == "table" and decoded["queue"]
        if type(q) == "string" then
          local pat, rep = '"enqueued_at":%-?%d[%d.eE+-]*', '"enqueued_at":' .. ARGV[3]
          if decoded["enqueued_at"] == nil then pat, rep = "^{", "{" .. rep .. "," end
          redis.call("sadd", KEYS[2], q)
          redis.call("lpush", ARGV[2] .. q, (string.gsub(job, pat, rep, 1)))
        else
          redis.call("zadd", KEYS[3], ARGV[1], job)
        end
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

    # Ent Unique (§3): atomic compare-and-delete of a lock key. Replaces the
    # two-command GET-then-DEL — between those calls the key can expire and a
    # fresh owner can grab it, and the bare DEL would then drop the new
    # owner's lock. Shared by `Unique::ServerMiddleware#release` (normal
    # success/start release), `Unique::DEATH_HANDLER` (automatic-death
    # release) and `Leader#release` (stepping down from the cluster lock)
    # so those paths cannot drift.
    # KEYS = [the lock key — unique:<sha256> | dear-leader]
    # ARGV = [the owner that must still hold it — jid | <host>:<pid>:<nonce>]
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
    # Returns the first payload removed, or nil (Lua false) when none matched —
    # Pro's `delete_job` return value. Every match is removed, so a
    # duplicate-jid corruption is cleaned up in the same pass.
    FAST_DELETE_JOB = <<~LUA
      local items = redis.call("lrange", KEYS[1], 0, -1)
      local deleted = false
      for i = 1, #items do
        if string.find(items[i], '"jid":"' .. ARGV[1] .. '"', 1, true) then
          if redis.call("lrem", KEYS[1], 1, items[i]) > 0 and not deleted then
            deleted = items[i]
          end
        end
      end
      return deleted
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

    # Ent Periodic (§2): compare-and-swap the fire marks of `loops:<lid>`.
    # The cron poller's leader gate is a cached read (`Component#leader?`,
    # LEADER_CACHE_TTL_MS), so for a few seconds after a handover two
    # processes both believe they lead and both reach the same due loop —
    # HMGET → decide → enqueue → HSET then fires it twice. Claiming the slot
    # atomically is what makes a tick fire exactly once; the loser gets 0 and
    # enqueues nothing. Values written are the same decimal-epoch strings the
    # Ruby path wrote, byte for byte — the dashboard reads these fields.
    #
    # `nf` present: the caller must still be looking at the mark it read
    # (byte compare, so no parse can drift the token).
    # `nf` absent: the caller derived the slot from `lf`, so refuse once `lf`
    # has reached it — that is the exhausted-schedule case, where the winner
    # cleared `nf` and a loser would otherwise re-fire the very same slot.
    # KEYS = [loops:<lid>]
    # ARGV = [expected `nf` (or the derived slot), new `lf`, new `nf` ('' → HDEL)]
    # Returns 1 when this caller claimed the slot, 0 otherwise.
    CRON_CLAIM_FIRE = <<~LUA
      local key = KEYS[1]
      local cur = redis.call("hget", key, "nf")
      if cur and cur ~= "" then
        if cur ~= ARGV[1] then return 0 end
      else
        local lf = tonumber(redis.call("hget", key, "lf") or "")
        if lf and lf >= tonumber(ARGV[1]) then return 0 end
      end
      redis.call("hset", key, "lf", ARGV[2])
      if ARGV[3] == "" then
        redis.call("hdel", key, "nf")
      else
        redis.call("hset", key, "nf", ARGV[3])
      end
      return 1
    LUA

    # The rest — batch (`batch_*`), limiter (`limiter_*`), flow and the
    # other per-feature scripts — live in `lib/wurk/lua/*.lua`, one script per
    # file. Loaded at boot, the file's basename (minus `.lua`) becomes the
    # SCRIPTS key as a symbol. Separate files keep each script diffable on its
    # own and self-contained for the `redis-cli --eval` debug workflow.
    LUA_DIR = File.expand_path('lua', __dir__)
    FILE_SCRIPTS = Dir.glob(File.join(LUA_DIR, '*.lua')).to_h do |path|
      [File.basename(path, '.lua').to_sym, File.read(path)]
    end.freeze

    SCRIPTS = {
      zpopbyscore: ZPOPBYSCORE,
      bulk_push: BULK_PUSH,
      reliable_schedule_promote: RELIABLE_SCHEDULE_PROMOTE,
      reliable_requeue: RELIABLE_REQUEUE,
      fast_delete_job: FAST_DELETE_JOB,
      fast_delete_by_class: FAST_DELETE_BY_CLASS,
      release_if_owner: RELEASE_IF_OWNER,
      cron_claim_fire: CRON_CLAIM_FIRE
    }.merge(FILE_SCRIPTS).freeze

    # SHA1 of each script source — matches what `SCRIPT LOAD` returns.
    # Precomputing keeps `eval_cached` allocation-free in the hot path.
    SHAS = SCRIPTS.transform_values { |src| Digest::SHA1.hexdigest(src) }.freeze
  end
end

require_relative 'lua/loader'
