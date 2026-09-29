---
name: taskbox redis keeps task fields in a per-task hash
description: How the TaskBox contract stores tasks in Redis so that retry state, group order, and finished-task status all work
problem: Redis streams are append-only and their entries immutable, yet a TaskBox task changes state (attempt, run_at, last_status, status) while keeping its place in its group's order — where does that state live, and how do delayed and stopped groups keep their order?
decision: A task's fields live in a hash `…:task:<id>`; partition streams, the delayed set, and the parked lists carry only ids. A grouped task enters its partition at enqueue whatever its `run_at`; a stopped group's entries are swept into its parked list atomically when its task dies; partitions are chosen by CRC-32/IEEE of the group.
---

# Problem
The first Redis design of the TaskBox contract (VP-C003) kept the §1 fields inside the stream entry. Four defects followed:
- A retrying head task stays at the head, but a stream entry cannot be changed, so its `attempt`, `run_at`, `last_status`, `last_error` had nowhere to go.
- Finished tasks were not kept at all, so Inbox's `GET …/tasks/<status_key>` could not be answered from Redis.
- A grouped task with a future `run_at` waited in the delayed set and entered its partition only when due, so a later task of the same group that was due at once overtook it — against the contract's strict group order.
- `hash(queue_group) mod partitions` named no hash function, so two stacks would route one group to different partitions, and a service rewritten in another stack would lose group order on its pending tasks.

A further order race: a task enqueued into a stopped group landed in its partition, and a requeue running before the worker parked it appended the older tasks behind it.

# Selected variant
[Per-task hash, id-only streams (selected)](#per-task-hash-id-only-streams-selected)

# Searched variants

## Per-task hash, id-only streams (selected)

### Description
- `…:task:<id>` hash holds the task's fields; its TTL starts at `finished_at`. `…:status:<status_key>` maps the Inbox key to the id.
- Streams (`{id, group}`), the delayed set (ungrouped only), the dead set, and the parked lists carry ids.
- A grouped task always enters its partition at enqueue; a head with a future `run_at` makes its partition wait, as a retrying head already does.
- Enqueue is a Lua script: into a stopped group it appends to `…:parked:<group>`. The dead script atomically stops the group and sweeps its remaining partition entries into the parked list, so nothing of a stopped group stays in its partition.
- Partition = CRC-32/IEEE of the UTF-8 group mod `partitions`, the count pinned in `…:meta`.

### Benefits
- Retry state, lease fencing, and status lookup work on one mutable record per task.
- Group order holds for delayed tasks and across stop / requeue without timing races — every order-changing step is one atomic script.
- Any stack computes the same partition; a stack switch keeps pending tasks in order.
- Finished tasks answer status queries for their retention window, like the SQL stores.

### Costs
- Two keys per task (hash + stream entry) and one more round of reads for the worker.
- A delayed grouped task stalls its partition until due, including other groups in that partition — the price of Kafka-like partition order; ungrouped delayed tasks do not.
- The dead script scans the partition once (O(partition length)); dying is rare.

## Keep fields in the stream entry, re-append on change

### Description
On every state change, delete the entry and append a new one with the new fields.

### Benefits
- One key per task.

### Costs
- Re-appending moves the task behind later tasks of its group — group order is lost on the first retry.
- No place for finished tasks.

## Per-group streams instead of partitions

### Description
One stream per `(queue, queue_group)`, no partitions.

### Benefits
- A stopped or delayed group never stalls another group.

### Costs
- Unbounded number of streams; a worker must discover which of them have due work (another index), and one lease per group instead of per partition.
- Moves away from the Kafka-like model the other stacks and the Outbox contract already assume.
