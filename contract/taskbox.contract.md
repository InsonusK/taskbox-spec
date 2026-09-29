# TaskBox storage contract (VP-C003)

The stack-agnostic contract every stack's TaskBox realization implements, so that the stored tasks look the same whatever language wrote them: a service rewritten in another stack keeps its tables, streams, and pending tasks. It defines the **mechanism only** — how a task is stored, ordered, claimed, retried, dead-lettered, and removed. It knows nothing about what a task does. Concept and store rules: [VP-C003 TaskBox](https://github.com/InsonusK/ai-skills/blob/develop/skills/common-workflow/architecture/design/plateau-map/variability-map-create.skill/templates/web-service-common-variability-map/vp/vp-c003-taskbox/vp-c003-taskbox.md).

A stack's solution decides only the client library and the code that writes, reads, and executes against the structures below.

## 1. Task

| Field | Type | Meaning |
| --- | --- | --- |
| `seq` | bigint, store-assigned, increasing | Primary key; inserts append to the index; within a group it is also the execution order (§3). |
| `id` | UUIDv7 | Global identifier, assigned by the enqueuing code: logs, handlers, cross-system references. Time-ordered, so it never scatters an index. |
| `status_key` | UUIDv4, nullable, unique | Set only for an Inbox task answered with `202`: the unguessable handle a caller uses to read the task's status ([Inbox contract](https://github.com/InsonusK/ai-skills/blob/develop/skills/common-workflow/architecture/design/plateau-map/variability-map-create.skill/templates/web-service-common-variability-map/vp/vp-c011-inbox/vp-c011-inbox.contract.md)). Never derived from `id` — see [adr/inbox-status-key-not-task-id](https://github.com/InsonusK/ai-skills/blob/develop/skills/common-workflow/architecture/design/plateau-map/variability-map-create.skill/adr/inbox-status-key-not-task-id.md). |
| `queue` | text, default `default` | Selects a worker pool. |
| `queue_group` | text, nullable | Ordering key inside a queue (like a Kafka message key). `null` = no ordering with any other task. |
| `type` | text | Task type name — the **only** key a worker dispatches on. Stable across languages: `send-order-confirmation`, not a class name. |
| `payload` | JSON | Handler parameters; the shape is owned by whoever owns the task type. |
| `idempotency_key` | text, nullable, unique | An enqueue with a key already present in the store adds nothing. |
| `status` | `pending` / `running` / `done` / `dead` / `cancelled` | Lifecycle, §4. |
| `attempt` | int, starts at 0 | Executions started. |
| `max_attempts` | int, default 10 | After this many failures → `dead`. |
| `run_at` | timestamp (UTC) | Not claimable before this — delayed tasks and retry backoff. |
| `locked_until` | timestamp, nullable | Lease end while `running`; an expired lease makes the task claimable again. |
| `last_status` | int, nullable | HTTP status code of the latest attempt's outcome (§4). |
| `last_error` | text, nullable | Error of the latest failed attempt. |
| `retention` | duration, nullable | How long to keep the task after it finishes; effective value = `max(service default, retention)` (§5). |
| `created_at`, `updated_at` | timestamp (UTC) | Bookkeeping. |
| `finished_at` | timestamp, nullable | Set when the task becomes `done`, `dead`, or `cancelled`. |

Criticality is not stored: it is implied by the store the task lives in (VP-C003 concept).

## 2. Ports

- **Enqueue** — `enqueue(tx, type, payload, {queue, queue_group, run_at, max_attempts, idempotency_key, retention})`. `tx` is the caller's own unit of work in that store (SQL transaction, Redis `MULTI`/script, nothing for InMemory); enqueue never commits by itself when a `tx` is given.
- **Handler registry** — the service registers one handler per `type`. A handler receives `(id, payload, attempt)` and returns an **HTTP status code** as its outcome (`2xx` = success), plus an optional `Retry-After`; an exception it raises counts as `500`. TaskBox never inspects `payload`; it classifies the code by [VP-C004](https://github.com/InsonusK/ai-skills/blob/develop/skills/common-workflow/architecture/design/plateau-map/variability-map-create.skill/templates/web-service-common-variability-map/vp/vp-c004-httpoutbound/vp-c004-httpoutbound.md)'s retry classification — every handler is idempotent (§4), so `500` is retryable.
- **Worker** — claims due tasks (§6), dispatches each by `type`, records the outcome (§4).
- **Dead-task operations** (for a person or an admin tool) — **requeue** a `dead` task (`pending`, `attempt = 0`, `run_at = now`) or **cancel** it (`cancelled`).

## 3. Ordering

- **Within `(queue, queue_group)`: strict order.** Tasks of one group run one at a time, lowest `seq` first: a task is claimable only when no task of its group with a lower `seq` is `pending`, `running`, or `dead`.
- **Enqueue takes the group lock before inserting.** `seq` is assigned at insert, not at commit; without a lock, two concurrent transactions could commit out of `seq` order and a later task would run first. The enqueuing transaction first locks the group's row (§6) and holds it until commit, so a second enqueue into the group waits, inserts after the first commits, and gets a higher `seq`.
- **Everything else: no order.** Ungrouped tasks and tasks of different groups run in parallel, roughly by `run_at`.
- **A group stops at its first `dead` task** — nothing says how important the failed task was, and running the later ones may make things worse. The group resumes only after a person requeues or cancels the dead task. While the head task waits for a retry, the group waits too.

## 4. Lifecycle

| From | Event | To |
| --- | --- | --- |
| — | enqueue | `pending` |
| `pending` (due, head of its group or ungrouped) | claimed | `running`, `attempt + 1`, `locked_until = now + lease` |
| `running` | handler returns `2xx` | `done`, `finished_at = now` |
| `running` | retryable code, `attempt < max_attempts` | `pending`, `run_at = now + max(backoff(attempt), Retry-After)`, `last_error` set |
| `running` | retryable code, `attempt ≥ max_attempts` | `dead`, `finished_at = now` — its group stops |
| `running` | non-retryable code (e.g. `400`, `404`, `409`) | `dead` at once, `finished_at = now` — its group stops; retrying cannot change the answer |
| `running` | lease expires (worker died) | claimable again, as if `pending` |
| `running` | no handler registered for `type` | outcome `503` — retryable, so a task reaching an older worker during a rolling deploy is retried, not lost |
| `dead` | requeue | `pending`, `attempt = 0`, `run_at = now`, `finished_at = null` |
| `dead` | cancel | `cancelled`, `finished_at = now` — its group resumes |

Every attempt records its outcome in `last_status`.
- **A run never outlives its lease.** The handler is cancelled when the lease ends; an outcome is written only while the task is still `running` under the attempt that was claimed (`attempt` is the fencing token), so the late outcome of a run whose lease expired and whose task was claimed again is discarded. Hence two workers never run one task at the same time. Why: [adr/taskbox-run-bounded-by-lease](../doc/adr/taskbox-run-bounded-by-lease.md).

- **At-least-once.** A task may run more than once (lease expiry mid-run, a crash between handler success and writing `done`). Every handler is idempotent.
- **Backoff** `min(1s × 2^attempt, 1h)`; **lease** default 5 min — both configurable per service.

## 5. Retention and idempotency window

- A `done` or `cancelled` task is deleted once `now > finished_at + max(service default, retention)`; the service default is 7 days, configurable. A task can extend its own retention, never shorten it below the default.
- A `dead` task in a VP-C001 store is never deleted automatically — it waits for a person. In a VP-C002 store it keeps a lifetime like every entry there (the store's concept wins).
- A `taskbox_group` row whose group has no task left is deleted by the same cleanup; the next enqueue into that group recreates it.
- The effective retention is also the **idempotency window**: an `idempotency_key` is remembered as long as its task row (or Redis marker) exists — however long the task waits before it finishes, plus the retention after. A task type that must reject duplicates for longer sets a longer `retention`.

## 6. Per-store realization

### PostgreSQL (schema v1)

```sql
CREATE TABLE taskbox_task (
  seq             bigint GENERATED ALWAYS AS IDENTITY (CACHE 1) PRIMARY KEY,
  id              uuid        NOT NULL UNIQUE,
  status_key      uuid        UNIQUE,
  queue           text        NOT NULL DEFAULT 'default',
  queue_group     text,
  type            text        NOT NULL,
  payload         jsonb       NOT NULL,
  idempotency_key text        UNIQUE,
  status          text        NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','running','done','dead','cancelled')),
  attempt         int         NOT NULL DEFAULT 0,
  max_attempts    int         NOT NULL DEFAULT 10,
  run_at          timestamptz NOT NULL DEFAULT now(),
  locked_until    timestamptz,
  last_status     int,
  last_error      text,
  retention       interval,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  finished_at     timestamptz
);
CREATE INDEX taskbox_task_due   ON taskbox_task (queue, run_at)          WHERE status IN ('pending','running');
CREATE INDEX taskbox_task_group ON taskbox_task (queue, queue_group, seq) WHERE status IN ('pending','running','dead');
CREATE INDEX taskbox_task_done  ON taskbox_task (finished_at)            WHERE status IN ('done','cancelled');

-- One row per group; exists only to be locked by enqueuing transactions (§3).
CREATE TABLE taskbox_group (
  queue       text NOT NULL,
  queue_group text NOT NULL,
  PRIMARY KEY (queue, queue_group)
);
```

Enqueue into a group — the lock first, held until the caller commits:

```sql
INSERT INTO taskbox_group (queue, queue_group) VALUES ($queue, $group)
ON CONFLICT (queue, queue_group) DO UPDATE SET queue_group = EXCLUDED.queue_group;
INSERT INTO taskbox_task (...) VALUES (...);
```

Claim — due tasks that head their group (or are ungrouped), without double claims:

```sql
UPDATE taskbox_task SET status = 'running', attempt = attempt + 1,
       locked_until = now() + $lease, updated_at = now()
WHERE seq IN (
  SELECT t.seq FROM taskbox_task t
  WHERE t.queue = $queue AND t.run_at <= now()
    AND (t.status = 'pending' OR (t.status = 'running' AND t.locked_until < now()))
    AND (t.queue_group IS NULL OR NOT EXISTS (
      SELECT 1 FROM taskbox_task e
      WHERE e.queue = t.queue AND e.queue_group = t.queue_group AND e.seq < t.seq
        AND e.status IN ('pending','running','dead')))
  ORDER BY t.run_at LIMIT $batch
  FOR UPDATE SKIP LOCKED)
RETURNING seq, id, type, payload, attempt;
```

Enqueue with a key: `INSERT … ON CONFLICT (idempotency_key) DO NOTHING`.

### SQLite (schema v1)

Same tables and columns; `seq` is `INTEGER PRIMARY KEY`; UUID, JSON, timestamps as `TEXT` (ISO-8601 UTC); `retention` as integer seconds. SQLite has one writer, so write transactions are already serialized: `seq` order is commit order without `taskbox_group` (the table is still created, so the schema matches PostgreSQL). A claim is one `BEGIN IMMEDIATE` transaction running the same `UPDATE … RETURNING` (SQLite ≥ 3.35) without `SKIP LOCKED`. One service instance by construction (VP-C001).

### Redis

Ordering follows Kafka: a queue has a fixed number of **partitions**; each partition is a stream drained by **one worker at a time**, in stream order. A task's fields live in its own hash; streams and lists carry only task ids, so a task's state can change while its place in the order stays put. A partition holds many groups, so a stopped group is **parked** rather than left blocking its partition. All keys of a queue share the hash tag `{taskbox:<queue>}` so they sit in one cluster slot; to enqueue atomically with Redis business data, the caller's data keys must be in that slot too — the caller's concern. Why this shape: [adr/taskbox-redis-task-hash](../doc/adr/taskbox-redis-task-hash.md).

**Field encoding** (every stack writes and reads a task hash the same way — [adr/redis-field-encoding](../doc/adr/redis-field-encoding.md)): times (`run_at`, `locked_until`, `created_at`, `updated_at`, `finished_at`) are RFC 3339 UTC with milliseconds, fixed width — `2026-09-29T10:00:00.123Z` — so string order is time order; durations (`retention`) are integer milliseconds; `payload` is its JSON text; `seq`, `attempt`, `max_attempts`, `last_status` are decimal integers; UUIDs are lower-case canonical text; a `null` field is absent from the hash. Sorted-set scores are the one numeric exception: Unix epoch milliseconds. Scripts take "now" from Redis `TIME`, never from a worker's clock, and format it with [redis/iso_now.lua](redis/iso_now.lua).

| Key | Type | Holds |
| --- | --- | --- |
| `{taskbox:<queue>}:meta` | Hash | `partitions` — set once (`HSETNX`); a process configured with another count refuses to start |
| `{taskbox:<queue>}:seq` | String, `INCR` | The `seq` counter (§1) |
| `{taskbox:<queue>}:task:<id>` | Hash | The task's §1 fields; TTL = effective retention once `done` or `cancelled`, none before (a `dead` task's lifetime is kept by the worker loop, see **Lifetime**) |
| `{taskbox:<queue>}:status:<status_key>` | String → `id` | Inbox status lookup; same TTL as its task hash |
| `{taskbox:<queue>}:p:<n>` | Stream, entry `{id, group}` | The order of partition `n` |
| `{taskbox:<queue>}:p:<n>:lease` | String, `SET NX PX <lease>` | The worker running partition `n`'s head task right now (a random token); taken for one run, `PX` = the task lease |
| `{taskbox:<queue>}:delayed` | Sorted set, score = `run_at` (epoch ms) | Ids of **ungrouped** tasks not yet due |
| `{taskbox:<queue>}:dead` | Sorted set, score = `finished_at` (epoch ms) | Ids of dead tasks |
| `{taskbox:<queue>}:stopped` | Set | Groups stopped at a dead task |
| `{taskbox:<queue>}:parked:<group>` | List | Ids of the later tasks of a stopped group, in order |
| `{taskbox:<queue>}:key:<idempotency_key>` | String → `id`; no TTL until the task is `done` / `cancelled`, then TTL = effective retention | Marks an idempotency key as already enqueued, for as long as the task row would exist in SQL |

- **Partition of a task:** grouped — `crc32(queue_group) mod partitions`, CRC-32/IEEE over the UTF-8 bytes of `queue_group`, so every stack routes a group to the same partition; ungrouped — any partition.
- **Enqueue** is one Lua script, queued inside the caller's `MULTI` when a `tx` is given: with an idempotency key, `SET …:key:<k> <id> NX` (no TTL — see §5) first and nothing more if it fails; `INCR …:seq`; `HSET …:task:<id>` (status `pending`); then a grouped task goes to `…:parked:<group>` (`RPUSH`) if its group is in `…:stopped`, otherwise to its partition (`XADD`) **whatever its `run_at`**; an ungrouped task goes to its partition when due, else to `…:delayed`. Stream ids are assigned at `EXEC`, so stream order is commit order.
- **Claim** is one Lua script per partition, for one run ([adr/redis-partition-lease-per-run](../doc/adr/redis-partition-lease-per-run.md)): take `…:p:<n>:lease` with a fresh random token (`SET NX PX <lease>`) or give up on this partition; read the head entry (`XRANGE … COUNT 1`). If the partition is empty, or the head's `run_at` is after now (a delayed grouped task, or a head waiting for a retry), release the lease and give up — the partition waits for its head, as a group does in SQL. Otherwise set the head task `running`, `attempt + 1`, `locked_until = now + lease`, and return it with the token. There is no renewal: a worker that dies leaves the lease to expire, and the next claim runs the same head again with `attempt + 1`.
- **Outcome** is one Lua script that writes only if `…:p:<n>:lease` still holds the claim's token and the task's `attempt` is the claimed one (§4), and always ends by deleting the lease (the partition is free for the next claim). `done`: `XDEL` the entry, set `finished_at`, give the task hash, the idempotency marker, and the status key their TTL = effective retention. Retry: the entry stays at the head, the hash gets `pending`, `run_at`, `last_status`, `last_error`. A late outcome whose token no longer matches changes nothing.
- **Dead:** one Lua script sets the hash to `dead`, `ZADD …:dead`, `XDEL`s the entry and, for a grouped task, `SADD …:stopped <group>` and moves every entry of that group still in the partition to `…:parked:<group>` in stream order. From then on the group's new tasks go straight to `…:parked:<group>` (enqueue above), so nothing of a stopped group stays in its partition and the other groups keep flowing.
- **Requeue / cancel:** one Lua script resets the dead task (requeue: `pending`, `attempt = 0`; cancel: `cancelled`, and the task hash, marker, and status key get their TTL = effective retention), `ZREM …:dead`, appends — for requeue — the task and then `…:parked:<group>` in order to the partition (for cancel only the parked ids), deletes the parked list, and removes the group from `…:stopped`.
- **Due mover:** moves ids from `…:delayed` with score ≤ now into a partition (a Lua script run by the worker loop).
- **Lifetime:** every task is lost with its store (VP-C002). A dead task keeps a lifetime too: once `finished_at + effective retention` has passed, the worker loop cancels it (the group resumes) and logs it — in this store the lifetime ending is the same event as losing the entry.

### InMemory

Per-process FIFO per `(queue, queue_group)` plus one queue for ungrouped tasks, a priority queue by `run_at` for delayed ones, and worker threads/goroutines that run at most one task per group at a time; a group with a dead head stops until requeue or cancel. Same lifecycle and handler registry; no `tx` — enqueue happens when called. Every task ends with the process (VP-C002 lifetime); NonCritical only.

## 7. Schema versions and migrations

The DDL above is **schema v1** of this contract. Every change adds a numbered version here (v2, …) with its DDL delta. Each stack applies these versions through its **own** migration tool (goose, EF Core migrations, …) as ordinary migrations in the service's history.

Switching a service to another stack is not designed yet — decided when a real switch happens. Known shape of the answer: the new stack's migration history starts from a baseline equal to the contract version the database is already at, instead of re-creating the tables.

## 8. Conformance scenarios

Every stack realization passes the same scenarios, one run per store it supports:
- A task enqueued in a transaction that rolls back never runs; committed, it runs exactly once when the handler succeeds.
- A handler returning a retryable code is retried with growing `run_at` (never before a `Retry-After`); after `max_attempts` such outcomes the task is `dead` with `last_status`, `last_error`, and `finished_at`.
- A handler returning a non-retryable code sends the task to `dead` on the first attempt; an exception counts as `500` and is retried.
- A task claimed by a worker that dies is claimed again after its lease.
- A handler still running when its lease ends is cancelled, and its late outcome does not change the task.
- Two workers never run the same task at the same time.
- Tasks of one `queue_group` run one at a time in `seq` order, even when enqueued by concurrent transactions; tasks of different groups run in parallel.
- A retrying head task holds back the rest of its group until it succeeds.
- A dead task stops its group; other groups — including those in the same Redis partition — keep running; requeue or cancel resumes the group in the original order.
- An enqueue repeating an existing `idempotency_key` adds no task, for as long as the effective retention keeps the first one.
- A `done` or `cancelled` task is removed after `max(default, retention)`; a `dead` task in a VP-C001 store is not removed.
- A task whose `type` has no handler is retried, not dropped.
- A delayed task does not run before its `run_at`.

## 9. Later (not in v1)


- **Skippable tasks:** a task-level flag (`skip_on_dead`) letting its group continue past it when it dies.
- **Skippable outcomes:** a handler outcome meaning "failed, but the group may continue" (`fail_allow_skip`) next to the default non-retryable failure that stops the group.
