---
name: taskbox-usage
description: How a backend service uses TaskBox — deferred, retried, per-group ordered tasks stored in the service's own database — whatever its stack; the stack library's own skill adds the code for that stack
whenToUse: when a backend service must run work later, retry it until it succeeds, or keep it in order per key — in particular work that must be enqueued atomically with a data change — or when reviewing how a service uses TaskBox
updated: 20260929
tags:
  - stack
  - concern/architecture
  - taskbox
---

# Goal
- Every deferred piece of work is a TaskBox task stored by a TaskBox library that conforms to [the contract](../../../contract/taskbox.contract.md), in the store its criticality allows.
- Every data port whose write can trigger follow-up work takes the tasks with the write, so data and task commit together.
- One task handler per task type, written as an inbound adapter that returns an HTTP status code.
- The schema version the library pins is applied by the service's own migration tool.

# Core Principle
- **Library, not code** - The service never implements TaskBox itself; it adds the library of its stack (see the table in [README](../../../README.md#libraries)) and writes only the seams this skill and the library's own skill describe.
- **Criticality picks the store** - A Critical task type lives in the durable store (PostgreSQL / SQLite); a NonCritical one may live in either the durable or the transient store (Redis / InMemory) — a task in a transient store may be lost with it.
- **The domain decides, the adapter commits** - The domain decides *that* a follow-up is needed; the adapter that writes the change enqueues it inside the same transaction ([ADR](../../adr/enqueue-through-the-data-port.md)).
- **Handlers are inbound adapters** - A task arrives like a request: decode the payload, call the domain, map the result to a status code — no business logic in the handler.
- **Everything runs at least once** - Every handler is idempotent; the task `id` is the idempotency key it passes on.

# Rule

## MUST

### Use a conforming library
Use the TaskBox library of your stack at a release that states the spec version it conforms to; never write the mechanism or use a job-queue library that brings its own schema.
- Violation: a hand-written `tasks` table and polling loop, or River / Hangfire / Celery for TaskBox work.
- Risk: the guarantees the conformance feature proves (group order under concurrency, lease fencing, retention) are lost silently, and a service switched to another stack cannot read its tasks.
- Fix: add the library; follow its skill in `doc/skills/` for the stack's code.

### Pick the store by criticality
Store a Critical task type only in the durable store; store a NonCritical one in either store.
- Violation: a payment follow-up enqueued into Redis because it is faster.
- Risk: a Redis failover or an InMemory restart loses work the business cannot lose.
- Fix: record each task type's criticality and store beside its handler; move Critical types to the durable store.

### Enqueue a follow-up in the data change's transaction
Enqueue a task that follows a data change through the data port that writes the change, inside the same transaction.
- Violation: the domain calls `history.Record(...)` and then `tasks.Enqueue(...)` as two separate operations.
- Risk: a crash between the two writes leaves a change without its follow-up, or a follow-up for a change that never committed.
- Fix: the port's write takes the tasks (`Record(entry, tasks...)`) as plain domain values; the adapter writes both in one transaction. Only a task with no data change behind it uses a stand-alone enqueue.

### Map every handler result to a status code
Return `2xx` for success, a retryable code (`408`, `429`, `500`, `502`, `503`, `504`) for a failure that retrying can fix, and a non-retryable `4xx` for one it cannot — never swallow a failure as `2xx`.
- Violation: a handler logs a validation error and returns success so the task "stops failing".
- Risk: work silently disappears; the dead-task list, which exists to show it, stays empty.
- Fix: unavailable dependency → `503`, invalid payload → `400`, missing entity → `404`, conflicting state → `409`; an unexpected exception counts as `500`.

### Keep handlers idempotent
Write every handler so that running it twice with the same task has the effect of running it once.
- Risk: a lease expiry or a crash between the handler's success and `done` runs the task again and applies its effect twice.
- Fix: key the effect on the task `id` (pass it as `Idempotency-Key` downstream, or record it with the effect and check first).

### Evolve payloads compatibly
Change a task type's payload only by adding optional fields, and make its handler accept every payload shape still stored.
- Risk: stored tasks from before a deploy (and new tasks reaching old workers during a rolling deploy) turn into dead tasks.
- Fix: add fields as optional with defaults; for a breaking change introduce a new task type name and keep the old handler until its tasks are gone.

### Bound handlers by the lease
Configure the lease above the slowest task type's run time and pass the handler's cancellation on to every call it makes.
- Risk: a handler outliving its lease is cancelled and its outcome discarded ([ADR](../../adr/taskbox-run-bounded-by-lease.md)); one that ignores cancellation overlaps its own retry.
- Fix: never replace the handler's context/token; raise the lease for slow task types.

### Apply the schema through the service's migrations
Apply the pinned schema version as ordinary migrations of the service, in the service's own migration history.
- Risk: tables created at runtime or by hand drift from the contract; a later schema version has nothing to migrate from.
- Fix: copy the library's DDL file for the pinned version into the next migration.

## SHOULD

### Name task types by the work, stably
Name a task type for the work in kebab-case (`recheck-flagged-link`), never after a class or function, and never rename it while tasks of it may be stored.

### Watch dead tasks
Expose the number of dead tasks per queue and alert above zero — a dead task stops its whole group until a person requeues or cancels it.

### Choose the group by the entity
Set `queue_group` to the key whose tasks must not overtake each other (an entity id); leave it empty for independent tasks so they run in parallel.

# Check list
- [ ] The service uses its stack's TaskBox library at a release that names its conformed spec version.
- [ ] Every task type has a recorded criticality; Critical types live only in the durable store.
- [ ] Every task that follows a data change is enqueued inside that change's transaction, through the data port.
- [ ] Every handler maps its results to status codes and is idempotent; the lease exceeds the slowest handler.
- [ ] The pinned schema version is a migration of the service.
