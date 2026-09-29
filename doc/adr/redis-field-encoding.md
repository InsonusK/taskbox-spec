---
name: redis field encoding
description: How the fields of a TaskBox task hash are written in Redis, so every stack reads every other stack's tasks
problem: Redis stores strings; the contract named the task fields but not their text form, so two libraries could write run_at or retention differently and a service switched between stacks could not read its pending tasks — which form, balancing a human reading the hash against scripts comparing times?
decision: Times are RFC 3339 UTC with milliseconds at fixed width (2026-09-29T10:00:00.123Z); durations are integer milliseconds; sorted-set scores stay Unix epoch milliseconds; scripts take now from Redis TIME and format it with the contract's iso_now.lua.
---

# Problem
A task hash is read by the library that wrote it, by another stack's library after a service is rewritten, and by a person inspecting a stuck queue with `redis-cli`. PostgreSQL fixes the forms through column types; Redis does not. The owner's criterion: balance use by code against human readability.

# Selected variant
[Readable times, numeric durations (selected)](#readable-times-numeric-durations-selected)

# Searched variants

## Readable times, numeric durations (selected)

### Description
Times as `YYYY-MM-DDTHH:MM:SS.mmmZ` (always UTC, always three fraction digits); `retention` in integer milliseconds (the unit of `PX`); sorted-set scores as epoch milliseconds (Redis requires numbers there); "now" from `TIME`, formatted by `contract/redis/iso_now.lua` (verified against 2,000 random instants and the calendar edge cases on Redis 8).

### Benefits
- A person reads `run_at` in `HGETALL` without converting.
- Fixed width with a constant `Z` makes string order equal time order — scripts compare `run_at <= now` as strings, no parsing.
- One clock (Redis's) for every worker; skew between worker hosts cannot reorder or delay tasks.

### Costs
- Every script that needs "now" carries the ~25-line formatting function.
- Two forms of time in one store: text in hashes, numbers in sorted-set scores.

## Epoch milliseconds everywhere

### Description
Every time a number.

### Benefits
- No formatting code; one form throughout.

### Costs
- Unreadable when inspecting a stuck queue — the case where a person looks at all.

## ISO strings with variable precision or offsets

### Description
Whatever each stack's default formatter produces.

### Benefits
- No work in the libraries.

### Costs
- `…10:00:00Z` vs `…10:00:00.5Z` vs `+00:00` — string comparison breaks and every script must parse.
