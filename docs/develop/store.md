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
  `insert into entity_fts(entity_fts, rank) values('secure-delete', 1)`, and the writer runs with
  `secure_delete=ON`: a deleted row's tokens leave the file (FTS5 before 3.42.0 cannot read the table afterwards;
  no Lisp reader opens it).
- A current link has `tx_to = SENTINEL` (2^62). Current reads plan on `link_cur`, as-of reads on `link_out` or
  `link_in` (`tx_to > T`, `tx_from <= T`).

## The writer (Task 1)

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
