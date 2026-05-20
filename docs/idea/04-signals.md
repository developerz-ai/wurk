# Signal Handling

## Signal map

| Signal | Sent to | Effect |
|---|---|---|
| SIGTERM | parent | Graceful drain. Parent relays to all children. Each child stops fetching, lets in-flight jobs finish up to the shutdown timeout, then exits. Parent waits for all children, then exits |
| SIGINT | parent | Same as SIGTERM (Ctrl-C in standalone) |
| SIGTSTP | parent | Pause fetching globally. In-flight jobs continue. Resume via SIGCONT |
| SIGUSR1 | parent | Rolling restart. Forks a replacement child before terminating the old one — zero dropped jobs even for long-running work |
| SIGUSR2 | child | Reopen log files (logrotate-friendly) |
| SIGKILL | any | Hard stop. Jobs already moved into the per-process private list survive in Redis and are reclaimed on next boot |

## Graceful drain semantics

When a child receives SIGTERM the fetcher stops issuing new BLMOVEs immediately. Processor threads finish their current perform. If any thread is still running when the shutdown timeout elapses, it's interrupted with a Wurk shutdown exception that bubbles through the middleware chain so cleanup hooks still run.

Anything still sitting in the per-process private list at the moment of exit is left there. The next process to boot drains the private list back to the head of the main queue before fetching new work.

## Why SIGKILL is safe

Reliable fetch atomically moves a job ID from the main queue into a per-process private list. The job ID is in two lists for the duration of the work, then removed from the private list on success. If the process disappears (SIGKILL, OOM, hardware failure), the job ID stays in the private list. A janitor — or simply the next boot of a process with the same hostname/PID lineage — moves it back. No job is lost.

## Rolling restart semantics

Triggered by SIGUSR1 to the parent. The parent walks its child list one at a time:

1. Fork a fresh replacement child.
2. Wait for the replacement to heartbeat at least once (proves it's fetching).
3. Send SIGTERM to the old child.
4. Wait for the old child to drain.
5. Move to the next slot.

Long-running jobs in the old child get up to the full shutdown timeout to finish, while the replacement is already serving new work.

## User-facing contract

The user never wires any of this. They write perform methods. Wurk guarantees: SIGTERM drains, SIGKILL doesn't lose work, rolling restart doesn't drop long jobs.
