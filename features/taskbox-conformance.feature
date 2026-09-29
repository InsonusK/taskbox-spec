Feature: TaskBox conformance
  Every stack realization of the TaskBox storage contract (VP-C003) passes these
  scenarios, once per store it supports.

  Background:
    Given the TaskBox settings:
      | setting           | value |
      | lease             | 2s    |
      | backoff base      | 100ms |
      | backoff cap       | 1s    |
      | default retention | 1h    |
      | poll interval     | 20ms  |
      | partitions        | 4     |

  Rule: A committed task runs once; a rolled-back one never runs

    @happy
    Scenario: Only the committed enqueue runs, exactly once
      Given the handler for "send-mail" answers:
        | attempt | status |
        | *       | 200    |
      When these tasks are enqueued in a transaction that rolls back:
        | task | type      |
        | a    | send-mail |
      And these tasks are enqueued in a transaction that commits:
        | task | type      |
        | b    | send-mail |
      And 2 workers run for 1s
      Then the tasks are:
        | task | status | attempt | runs | last status | finished |
        | a    | absent |         | 0    |             |          |
        | b    | done   | 1       | 1    | 200         | yes      |

  Rule: A handler's outcome is an HTTP status code

    @error
    Scenario: A retryable code is retried with a growing delay until the task is dead
      Given the handler for "flaky" answers:
        | attempt | status |
        | *       | 503    |
      When these tasks are enqueued in a transaction that commits:
        | task | type  | max attempts |
        | t    | flaky | 3            |
      And 1 worker runs for 2s
      Then the tasks are:
        | task | status | attempt | runs | last status | finished |
        | t    | dead   | 3       | 3    | 503         | yes      |
      And the runs of "t" started at least these gaps apart:
        | between attempts | at least |
        | 1 and 2          | 200ms    |
        | 2 and 3          | 400ms    |

    @error
    Scenario Outline: Every retryable code is retried
      Given the handler for "call" answers:
        | attempt | status   |
        | 1       | <status> |
        | *       | 200      |
      When these tasks are enqueued in a transaction that commits:
        | task | type |
        | t    | call |
      And 1 worker runs for 1s
      Then the tasks are:
        | task | status | attempt | runs | last status |
        | t    | done   | 2       | 2    | 200         |

      Examples:
        | status |
        | 408    |
        | 429    |
        | 500    |
        | 502    |
        | 503    |
        | 504    |

    @error
    Scenario: A Retry-After longer than the backoff is honoured
      Given the handler for "call" answers:
        | attempt | status | retry after |
        | 1       | 503    | 1s          |
        | *       | 200    |             |
      When these tasks are enqueued in a transaction that commits:
        | task | type |
        | t    | call |
      And 1 worker runs for 2s
      Then the tasks are:
        | task | status | attempt | runs |
        | t    | done   | 2       | 2    |
      And the runs of "t" started at least these gaps apart:
        | between attempts | at least |
        | 1 and 2          | 1s       |

    @negative
    Scenario Outline: A non-retryable code sends the task to dead on the first attempt
      Given the handler for "call" answers:
        | attempt | status   |
        | *       | <status> |
      When these tasks are enqueued in a transaction that commits:
        | task | type |
        | t    | call |
      And 1 worker runs for 1s
      Then the tasks are:
        | task | status | attempt | runs | last status | finished |
        | t    | dead   | 1       | 1    | <status>    | yes      |

      Examples:
        | status |
        | 400    |
        | 404    |
        | 409    |
        | 422    |

    @error
    Scenario: An exception counts as 500 and is retried
      Given the handler for "call" answers:
        | attempt | error |
        | *       | boom  |
      When these tasks are enqueued in a transaction that commits:
        | task | type | max attempts |
        | t    | call | 2            |
      And 1 worker runs for 1s
      Then the tasks are:
        | task | status | attempt | runs | last status | last error |
        | t    | dead   | 2       | 2    | 500         | boom       |

    @error
    Scenario: A task whose type has no handler is retried, not dropped
      Given no handler is registered for "later"
      When these tasks are enqueued in a transaction that commits:
        | task | type  |
        | t    | later |
      And 1 worker runs for 500ms
      Then the tasks are:
        | task | status  | runs | last status |
        | t    | pending | 0    | 503         |
      When the handler for "later" answers:
        | attempt | status |
        | *       | 200    |
      And 1 worker runs for 2s
      Then the tasks are:
        | task | status | runs | last status |
        | t    | done   | 1    | 200         |

  Rule: A lease bounds every run

    @error
    Scenario: A task whose worker dies is claimed again after its lease
      Given the handler for "call" answers:
        | attempt | status |
        | *       | 200    |
      When these tasks are enqueued in a transaction that commits:
        | task | type |
        | t    | call |
      And a worker claims "t" and stops without an outcome
      And 1 worker runs for 1s
      Then the tasks are:
        | task | status  | attempt | runs |
        | t    | running | 1       | 0    |
      When 1 worker runs for 2s
      Then the tasks are:
        | task | status | attempt | runs |
        | t    | done   | 2       | 1    |

    # Attempt 1's late 400 arrives while attempt 2 still runs: only fencing by attempt keeps it out.
    @concurrency
    Scenario: A handler still running when its lease ends is cancelled and its late outcome is discarded
      Given the handler for "slow" answers:
        | attempt | status | delay  |
        | 1       | 400    | 3s     |
        | *       | 200    | 1500ms |
      When these tasks are enqueued in a transaction that commits:
        | task | type |
        | t    | slow |
      And 2 workers run for 5s
      Then the tasks are:
        | task | status | attempt | runs | last status |
        | t    | done   | 2       | 2    | 200         |
      And the run of "t" attempt 1 saw its cancellation

    @concurrency
    Scenario: Two workers never run the same task at the same time
      Given the handler for "work" answers:
        | attempt | status | delay |
        | *       | 200    | 20ms  |
      When 40 tasks of type "work" are enqueued
      And 4 workers run for 2s
      Then every task is "done" after exactly 1 run
      And no task had two runs at the same time

  Rule: Tasks of one group run one at a time in seq order

    # Workers run during the enqueues, so a task committed ahead of a lower seq would be claimed first.
    @concurrency
    Scenario: Concurrent enqueues into one group run in commit order
      Given the handler for "work" answers:
        | attempt | status | delay |
        | *       | 200    | 10ms  |
      When 4 workers are started
      And 20 tasks of type "work" in group "g" are enqueued concurrently, each transaction held open up to 200ms after its insert
      And the workers are stopped after 2s
      Then every task is "done" after exactly 1 run
      And the tasks of group "g" ran one at a time in seq order

    @concurrency
    Scenario: Tasks of different groups run in parallel
      Given the handler for "slow" answers:
        | attempt | status | delay |
        | *       | 200    | 300ms |
      When these tasks are enqueued in a transaction that commits:
        | task | type | group    |
        | x    | slow | group-a  |
        | y    | slow | group-b  |
      And 2 workers run for 1s
      Then the runs of "x" and "y" overlapped

    @error
    Scenario: A retrying head task holds back the rest of its group
      Given the handler for "flaky" answers:
        | attempt | status |
        | 1       | 503    |
        | *       | 200    |
      And the handler for "ok" answers:
        | attempt | status |
        | *       | 200    |
      When these tasks are enqueued in a transaction that commits:
        | task | type  | group |
        | t1   | flaky | g     |
        | t2   | ok    | g     |
      And 2 workers run for 1s
      Then the tasks ran in this order:
        | task |
        | t1   |
        | t1   |
        | t2   |

    @boundary
    Scenario: A delayed head task holds back the rest of its group
      Given the handler for "ok" answers:
        | attempt | status |
        | *       | 200    |
      When these tasks are enqueued in a transaction that commits:
        | task | type | group | run at |
        | t1   | ok   | g     | +1s    |
        | t2   | ok   | g     |        |
      And 2 workers run for 2s
      Then the tasks ran in this order:
        | task |
        | t1   |
        | t2   |

    @boundary
    Scenario: A delayed task does not run before its run at
      Given the handler for "ok" answers:
        | attempt | status |
        | *       | 200    |
      When these tasks are enqueued in a transaction that commits:
        | task | type | run at |
        | t    | ok   | +1s    |
      And 1 worker runs for 500ms
      Then the tasks are:
        | task | status  | runs |
        | t    | pending | 0    |
      When 1 worker runs for 1s
      Then the tasks are:
        | task | status | runs |
        | t    | done   | 1    |
      And the first run of "t" started no earlier than its run at

  Rule: A dead task stops its group until a person requeues or cancels it

    @error
    Scenario: A dead task stops its group while other groups keep running
      Given the TaskBox setting "partitions" is 1
      And the handler for "fail" answers:
        | attempt | status |
        | *       | 400    |
      And the handler for "ok" answers:
        | attempt | status |
        | *       | 200    |
      When these tasks are enqueued in a transaction that commits:
        | task | type | group |
        | t1   | fail | g     |
        | t2   | ok   | g     |
        | u1   | ok   | h     |
      And 2 workers run for 1s
      And these tasks are enqueued in a transaction that commits:
        | task | type | group |
        | t3   | ok   | g     |
        | u2   | ok   | h     |
      And 2 workers run for 1s
      Then the tasks are:
        | task | status  | runs |
        | t1   | dead    | 1    |
        | t2   | pending | 0    |
        | t3   | pending | 0    |
        | u1   | done    | 1    |
        | u2   | done    | 1    |

    @happy
    Scenario: Requeue resumes the group in the original order
      Given the TaskBox setting "partitions" is 1
      And the handler for "fail" answers:
        | attempt | status |
        | *       | 400    |
      And the handler for "ok" answers:
        | attempt | status |
        | *       | 200    |
      When these tasks are enqueued in a transaction that commits:
        | task | type | group |
        | t1   | fail | g     |
        | t2   | ok   | g     |
      And 1 worker runs for 1s
      And these tasks are enqueued in a transaction that commits:
        | task | type | group |
        | t3   | ok   | g     |
      And the handler for "fail" answers:
        | attempt | status |
        | *       | 200    |
      And task "t1" is requeued
      And 1 worker runs for 1s
      Then the tasks are:
        | task | status | attempt | runs |
        | t1   | done   | 1       | 2    |
        | t2   | done   | 1       | 1    |
        | t3   | done   | 1       | 1    |
      And the tasks ran in this order:
        | task |
        | t1   |
        | t1   |
        | t2   |
        | t3   |

    @happy
    Scenario: Cancel resumes the group without the dead task
      Given the TaskBox setting "partitions" is 1
      And the handler for "fail" answers:
        | attempt | status |
        | *       | 400    |
      And the handler for "ok" answers:
        | attempt | status |
        | *       | 200    |
      When these tasks are enqueued in a transaction that commits:
        | task | type | group |
        | t1   | fail | g     |
        | t2   | ok   | g     |
      And 1 worker runs for 1s
      And task "t1" is cancelled
      And 1 worker runs for 1s
      Then the tasks are:
        | task | status    | runs | finished |
        | t1   | cancelled | 1    | yes      |
        | t2   | done      | 1    | yes      |
      And the tasks ran in this order:
        | task |
        | t1   |
        | t2   |

  Rule: An idempotency key admits one task for as long as the first one is kept

    @negative
    Scenario: A repeated idempotency key adds no task
      Given the handler for "ok" answers:
        | attempt | status |
        | *       | 200    |
      When these tasks are enqueued in a transaction that commits:
        | task | type | idempotency key |
        | a    | ok   | order-42        |
      And 1 worker runs for 500ms
      And these tasks are enqueued in a transaction that commits:
        | task | type | idempotency key |
        | b    | ok   | order-42        |
      And 1 worker runs for 500ms
      Then the tasks are:
        | task | status | runs |
        | a    | done   | 1    |
        | b    | absent | 0    |

    @boundary
    Scenario: An idempotency key keeps blocking while its task waits longer than the retention
      Given the TaskBox setting "default retention" is 1s
      And the handler for "ok" answers:
        | attempt | status |
        | *       | 200    |
      When these tasks are enqueued in a transaction that commits:
        | task | type | idempotency key | run at |
        | a    | ok   | order-42        | +3s    |
      And 1500ms pass
      And the retention cleanup runs
      And these tasks are enqueued in a transaction that commits:
        | task | type | idempotency key |
        | b    | ok   | order-42        |
      Then the tasks are:
        | task | status  |
        | a    | pending |
        | b    | absent  |

    @boundary
    Scenario: An idempotency key is free again once its task is removed
      Given the TaskBox setting "default retention" is 1s
      And the handler for "ok" answers:
        | attempt | status |
        | *       | 200    |
      When these tasks are enqueued in a transaction that commits:
        | task | type | idempotency key |
        | a    | ok   | order-42        |
      And 1 worker runs for 500ms
      And 1500ms pass
      And the retention cleanup runs
      And these tasks are enqueued in a transaction that commits:
        | task | type | idempotency key |
        | b    | ok   | order-42        |
      Then the tasks are:
        | task | status  |
        | a    | absent  |
        | b    | pending |

  Rule: Finished tasks are removed after max(default, own retention)

    @boundary
    Scenario: Done and cancelled tasks are removed after their effective retention
      Given the TaskBox setting "default retention" is 1s
      And the handler for "ok" answers:
        | attempt | status |
        | *       | 200    |
      And the handler for "fail" answers:
        | attempt | status |
        | *       | 400    |
      When these tasks are enqueued in a transaction that commits:
        | task | type | retention |
        | a    | ok   |           |
        | b    | ok   | 1h        |
        | c    | fail |           |
      And 1 worker runs for 500ms
      And task "c" is cancelled
      And 1500ms pass
      And the retention cleanup runs
      Then the tasks are:
        | task | status |
        | a    | absent |
        | b    | done   |
        | c    | absent |

    @boundary @store-persistent
    Scenario: A dead task in a persistent store is never removed
      Given the TaskBox setting "default retention" is 1s
      And the handler for "fail" answers:
        | attempt | status |
        | *       | 400    |
      When these tasks are enqueued in a transaction that commits:
        | task | type |
        | d    | fail |
      And 1 worker runs for 500ms
      And 1500ms pass
      And the retention cleanup runs
      Then the tasks are:
        | task | status |
        | d    | dead   |

    @boundary @store-transient
    Scenario: A dead task in a transient store ends with its lifetime and its group resumes
      Given the TaskBox setting "default retention" is 1s
      And the handler for "fail" answers:
        | attempt | status |
        | *       | 400    |
      And the handler for "ok" answers:
        | attempt | status |
        | *       | 200    |
      When these tasks are enqueued in a transaction that commits:
        | task | type | group |
        | d    | fail | g     |
        | e    | ok   | g     |
      And 1 worker runs for 500ms
      And 1500ms pass
      And 1 worker runs for 500ms
      Then the tasks are:
        | task | status    | runs |
        | d    | cancelled | 1    |
        | e    | done      | 1    |
