# Changelog

## Unreleased — 0.1.0
- Contract v1 (schema v1) moved here from `ai-skills` (`vp-c003-taskbox.contract.md`), with the amendments of 2026-09-27/28: status-code outcomes, `last_status`, `status_key`, a run bounded by its lease with outcomes fenced by `attempt`, the Redis per-task-hash design.
- Conformance feature and step vocabulary moved here from `ai-skills` (`solution-taskbox`); proven against PostgreSQL 18 by the Go realization (30/30 scenarios, group-lock and fence mutations fail it).
- `doc/skills/`: `taskbox-usage` (moved from ai-skills `solution-taskbox`) and `taskbox-library`; `docs/` renamed `doc/`; ADRs `enqueue-through-the-data-port`, `one-conformance-feature-for-every-stack` moved from ai-skills.
- Redis questions resolved (2026-09-29): field encoding (`contract/redis/iso_now.lua`, ADR `redis-field-encoding`); idempotency marker gets its TTL at finish, not at enqueue (+1 scenario); partition lease per run (ADR `redis-partition-lease-per-run`).
