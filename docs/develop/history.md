# The edit history (`verdandi`)

Every change to a project's text — the user's keystrokes, agents' writes, tools, git — recorded with who and why, so
an agent step can be reverted to (keep mine, or roll back mine too), redone, forked and compared, with anchors exact
to the character across every worktree. The store is the crate `runtime/crates/verdandi`: `history.db` and a
[Loro](https://loro.dev) document per tracked file, with no hub, editor or Urdr type. The hub's capture, methods and the
editor's tracking build on it.

Git decides merged text; Loro holds element ids; the selective revert is drgnx's own, on Loro's public API only.

## `history.db`

One per project (`History::open(dir)` → `<dir>/history.db`), on urdr's store: WAL, `0600`, full sync, migrations as
data (`schema.rs`; schema 1). The hub is its only writer. A record and the document updates it carries go in one
transaction (`History::put_op`), so a multi-file action is all there or not at all.

| Table | Holds |
|---|---|
| `op` | one immutable record per action: `kind`, `author` (a peer), `cause_json`, `spans_blob`, `view_blob`, `git`, `summary`, `at` |
| `op_parent` | the records' DAG: concurrent records diverge, merges join |
| `doc` | a document per tracked file, by its path in the project, with its `class` |
| `branch` | `wt/<id>` per worktree, `fork/<id>`, `undone/<record>`; `kind`, `base_commit`, `frontier_blob`, `frozen_at`, `pinned` |
| `doc_update` | each document's Loro updates per branch, in order (`seq`) |
| `doc_snapshot` | each document's current snapshot per branch, and the last update it holds (`upto_seq`) |
| `peer` | a Loro peer per author per branch (`History::peer`): the user's session, an agent run, `external:<source>` |
| `pending` | a revert in progress (the hub finishes it at start-up) |
| `preview` | a revert preview until it is applied: its branch, the documents' versions then, its scope |

Ids: `DocId`, `OpId`, `PeerId`, `BranchId`; `WorktreeId::of(path, common_dir)` is the hex of both. A `Span { peer,
start, end }` names the element ids a record's operations made in one document (a peer's counters); a `Frontier` is
encoded Loro frontiers.

**A peer is never shared by two branches.** Loro ids are (peer, counter): one author writing on two branches under
one peer would make two different operations with one id, which corrupts a later merge. `History::peer(author,
branch)` makes a new one each time.

## Documents and branches

The document's text is UTF-8 with LF line ends (`text::canonical(bytes, coding)`): a DOS file (`Coding::Utf8Dos`, every
LF after a CR) holds LF and is written back with CRLF; a file that is binary (a NUL byte), is not UTF-8, or does not
round-trip through its coding (a bare LF in a DOS file) is `NotText` and takes the snapshot class (whole-file versions
in the hub's shadow repository). Offsets in a `Change { start, old_len, inserted }` are characters of that text.

A branch is rows; an **active** branch of a file is a Loro document in memory (`History::activate(doc, branch,
text_at_base)` → `ActiveDoc`). It is built on its first touch from the branch's base commit, and only then is
`text_at_base` called (lazy). Every worktree branch at one commit starts from the same seed: the base text inserted in
chunks of about 300 bytes, ascending, by a peer derived from the document and the commit (top bit set, so it never
meets a peer of `History::peer`), and a second branch at that commit copies the first's seed instead of reading the base
again. So branches share element ids up to their base and merge without crossing. Ascending chunks matter: later edits
on a document seeded in one insert cost 3–4 times as much (the spike, item 7).

`ActiveDoc::apply(peer, change)` applies one change as that peer's operations and stores them at once (`doc_update`);
it answers the span it made. A **current snapshot** is kept per document and branch: written again once
`SNAPSHOT_TAIL` (300) updates follow the last one, when a document is parked and when the history closes
(`History::close`, at hub stop). A load is that snapshot and a short tail: a million-event document loads in about 1 ms
from a fresh snapshot, but 1.5 s with any tail on an old one (the spike, item 1).

`History::park(doc, branch)` stores the snapshot and drops the document from memory; `History::park_idle(older_than,
now)` parks every document unused since an earlier call at least `older_than` seconds before `now` (the hub calls it on
its own clock, every minute, with 300 s). Nothing in verdandi reads a clock for these: the time is a parameter.

## The operation log

`Kind` is `edits`, `agent_step`, `decision`, `save`, `revert`, `restore`, `redo`, `fork`, `merge`, `rename`,
`external`, `compact` or `excise`. A `Cause` names the agent conversation, message, turn and step, the Urdr decision and
the task. `History::record(Record { kind, author, cause, spans, parents, git, summary, at })` writes one with its view:
every active branch head's version after the action. A `revert`, `restore` or `redo` must name the record it acts on
(a parent); a redo is a revert of the revert. Nothing is rewritten.

Typing is grouped by the **settle rule** (`Settler`): `change(doc, peer, spans, now)` as changes are applied; one
`edits` record per author per document after 30 s without a change (`settle_due(history, now)`), or at once on a save,
a buffer switch, an agent step boundary or a revert (`flush(history, reason, now)`). So typing makes a few hundred
records a day; the keystroke-level operations stay in the documents.

## Revert to here

`History::preview_revert(branch, scope)` → `RevertPreview { id, files, overlaps, threeway_differs }`, stored as a
`preview` row; it changes no document. `History::apply_revert(preview, choices, mode, peer, at)` applies it as one
`revert` record naming the scope, with every document's operations in one transaction; a document that moved since the
preview is refused as `stale`.

**Keep mine** (`Mode::KeepMine`). The scope's operations come from Loro's `export_json_in_id_span` over its spans. Each
element the scope inserted that is still there is deleted; each it deleted (read from the document just before that
deletion) is inserted again after its nearest surviving left neighbour, the latest deletion first, and a character
inserted again stands in for the one it replaces when a later run looks for its neighbour. The revert's operations are
new operations by the user's peer.

**Overlaps** are found by adjacency at the scope's own version: two scoped characters that were neighbours then and are
not now (the user typed between them), or a scoped character there then and gone now (the user deleted it). Counters
would not do: two different inserts of one agent have consecutive counters (the spike's first rule gave 121 false
positives in 300 cases). Each overlap is a hunk: `OverlapChoice::KeepUsers` (the default), `TakeReverted` (the user's
text inside the scope's insert goes with it) or `Edited(text)`.

**The 3-way check.** Where no overlap is found, the result is compared with `git merge-file -p` (ours: now; base: the
text after the scope; theirs: the text before it), run over three temporary files in a private folder. A clean merge
that differs is a bug in the span revert: the preview says `threeway_differs` and carries git's text, which the apply
then writes. `src/revert_props.rs` holds the property in 10,000 seeded cases (the spike's, through the history's own
records and a reload of each document from its rows): every case without an overlap equals git, and every overlap the
case made is found, and no other.

**Roll back mine too** (`Mode::RollBackMine`). The text goes back to what it was before the scope, applied as new
operations; the document as it was is kept as branch `undone/<record>`, so its hunks can be redone.

## The hub

`drgnx-ratatoskr/src/history/` is the hub side: capture, the editor's methods and the watcher feed. One `Hub` per
project (its git common folder), `history.db` under `<state>/hub/history/<project>/`. Its methods are synchronous and run
git; the front calls them in blocking tasks.

**Capture** (`capture.rs`). A file's new content comes from an agent's write (`on_agent_write`, called before the file is
written), the watcher (`on_disk_change`), a step-boundary rescan (`rescan`, `rescan_known`) or a git event
(`on_git_event`: one record for every file that differs between two commits). The content is read as an agent's files
must be: `eitri::read_regular` below the worktree's folder, no link followed, a FIFO refused at once. A link is recorded
as a link (a version in the snapshot class whose blob is the target's name), never read through; credentials files
(`gleipnir::toolchain::SECRET_FILES` and the snapshot's key files) are never read. Text becomes a diff onto the
document (`similar`, ascending, applied as the author's peer), and one record: `agent_step` with the cause, `external`
by the peer `external:disk` or `external:git`, `rename` for an agent's move. Binary files, files over 4 MB, lock files,
files `linguist-generated` in `.gitattributes` and links take the snapshot class: a version with a blob id and no
document. The blob id is `git hash-object --path` over the bytes read (the repository's filters), through the git
directory the tree names: the run's trusted store for a tree a sandboxed agent worked in, never plain git in such a tree.
Each version is published as the bus event `history/file-version {worktree, path, blob, op}`; its shape is frozen for its
consumers.

**Whose version** (`origin.rs`, pure). The hub registers a write before the file is written; the watcher's event about it
and a rescan then find it known. `OriginCore` takes `HubWrite`, `Watch` and `Rescan` events (a path and a content hash)
and answers which version each is: the hub's write, its own watcher event and a rescan are one version, the hub's; a
change another program made is its own, `Outside`. Tests run every order (`every_order_*`).

**Watcher** (`watch.rs`). One watcher per project: Hrafn's. `Project::tap` gives a second reader of its `WatchEvent`
stream; `history/register` starts a loop that feeds it to the hub (a changed file is diffed onto its document, a change
to `HEAD`, the index or a ref rescans every known path). Ignored files are skipped.

**Methods** (`methods.rs`, `wire.rs`; user only). `history/register {path, worktree_root, buffer_id}` answers
`{doc, tracked}`: a gitignored file, a credentials file, a personal-notes file and a folder a sandboxed agent worked in
are `tracked: false` with the reason. `history/batch {buffer_id, changes, region_hash}` applies changes (character
offsets in the document's LF text) as the origin's peer (`user`, or `agent:<session>` for a change merged in) and answers
`{ok}` or `{resync: true}` when the SHA-256 of the document's text differs from `region_hash`; more than 1 MiB inserted
is refused as `split-required`. `history/resync {buffer_id, text}` replaces the document's text as the user's change;
`history/unregister {buffer_id}` stops tracking.

**Timers** (`timers.rs`). Started with the project's hub, on the hub's clock (`crate::clock`, so `--test-clock` and
`__test_advance` decide them): typing settles into one `edits` record per author and document after 30 s without a
change (looked for every 5 s), and a document unused for 5 minutes is parked (looked for every minute, so a parked
document leaves memory between 5 and 6 minutes after its last use).

## The editor

`core/drgnx-history.el` (`drgnx-history-mode`, global) is the editor's side; it needs Nidhogg built with
`--with-nidhogg-history` and stays off without it. A file buffer inside a git project is registered with `history/register`
(on `find-file-hook`, and for every open file buffer when a hub connects; a hook never opens a connection). Nidhogg then
records each change to the buffer's text in a ring, outside the command's own work. The timer `history-drain` (every
0.1 s, through `drgnx-timer-*`) does nothing unless `nidhogg-history-pending-p`; otherwise it sends each tracked buffer's
ring as `history/batch`es with the SHA-256 of the buffer's whole text. A change that inserts more than 1 MiB is split into
pieces of at most a quarter of that many characters, and batches are filled up to the cap. The hub checks every batch
against the hash of the buffer's whole text, which costs time in proportion to the buffer (about 4 ms per MB), so a
buffer over 256 K characters is drained only after 0.3 s of idleness and its changes wait in the ring meanwhile. When the hub answers
`resync` (or Nidhogg drains the symbol `resync`), the ring is dropped and the whole text goes as `history/resync`. A hub
that goes drops every registration; the next connection registers the buffers again.

The module `tools/work-space` turns the mode on in its setup and off in its teardown.
A buffer that holds a large file (`drgnx-large-file-p`) is never registered, and one that becomes a large file is
unregistered at the next drain.

An indirect buffer shares its base's text, so only the base is registered and each change is recorded once.
`drgnx-history-with-origin` binds `nidhogg-history-origin` for code that writes into buffers for someone else (a merge,
a revert, git): the changes carry that origin. Emacs's own undo of them runs outside the macro, so it is the user's
change. Auto-revert binds `external:disk`.

## Testing

`test/unit/history-test.el` (pattern D: batch splitting, the origin macro, an indirect buffer, the mode's teardown, the
no-prompt lint) and `test/unit/history-hub-test.el` (pattern B: the real hub through the delivery gate; the answers to
batches and resyncs are the evidence). Rows that need the hook skip on a Nidhogg built without the flag.

`cargo test -p verdandi`: `tests/store.rs`, `tests/docs.rs`, `tests/log.rs`, `tests/revert.rs` and the property in
`src/revert_props.rs` (in the crate so it can use a store without a sync at each commit; its 10,000 cases make some
hundred thousand records). Every test is pattern D: a temporary folder, `git merge-file` at most, every time a
parameter. Loro and its own crates build with `opt-level = 3` in the dev profile (`runtime/Cargo.toml`), as the
embedder's do.
