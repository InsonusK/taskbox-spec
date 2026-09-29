# taskbox-conformance.feature — step vocabulary and rules

## Goal
- One executable statement of the contract's conformance scenarios that every stack runs unchanged, so "conforms to VP-C003" means the same feature file passed, whatever the language.

## Principles
- The feature is **store-agnostic**: it talks about tasks, handlers, workers, and transactions; the stack's runner binds each step to the store under test and runs the whole feature once per store it supports.
- Timings are **settings of the run** (lease, backoff, retention, poll interval), not the service defaults — the contract makes them configurable per service, and short values keep the run fast.
- Task aliases (`a`, `t1`, …) name tasks inside one scenario; the runner maps them to the task ids it generated.

## Step vocabulary
The runner implements exactly these steps; an empty table cell means "not set" (enqueue) or "not checked" (assertion).

| Step | Meaning |
| --- | --- |
| `the TaskBox settings:` | table `setting`/`value`: `lease`, `backoff base`, `backoff cap`, `default retention`, `poll interval`, `partitions` (Redis only; other stores ignore it) |
| `the TaskBox setting "<setting>" is <value>` | overrides one setting for this scenario |
| `the handler for "<type>" answers:` | registers (or replaces) a scripted handler; table `attempt` (`*` = any), `status`, `retry after`, `delay` (the handler keeps running this long **ignoring cancellation**), `error` (the handler raises this instead of returning a status) |
| `no handler is registered for "<type>"` | removes the handler |
| `these tasks are enqueued in a transaction that commits:` / `…that rolls back:` | one transaction; table `task`, `type`, `group`, `run at` (`+1s` = relative to now), `max attempts`, `idempotency key`, `retention` |
| `<n> tasks of type "<type>" are enqueued` | `n` ungrouped tasks, one committed transaction each |
| `<n> tasks of type "<type>" in group "<group>" are enqueued concurrently, each transaction held open up to <duration> after its insert` | `n` parallel transactions, each holding its transaction open a random time before committing |
| `<n> worker(s) run(s) for <duration>` | starts `n` workers on the queue, stops them after `duration` (`1 worker runs for 1s`, `2 workers run for 1s`) |
| `<n> worker(s) (is\|are) started` / `the workers are stopped after <duration>` | the same, split so that other steps run while the workers do |
| `a worker claims "<task>" and stops without an outcome` | claims the task through the store and abandons it (a dying worker) |
| `task "<task>" is requeued` / `task "<task>" is cancelled` | the dead-task operations |
| `<duration> pass` / `the retention cleanup runs` | waiting; one cleanup pass (a no-op for a store whose entries expire by themselves) |
| `the tasks are:` | read back from the store; table `task` plus any of `status` (`absent` = not in the store), `attempt`, `runs`, `last status`, `last error`, `finished` (`yes`/`no`) |
| `every task is "<status>" after exactly <n> run(s)` | over every task of the scenario |
| `no task had two runs at the same time` | over every recorded run |
| `the tasks ran in this order:` | table `task`: the sequence of run starts of the listed tasks |
| `the tasks of group "<group>" ran one at a time in seq order` | run starts ascend by `seq`, and no two runs of the group overlap |
| `the runs of "<task>" and "<task>" overlapped` | the two tasks ran in parallel |
| `the runs of "<task>" started at least these gaps apart:` | table `between attempts` (`1 and 2`), `at least` |
| `the run of "<task>" attempt <n> saw its cancellation` | the handler observed its context/token cancelled |
| `the first run of "<task>" started no earlier than its run at` | delayed-task check |

Tags beyond the type tag: `@store-persistent` — run only against a VP-C001 store; `@store-transient` — only against a VP-C002 store.

## Rules for every stack library


### Run the pinned feature unchanged
Run `features/taskbox-conformance.feature` of a pinned release of this repository unchanged — fetched (submodule or release download), never copied and edited.
- Violation: a stack drops a scenario that is hard to implement, or rewords a step to fit its runner.
- Risk: two stacks both "pass conformance" while testing different behaviour, and a service switched between them breaks on the difference.
- Fix: implement the step in the runner; if a scenario is wrong for every stack, change it here and in the contract §8 together, in one release.

### Run the feature once per supported store
Run the whole feature against every store the stack realization supports, excluding only `@store-persistent` scenarios for a VP-C002 store and `@store-transient` scenarios for a VP-C001 store.
- Risk: a store that was never run against the feature carries untested ordering, lease, or retention behaviour.
- Fix: parameterize the runner by store; one test run per store.

### Never skip a scenario for lack of a store
Fail — never skip — a scenario whose store is unreachable in the run.
- Risk: a runner that skips when the database is missing reports green without having tested anything.
- Fix: require the store's connection setting; its absence is a failed run with a message naming the setting.

### Verify the order scenario catches a missing group lock
Mutation-test "Concurrent enqueues into one group run in commit order" once per stack by removing the group lock from enqueue; the scenario must fail.
- Risk: with too little concurrency the scenario passes without the lock, so it proves nothing about commit order.
- Fix: raise the task count or the hold time until the lock-less build fails reliably, then restore the lock.

## Check list
- [ ] The library's CI runs `taskbox-conformance.feature` of the pinned spec release, unchanged.
- [ ] The runner implements every step in [# Step vocabulary](#step-vocabulary), and nothing else.
- [ ] One run per supported store; only the `@store-*` exclusions apply.
- [ ] A missing store connection fails the run.
- [ ] The group-order scenario was seen failing with the group lock removed.
