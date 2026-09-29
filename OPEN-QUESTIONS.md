# Open questions

None open. Resolved:

| Date | Question | Decision (owner) |
| --- | --- | --- |
| 2026-09-29 | Encoding of the Redis task hash fields | Times as fixed-width RFC 3339 UTC with milliseconds, durations in integer ms, sorted-set scores epoch ms, "now" from Redis `TIME` via `contract/redis/iso_now.lua` — [ADR](doc/adr/redis-field-encoding.md) |
| 2026-09-29 | Idempotency marker TTL counted from enqueue | Marker without TTL at enqueue; TTL = effective retention from `done` / `cancelled` — contract §5/§6, new scenario "An idempotency key keeps blocking while its task waits longer than the retention" |
| 2026-09-29 | Partition lease: long-held with renewal? | Lease for one run of the head task, released by the outcome script — [ADR](doc/adr/redis-partition-lease-per-run.md) |
