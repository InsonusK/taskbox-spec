---
name: taskbox-library
description: How a TaskBox library for one stack is built and proven against this specification — what it implements, how it runs the conformance feature, and when it may be released
whenToUse: when building, changing, or releasing a TaskBox library for a stack (taskbox-go, taskbox-dotnet, taskbox-python, …), or reviewing whether such a library conforms to the spec
updated: 20260929
tags:
  - stack
  - concern/architecture
  - concern/testing
  - concern/testing/bdd
  - taskbox
---

# Goal
- A library that implements [the contract](../../../contract/taskbox.contract.md) at a pinned spec release, for every store it claims to support.
- A CI run of [taskbox-conformance.feature](../../../features/taskbox-conformance.feature) from that release, unchanged, green once per supported store.
- A usage skill in the library's own `doc/skills/` describing the seams a service writes in that stack.

# Core Principle
- **The spec is the source of truth** - Behaviour the contract fixes is implemented exactly; a gap is a question to the spec owner, never a local decision.
- **Proven by execution** - A library is conforming when the pinned feature passes against real stores, and the two guarantees tests miss easily are shown to be tested.
- **Mechanism only** - The library knows nothing of any service's domain and never creates tables at runtime.

# Rule

## MUST

### One repository per stack, one module per store
Build a stack's library as one repository with a store-independent core (task values, handler registry, outcome classification, worker), one module per store, and one conformance runner shared by all stores; package it by the stack's idiom.
- Violation: separate repositories per store, or one "persistent" and one "transient" library.
- Risk: the core and the runner are duplicated or versioned apart; the persistent/transient split separates no dependency (PostgreSQL and SQLite differ by driver, Redis and InMemory by design).
- Fix: Go — one module, a package per store (`pgstore`, `redisstore`, …); .NET — one solution, a project and NuGet package per store over a core package (`TaskBox`, `TaskBox.EntityFrameworkCore.PostgreSql`, `TaskBox.Redis`); Python — one distribution, a subpackage per store with its driver as an extra (`taskbox[postgres]`, `taskbox[redis]`). A service installs only the store it uses.

### Pin a spec release
Consume this repository at a release tag (git submodule at `spec/`, or the release archive in CI) and state the pinned version in the library's README.
- Risk: an unpinned spec changes under the library and its "conforms" claim stops meaning anything.
- Fix: bump the pin deliberately, in a library release that passes the new feature.

### Raise contract gaps as open questions
Record a gap or error in the contract in `OPEN-QUESTIONS.md` of this repository with a proposal, and stop that part of the work until the owner decides.
- Violation: a library adds a column, changes a Redis key, or reorders the claim "because it works better".
- Risk: libraries of different stacks drift apart; a service switched between stacks breaks on the difference.
- Fix: propose the change here; implement it after it is released in the spec.

### Run the pinned feature unchanged
Run the pinned `features/taskbox-conformance.feature` byte for byte, implementing exactly the steps in [STEP-VOCABULARY.md](../../../features/STEP-VOCABULARY.md), once per supported store, excluding only `@store-persistent` for a transient store and `@store-transient` for a durable store.
- Risk: an edited or partially run feature proves a different behaviour than every other stack.
- Fix: change the feature here, in a spec release, never in the library.

### Fail when a store is unreachable
Fail the conformance run when a store it must test cannot be reached; never skip.
- Risk: a skipped run reports conformance it never tested.
- Fix: require the store's connection setting (or start it in a container) and fail with the setting's name.

### Prove the lock and the fence are tested
Show once, and record in the README, that removing the group lock from enqueue makes "Concurrent enqueues into one group run in commit order" fail reliably, and that removing the `attempt` condition from outcome writes makes "A handler still running when its lease ends is cancelled…" fail.
- Risk: with too little real concurrency the order scenario passes without the lock (the first Go realization did: its enqueues finished before any worker ran, and its connection pool of ~4 serialized the transactions).
- Fix: run workers during the concurrent enqueues, hold transactions long enough (≈200 ms), size the pool above the number of concurrent transactions; repeat until the lock-less build fails 10/10.

### Ship the schema as files
Ship the DDL of every supported schema version as files identical to the contract's, and check the identity in CI.
- Risk: a library-generated schema (ORM migrations, runtime `CREATE TABLE`) drifts from the contract.
- Fix: consumers copy the file into their own migration history; for an ORM, verify the generated DDL equals the file.

### Release only from a green build
Tag a release only when the conformance run for every claimed store is green in CI.
- Risk: a consumer pins a release that does not conform.
- Fix: make the conformance job a required check.

### Document the seams
Write `doc/skills/taskbox-{stack}-usage.skill/` in the library: the dependency, the enqueue call inside the caller's transaction, the data port taking tasks, the handler registry as an inbound adapter, the worker's hosting, and the migration — following [taskbox-usage](../taskbox-usage.skill/taskbox-usage.skill.md).
- Risk: every consuming agent rediscovers the wiring and some get the transaction wrong.
- Fix: one usage skill per library, updated with every API change.

# Check list
- [ ] One repository: a core, one module per store packaged by the stack's idiom, one conformance runner.
- [ ] The README names the pinned spec release and the supported stores.
- [ ] CI runs the pinned feature unchanged, once per store, against real stores; a missing store fails.
- [ ] The group-lock and `attempt`-fence mutations were shown to fail the feature; the result is in the README.
- [ ] Schema files equal the contract's DDL (checked in CI).
- [ ] `doc/skills/taskbox-{stack}-usage.skill/` exists and matches the released API.
