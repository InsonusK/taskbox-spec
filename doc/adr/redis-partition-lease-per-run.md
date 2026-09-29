---
name: redis partition lease per run
description: How a TaskBox worker owns a Redis partition so that a partition is drained by one worker at a time, in order
problem: The contract said a worker takes a partition lease and keeps renewing it, without saying how often, what happens when a renewal fails mid-run, or how the partition lease relates to the task lease that bounds a handler — every library would invent its own answer and its own races.
decision: A worker takes the partition's lease for the run of its head task only (SET NX PX = the task lease), and the outcome script releases it; no renewal loop. The outcome is fenced by the lease token plus attempt.
---

# Problem
One worker at a time per partition is what keeps group order in Redis. A long-held, renewed lease needs a background renewal loop per partition and a rule for a renewal that fails while a handler runs; the contract gave neither, and the handler is already bounded by the task lease.

# Selected variant
[Lease per run (selected)](#lease-per-run-selected)

# Searched variants

## Lease per run (selected)

### Description
Claim = one script: `SET …:p:<n>:lease <token> NX PX <lease>`, read the head, give up (and release) if the partition is empty or the head is not due, else mark the head `running`. The outcome script checks token and `attempt`, writes, and deletes the lease. The next run of the partition goes to whichever worker claims first.

### Benefits
- The same guarantee — one run per partition at a time, head first — with no renewal loop.
- The partition lease and the task lease are one timer; a dead worker's partition frees itself when the handler's deadline would have passed anyway.
- The fence is local: token + `attempt`, checked in the same script that writes.

### Costs
- One extra `SET`/`DEL` per task.
- No worker affinity to a partition (irrelevant for correctness).

## Long-held lease with renewal

### Description
A worker owns a partition for many tasks and renews the lease periodically.

### Benefits
- Fewer lease writes under high throughput.

### Costs
- A renewal loop per owned partition and undefined behaviour when a renewal fails mid-run — the gaps the contract left open.
