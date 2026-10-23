# The store (Urdr): `work.db` schema 7

`work.db` holds one knowledge graph across projects: entities and immutable links with transaction-time history,
written by Ratatoskr only. The graph layer is the generic `urdr::graph` (kinds, link names and policy are the
caller's); drgnx's policy, the migration and the tracker are in `norn`. This page is being written: each section
below is filled with the change that builds it.

## Tables (Task 2)

## The writer (Task 1)

`urdr::graph::writer` (design: storage §7). One thread, `urdr-writer`, owns the only write connection to `work.db`;
nothing else in the process writes it, and no request runs SQLite on its caller's thread.

- **The connection.** The writer makes a missing file with mode 0600, then opens it with WAL, `synchronous=FULL`
  (`WriterOpts::synchronous_full`), a 5 s busy timeout and `secure_delete=ON`, so deleted cells are zeroed rather
  than left in free pages.
- **Opening is the caller's.** The generic writer knows no schema: the caller's `OpenRule` (norn's
  `migrate7::open_rule`) runs on the writer thread with the connection before the first request, and answers
  `Ready { schema }`, `NotReady(text)`, `ReadOnly { schema }` or `Failed(reason)`.
  - `NotReady` is tried again at each `WriterHandle::tick()` (the hub's schema tick).
  - `Failed` is never tried again in this process (a failed migration is not re-run every tick); writes answer its
    reason until the hub restarts.
  - `ReadOnly` (a newer schema) refuses every write.
  - A tick also re-opens when the file at the path is another file (its `(dev, inode)` changed).
  - `status()` shows the rule's last answer (`last_open`), whether the store is open, its schema, and counts of
    batches, writes and replays, with the last `COMMIT`'s time in milliseconds.
- **Group commit.** Requests arrive over a channel bounded at 256 (a write waits for room). The thread takes the
  first one and whatever arrives within `max_wait` (10 ms), up to `max_batch` (256), into one
  `BEGIN IMMEDIATE … COMMIT`, so `synchronous=FULL` costs one fsync per batch.
  - Each request runs in its own savepoint, after its `tx` row. A closure that returns an error, or panics, rolls
    back to its savepoint and gets its error (a panic is `Sql("the write panicked: …")`); the others go on.
  - **No answer leaves the thread before `COMMIT` returns.** If `COMMIT` fails, every request that would have been
    written answers `Retryable` with SQLite's text, and the transaction is rolled back; a request that had failed on
    its own keeps its own error. If SQLite rolls the whole transaction back mid-batch (a full disk, an I/O error),
    the batch answers the same way.
- **The `tx` row.** Every request inserts its `tx` row first, from its `TxMeta` (actor, class, session, profile,
  job, project, tool, req, state, reverts, imported, note). `tx.at` is `max(now, previous at)`: the previous one is
  read from the file once at open, so a clock that steps back never reorders time.
- **Request keys** (call 3, call 7). With `TxMeta.req` set, the writer looks `(actor, req)` up inside the batch's
  transaction before running anything.
  - On a hit it runs nothing and answers the stored first answer (`Written { replayed: true }`, the first tx's id).
  - On a miss it runs the closure and stores the value as JSON in `tx.answer`. An answer over 64 KiB is stored as
    `{"truncated":true}`, and its replay is refused: "the first answer was too large to replay; read the entity".
    An answer excise blanked replays as "the first answer is no longer kept; read the entity".
  - The same key twice in one batch writes once: the second finds the first's row in the same transaction.
  - Without a key, `tx.req` and `tx.answer` stay null: a key nobody can repeat would protect nothing.
  - The unique index `tx_req (actor, req)` is the second guard.
- **Maintenance** (`maintain(Scrub | Checkpoint)`) runs on the writer thread between batches, outside any
  transaction: `Scrub` is `VACUUM` then `wal_checkpoint(TRUNCATE)`, `Checkpoint` the checkpoint only. The report
  says whether the WAL was truncated and, if not, whether readers or another writer kept it.
- **Tests** reach the thread through `Writer::spawn_with_hooks` (`test-hooks`): a clock, and hooks right before and
  right after `COMMIT`. `writer::crash::kill_between_commit_and_answer` re-runs the test binary as a child that is
  `SIGKILL`ed between `COMMIT` and its answer; the parent's repeat of the same key gets the first answer and writes
  nothing.

## Entities and links (Task 2)

## Guards (Task 2)

## History (Task 3)

## Walks (Task 4)

## Search (Task 5)

## Vectors (Task 12b)

## Readers (Task 6)

## graph/sql (Task 6)

## Backup (Task 7)

## Export and import (Task 7)

## Excise (Task 8)

## The deny-list (Task 9)

## The opt-in (Task 9b)

## Scope and grants (Task 10)

## Trust (Task 10)

## Projects (Task 10)

## Migration from schema 6 (Task 11)

## Parsed entities (Task 15a)

## The one-writer gate (Task 18)
