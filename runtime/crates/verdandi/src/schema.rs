//! `history.db`'s migrations, as data (urdr runs each batch once, under `BEGIN IMMEDIATE`, and keeps the version in
//! `meta.schema`).

/// Schema 1: the records and their parents, the documents with their updates and snapshots per branch, the peers,
/// the branches, the pending revert and the stored previews.
const V1: &str = "
create table op(
  id integer primary key, kind text not null, author integer not null, cause_json text not null,
  spans_blob blob not null, view_blob blob not null, git text, summary text not null, at real not null);
create table op_parent(
  op integer not null references op(id), parent integer not null references op(id),
  primary key (op, parent)) without rowid;
create table doc(id integer primary key, path text not null unique, created real not null,
  class text not null default 'text');
create table branch(
  id integer primary key, name text not null unique, kind text not null check (kind in ('wt', 'fork', 'undone')),
  base_commit text, frontier_blob blob, frozen_at real, pinned integer not null default 0);
create table doc_update(
  doc integer not null references doc(id), branch integer not null references branch(id), seq integer not null,
  bytes blob not null, primary key (doc, branch, seq)) without rowid;
create table doc_snapshot(
  doc integer not null references doc(id), branch integer not null references branch(id),
  upto_seq integer not null, bytes blob not null, primary key (doc, branch)) without rowid;
create table peer(id integer primary key, author_json text not null, branch integer references branch(id));
create table pending(op integer primary key references op(id), json text not null, at real not null);
create table preview(
  id integer primary key, branch integer not null references branch(id), frontier_blob blob not null,
  json text not null, at real not null);
";

/// Schema 2: where text applied by diff came from (the source's element ids), per record.
const V2: &str = "
create table provenance(op integer primary key references op(id), spans_blob blob not null);
";

/// Schema 3: anchors (a cursor on an element id, the version it was made at, who asked).  `op` is the newest record
/// then (0: none), the oldest history the anchor still needs.
const V3: &str = "
create table anchor(
  id integer primary key, doc integer not null references doc(id), branch integer not null references branch(id),
  cursor_blob blob not null, frontier_blob blob not null, op integer not null, owner text not null);
";

/// Schema 4: where compaction cut a document's history on a branch: records up to and including `op` are past it.
const V4: &str = "
create table doc_cut(
  doc integer not null references doc(id), branch integer not null references branch(id), op integer not null,
  primary key (doc, branch)) without rowid;
";

/// Every migration, oldest first.
pub(crate) const MIGRATIONS: &[(u32, &str)] = &[(1, V1), (2, V2), (3, V3), (4, V4)];
