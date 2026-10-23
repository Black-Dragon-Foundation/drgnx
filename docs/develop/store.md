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
  the embedding model, so `vec_stale` can list entities without a vector of a model. Both are departures from the
  design's sketch.
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

All in `urdr::graph::{entity, link}`; every function takes the write's `&mut Tx`.

- `entity::create` inserts at `ver = 1` with `field_tx` naming the tx for each non-null field (`data` only when not
  `{}`) and the FTS row; a duplicate `id` is `Refused("id exists")`.
- `entity::update(tx, n, expect_ver, changes)`:
  - A stale `expect_ver` answers `Conflict { ver, changed_since }` and writes nothing. `changed_since` lists the
    fields whose `field_tx` is newer than the tx that wrote the caller's version, each with its new value, the
    tx's actor and class.
  - Otherwise the old row goes to `entity_hist` (`tx_from` = its `updated_tx`, `tx_to` = this tx), the changes
    apply (`data_patch` is an RFC 7396 merge patch), `ver` and `field_tx` and `updated_tx` follow.
  - Title or body changes delete and re-insert the FTS row by rowid (never a partial `UPDATE`).
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

## History (Task 3)

`urdr::graph::hist` reads and rewrites the past. It is policy-free: the caller checks the class (user only).

- **As of a tx.** `tx_at(conn, at)` is the last tx at or before a time. `entity_as_of(conn, n, tx)` answers the
  current row if `updated_tx <= tx`, else the `entity_hist` row that held at `tx` (one seek on `entity_hist_tx`:
  the first `tx_to` past `tx`), none before creation. `approximate` is true when that version's tx is `imported`.
  `entity_hist` keeps no lease, origin or retirement: an old version has the default lease, the entity's origin and
  source, and `retired_tx` only if the entity was retired at or before it. `links_as_of(conn, n, kinds, direction,
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
  text and no vector of that model (the indexer's work list; Task 12b supplies the `Embedder`).

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

## Export and import (Task 7)

`graph::export` writes and reads a directory of JSONL files.

- **Files.** `entities.jsonl` and `links.jsonl` hold the current state, one object per line, sorted by id (links by
  src, kind, dst), keys in a fixed order, with ids only (no database-local numbers). `tx.jsonl` is the tx log
  (`since` limits it). `history.jsonl` (option) has every earlier version of an exported entity.
- **Content.** Authored entities (`recorded`, `imported`) and the links between them. Parsed entities are rebuilt
  from their files. With `with_activity`: `inferred` entities and `session` entities, `touched` links and
  `link_stat.jsonl`.
- **`allow`** (door 5 for export, door 2 for import) is asked for every entity; a refused one leaves no line, no
  history, and no link to it.
- **No half exports.** The files are written into `dir.tmp` and renamed; a failure or panic removes `dir.tmp`, and an
  earlier export at `dir` stays until the new one replaces it. `<data>/export/` is made 0700.
- **Import** is idempotent by `id` and `ver`: a record present at that version or later is skipped; an older one is
  updated (the old row goes to `entity_hist`); an absent one is created at the record's `ver`. One tx per 500
  records (`actor` and `tool` `import`, class `system`, `imported = 0`: real versions). A different kind under an
  existing id, a bad line, or a link with a missing end is refused with its line number. Because the class is
  `system`, kinds the guard reserves for the user are refused too.

## Excise (Task 8)

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
  matches at that moment.

## The opt-in (Task 9b)

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

## Parsed entities (Task 15a)

## The one-writer gate (Task 18)
