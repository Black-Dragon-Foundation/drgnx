# The store (Urdr): `work.db` schema 7

`work.db` holds one knowledge graph across projects: entities and immutable links with transaction-time history,
written by Ratatoskr only. The graph layer is the generic `urdr::graph` (kinds, link names and policy are the
caller's); drgnx's policy, the migration and the tracker are in `norn`. This page is being written: each section
below is filled with the change that builds it.

## Tables (Task 2)

## The writer (Task 1)

## Entities and links (Task 2)

## Guards (Task 2)

## History (Task 3)

## Walks (Task 4)

## Search (Task 5)

## Vectors (Task 12b)

## Readers (Task 6)

Reads never go through the writer. `urdr::graph::ReadPool` (`graph/pool.rs`) holds a few connections (the hub uses
2–4) opened with `urdr::open_readonly`: `file:…?mode=ro`, so a reader can neither write nor checkpoint the WAL, even
when it is the last connection to close. Connections are opened when first needed and reused.

- `ReadPool::open(path, size)` is lazy and cannot fail; `pool.with(|conn| …).await` waits for a free connection,
  runs the closure on tokio's blocking pool (SQLite never runs on an async worker) and gives the connection back.
  It fails only when no connection can be opened.
- The closure is synchronous, so a caller cannot hold a connection across an await. A long reader (a walk) takes
  one connection per step rather than one for its whole run.
- A connection the closure leaves inside a transaction is closed instead of given back: an open read transaction
  pins a WAL snapshot and would block checkpoints.

## graph/sql (Task 6)

`graph/sql` is the user's read-only escape hatch into the whole store (user class only). Its runner,
`urdr::graph::sqlro::run(pool, sql, params, deadline, row_cap)`, opens a dedicated `mode=ro` connection per call, not
a pool connection, and hardens it before preparing anything:

- **Defensive mode on, schema untrusted:** `SQLITE_DBCONFIG_DEFENSIVE` on and `SQLITE_DBCONFIG_TRUSTED_SCHEMA` off.
- **An authorizer** that allows only `SQLITE_SELECT`, `SQLITE_READ` and `SQLITE_FUNCTION`. Within functions it
  refuses `load_extension` and `fts3_tokenizer` by name: the bundled SQLite compiles extension loading and FTS3 in,
  and the authorizer must not depend on their API switches staying off. Everything else is refused: writes, DDL,
  `ATTACH`, `PRAGMA`, transactions and savepoints, and recursive CTEs (walks are the graph tool's job). The
  authorizer stays installed for the connection's life, because SQLite may re-prepare a statement during a step.
  This also covers statements that only act when they run: a pragma's table-valued function (`pragma_table_info`)
  prepares a `PRAGMA` when it runs, and `VACUUM` (including `VACUUM INTO`) attaches a database when it runs; both
  are refused at that point.
- **Lowered limits** on that connection only, because the progress handler cannot interrupt a single opcode
  (`randomblob(999999999)` would allocate about 1 GB first): `LENGTH` 1,000,000, `SQL_LENGTH` 100,000,
  `ATTACHED` 0, `EXPR_DEPTH` 100, `COMPOUND_SELECT` 50, `FUNCTION_ARG` 8, `LIKE_PATTERN_LENGTH` 1,000. The
  process-wide heap limit is not used: it would also bind the writer.
- **One statement:** a second statement after the first is refused (a trailing `;`, blanks or comments are fine).
- **A deadline** through the progress handler (callers default to 2 s) and **a row cap** (default 1,000; the
  answer says `truncated`).

Parameters are JSON values, bound positionally (booleans as 0/1, arrays and objects as their JSON text). The answer
is `Rows { columns, rows, truncated }`, each row an array of JSON values; a blob is shown as `{"blob": LEN}` and a
non-finite real as `null`. A refusal is `SqlRefusal::NotAllowed(action)` (the first refused action: `attach`,
`pragma`, `insert`, `recursive`, `load_extension`, …; DDL often reports `insert` or `delete`, SQLite's check on the
schema table, before its own code), `Deadline`, `TooManyStatements`, or `Sql(text)` for SQLite's own errors, such as
"string or blob too big" when a value passes `LENGTH`.

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
