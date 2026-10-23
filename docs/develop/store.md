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

`urdr::graph::search` holds full text, the vector scheme and rank fusion. Nothing in it knows a kind.

- **Full text.** `entity_fts(title, body)` is contentless with delete; its rowid is `entity.n`. `fts_put` deletes the
  row and inserts it (never an `UPDATE`), `fts_delete` deletes by rowid; the entity primitives call them in the
  same transaction as the change. `find_fts(conn, q, limit)` takes the words of `q` (letters, digits, `_`), quotes each,
  and joins them with `OR`: no operator, column filter, prefix star or `NEAR` from a query reaches FTS5, and a query with
  no word answers nothing. Hits are ranked by `bm25(entity_fts, 5, 1)` (a title match counts five body matches;
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
