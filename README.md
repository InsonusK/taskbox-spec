# taskbox-spec

Stack-agnostic specification of **TaskBox** — deferred, retried, per-group ordered task execution stored in the service's own database (Variation Point VP-C003 of the [web-service common map](https://github.com/InsonusK/ai-skills/blob/develop/skills/common-workflow/architecture/design/plateau-map/variability-map-create.skill/templates/web-service-common-variability-map/web-service-common-variability-map.md)).

This repository holds **no code**. It is what every TaskBox library conforms to:

| Path | Content |
| --- | --- |
| [contract/taskbox.contract.md](contract/taskbox.contract.md) | The storage contract: task record, ports, ordering, lifecycle, retention, per-store schema (PostgreSQL, SQLite, Redis, InMemory), migrations |
| [contract/schema/postgresql/v1.sql](contract/schema/postgresql/v1.sql) | PostgreSQL schema v1 as a file (identical to the contract's §6 DDL) |
| [features/taskbox-conformance.feature](features/taskbox-conformance.feature) | The conformance scenarios (contract §8) as one Gherkin feature |
| [features/STEP-VOCABULARY.md](features/STEP-VOCABULARY.md) | The steps every library's runner implements, and the rules for running the feature |
| [docs/adr/](docs/adr/) | Decisions made inside the contract |
| [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md) | Contract gaps waiting on the owner — they block the Redis store |

## Libraries

| Stack | Repository |
| --- | --- |
| Go | `taskbox-go` (mock: `https://github.com/InsonusK/taskbox-go`) |
| .NET | `taskbox-dotnet` (mock: `https://github.com/InsonusK/taskbox-dotnet`) |
| Python | `taskbox-python` (mock: `https://github.com/InsonusK/taskbox-python`) |

## How a library consumes this repository
- Pin a release tag (`vX.Y.Z`) of this repository — git submodule at `spec/`, or download of the release archive in CI.
- Run `features/taskbox-conformance.feature` of that release unchanged, once per store the library supports, in its CI.
- Apply the schema versions through the consuming service's own migration tool (contract §7) — a library ships the DDL of the pinned version, it never creates tables on its own at runtime.

## Versioning
- `MAJOR` — a schema version that is not backward compatible or a changed lifecycle rule.
- `MINOR` — a new schema version that is additive, a new scenario, a new store realization.
- `PATCH` — wording that changes no behaviour.

A change to the contract and the matching change to the feature ship in one release.
