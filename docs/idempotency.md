# Idempotent jobs

Wurk delivers every job **at least once**, as Sidekiq does. In a few windows a
job that already started, or already finished, runs again **from the top**. This
page lists those windows so you know which jobs need a guard. The mechanics are in
[Reliability](reliability.md).

## When a job runs twice

| Window | What happens | How long it stays open |
|---|---|---|
| **Deploy, or any graceful stop** (`SIGTERM`) that outlasts `shutdown_timeout` | Jobs still running at the deadline go back to the front of their queue and their threads are interrupted. The next worker runs them again | Any job that runs longer than `shutdown_timeout` (default 25s, `config[:timeout]`) |
| **Hard death mid-`perform`** (`SIGKILL`, OOM kill, lost host) | The private-list entry is reclaimed once the owner's heartbeat expires, and a live worker runs the job again | About 1s for a swarm child, 90s after a pod restart, 90–140s for a lost host ([deployment](deployment.md)) |
| **Hard death just after `perform` returned** | The ACK rides the next fetch, so a finished job whose ACK was not sent yet is reclaimed and run again | Until that worker's next fetch or ACK flush ([the ACK rides the next fetch](reliability.md#the-ack-rides-the-next-fetch)) |
| **Scheduled and retry promotion** | The poller leases due jobs before pushing them. A crash between the push and the removal promotes them again when the lease lapses | Up to the 60s lease ([the reliable scheduler](reliability.md#the-reliable-scheduler)) |
| **A retry** | A job that raised runs again on its retry schedule. Whatever it did before the raise is already done | Every failure, by design ([retries](retries.md)) |

The deploy window is the one long jobs hit. A job that calls a paid API for 3
minutes against a 25s `shutdown_timeout` is interrupted on every deploy, and the
retry pays for the call again. Wurk logs each one when the drain deadline passes:

```text
WARN: Terminating 2 busy threads
WARN: Interrupting ArticleGenerationJob jid=1f0c… queue=default: past the shutdown deadline, it is requeued to run again
```

The payload has no "this is a re-run" field. Sidekiq's job JSON has none, and
Wurk does not add fields to the job format.

## Guards

- **Key side effects on something stable** (`article.id`, `order.id`), never on
  the attempt. Check whether the work is already done and return early.
- **Pass an idempotency key to the remote service** where it supports one
  (Stripe and most payment APIs), built from the job's own arguments.
- **Use upserts** (`find_or_create_by!`, `upsert`, a unique index) instead of a
  bare `create!`.
- **Wrap writes that belong together in one database transaction**, so an
  interruption between them leaves neither one.
- **Stop at a safe point when the process is stopping.** `interrupted?` turns true
  once this worker is quieted or told to stop (`SIGTSTP`, `SIGTERM`). A loop that
  checks it can hand the rest of its work to a new job and return before the
  deadline. A plain `return` would end the job as a success and drop the rest:

  ```ruby
  def perform(batch_id)
    Item.where(batch_id: batch_id, done: false).find_each do |item|
      if interrupted?
        self.class.perform_async(batch_id) # the items still done: false run there
        return
      end
      item.process!
    end
  end
  ```

  [Iterable jobs](iterable-jobs.md) do this for you: they save a cursor and
  resume from it instead of starting over.
- **Give long jobs room.** Raise `shutdown_timeout` (and the orchestrator's
  grace period with it, see [deployment](deployment.md)) above the longest job
  you would rather finish than repeat.

Turning off reliability is not one of the options. There is no setting for it,
and a lost job is worse than one that runs twice.

## Related

- [Reliability](reliability.md): reliable fetch, the reaper, graceful shutdown.
- [Deployment](deployment.md): signals, drain budgets, rolling restarts.
- [Retries](retries.md): backoff and the retry budget.
- [Iterable jobs](iterable-jobs.md): resumable jobs with saved cursors.
