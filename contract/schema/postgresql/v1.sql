-- TaskBox contract schema v1 (PostgreSQL) — identical to contract/taskbox.contract.md §6.
CREATE TABLE taskbox_task (
  seq             bigint GENERATED ALWAYS AS IDENTITY (CACHE 1) PRIMARY KEY,
  id              uuid        NOT NULL UNIQUE,
  status_key      uuid        UNIQUE,
  queue           text        NOT NULL DEFAULT 'default',
  queue_group     text,
  type            text        NOT NULL,
  payload         jsonb       NOT NULL,
  idempotency_key text        UNIQUE,
  status          text        NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','running','done','dead','cancelled')),
  attempt         int         NOT NULL DEFAULT 0,
  max_attempts    int         NOT NULL DEFAULT 10,
  run_at          timestamptz NOT NULL DEFAULT now(),
  locked_until    timestamptz,
  last_status     int,
  last_error      text,
  retention       interval,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  finished_at     timestamptz
);
CREATE INDEX taskbox_task_due   ON taskbox_task (queue, run_at)          WHERE status IN ('pending','running');
CREATE INDEX taskbox_task_group ON taskbox_task (queue, queue_group, seq) WHERE status IN ('pending','running','dead');
CREATE INDEX taskbox_task_done  ON taskbox_task (finished_at)            WHERE status IN ('done','cancelled');

-- One row per group; exists only to be locked by enqueuing transactions (§3).
CREATE TABLE taskbox_group (
  queue       text NOT NULL,
  queue_group text NOT NULL,
  PRIMARY KEY (queue, queue_group)
);
