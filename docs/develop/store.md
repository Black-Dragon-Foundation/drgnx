# The store (Urdr): `work.db` schema 7

`work.db` holds one knowledge graph across projects: entities and immutable links with transaction-time history,
written by Ratatoskr only. The graph layer is the generic `urdr::graph` (kinds, link names and policy are the
caller's); drgnx's policy, the migration and the tracker are in `norn`. This page is being written: each section
below is filled with the change that builds it.

## Tables (Task 2)

`urdr::graph::schema::GRAPH_DDL` creates the graph tables in one `execute_batch`: `tx`, `entity`, `entity_hist`,
`link`, `link_stat`, `entity_fts`, `entity_vec`, `project_alias`, `excise_log`, with their indexes. There are no
triggers and no foreign keys; the primitives write versions, FTS rows and stats in the caller's tx, and a test
(`urdr/tests/one_write_path.rs`) fails when other Rust code writes these tables.

- `tx.answer` holds a keyed request's answer (at most 64 KiB, else `{"truncated": true}`); `entity_vec.model` names
  the embedding model, so `vec_stale` can list entities without a vector of a model; `entity_hist` also keeps each
  version's lease (`lease_holder`, `lease_epoch`, `lease_until`), `origin` and `retired_tx`, so an as-of read shows
  them as they were (URDR-HIST-RETIRED-1). All three are departures from the design's sketch.
- `entity.n` is an explicit integer key: the FTS rowid and the link ends. Entities are never deleted, so `n` is
  never reused.
- `entity_fts` is `fts5(title, body, content='', contentless_delete=1)`. The DDL ends with
  `insert into entity_fts(entity_fts, rank) values('secure-delete', 1)` (FTS5 before 3.42.0 cannot read the table
  afterwards; no Lisp reader opens it), and the writer runs with `secure_delete=ON`, so deleted cells and freed
  pages are zeroed. FTS5's `secure-delete` alone does not remove a deleted row's tokens here: a contentless-delete
  table only tombstones the rowid (removing terms in place needs the old values, which such a table refuses). So
  `search::fts_delete` follows the delete with `optimize`, which rewrites the index without tombstoned entries;
  only then do a deleted row's tokens, and those of versions `fts_put` replaced, leave the file.
- A current link has `tx_to = SENTINEL` (2^62). Current reads plan on `link_cur`, as-of reads on `link_out` or
  `link_in` (`tx_to > T`, `tx_from <= T`).

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
    batches, writes and replays, with the last `COMMIT`'s time in milliseconds. `texts` counts the writes that put
    an entity's text (`search::fts_put`: a new entity, a changed title or body, a restored version, an import).
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
    An answer excise blanked (`[excised <tx>]`, never a JSON value) replays as "this answer was excised; read the
    entity"; a null answer as "the first answer is no longer kept; read the entity".
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

All in `urdr::graph::{entity, link}`; every function takes the write's `&mut Tx`.

- `entity::create` inserts at `ver = 1` with `field_tx` naming the tx for each non-null field (`data` only when not
  `{}`) and the FTS row; a duplicate `id` is `Refused("id exists")`.
- `entity::update(tx, n, expect_ver, changes)`:
  - A stale `expect_ver` answers `Conflict { ver, changed_since }` and writes nothing. `changed_since` lists the
    fields whose `field_tx` is newer than the tx that wrote the caller's version, each with its new value, the
    tx's actor and class.
  - Otherwise the old row goes to `entity_hist` (`tx_from` = its `updated_tx`, `tx_to` = this tx), the changes
    apply (`data_patch` is an RFC 7396 merge patch), `ver` and `field_tx` and `updated_tx` follow.
  - Title or body changes delete and re-insert the FTS row by rowid (never a partial `UPDATE`) and drop the
    entity's vector ("Search" below).
  - A change that changes nothing writes nothing and answers `Done` with the current `ver`.
- `entity::retire` sets `retired_tx` as a new version; the row stays.
- `entity::set_version` (crate-private) gives an entity a new version holding an older version's fields and, when
  asked, a new `retired_tx` (`None` un-retires); the lease stays. History's revert and restore write through it, so
  every entity version, its `entity_hist` row and its FTS row are written in `entity.rs`.
- `link::add` refuses a missing or retired end and answers `existed: true` for a current `(src, kind, dst)`; `data`
  is set once. `link::retire` and `retire_by_source` set `tx_to`; a re-add is a new row. `link::stat_bump` counts in
  `link_stat`, unversioned.
- Readers: `entity::{by_id, by_n}` answer the current row, retired or not.

## Guards (Task 2)

`urdr::graph::guard::Guard` maps an entity kind (and a `kv` key prefix) to the one class allowed to write it, with
the refusal text. Urdr knows no kind: norn registers drgnx's rules. `entity::{create, update, retire}` call
`guard::check` with the tx's class before writing, on every path (proposed txs and imports included), and the `kv`
writer calls `guard::check_key`. An unregistered kind or key passes; a class other than the registered one gets
`Refused(<text>)`.

A kind may also carry a rule (`guard::register_rule(&mut guard, kind, rule)`) that decides from the write itself:
`rule(conn, &meta, at, Target { id, project, origin })`, where `project` is the entity's project after the write (an
update's new one) and `origin` the origin a create gives it (`None` for a write to a stored entity, which keeps its
origin). Every entity write (`create`, `update`, `retire`, `unretire`, revert and restore, import) calls
`guard::check_entity(tx, kind, target)`, which runs the kind's class check and then its rule. norn registers one
rule, for kind `option` (below, "Settings history and grants").

## History (Task 3)

`urdr::graph::hist` reads and rewrites the past. It is policy-free: the caller checks the class (user only).

- **As of a tx.** `tx_at(conn, at)` is the last tx at or before a time. `entity_as_of(conn, n, tx)` answers the
  current row if `updated_tx <= tx`, else the `entity_hist` row that held at `tx` (one seek on `entity_hist_tx`:
  the first `tx_to` past `tx`), none before creation. `approximate` is true when that version's tx is `imported`.
  Every `entity_hist` row keeps its version's lease, origin and `retired_tx` (written by `to_hist` with the fields),
  so an old version answers them as they were: an entity retired and later brought back is retired as of the time
  between, a lease held then is held; the source is the entity's. `links_as_of(conn, n, kinds, direction,
  tx)` is `tx_from <= tx < tx_to` on `link_out` / `link_in`.
- **Who changed what.** `history(conn, n, since)` lists versions (tx, time, actor, class, tool, session, the fields
  that version set, from `field_tx`; `retired` for the retiring version; `since` is inclusive).
  `link_history(conn, n)` lists a link's rows with the authors of `tx_from` and `tx_to`.
- **Revert.** `revert(tx, target)` gives every entity the target wrote a version of its previous state as a new
  version (an entity the target created is retired; one it retired is un-retired), retires the links the target
  added and adds again, as new rows, those it retired; the new tx's `reverts` names the target. If any such
  entity has a later version by another tx, nothing is written and the answer is `Blocked { later }`. Reverting a
  revert follows the same rule. `restore(tx, n, ver)` sets the fields of an old version (a new version; retirement
  untouched).
- **Proposed txs.** `settle_proposed(tx, txs, accept)` marks proposed txs `accepted`, or reverts them newest first
  (the batch's own earlier reverts are not "later changes"; a block rolls the whole call back) and marks them
  `reverted`. Any other state is refused. The settling tx is the user's record of the decision.
- **Limits.** A revert finds the links a tx added with a scan of `link` by `tx_from` (no index; reverts are rare).
## Walks (Task 4)

`urdr::graph::walk` answers `neighbors` and `path` from the read pool (storage §6.2). Both are async; each level is
one `ReadPool::with` call (one connection, given back before the next level), never held across an await.

- **Levels.** One level reads, in that call: the degree of each frontier node, then `select src, kind, dst from
  link where src in (…)` (or `dst in …` for incoming; both for `Both`) in chunks of 500 ids, with the `kind in (…)`
  filter and the live form (`tx_to = SENTINEL`) or the as-of form (`tx_from <= T and tx_to > T`), then the entity
  rows (`n, project, kind, id, title`) of the nodes reached that the walk does not have yet. The visited set holds
  nodes; every link between two nodes of the answer is listed once.
- **Retired and as-of.** A current walk reads only entities with `retired_tx is null` (search's rule): a retired
  entity is neither answered, followed, counted in `hidden` nor named by a link, and a retired root or path end
  answers nothing. An as-of walk reads each entity through `hist::entity_as_of` (its fields at that tx; one created
  later, or retired by then, is left out) and links with `links_as_of`'s `tx_from <= T < tx_to`.
- **Path.** Bidirectional: the forward side follows outgoing links from `from`, the backward side incoming links
  from `to`. It expands the smaller frontier a whole level at a time and, once a level meets the other side, answers
  the shortest meeting. No path: an empty answer, with `truncated: depth` when `max_depth` stopped it.
- **Budget.** 20,000 visited nodes (`budget`), 200 nodes in the answer (`cap`), and a 250 ms deadline armed as a
  SQLite progress handler on the level's connection (every 1000 VM steps; cleared before the connection goes back),
  so a slow statement is interrupted, not waited for. `kinds` is required past depth 3
  (`Refused("name kinds for depth over 3")`); depth is clamped to 16 (`truncated: depth`). A stopped walk answers
  what it found with `truncated`: `budget`, `deadline`, `depth`, `cap` or `scope`.
- **Hot nodes.** A node with more than `hot_degree` (1,000) live links in the walked direction(s), counted over
  `link` with a bound of `hot_degree + 1` (so a hot node costs a bounded scan), is answered with `hot: <degree>`
  and not expanded. `link_stat` counts repeats of a pair and has no index by `dst`, so it is not used.
- **Scope.** `Scope::allows(project)` decides per entity: `Hidden` is not followed, counted in `hidden`, and no
  link naming it is answered; `Stub` shows `id`, `kind` and `title` only (no project) and is followed. `valid()` is
  asked before the first level and before each next one; false stops with `truncated: scope`.
- **Bench.** `benches/walk.rs` (ignored; `--features test-hooks`) builds graph B with `walk::synthetic`.

## Search (Task 5)

`urdr::graph::search` holds full text, the vector scheme and rank fusion. Nothing in it knows a kind.

- **Full text.** `entity_fts(title, body)` is contentless with delete; its rowid is `entity.n`. `fts_put` deletes the
  row and inserts it (never an `UPDATE`), `fts_delete` deletes by rowid and then runs `optimize` so the tokens leave
  the file ("Tables"); the entity primitives call them (the only FTS write path) in the same transaction as the
  change. `find_fts(conn, q, limit)` takes the words of `q` (letters, digits, `_`), quotes each,
  and joins them with `OR`: no operator, column filter, prefix star or `NEAR` from a query reaches FTS5, and a query with
  no word answers nothing. Retiring an entity keeps its FTS row, so `find_fts` answers only live entities
  (`retired_tx is null`). Hits are ranked by `bm25(entity_fts, 5, 1)` (a title match counts five body matches;
  lower is better). A contentless table cannot make snippets, so they come from `entity.body` (about 160 characters
  around the first matching word; the title when there is no body).
- **Vectors.** `vec::quantize` is `drgnx-search-quantize`: sign bits (bit `i % 8` of byte `i / 8`), int8 values
  `round(v / scale)` (halves to even) and `scale = max|v| / 127`. `entity_vec(n, bits, vec, scale, model)` holds them;
  `model` is a departure from the design's §5.2 table, needed by `vec_stale`. `hamming_scan` ranks fingerprints by
  Hamming distance (u64 popcount, a bounded heap) and `rerank` orders the candidates by the integer dot product
  of the int8 vectors times both scales. Fixtures: `test/fixtures/quantize/cases.json`, regenerated with `gen.el`
  from the Lisp quantizer.
- **Fusion.** `rrf(lists, 60)` sums `1 / (k + rank)` over the lists (rank from 1), best first.
- **Staleness.** `vec_put` replaces an entity's vector; `vec_stale(conn, model, limit)` lists live entities with
  text and no vector of that model (the indexer's work list; Task 12b supplies the `Embedder`). A vector is always
  of its entity's current text: `fts_put`, which every write of a new title or body goes through, deletes the
  entity's `entity_vec` row in the same tx, so `vec_stale` lists it again and no vector of an old text is kept.
  (Chosen over a vector that records the version it was made from and a `vec_stale` that lists mismatches: that
  needs a column and leaves the old text's vector in the file until the embedder runs, which may be never when no
  provider answers.)

## Vectors (Task 12b)

Entity vectors are made by the hub (`drgnx-ratatoskr/src/embed.rs`), through the gateway, never by the store itself.

- **Provider.** The first provider of kind `tei` with the `embed` cap in the settings' provider table. Texts (`title`, a blank
  line, `body`, at most 8000 characters) go to the gateway's own loopback listener as the editor's
  `POST /p/PROVIDER/embed`, with an in-memory editor token (never stored). The request is counted in `spend` like
  any other. The model name is `tei:PROVIDER`. The hub never starts the provider.
- **Round.** `embed::fill` takes up to 64 stale entities (`vec_stale`) per request and stores the vectors with
  `vec_put` in one `system` tx (tool `embedder`). A failed batch is tried once more; failing twice stops the round.
- **The write checks again.** The provider is awaited outside the writer, so an excise, a revoke's excise, a retire
  or an edit can commit while it answers. The write therefore stores a vector only for an entity that, inside the
  writer's tx, is live at the `ver` and with the text that was read (an excise blanks in place without a new
  version, so the text is compared too); the others are stale again and the next batch sends their text of now.
  Test: `embed::tests::a_text_changed_while_the_provider_answers_gets_no_old_vector` (a held provider). The
  `embed::tests` provider is `ratatoskr-mock llm`, found beside the test binary and built there when missing (the
  run's own target dir and profile, so `--target-dir` and `--release` runs work too).
- **Door 4.** An entity whose source, id or `data.path` the personal-notes deny-list denies (or whose source form is
  unknown) is never sent, whatever the scan's door let in. It stays stale and is looked at again each round.
- **Schedule.** `embed::Timer`: a round starts when the graph writer has seen no write that put text (its `texts`
  count) for a minute and none runs. Lease, status, event and `kv` writes do not count: the Lisp backend's
  housekeeping writes every 60 s and would otherwise keep every round away. After a stop the next round begins by sending one text; it goes on only when the provider answers.
- **Spend.** `norn::write::spend::add_spend` takes the write's `Tx` and sets the row's `tx` (class `system`, tool
  `gateway`).

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
  are refused at that point. A pragma function SQLite rejects itself is as harmless: `pragma_journal_mode('delete')`
  reads its argument as a schema name and fails with `unknown database 'delete'` before it prepares anything.
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

`graph::backup` makes dated copies of the file without a second writer.

- **`vacuum_into(pool, dest)`** runs `VACUUM INTO dest.tmp` on a read-pool connection (a snapshot; writes go on),
  sets it 0600, runs `check` on the tmp, and only then renames it to `dest`. The directory is made 0700. A failed
  check deletes the tmp and leaves any copy already at `dest` (same day included) untouched.
- **`check(dest)`** runs `PRAGMA integrity_check` and FTS5's `integrity-check` (index only, which is all a
  contentless table can be checked for) on the copy. A failed check deletes that copy and answers the failure in the
  `Report` (`ok: false`, `error`); copies under other names stay, so yesterday's remains.
- **`rotate(dir, Policy { daily: 7, weekly: 4 })`** keeps the newest 7 `work-YYYYMMDD.db` and the newest 4 Sundays,
  and removes the rest. Other names (`work-pre7-*.db`, `.tmp`) are never touched.

### The nightly copy and compaction (Task 17)

- **Schedule.** `drgnx_ratatoskr::backup_timer` (pure `due(now, last_ok, since_attempt)`, the clock injected): a copy
  is due when the local time is 03:00 or later, no good copy was made today, and the last try is over an hour old (a
  failure is retried hourly, not every tick). The hub's 2 s schema tick asks it, so a hub that was off at 03:00 copies
  at its first tick after it is ready. At start the newest `work-*.db` seeds the record, so a restart does not copy
  twice a day. No copy starts while an excise runs (`backup_timer::excising`) or the writer is not `Ready`.
- **Record.** `graph::run_backup` (the body of `graph/backup` and of the timer) logs and records the outcome;
  `status.store.last_backup` (RFC 3339) and `backup_ok` come from it.
- **`graph::compact`** (`graph/compact`, user only, never from the backend's connection): per batch of 500 parsed
  entities, one writer request deletes the `entity_hist` versions that a later version of the same UTC day makes
  redundant (the kept version takes over the dropped one's `tx_from`, so as-of reads find no gap), then batches of
  500 `link_stat` rows of retired `session` entities that point at a `file` fold into a `<kind>_total` row whose
  `src` and `dst` are both the file. Other origins and kinds are never read for deletion. A batch with nothing to do
  writes nothing, not even a `tx`. `dry_run` counts on a pool connection.
- **`graph/scrub`** is `Maintenance::Scrub` on its own (what an excise ends with).

## Export and import (Task 7)

`graph::export` writes and reads a directory of JSONL files.

- **Files.** `entities.jsonl` and `links.jsonl` hold the current state, one object per line, sorted by id (links by
  src, kind, dst), keys in a fixed order, with ids only (no database-local numbers). `tx.jsonl` is the tx log
  (`since` limits it). `history.jsonl` (option) has every earlier version of an exported entity.
- **Content.** Authored entities (`recorded`, `imported`) and the links between them. Parsed entities are rebuilt
  from their files. With `with_activity`: `inferred` entities and `session` entities, `touched` links and
  `link_stat.jsonl`.
- **`allow`** (door 5 for export, door 2 for import) is asked for every entity; a refused one leaves no line, no
  history, and no link to it. On export it is asked for the entities not exported too (parsed, retired), and the
  tx log leaves out every tx that wrote a version of a refused entity or a link at one, so its note never leaves.
- **No half exports.** The files are written into `dir.tmp` and renamed; a failure or panic removes `dir.tmp`, and an
  earlier export at `dir` stays until the new one replaces it. The folders an export makes are 0700; an existing
  parent keeps its mode.
- **Only an export is replaced.** `dir`, `dir.tmp` and `dir.old` must each be missing or a folder holding only an
  export's files (`entities.jsonl`, `links.jsonl`, `tx.jsonl`, `history.jsonl`, `link_stat.jsonl`); a file, a link
  or a folder with anything else (`--out` naming a repository) is refused before a file is written. Backups write a
  fixed file under `<data>/backup/`, and import and the 6 → 7 copy only read or add, so no other path replaces a
  folder.
- **Import** is idempotent by `id` and `ver`: a record present at that version or later is skipped; an older one is
  updated (the old row goes to `entity_hist`); an absent one is created at the record's `ver`. One tx per 500
  records (`actor` and `tool` `import`, class `system`, `imported = 0`: real versions). A different kind under an
  existing id, a bad line, or a link with a missing end is refused with its line number. Because the class is
  `system`, kinds the guard reserves for the user are refused too.

## Excise (Task 8)

`urdr::graph::excise` removes a text written in by mistake (a secret, a personal note) from everything in
`work.db` that kept it (storage §8.3). It is the one rewrite of history; the caller checks that the user asked
(user class), and `excise` itself refuses an agent or outside agent.

- **`excise(writer, meta, target, fields, reason, blankers)`** is one tx:
  1. **Versions.** A target `Entity(id)` blanks the named fields (default `title`, `body`, `data`; any of `title`,
     `status`, `body`, `assignee`, `data`) in the current row and in every `entity_hist` version. A target `Tx(n)`
     blanks, in every version of every entity, the fields whose `field_tx` names that tx (default: all five), so a
     value it wrote is blanked in the later versions that still carried it. A text becomes `[excised <tx>]`, `data`
     becomes `{"excised": <tx>}`; unset fields stay unset. Versions, `ver` and `field_tx` stay: history still shows
     that something changed, and who changed it.
  2. **FTS.** Each blanked entity's row is put again (delete, insert), then one `optimize` rewrites the segments
     without the tombstoned tokens of every old version (see "Search").
  3. **Vectors.** The `entity_vec` row is deleted; the embedder makes it again.
  4. **`tx` rows.** `answer` and `note`, where set, become the marker for every tx that wrote a version of an excised
     entity (an entity target), or wrote a blanked version (a tx target), and for the target tx. So do the txs that
     name the target without versioning it: a tx that wrote a link at an excised entity, the txs of the events,
     notices and cards a blanker blanks as about it (`Blanker::txs_about`), and every tx whose answer or note holds
     one of the needles (a keyed `task_write` that echoed the target while versioning another). A repeat of a keyed
     request answers `Refused("this answer was excised; read the entity")`, never the old text.
  5. **Blankers.** Each `Blanker` (norn's: events, messages, cards) gets `Excised { entities, txs, marker }` and
     blanks its copies in the same tx; a blanker's error fails the whole excise.
  6. **`excise_log (tx, target, fields, reason)`**: the target is the entity's id or `tx:<n>`; never the content.
- **`ExciseReport { tx, entities, versions, txs_blanked, blanked }`**, plus `needles` (in memory only, never
  serialized): every value removed of at least 12 bytes (`MIN_NEEDLE`; shorter ones would match unrelated text), as
  stored and JSON-escaped, and the blanked notes.
- **`scrub(writer)`** is the writer's `maintain(Scrub)` (see "The writer"), run after the excise's commit, never on a
  second connection: `secure_delete` has zeroed the cells, `VACUUM` rewrites the file without the free pages and
  FTS5's old segments, and `wal_checkpoint(TRUNCATE)` empties the WAL. A reader's open transaction keeps the WAL
  (`wal_truncated: false`, `blocked_by: "readers"`, after the 5 s busy timeout); `scrub` can be run again once
  the readers are gone.
- **Outside the file.** `kept_copies(work_db)` lists every regular file under `<data>/backup/` (dated copies,
  `work-pre7-*.db`), the Lisp's `work.db.schema5`, the `work.db.schema7-*` files (and their `-wal`, `-shm`) that
  `store restore-pre7` moved aside, and every file under `<data>/export/`; `holding(files, needles)`
  is the byte search over them (a file that cannot be read is listed). `redact(path, needles, marker)` rewrites a
  file (a session transcript) without the needles, through a `.tmp` and a rename, keeping its mode.
- **Limits.** `link.data`, entity ids and `source` are not blanked. A tx that quoted a value shorter than
  `MIN_NEEDLE` without naming the target otherwise keeps it. A tx target finds its versions with a scan of
  `entity_hist` by `tx_from`, and the needle search scans every tx's answer and note (no index; excise is rare).

## The deny-list (Task 9)

`norn::deny` keeps the user's personal notes out of the store (storage §5.6). The denied root is `HOME/org/`; the
one exception is exactly `HOME/org/board.org` (`Verdict::Board`; `board.org.bak` is denied).

- **`DenyList::load(home, config_dir)`** is the only constructor; nothing sets a list's contents (a test reads the
  source to keep it so). The hub keeps the current list in a `SharedDeny` (`Arc<RwLock<Arc<DenyList>>>`): a reload
  replaces it whole, readers take a snapshot.
- **Two tiers.** The hard tier is `HOME/org/notes.org`; under `HOME/org/` at any depth, a file whose name starts with
  `notes`, `journal`, `diary` or `personal` (any case), or anything under a folder so named (`HARD_PATTERNS`); and
  the user's own entries. The soft tier is the rest of `HOME/org/`. `check` tries the hard tier before the opt-ins,
  so an opt-in never lifts it, and a grant never reaches it.
- **The user's entries** come from `<config>/personal-notes-deny.json`: `{"version": 1, "entries": [{"kind":
  "file"|"folder"|"glob", "path": "…"}]}`, `~` expanded, resolved through links. They may name paths outside
  `~/org`, and they cover the board too. A file or folder entry denies the path and everything under it. A glob has
  `*` and `?` in its last part only and also denies everything under a folder it matches. The built-ins cannot be
  removed: the file only adds.
- **The opt-ins** come from `<config>/personal-notes-allow.json`: `{"version": 1, "paths": [...]}`. An entry counts
  only if it resolves to an existing regular file under the denied root; a folder, a glob, a missing file, the
  board or a path outside `~/org` is ignored with a warning. An entry in the hard tier is kept but opens nothing,
  with a warning (Task 9b's notice lists it).
- **Failing closed.** A missing file means none. An opt-in file that is unreadable, malformed or writable by group
  or others opens nothing. A deny file that is unreadable or malformed leaves the built-ins; one writable by group
  or others still applies its entries; a bad entry is skipped. Any of those also drops every opt-in, since what the
  user meant to keep out is not known. Each problem is a warning (`warnings()`, for the doctor).
- **Paths are resolved, never trusted as text.** `check` resolves `..`, doubled slashes, a trailing `/` and links
  with `std::fs::canonicalize` (no `/proc`); a path that does not exist is resolved from its nearest existing parent,
  and a dangling link is followed to its target. A path is denied when its resolved form is, and also when the name
  it was given by is (a link in `~/org` to a file elsewhere). A relative path or a link loop is denied. macOS folds
  case (`cfg(target_os = "macos")`); Linux and Android compare bytes; the hard names fold case everywhere.
- **Every path a record carries.** `paths_of(source, id, data)` gives the source's path (`Source::File`,
  `Source::Spec`), the path inside a path-form id (`spec:`, `plan:`, `file:` whole; `task:`, `step:`, `ruling:`,
  `todo:` cut at the first and at the last `#`), and `data.path`. `check_record` denies a record when any of them is
  denied. `Source::parse` reads schema 6's source strings (`"spec /path"`, `/path`, `commit`, `branch`,
  `recorded`); anything else is `None`, and the door denies the record ("unknown source form").
- **Project roots** (door 3): `check_root` refuses a root inside a denied path, and for a root that contains denied
  paths (`HOME` itself) lists them (`Contains`): `~/org`, the user's file and folder entries, and the names a glob
  matches at that moment. The Lisp code indexer's door is `drgnx-search--files-1` (`core/drgnx-search-chunk.el`), the
  one place every indexed path passes: a root `drgnx-search-denied-p` denies (`drgnx-deny-path-p` with the opt-ins
  ignored) is refused with `drgnx-search-personal-notes-refusal` before its `.drgnx/search.eld` is read, and every
  listed file it denies is dropped before anything reads it.
- **Import and export** (doors 2 and 5): `may_import` and `may_export` are the hub's filters for `graph/import` and
  `graph/export` (`check_record` over the record's source, id and `data`; an unreadable source string is denied).
  Export asks again at each run, so a path the user denied after it came in does not leave.
- **The canary** (Task 19): `norn/tests/canary.rs` drives the Rust-only doors (crafted `graph/put-parsed` payloads,
  the 6 → 7 migration of `test/fixtures/work-db-6-canary.sql`, a tampered import, export after a new deny entry) and
  `test/conformance/privacy/personal-notes-canary.jsonl` the whole path through the Lisp scan and indexer; random
  bytes planted in fixture notes must reach no store, WAL, export, provider request or log, and no file under
  `HOME/org` may change. The entity embedder's door (Task 12b) joins them there.

## The opt-in (Task 9b)

`norn::privacy` applies the two files of the deny-list (`personal-notes-allow.json`, `personal-notes-deny.json`) to
the store; `core/drgnx-store-privacy.el` holds the user's commands that write them (call 8; question 5).

- **`apply(writer, deny: Arc<DenyList>) -> PrivacyReport`** compares DENY (just loaded, and already in force in the
  hub's `SharedDeny`, so no door lets back in what goes) with the **applied state**, `kv` `privacy:applied`
  (`{opt_ins, denied, ignored}`: the opt-ins that open something, the user's entries as `kind:path`, the
  warnings). Only `apply` writes that key (a test reads the sources); the `privacy:` key guard (`privacy::register`,
  called by `grants::register`) refuses every class but the user's.
- **What the list now denies goes.** Every entity one of whose absolute paths (`deny::paths_of`) the list denies is
  retired with its current links (one tx, which reads the applied state and the denied entities itself, inside the
  writer: a write queued before it is seen, so nothing it stored with the old list stays; when nothing is denied
  the tx is rolled back and writes no row), then excised entity by entity (`excise::FIELDS`, reason "personal-file
  opt-in revoked", `write::blankers()`), its source's `parsed_file` row forgotten (so a later opt-in is read
  again), then the applied state and the notice are written (one tx), then `scrub`; the report lists the copies
  that still hold an excised value (`excise::holding`): `backups_holding` (`deletable_copies`: `backup/`,
  `work.db.schema5`, `work.db.schema7-*`) and `exports_holding`. **`apply` and `tick` never delete a file:** a
  change of the opt-in file by anything else (an agent too) must not cost a backup. `delete_copies(work_db, wanted)`
  deletes those of WANTED that are deletable copies, nothing else and never an export; only `graph/privacy
  {delete_copies}` calls it (not from the backend's connection), which the revoke and deny commands send after
  asking, with the copies the first answer named. It must be the same command run: once excised, the values are
  gone, so nothing could find those copies again. This covers a revoked opt-in, a new deny entry
  and a change made while the hub was down alike. An entity already retired and excised since is skipped; relative
  paths are not looked at. Added opt-ins need nothing: the next scan reads them. Link `data` is not excised (as for
  every excise).
- **The notice** is an `event` row (kind `status`, agent none) in the applied state's tx: "personal-file opt-ins
  changed: +X / −Y", then "; your deny list: +A / −B", "; N ignored", "; N excised" when non-zero: counts, never a
  path. `PrivacyReport.notice` carries the text; nothing is written and it is `None` when nothing changed.
- **`tick(watch, writer, deny, home, config_dir)`**, from the hub's 2 s schema tick: at the first tick, and when
  either file's `(mtime, size)` moved, it reloads the list into `deny`, then applies. The hub broadcasts a changed
  report as a `notice` event (`id` `privacy-opt-ins`, severity `warn`) to every editor and wakes `coord/notify`. A
  failure (a store not ready) is said once and tried again at the next tick.
- **`graph/privacy {reload, delete_copies?}`** does the same at once for the commands: load, swap, apply, then
  delete the named copies; the answer is the report plus `backups_removed`.
- **The commands** (`drgnx-store-{allow,revoke}-personal-file`, `drgnx-store-{deny,undeny}-personal-path`) refuse
  a folder, a path outside `~/org`, the board and the hard tier (the built-in names, mirrored in Lisp, and the
  user's entries) before asking; confirm with the resolved path; write the file with `drgnx-file-write-text
  :private t` (a temp file renamed, `0600`); refuse to overwrite a file with a mistake; then call `graph/privacy`
  through `drgnx-hub-call-sync` (30 s). A hub that does not answer leaves the file written: the tick applies it.

## Scope and grants (Task 10)

All in `norn::{scope, grants}`. The caller, its class and its project come from the connection, never from a tool's
arguments.

- **`Caller`** `{ class, actor, session, profile, job, project, backend }`. `Caller::from_identity(&Identity,
  &ProjectCache)` builds it for a tool connection: a session drgnx runs is class `agent`, actor `agent:<sid>`, with
  its sid, profile and job, and the project of its `home` (a job's agent runs in the job's worktree, which shares
  the repository's project); an outside agent is class `ext`, actor and session its `ext:KIND:PID-HASH` name, and
  the project of the cwd its bridge reported; no identity is class `ext` with nothing. It runs no git: the project
  comes from the `ProjectCache`, filled before (below). A folder the cache has not resolved and registered gives no
  project. `Caller::user(backend)` is a proven user connection, `backend` marking the Lisp backend's. `tx_meta(tool)`
  makes the write's `TxMeta`; `may_write_into(project)` is the user anywhere, an agent only its own project.
- **`scope::for_caller(conn, &caller, now)`**, computed from the rows on every call and never cached:
  - class `user` (and the hub's `system`): everything;
  - `agent` and `ext`: the caller's project plus the projects of every active `read` grant whose `who` is the
    caller's project, profile or session (`*`: every project, future ones too);
  - `allows(project)`: in scope `Full`; an entity without a project (`agent:`) `Stub`; otherwise `Hidden`.
    `reach()` gives the same as `Everything`, `AnyProject` or `Projects(&[n])` for queries that filter by project;
  - a caller with no project and no grants reaches nothing but stubs.
- **`valid()`** is cheap and never blocks (walks call it from async code before each level). Each database file has
  a watch: `grants::{create, revoke}` bump it inside their tx (`scope::grants_changed`), and every `for_caller`
  bumps it when the grants' highest `updated_tx` moved since the last look, so a change made by another path (a
  revert, an import) still ends older scopes at the next scope computed on that file. A scope holding a grant that
  has since expired is not valid either. The user's scope does not depend on grants and stays valid.
- **Grants** are entities of kind `grant` (`grant:<8 base36>`, no project), `status` `active` or `revoked`, `data
  {who: {project: N} | {profile: NAME} | {session: SID}, what: {project: N} | "*" | {task: N}, access: "read" |
  "edit-user-tasks", expires?}`. A row that does not parse opens nothing.
  - `create(tx, who, what, access, expires)`: a `read` grant opens a project or `*`; an `edit-user-tasks` grant a
    task, a project or `*`. The named projects and task must exist; `expires` must be later than the tx.
  - `revoke(tx, id)` sets `revoked`; false when there was no active grant.
  - `list(conn, &caller, &Filter { who, active }, now)`: the user sees every grant; an agent or ext caller only the
    grants whose `who` is its own (others would name other projects).
  - `may_edit_user_task(conn, &caller, task, now)`: an active `edit-user-tasks` grant for the task, its project or
    `*`, and the task in the caller's own project (a grant never opens writes across projects); the user always.
- **The class check is in the write path.** `grants::register(&mut Guard)` puts norn's two rules into urdr's guard:
  kind `grant` needs class `user` ("grants are the user's"), and `kv` keys `setting:*` need class `user` ("settings
  are the user's"). `entity::{create, update, retire}` check it on every path, so a proposed tx, an import (class
  `system`), a parsed entity (class `system`) or any agent tool that names kind `grant` is refused;
  `grants::{create, revoke}` check it first too. Test: `grants::tests::every_agent_reachable_write_is_refused`.

## Settings history and grants (Urdr Task 10b)

Built in the unified-settings plan (its Task 23; design §12, §13), in `norn::options` and `norn::grants`. The file
stays the truth for a setting; the store records its history as entities of kind `option`.

- **Ids** (`options::parse_id(&str) -> Result<OptionId, BadId>`; `OptionId { scope, dir, mode, var }` prints back
  as its id):
  - `option:global:<var>` and `option:global:mode/<mode>:<var>` (`settings.el`);
  - `option:private/<project>:[dir/<sub>/:][mode/<mode>:]<var>` (your private workspace file) and the same with
    `shared/` (the repository's `.drgnx/settings.el`).
  - `<project>` is the Urdr project id without `project:` (`[a-z0-9-]`), or `root-<12 hex of sha256(true root)>` for
    a folder with no Urdr project. `OptionId::project()` gives `project:<project>`, or `None` for a global id and a
    `root-` folder.
  - A dir is relative, ends in `/`, and has no empty, `.` or `..` part; a mode has no `/`; the variable comes last,
    is not empty and does not start with `dir/` or `mode/` (it may hold `/` and `:`). No part holds whitespace or a
    control character, and an id is at most 1024 bytes.
- **The `options` grant** is a grant (above) with `access: "options"`, `what: "options:global" | "options:project"`
  and optional `names`: 1 to 64 globs, `*` the only wildcard, no `/`. `grants::create_options(tx, who, what, names,
  expires)` makes one (user class only, as every grant). An `options` grant opens no reads, and a `read` or
  `edit-user-tasks` grant never names an `options:` scope or carries names; a row that mixes them opens nothing.
- **The rule** (`options::rule`, registered by `grants::register`), on every write of kind `option`:
  - every class: the id parses;
  - the user: passes;
  - an agent (`Class::Agent`, a proposed tx included): the name is not on the deny-list (`DENIED`); for a private or
    shared id, the agent's project is the id's project and the entity's `project` column is that project
    (`NOT_ITS_PROJECT`); a global id has no project; and an active `options` grant whose `who` is the agent's
    project, profile or session, whose `what` is the id's scope (`options:project` covers the agent's own project's
    private and shared ids, never a `root-` folder) and whose `names` match (`NO_GRANT` otherwise);
  - the tracker scan (class `system`, tool `scan`: `graph/put-parsed`; `options::scan_may_write`, unified-settings
    Task 24): a repository's `.drgnx/settings.el` describes the repository, never your global or private settings,
    so only a shared id ("settings are the user's" otherwise), made `parsed` by a create (a write to a stored one
    keeps its origin: a shared setting's history holds your Settings changes and the repository's alike), in the
    project the id names, live (`NOT_THE_REPOSITORYS`; a `root-` folder: no project). What it records applies
    nothing: workspace trust decides what the file's values do;
  - an outside agent, the hub and an import (`Class::Ext`, `Class::System` with another tool): refused ("settings
    are the user's").
  - `options::may_write(conn, &caller, target, now)` is the same check without a write (the hub's `settings_change`
    asks it before it records a proposed tx; [hub.md](hub.md#agents-change-settings)).
  - `options::may_read(conn, &caller, scope, now)` is `settings_get`'s: the user always; anyone else under an active
    grant of its own `who` that is an `options` grant of the scope or a `read` grant covering it (`*`, or its own
    project for private and shared; `NO_READ_GRANT` otherwise). `options::option_id(scope, project, name)` is the
    id of an agent's plain setting (never a dir or mode section; `NO_PROJECT` for a project scope with none).
- **The deny-list's name half** (`options::deny::is_denied(name)`, call 9): the names, prefixes and suffixes of
  `test/fixtures/settings-deny.json` (drgnx's and Emacs's security settings, `eval` and `mode`, `drgnx-trust-*`,
  `safe-local-variable-*`, Emacs's risky endings and design §4.4's program endings, case folded), and every name
  no variable has (`options::deny::is_not_a_name`: a keyword such as `:eval`, `nil`, `t`, whitespace, a control
  character or one of the file's `characters`, which the editor refuses too; `settings_change` and `settings_get`
  refuse such a name before any grant or card). The test `options::tests::deny_table` keeps the Rust lists equal
  to the file and runs its cases, and the editor's `drgnx-settings-agents/the-shared-deny-table` runs them against
  its check, which adds what only Lisp knows (`:agents never`, `:workspace code`).
- **`graph/put-parsed`** (Task 24) takes `option` entities from a `file` source whose path ends in
  `/.drgnx/settings.el` only: each id a well-formed shared id, `data` only `value` (a text), `file` (the source's
  path) and `line` (a number). Anything else refuses the source, which stores nothing (`norn::parsed`). The entity's
  project is the repository's (the source's folder, resolved as for every parsed entity); the guard checks it again.
- **`settings/record`** (Task 24; `norn::write::options::{project_of, meta, record}`; the method:
  [hub.md](hub.md#settings-history)): one call is one tx of the editor's, its `tool` the call's, its `req`
  `settings <req>`, `reverts` the tx it undoes (which must exist), and `project` the ids' (one project per call; a
  project the store does not know is refused). Each change makes its entity (origin `recorded`, `data {value, file,
  line}`), brings back a retired one, or gives it a new version; a removed setting's `data` has no `value`. A value
  `runstav::secrets::looks_like_secret` flags is never stored: that version's `data` has no `value` and
  `redacted: true` (the next value in the clear drops the flag).
- Tests: `options::tests::{id_grammar, project_is_the_ids_project, deny_table, globs_match_star_only}`,
  `grants::tests::{every_agent_reachable_write_is_refused, an_options_grant_allows_its_names_only,
  project_grant_covers_private_and_shared, options_grants_are_well_formed_and_open_no_reads}`,
  `write::options::tests::{one_tx_per_call, a_tx_of_another_project_is_refused_in_the_write,
  the_project_is_the_ids_live_project, a_retry_is_one_tx,
  removed_is_null, a_secret_is_never_stored, reverts_is_recorded, a_retired_option_comes_back}`, `norn/tests/parsed.rs`
  `a_repositorys_settings_file_brings_its_shared_options`, `urdr::graph::guard::tests::{a_rule_decides_from_the_target,
  a_rule_sees_a_creates_origin_only, every_entity_write_runs_the_rule}`,
  `urdr::graph::export::tests::an_import_runs_the_rule_on_both_paths`; rows `history/*`.

## Trust (Task 10)

`norn::trust`: every text field a tool returns carries its author, `Authored { text, by, class, tx, project, trust
}`, read by `trust::authored(conn, &ent, field)` from the field's `field_tx` entry and that tx's `actor` and `class`
(`project` is the entity's project id).

- `trust` is `user` for text a user-class tx wrote, and for text of a parsed entity written by the scan (class
  `system`). Everything else is `untrusted`: agents' and outside agents' text, the reader's own included, and the
  hub's other `system` writes, which carry what agents sent. A tx that cannot be read gives an untrusted `unknown`
  author.
- `fence(text, by, project)` renders untrusted text as `<untrusted-data by="…" project="…">…</untrusted-data>`.
  Inside the text, a backslash goes after the `<` of every `</untrusted-data` and `<untrusted-data` (ASCII case
  ignored), so the text can neither close the fence nor open one that claims another author. `by` and `project` are
  one line of at most 80 characters (`runstav::text::one_line`) with `&`, `"`, `<` and `>` escaped.
  `Authored::render()` fences untrusted text and leaves the user's as it is.

## Projects (Task 10)

`norn::project`. A project's id is `project:<root commit, 12 hex>`.

- `resolve(cwd)` runs the hardened git of `hello` (`draugr::git`, the root-owned git, a minimal environment, 3 s)
  and answers a `ProjectRef { id, root, slug, root_commit, roots }`, or `None` outside a repository, for the home
  folder itself, or when no trusted git runs (Android). It is blocking: it never runs on an async worker or under
  the writer's lock.
  - `root` is the main repository's top-level: a linked worktree's common git dir is the main `.git`, so worktrees
    share their repository's project. `slug` is its folder name.
  - With several root commits (an unrelated history merged in), the earliest committer date wins, ties by sha.
  - A repository without commits gets `project:x-<8 base36, random>`.
- `register(tx, &root)` answers the project entity's `n`, making it when new (kind `project`, title the slug, its
  `project` column its own `n`, `data {root, path}`):
  - with a root commit, the stored project made from any of the repository's roots (so a later merge of an earlier
    root, or a renamed folder, changes nothing); a `project:x-…` project of the same folder gives its aliases to
    it, is retired, and names it in `data.moved_to`;
  - without one, the `project:x-…` project of the same folder.
  - The slug becomes a `project_alias` row when no project holds it yet (a rename adds one). The row is written by
    urdr's `entity::set_alias`, the one writer of `project_alias`.
- `ProjectCache` keeps resolved folders so `Caller::from_identity` runs no git: `fill(dir)` resolves (blocking),
  `unregistered()` lists what one write should `register`, `set_registered(id, n)` records the answer,
  `project_n(dir)` is what callers get, `forget(dir)` drops one. The hub fills it when a session starts; the
  migration fills it before its transaction.

## Migration from schema 6 (Task 11)

`norn::migrate7` moves a schema-6 `work.db` to schema 7. The hub runs it as the graph writer's opening rule
(`open_rule(MigrateOpts{backup_dir, home, config_dir})`), before it serves anything, so the first request sees the
result. What the rule answers for the file it finds:

| The file | The answer |
|---|---|
| missing (or empty) | made at schema 7: schema 6's tables, then shaped as a migrated file is, so both have the same schema |
| schema 6 | migrated (below), then `Ready { 7 }` |
| schema 7 | `Ready { 7 }` |
| above 7 | `ReadOnly { schema }`: writes answer `schema`; nothing is changed or copied |
| below 6 | `NotReady`: "work.db is schema N; open it once with drgnx 6 first, or remove it (installs are disposable)" |
| a migration that failed | `Failed { reason }`, never tried again in this process (call 18) |

Another process holding the write lock, or changing the file between the look and the lock, is `NotReady` and is
looked at again at the next tick; nothing was done.

**The steps.**

0. Outside any transaction: the deny-list loaded from `HOME` and the config dir, and every project folder the old
   rows name (`data.repo`, a commit's or branch's path, a file's folder, the jobs' repositories; denied folders
   left out) resolved through `ProjectCache::fill`. All git runs here, never under the lock.
1. The copy: `VACUUM INTO <data>/backup/work-pre7-<unix>.db` (the dir 0700, the file 0600, written at a `.tmp` name and
   renamed once `urdr::graph::backup::check` passed). A copy that fails its check is deleted and the migration
   fails. Within one process an unchanged file reuses its copy (one copy per hub process at most); an older copy is
   never removed.
2. One `BEGIN IMMEDIATE` transaction holds every step below; a crash or an error rolls all of it back, so the file is
   schema 6 or schema 7, never between (`interrupted_migration_leaves_schema_6` kills a child mid-way).
3. The schema-6 rows are read again under the lock. **3a, the door:** a node whose source, id, `data.path`,
   `data.repo` or `data.worktree` the deny-list denies (everything under `~/org` but the board; `Source::parse`
   failing is denied too), a job task whose data's `path`, `repo` or `worktree` it denies, a decision whose task or `paths` name a
   denied path (`~/…` and absolute words), an edge with a denied end or source, and a denied `file` row are not
   migrated; they are counted (`denied_nodes`).
4. Schema 7's tables (`GRAPH_DDL`); `node`, `edge`, `jtask`, `jdep` and `decision` renamed `old_*`, `file` to
   `parsed_file` and `meta` to `kv`, with read-only views `file` and `meta` over them.
5. History in time order: one imported transaction (`tx.imported = 1`, tool `import`, class `system` or `agent`,
   never `user`) per (time, actor) group, the earliest first; the project registrations go first.
   - Nodes become entities of their kind (an unknown kind becomes `note` with `data.was_kind`); time `updated`, a
     commit's the earlier of that and its date. `path`, `line`, `parent` and `ord` go to `data`; origin `recorded`
     when the source said so, else `parsed`.
   - Job tasks become `task:<job>#<n>` entities (assignee the agent, a held lease kept with epoch 1), timed by
     their job's creation or first event; `jdep` rows become `blocks` links.
   - Decisions become `decision:<n>` entities (subject the title, reason the body; author `user` is actor `user`
     with class `system`); `replaces` becomes a `supersedes` link.
   - Edges keep their kind where `kinds::LINKS` allows it (`on-branch` becomes `on_branch`); any other kind or pair
     becomes `relates` with `data.was`. `ledger-of` has no kind of its own: its ledger file becomes a `file:<path>`
     entity and the edge `relates` file → plan, `{"was": "ledger-of"}`. Parents become `parent_of` links.
   - An edge whose end is no node is dropped. Every edge is counted by old kind → new kind (`->dropped`,
     `->denied`, `->merged` included).
   - History before the move is approximate: `hist::entity_as_of` says so for a time before the migration.
6. The kept tables (`job`, `card`, `message`, `spend`, `event`, `agent`, `review_mark`) gain a `tx` column, `message`
   and `card` an `entity` column; their rows stay.
7. Compat views `node`, `edge`, `jtask`, `jdep` and `decision` with schema 6's columns, so the Lisp readers' selects
   run unchanged (`every_old_select_runs_on_the_views` extracts every one from `core/` and `modules/`); writes to
   them fail (`every_schema_6_lisp_write_fails_on_7`).
8. `kv`: `schema` 7, `compat-read` 6, and `migrate-7`, the report. The `old_*` tables are dropped.
9. Commit. When step 3a denied anything, `VACUUM` and a WAL checkpoint follow, so what was denied leaves the file
   and its WAL; the report names the copies that still hold it (the pre-migration copy, `work.db.schema5` if any).

**The report** (`kv.migrate-7`, the hub log, `status.store.migrated_at` and `denied_in`, the doctor): rows in and out
per table, links per old → new kind, denied counts, entities without a project, retyped and duplicate rows, the
transactions and the time. Never a path of the user's content, a title or a body.

**Commands** (`ratatoskr store`, `drgnx-ratatoskr/src/store_cli.rs`):

- `store migrate-check --db FILE --scratch DIR [--json]` migrates FILE, a copy, in place with the same code, its
  pre-migration copy in DIR, and prints the report. It refuses the configured live `work.db` (by path or inode)
  and a file in the data dir of a running hub.
- `store restore-pre7 [--yes]` refuses while a hub holds the lock; it copies the newest `work-pre7-*.db` that checks
  to a temporary name first (a copy that fails is skipped; the backups are never changed), then moves `work.db`,
  `work.db-wal` and `work.db-shm` aside together to `work.db.schema7-<unix>` (`-wal`, `-shm`), and renames the copy
  into place. A schema-7 WAL beside the restored file would corrupt it. Without `--yes` it says what it would do.

## Parsed entities (Task 15a)

The tracker scan reads plans, specs, ledgers and git; what it finds reaches the graph through two front methods
(`norn/src/parsed.rs`, `drgnx-ratatoskr/src/graph.rs`; class `user`, hub.md's table). Each is one request of the
graph writer, with the deny-list in force when the writer runs it: the list is read inside the writer's closure,
after the git resolution, so a revoke or deny entry applied meanwhile (whose `apply` the writer runs first, or
after) is never undone by a write that checked the older list.

**`graph/put-parsed`** `{root?, sources?, gone?, updates?, collected?}` → `{changed, retired, refused}`:

- **A source is typed:** `{kind: "file"|"spec"|"commit"|"branch", path?}`. Its entities are stored with origin
  `parsed` and the source text schema 6 used (the path, `spec PATH`, `commit`, `branch`), so migrated rows and new
  ones are one set. A `file` or `spec` source is whole: an entity or `parsed` link of it that is not sent again is
  retired. `commit` and `branch` sources only add.
- **Door 1 (§5.6):** every path a source carries is checked against the deny-list: the source's path, each
  entity's id (`check_record`), `data.path`, `data.repo`, `data.worktree`, `data.parent` and both ends of every link.
  One denied path refuses the whole source with `personal notes are never stored`, a text that names no path, and
  nothing of it is written. A source whose shape is wrong (a kind the source kind cannot hold, an id or `data.path`
  that is not the source's path, a link kind `kinds::LINKS` refuses) is refused the same way with its reason; the
  other sources of the request are stored.
- **Unchanged is untouched:** an entity whose kind, title, status and data are what is stored gets no new version
  (the same scan twice writes nothing). One that changed gets one version; a retired one sent again comes back
  (`entity::unretire`). `data.parent` becomes a `parent_of` link; `on-branch` becomes `on_branch`; `ledger-of`
  becomes `relates` `{"was": "ledger-of"}`.
- **`updates`** are derived statuses: `{id, status?, data_patch?}`, status `open` or `done`, a patch of the scan's
  flags only (`gone`, `stale`, `range-stale`, `merged`, `branch`, `worktree`, `repo`). An update of an entity sent
  in the same request is folded into it; any other must name a live `parsed` entity. Other fields are refused.
- **`gone`** retires a source's entities and links and forgets its file time (a gone file also its `spec` source).
- **Cleanups**, as the Lisp scan did: commits no live link reaches are retired, and so is a spec no live plan
  `derives` from (unless it sits under a `specs` folder). Entities sent in the request are exempt: a plan, its spec
  and its ledger's commits go in one request.
- **`collected`** keys (`job <id>`) are set to `collected` in `kv` (read through the `meta` view).
- **File times** go to `parsed_file` (the `file` view). **Projects** of new entities are resolved (git) before the
  write, on a blocking thread, and registered in it. The tx is `scan:<root>`, class `system`, tool `scan`.

**`graph/record`** `{task, repo, commits: [{sha, date, subject, seq?}], collected?}` → `{ids}` records a job's
commits against its task (§9 step 3): each a `commit:<sha>` entity and an `implements` link (origin `recorded`). The
tx is the caller's, keyed by `collected`: the same record again answers the first answer and writes nothing; a key
already collected by a put writes nothing either. A denied repository or task is refused with the door-1 text.

## The store's methods (Task 15b)

Every other `graph/*` method and `tasks/*` are the front's, class `user` only (hub.md's table;
`drgnx-ratatoskr/src/graph.rs`). Writes go through the front's writer as the user's tx (`actor user`, class `user`,
tool the method's name); a write the backend's connection asks for (grants, settings, excise, import, `tasks/write`)
is `not-allowed` even though its class is `user`.

- **Reads:** `graph/entity {id, as_of?, include?: [links|notes|history]}` → `{entity, by: {created, updated},
  approximate?, links?, notes?, history?}`; `graph/neighbors` and `graph/path` (`max_depth` 1 to 6, default 3; kinds
  required past 3) walk with the walk budgets and answer `truncated` and `hidden`; `graph/history {id, since?}` →
  `{versions}`. The user's scope is everything.
- **`graph/sql {sql, params?, deadline_ms?, rows?}`** → `{columns, rows, truncated}`: one read-only `SELECT` through
  `sqlro` (defaults 2000 ms, 1000 rows); a write, `ATTACH`, a `PRAGMA`, a second statement or a recursive CTE is
  `invalid-params` at `sql`, a run past the deadline at `deadline_ms`.
- **`graph/revert {tx} | {entity, ver}, cascade?`** → `{reverted?: {entities, links}, blocked?, listed?}`: a tx is put
  back by new versions, or blocked (nothing written) by the later txs named; an entity goes back to a version as a
  new one. `cascade` only lists. A reverted grant changes scopes at once. **`graph/proposed {accept | reject: [tx]}`**
  settles proposed txs the same way (`hist::settle_proposed`). Both are the user's: the backend's connection is
  `not-allowed` before anything is read or written, its `cascade` look included (as for scrub, compact, excise,
  grants and import).
- **`graph/excise {target: tx | id, fields?, reason, rotate_backups?, transcripts?}`** → the excise report, the
  scrub's (`vacuumed`, `wal_truncated`, `blocked_by`), and the copies outside `work.db` that hold an excised value:
  `backups_holding` (or `backups_removed` with `rotate_backups`) and `transcripts_holding` (or `transcripts_redacted`:
  the hub's `sessions/*.jsonl`, rewritten in place with `transcripts`). Exports are listed with the backups, not
  made again.
- **`graph/grants {list: {who?, active?}} | {grant: {who, what, access, expires?}} | {revoke: id}`**: `who` is
  `project:ID` (or a slug), `profile:NAME` or `session:SID`; `what` is `project:ID`, `*` or `task:ID`; access `read`
  or `edit-user-tasks`. Only the user's connection makes or revokes one (an agent's or the backend's is
  `not-allowed`, the registry's class check aside); the store's grant guard refuses any other tx too.
- **`graph/settings {get} | {set: {only_user_closes}}`** → `{only_user_closes}`: `kv` key `setting:only-user-closes`,
  written in a user-class tx (the store's `setting:` guard). **`graph/privacy {reload}`** applies a change of the
  personal-notes opt-ins and deny entries at once (`norn::privacy`, "The opt-in" above); the hub's tick also checks
  both files.
- **Copies:** `graph/export {project?, out?, since?, history?, …}` (default `<data>/export/`), `graph/import {dir,
  …}` (never a `grant`: grants are made only through `graph/grants`), `graph/backup` (a dated
  `backup/work-YYYYMMDD.db`, rotated), `graph/compact {dry_run?}` and `graph/scrub` (Task 17: "The nightly copy and
  compaction"). `ratatoskr graph …` (`drgnx graph …`) is a client of these methods (`graph_cli.rs`); the doctor's
  `store` section is `ratatoskr doctor --json`'s: the schema, a failed move, the WAL (a warning above 64 MiB), the last
  backup's age (above 48 h) and check, the opt-in file's warnings and count, and the pre-migration copies. It does not
  open the live file: the full-text and integrity checks run on each copy before it is kept.
- **Tasks for the editor:** `tasks/ready {labels?, limit?, project?}` and `tasks/find {query?, status?, assignee?,
  labels?, project?, cursor?}` → `{tasks: [{id, title, status, priority, assignee, labels, project, ver, lease}],
  cursor?}` (50 at a time); `tasks/write {op, …}` runs one tracker op as the user (`create` needs `project` or
  `cwd`; `tools {id, tracker?}` sets a task's tracker tools) and answers `{id, title, ver, lease?, parts?}` or the
  op's `{conflict}`, `{lease_lost}` or `{proposed}`.

**Cards the store settles** (`cards/settle`): an `access` card's choices are `session`, `project`, `profile` (a read
grant of the target project for the requesting session, its project or its profile, made in the settle's tx; a
`session` grant expires a day after the settle, since the session's end is not known then and a session id is never
used again, while the other two last until revoked) and `refuse`; `resolved` is `refuse`; the requester gets a message either way. A `close` card's are `accept` (the task
done as the user, its lease cleared, if it is still at the card's version: else the conflict, and the card stays
open) and `reject` (`resolved` too: nothing changes, the proposing agent gets a notice). Any other choice is
`invalid-params`. The backend's connection settles an access card only by refusing and a close card only by
rejecting (`not-allowed` otherwise). Other card kinds settle as before.

**Sessions' tool sets:** `mcp/session` takes `profile?` and `tools?: {tracker}` (runtime.db `msession.profile` and
`msession.tools`, migration 4). The session socket serves `norn::tools::tools_for` of: the task's
`data.tracker_tools` if set, else the profile's `tools.tracker`, else on (21 tools; 16 without the tracker tools).
The list is fixed when the socket opens, and again when a session comes back after a restart.

`status.store` adds `batches` and `replays` (the writer's counters) and `readers` (read connections in use).

## The one-writer gate (Task 18)

The hub is the one writer of `work.db` (schema 7). Lisp that stays reads it; nothing in Lisp but the standalone
Lisp hub of the v0 conformance rows and the coordination unit tests of the `local` writer mode (`drgnx-coord-writer`)
opens it read-write. The gate proves that.

- **Gate mode:** `DRGNX_WORK_DB_GATE=1`. The unit-test runner (`harness/run-ert.el`) and the Lisp backend
  (`test/conformance/lisp-hub.sh`) load `test/support/work-db-gate.el`, which advises `sqlite-open` to signal
  `drgnx-work-db-gate` when the file is named `work.db` and is not opened read-only. (`drgnx-work-db` already
  signals `drgnx-work-db-not-the-writer` outside `local`; the gate also catches an `sqlite-open` that bypasses it.)
- **The exemption is narrow.** A test of the `local` mode is defined with `drgnx-work-db-writer-deftest`: it carries
  the ERT tag `:work-db-writer`, binds `drgnx-coord-writer` to `local`, and the runner leaves it out in gate mode (it
  is listed as skipped). The backend half of `drgnx-hub`, `drgnx-job*` and `drgnx-coord*` in `front` mode are not
  tagged: they run in gate mode, so a backend path that still opens `work.db` read-write fails the gate.
- **The lint** `drgnx-lint/work-db-writer-tags-only-in-local-mode` (`test/unit/lint-work-db-writers-test.el`) keeps
  the tag to the test files of the Rust-bound Lisp (a fixed list in the lint), and requires the test to bind
  `local`, so the tag cannot hide an editor writer or a backend reader. Phase 7 deletes the tagged tests and the list.
- **CI:** the job `no-lisp-writes` (`.github/workflows/drgnx-tiers.yml`) runs the whole unit suite once in gate mode on Linux (`docs/develop/ci.md`). The
  `lisp-backend` rows (`seam/*`, `coord/*` through the Lisp backend, `store/the-lisp-backend-starts-on-schema-7`) run
  with the backend under `DRGNX_WORK_DB_GATE=1` before a push.
- **Readers' conformance:** `drgnx-work-db/every-reader-reads-schema-7` (`test/unit/work-db-readers-test.el`) loads
  `test/fixtures/work-db-7.sql` (a database the hub made: `test/fixtures/work-db-7-gen.el` migrates a small synthetic
  schema-6 database with `ratatoskr store migrate-check` and dumps it) and calls every reader of `drgnx-work-db.el`,
  `drgnx-coord.el` and `drgnx-cockpit-model.el` through the compatibility views, with Nidhogg's linked SQLite (the
  oldest reader, 3.51.3 or later). When the container has a `sqlite3` binary, `sqlite3 -readonly` reads the views too.
