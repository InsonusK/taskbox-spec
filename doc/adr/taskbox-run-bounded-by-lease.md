---
name: taskbox run bounded by its lease, outcome fenced by attempt
description: How the TaskBox contract keeps two workers from running one task at the same time when a handler outlives its lease
problem: A claimed task carries a lease; if its handler is still running when the lease ends, another worker claims it again — which mechanism prevents two concurrent runs and a stale outcome overwriting a fresh one?
decision: The handler is cancelled when its lease ends, and every outcome write is conditional on the task still being `running` under the claimed `attempt`; a late outcome is discarded.
---

# Problem
TaskBox (VP-C003) claims a task with a lease (`locked_until`) so that a task whose worker died is claimed again. The same rule re-claims a task whose handler is merely slow: the first run continues while a second one starts, and whichever finishes last writes the task's outcome. The contract's conformance scenarios require that two workers never run one task at the same time. The contract must say how every stack keeps that promise.

# Selected variant
[Cancel at lease end, fence the outcome by attempt (selected)](#cancel-at-lease-end-fence-the-outcome-by-attempt-selected)

# Searched variants

## Cancel at lease end, fence the outcome by attempt (selected)

### Description
The handler runs with a deadline equal to the lease end and is cancelled when it passes. The outcome write (`done`, retry, `dead`) applies only while the task is `running` with the `attempt` value the worker claimed; after a re-claim `attempt` has grown, so the stale write matches nothing.

### Benefits
- The promise holds by construction: no run continues past the moment another worker may claim the task, and no stale outcome survives.
- One rule for every store: SQL `UPDATE … WHERE status = 'running' AND attempt = $claimed`, the same check inside Redis's outcome script, a field check in memory.
- No background renewal traffic; the lease stays a single timestamp.

### Costs
- A handler that legitimately needs longer than the lease fails; the lease must be configured above the slowest task type (default 5 min, configurable per service).
- A handler must honour cancellation of its context/token — a handler that ignores it can still overlap. At-least-once delivery and idempotent handlers remain the safety net.

## Heartbeat renewal while the handler runs

### Description
The worker keeps extending `locked_until` while the handler runs; the lease expires only when the worker stops renewing (it died).

### Benefits
- Handlers of any duration are fine.

### Costs
- A renewal loop per running task and a write every few seconds per task.
- A worker that is alive but stuck (a hung handler) keeps its lease forever; the task never moves on without an extra timeout — which is the selected variant again.
- A network partition between the renewing worker and the store still lets a second worker claim; fencing on the outcome is needed anyway.

## Rely on at-least-once only

### Description
Say nothing: overlapping runs are one more case of at-least-once delivery, handled by idempotent handlers.

### Benefits
- No extra rule.

### Costs
- The conformance scenario "two workers never run the same task at the same time" becomes false.
- A stale outcome may overwrite a fresh one — e.g. a late failure turning a `done` task back to `pending`, so it runs again.
