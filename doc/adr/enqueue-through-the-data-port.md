---
name: enqueue through the data port that owns the transaction
description: How a domain service gets a TaskBox task written in the same transaction as the data change that triggered it
problem: The domain decides that a data change needs a follow-up task, but the transaction belongs to the store adapter behind a domain port — how does the task reach that transaction without the domain knowing about transactions or TaskBox?
decision: The data port's write method takes the tasks as plain domain values next to the data; its adapter writes the data and enqueues each task inside its own transaction. A stand-alone enqueue port exists only for tasks with no data change behind them.
---

# Problem
TaskBox makes a follow-up atomic with its data change only when both are written in one transaction of one store (VP-C003 concept). In the ports-and-adapters layout every catalog uses, the domain talks to narrow, business-named ports (`LinkHistory.Record`), and the transaction is an internal detail of the store adapter. The domain must be able to say "and schedule this" without opening transactions or importing TaskBox.

# Selected variant
[Tasks passed to the data port (selected)](#tasks-passed-to-the-data-port-selected)

# Searched variants

## Tasks passed to the data port (selected)

### Description
A plain domain value `Task {Type, Payload, Group, RunAt, …}` is declared beside the ports. A write method that can trigger follow-ups takes them: `Record(ctx, entry, tasks ...Task)`. The adapter opens its transaction, writes the entry, calls TaskBox `enqueue(tx, …)` for each task, and commits.

### Benefits
- Atomicity is visible in the signature: a reader sees which writes carry follow-ups.
- The domain stays free of transactions, stores, and TaskBox types; its tests assert the tasks it passed with a stub port.
- A task cannot be enqueued "outside" the change by mistake — there is no transaction handle to forget.

### Costs
- Every write method that can trigger follow-ups grows a parameter.
- A domain operation that writes through two ports cannot make both atomic; it needs one port method for the combined write.

## Unit of work carried in the context

### Description
A `UnitOfWork.Do(ctx, func(ctx) error)` port starts a transaction and puts it into the context; every adapter and the enqueue port pick it up from there.

### Benefits
- Any number of ports join one transaction without new methods.

### Costs
- The transaction is invisible: an enqueue called outside `Do` silently runs in its own transaction, which is exactly the non-atomic write TaskBox exists to prevent.
- Every adapter must look for a transaction in the context; a forgotten lookup breaks atomicity without failing any test.

## The adapter decides on its own

### Description
The store adapter inspects the data it writes and enqueues follow-ups itself (for example, "flagged → schedule a re-check").

### Benefits
- No port change at all.

### Costs
- A business rule — when a follow-up is needed — moves into infrastructure, where domain tests cannot see it.
