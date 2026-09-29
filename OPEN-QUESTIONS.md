# Open questions (block the Redis store in every library)

Found while designing the Go Redis store, 2026-09-28; proposals by the implementing agent, not yet decided by the owner.

1. **Encoding of the task hash fields is not specified.** Two stacks would write times and durations differently, and a service switched between stacks could not read its tasks.
   *Proposal:* timestamps as Unix epoch milliseconds, `retention` in milliseconds, `payload` as a JSON string, an absent field = `null`.
2. **The idempotency marker gets its TTL at enqueue.** A task pending longer than its retention loses its marker while it still waits, and a duplicate gets in.
   *Proposal:* set the marker without a TTL at enqueue; give it the effective retention when the task becomes `done` / `cancelled`, like the task hash.
3. **Partition lease granularity.** The contract says a worker takes a partition's lease and keeps renewing it.
   *Proposal:* take the partition lease for the run of its head task only (same length as the task lease) and release it in the outcome script. Same guarantee (one worker per partition, in order), no renewal loop, and the outcome fence is "lease token + attempt".
