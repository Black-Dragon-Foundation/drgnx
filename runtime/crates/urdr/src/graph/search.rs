//! Full text over entities (contentless FTS5, quoted queries), the 1-bit + int8 vector scan ported from
//! `core/drgnx-search-store.el`, and reciprocal-rank fusion (Task 5; storage §10).

use std::future::Future;
use std::pin::Pin;

use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};

use super::tx::Tx;
use super::writer::WriteError;

/// A boxed, sendable future (no `futures` crate in the workspace; mimir's is the same type).
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Put entity N's FTS row (rowid = N): delete, then insert (never a partial `UPDATE`). The replaced row's tokens
/// stay in the index under a tombstone (the old text is in `entity_hist` anyway) until [`fts_delete`] or a merge.
pub fn fts_put(
    tx: &mut Tx<'_>,
    n: i64,
    title: Option<&str>,
    body: Option<&str>,
) -> Result<(), WriteError> {
    let sql = tx.sql();
    sql.execute("delete from entity_fts where rowid = ?1", params![n])?;
    sql.execute(
        "insert into entity_fts(rowid, title, body) values (?1, ?2, ?3)",
        params![n, title, body],
    )?;
    Ok(())
}

/// Delete entity N's FTS row by rowid, and its tokens with it. A contentless-delete table only tombstones a deleted
/// rowid (its terms stay in the segment, and FTS5's `secure-delete` cannot reach them: it needs the old values,
/// which such a table refuses), so the delete is followed by `optimize`: every segment is rewritten without its
/// tombstoned entries (this row's and every replaced version's), and `secure_delete=ON` zeroes the old pages.
pub fn fts_delete(tx: &mut Tx<'_>, n: i64) -> Result<(), WriteError> {
    let sql = tx.sql();
    sql.execute("delete from entity_fts where rowid = ?1", params![n])?;
    sql.execute("insert into entity_fts(entity_fts) values ('optimize')", [])?;
    Ok(())
}

/// A full-text hit.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Hit {
    pub n: i64,
    /// `bm25`: lower is better.
    pub rank: f64,
    pub snippet: Option<String>,
}

/// bm25's weight of a title match against a body match (the code search's `bm25(…)` weights start 5/5/2/1 the
/// same way: names count more than text).
const TITLE_WEIGHT: f64 = 5.0;
const BODY_WEIGHT: f64 = 1.0;
/// The snippet's length in characters, and how many of them come before the first match.
const SNIPPET_LEN: usize = 160;
const SNIPPET_LEAD: usize = 40;

/// Q's words (letters, digits, `_`; each once, in order). Nothing else of Q reaches FTS5.
fn words(q: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for w in q.split(|c: char| !(c.is_alphanumeric() || c == '_')) {
        if !w.is_empty() && !out.iter().any(|o| o == w) {
            out.push(w.to_string());
        }
    }
    out
}

/// An FTS5 `MATCH` with Q's words quoted as phrases (no FTS syntax passes through), ranked by `bm25`.
///
/// The words are joined by `OR`, as the Lisp store does, so `AND`, `NOT`, `NEAR`, `*`, `^`, `title:` and the like in a
/// query are plain words or nothing. A query with no word answers nothing. Snippets come from `entity.body` (the
/// FTS table is contentless): about [`SNIPPET_LEN`] characters around the first matching word, else the start of
/// the body, else the title.
pub fn find_fts(conn: &Connection, q: &str, limit: u32) -> rusqlite::Result<Vec<Hit>> {
    let ws = words(q);
    if ws.is_empty() || limit == 0 {
        return Ok(Vec::new());
    }
    let m = ws
        .iter()
        .map(|w| format!("\"{w}\""))
        .collect::<Vec<_>>()
        .join(" OR ");
    let mut st = conn.prepare(
        "select entity_fts.rowid, bm25(entity_fts, ?2, ?3) as r, e.title, e.body \
         from entity_fts join entity e on e.n = entity_fts.rowid \
         where entity_fts match ?1 and e.retired_tx is null order by r, entity_fts.rowid limit ?4",
    )?;
    let rows = st.query_map(
        params![m, TITLE_WEIGHT, BODY_WEIGHT, i64::from(limit)],
        |r| {
            let title: Option<String> = r.get(2)?;
            let body: Option<String> = r.get(3)?;
            Ok(Hit {
                n: r.get(0)?,
                rank: r.get(1)?,
                snippet: snippet(title.as_deref(), body.as_deref(), &ws),
            })
        },
    )?;
    rows.collect()
}

/// A character that compares equal across case (one char to one char, so offsets stay valid).
fn fold(c: char) -> char {
    c.to_lowercase().next().unwrap_or(c)
}

fn snippet(title: Option<&str>, body: Option<&str>, ws: &[String]) -> Option<String> {
    let text = match body {
        Some(b) if !b.trim().is_empty() => b,
        _ => {
            return title
                .map(|t| t.trim().to_string())
                .filter(|t| !t.is_empty());
        }
    };
    let chars: Vec<char> = text.chars().collect();
    let folded: Vec<char> = chars.iter().map(|&c| fold(c)).collect();
    let first = ws
        .iter()
        .filter_map(|w| {
            let wf: Vec<char> = w.chars().map(fold).collect();
            folded
                .windows(wf.len())
                .position(|win| win == wf.as_slice())
        })
        .min();
    let start = first.map_or(0, |p| p.saturating_sub(SNIPPET_LEAD));
    let end = (start + SNIPPET_LEN).min(chars.len());
    let mut s: String = chars[start..end]
        .iter()
        .map(|&c| if c.is_whitespace() { ' ' } else { c })
        .collect();
    s = s.trim().to_string();
    if start > 0 {
        s.insert(0, '…');
    }
    if end < chars.len() {
        s.push('…');
    }
    Some(s)
}

/// The vector scheme of `drgnx-search-store`, byte-equal for its fixtures.
pub mod vec {
    use std::collections::BinaryHeap;

    /// `(bits, int8, scale)`: the sign bits as the blob's bytes (`entity_vec.bits`), the int8 values
    /// (`entity_vec.vec`) and their scale (`entity_vec.scale`).
    ///
    /// `drgnx-search-quantize`, exactly: bit `i % 8` of byte `i / 8` is set when `v[i] > 0`; `scale` is
    /// `max|v| / 127` (0 for the zero vector); `int8[i]` is `round(v[i] / scale)` (halves to even, as Emacs's
    /// `round`), in -127..=127. The input is meant to be normalised.
    pub fn quantize(v: &[f32]) -> (Vec<u8>, Vec<i8>, f64) {
        let mut bits = vec![0u8; v.len().div_ceil(8)];
        let mut peak = 0.0f64;
        for &x in v {
            peak = peak.max(f64::from(x).abs());
        }
        let scale = peak / 127.0;
        let mut ints = vec![0i8; v.len()];
        for (i, &x) in v.iter().enumerate() {
            let x = f64::from(x);
            if x > 0.0 {
                bits[i >> 3] |= 1 << (i & 7);
            }
            if scale != 0.0 {
                ints[i] = (x / scale).round_ties_even().clamp(-127.0, 127.0) as i8;
            }
        }
        (bits, ints, scale)
    }

    fn distance(a: &[u8], b: &[u8]) -> u32 {
        let mut d = 0;
        let ((ca, ra), (cb, rb)) = (a.as_chunks::<8>(), b.as_chunks::<8>());
        for (x, y) in ca.iter().zip(cb) {
            d += (u64::from_le_bytes(*x) ^ u64::from_le_bytes(*y)).count_ones();
        }
        for (x, y) in ra.iter().zip(rb) {
            d += (x ^ y).count_ones();
        }
        d
    }

    /// The K rows nearest QUERY's bits by Hamming distance: `(n, distance)`, nearest first, ties by `n`. A row whose
    /// fingerprint is not QUERY's length (another model's) is skipped.
    pub fn hamming_scan(rows: &[(i64, Vec<u8>)], query: &[u8], k: usize) -> Vec<(i64, u32)> {
        if k == 0 {
            return Vec::new();
        }
        // A max-heap of the best K so far: the worst of them is on top.
        let mut heap: BinaryHeap<(u32, i64)> = BinaryHeap::with_capacity(k + 1);
        for (n, bits) in rows {
            if bits.len() != query.len() {
                continue;
            }
            let item = (distance(bits, query), *n);
            if heap.len() < k {
                heap.push(item);
            } else if heap.peek().is_some_and(|worst| item < *worst) {
                heap.pop();
                heap.push(item);
            }
        }
        heap.into_sorted_vec()
            .into_iter()
            .map(|(d, n)| (n, d))
            .collect()
    }

    /// Re-rank candidates `(n, int8, scale)` by their dot product with QUERY: the best K, `(n, score)`, best first,
    /// ties by `n`.
    ///
    /// As the Lisp: QUERY is quantized too, and the score is the integer dot product of the two int8 vectors times
    /// both scales (the cosine estimate of two unit vectors). A candidate of another length is skipped.
    pub fn rerank(candidates: &[(i64, Vec<i8>, f64)], query: &[f32], k: usize) -> Vec<(i64, f64)> {
        let (_, qi, qs) = quantize(query);
        let mut out: Vec<(i64, f64)> = candidates
            .iter()
            .filter(|(_, v, _)| v.len() == qi.len())
            .map(|(n, v, s)| {
                let dot: i64 = qi
                    .iter()
                    .zip(v)
                    .map(|(&a, &b)| i64::from(a) * i64::from(b))
                    .sum();
                (*n, dot as f64 * qs * s)
            })
            .collect();
        out.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
        out.truncate(k);
        out
    }
}

/// Reciprocal-rank fusion: `sum 1 / (K + rank)` over LISTS (rank from 1), best first, ties by `n`.
pub fn rrf(lists: &[Vec<i64>], k: u32) -> Vec<(i64, f64)> {
    let mut score: std::collections::HashMap<i64, f64> = std::collections::HashMap::new();
    for list in lists {
        for (i, &n) in list.iter().enumerate() {
            *score.entry(n).or_insert(0.0) += 1.0 / (f64::from(k) + (i + 1) as f64);
        }
    }
    let mut out: Vec<(i64, f64)> = score.into_iter().collect();
    out.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
    out
}

/// Why an embedding failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EmbedError(pub String);

/// Something that embeds texts (Task 12b: the `tei` provider through the gateway).
pub trait Embedder: Send + Sync {
    fn embed<'a>(&'a self, texts: &'a [String])
    -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>>;
    fn model(&self) -> &str;
}

/// Store entity N's vector V of MODEL (replacing any it had).
pub fn vec_put(tx: &mut Tx<'_>, n: i64, model: &str, v: &[f32]) -> Result<(), WriteError> {
    let (bits, ints, scale) = vec::quantize(v);
    let blob: Vec<u8> = ints.iter().map(|&i| i as u8).collect();
    tx.sql().execute(
        "insert or replace into entity_vec(n, bits, vec, scale, model) values (?1, ?2, ?3, ?4, ?5)",
        params![n, bits, blob, scale, model],
    )?;
    Ok(())
}

/// Up to LIMIT live entities that have text (a title or a body) and no vector of MODEL, by `n`.
pub fn vec_stale(conn: &Connection, model: &str, limit: u32) -> rusqlite::Result<Vec<i64>> {
    let mut st = conn.prepare(
        "select e.n from entity e \
         where e.retired_tx is null and (e.title is not null or e.body is not null) \
           and not exists (select 1 from entity_vec v where v.n = e.n and v.model = ?1) \
         order by e.n limit ?2",
    )?;
    let rows = st.query_map(params![model, i64::from(limit)], |r| r.get(0))?;
    rows.collect()
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::graph::schema::GRAPH_DDL;
    use crate::graph::tx::{Class, TxMeta};

    fn db() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch(GRAPH_DDL).unwrap();
        c
    }

    /// A live entity with its FTS row, written through a test tx; its `n`.
    fn put(c: &mut Connection, id: &str, title: Option<&str>, body: Option<&str>) -> i64 {
        let mut tx = Tx::for_test(c, TxMeta::new("user", Class::User, "test"), Arc::default());
        let t = tx.id();
        tx.sql()
            .execute(
                "insert into entity(id, kind, title, body, origin, ver, created_tx, updated_tx) \
                 values (?1, 'task', ?2, ?3, 'recorded', 1, ?4, ?4)",
                params![id, title, body, t],
            )
            .unwrap();
        let n = tx.sql().last_insert_rowid();
        fts_put(&mut tx, n, title, body).unwrap();
        tx.commit_for_test().unwrap();
        n
    }

    #[test]
    fn fts_syntax_from_a_query_is_quoted() {
        let mut c = db();
        let a = put(&mut c, "task:a", Some("alpha beta"), Some("plain words"));
        let b = put(&mut c, "task:b", Some("gamma"), Some("only alpha here"));
        // Operators, a column filter, a prefix star, parentheses and an open quote are words or nothing.
        for q in [
            "alpha\" OR (",
            "title:alpha",
            "alpha AND zzz",
            "NEAR(alpha beta) *",
            "^alpha -beta",
            "alpha NOT gamma",
        ] {
            let hits = find_fts(&c, q, 10).unwrap_or_else(|e| panic!("{q:?} reached FTS5: {e}"));
            assert!(hits.iter().any(|h| h.n == a), "{q:?} should find alpha");
        }
        // OR of plain words: `AND` is only a word, so a second word does not narrow.
        let hits = find_fts(&c, "alpha AND zzz", 10).unwrap();
        assert!(hits.iter().any(|h| h.n == b));
        // A star is not a prefix match, a column filter is not a filter.
        assert!(find_fts(&c, "alp*", 10).unwrap().is_empty());
        assert!(
            find_fts(&c, "body:gamma", 10)
                .unwrap()
                .iter()
                .any(|h| h.n == b)
        );
        // No word at all: nothing, no error.
        assert!(find_fts(&c, "\" ( ) * :", 10).unwrap().is_empty());
        assert!(find_fts(&c, "", 10).unwrap().is_empty());
    }

    #[test]
    fn find_ranks_title_over_body() {
        let mut c = db();
        let in_body = put(
            &mut c,
            "task:body",
            Some("something else entirely"),
            Some("the migration is mentioned here"),
        );
        let in_title = put(
            &mut c,
            "task:title",
            Some("migration"),
            Some("something else entirely here"),
        );
        let hits = find_fts(&c, "migration", 10).unwrap();
        assert_eq!(
            hits.iter().map(|h| h.n).collect::<Vec<_>>(),
            [in_title, in_body]
        );
        assert!(hits[0].rank < hits[1].rank, "bm25: lower is better");
        // Snippets come from the entity: the match's neighbourhood, or the title when there is no body.
        assert!(
            hits[1]
                .snippet
                .as_deref()
                .unwrap()
                .contains("migration is mentioned")
        );
        let t = put(&mut c, "task:nobody", Some("migration only title"), None);
        let hit = find_fts(&c, "migration", 10)
            .unwrap()
            .into_iter()
            .find(|h| h.n == t)
            .unwrap();
        assert_eq!(hit.snippet.as_deref(), Some("migration only title"));
        // The limit applies.
        assert_eq!(find_fts(&c, "migration", 2).unwrap().len(), 2);
    }

    #[test]
    fn find_fts_skips_retired() {
        let mut c = db();
        let live = put(&mut c, "task:live", Some("migration"), None);
        let gone = put(&mut c, "task:gone", Some("migration"), None);
        {
            let tx = Tx::for_test(
                &mut c,
                TxMeta::new("user", Class::User, "test"),
                Arc::default(),
            );
            // Retire keeps the FTS row (entity::retire); the search filters it.
            tx.sql()
                .execute(
                    "update entity set retired_tx = 1 where n = ?1",
                    params![gone],
                )
                .unwrap();
            tx.commit_for_test().unwrap();
        }
        let hits = find_fts(&c, "migration", 10).unwrap();
        assert_eq!(hits.iter().map(|h| h.n).collect::<Vec<_>>(), [live]);
    }

    #[test]
    fn fts_put_replaces_and_fts_delete_removes() {
        let mut c = db();
        let n = put(&mut c, "task:a", Some("first"), None);
        {
            let mut tx = Tx::for_test(
                &mut c,
                TxMeta::new("user", Class::User, "test"),
                Arc::default(),
            );
            fts_put(&mut tx, n, Some("second"), None).unwrap();
            tx.commit_for_test().unwrap();
        }
        assert!(find_fts(&c, "first", 5).unwrap().is_empty());
        assert_eq!(find_fts(&c, "second", 5).unwrap().len(), 1);
        {
            let mut tx = Tx::for_test(
                &mut c,
                TxMeta::new("user", Class::User, "test"),
                Arc::default(),
            );
            fts_delete(&mut tx, n).unwrap();
            tx.commit_for_test().unwrap();
        }
        assert!(find_fts(&c, "second", 5).unwrap().is_empty());
    }

    #[derive(Deserialize)]
    struct Case {
        input: Vec<f32>,
        bits: Vec<u8>,
        int8: Vec<i8>,
        scale: f64,
    }

    #[test]
    fn quantize_matches_the_lisp_fixtures() {
        // test/fixtures/quantize/cases.json: the Lisp quantizer's outputs (`gen.el` there regenerates them).
        let cases: Vec<Case> = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../test/fixtures/quantize/cases.json"
        )))
        .unwrap();
        assert!(cases.len() >= 4);
        for (i, c) in cases.iter().enumerate() {
            let (bits, int8, scale) = vec::quantize(&c.input);
            assert_eq!(bits, c.bits, "case {i}: bits");
            assert_eq!(int8, c.int8, "case {i}: int8");
            assert_eq!(scale.to_bits(), c.scale.to_bits(), "case {i}: scale");
        }
    }

    /// A tiny deterministic generator (xorshift): values in -1..1.
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> f32 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            ((self.0 >> 11) as f64 / (1u64 << 52) as f64 * 2.0 - 1.0) as f32
        }
        fn unit(&mut self, dims: usize) -> Vec<f32> {
            let v: Vec<f32> = (0..dims).map(|_| self.next()).collect();
            let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
            v.into_iter().map(|x| x / norm).collect()
        }
    }

    #[test]
    fn hamming_then_rerank_recall() {
        let dims = 128;
        let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
        let corpus: Vec<Vec<f32>> = (0..1000).map(|_| rng.unit(dims)).collect();
        let rows: Vec<(i64, Vec<u8>)> = corpus
            .iter()
            .enumerate()
            .map(|(i, v)| (i as i64, vec::quantize(v).0))
            .collect();
        let stored: Vec<(i64, Vec<i8>, f64)> = corpus
            .iter()
            .enumerate()
            .map(|(i, v)| {
                let (_, ints, s) = vec::quantize(v);
                (i as i64, ints, s)
            })
            .collect();
        for target in (0..1000).step_by(50) {
            // A query close to one stored vector: it must come out first, and its score must be near 1.
            let q: Vec<f32> = corpus[target]
                .iter()
                .map(|x| x + 0.1 * rng.next() / 11.0)
                .collect();
            let norm = q.iter().map(|x| x * x).sum::<f32>().sqrt();
            let q: Vec<f32> = q.into_iter().map(|x| x / norm).collect();
            let near = vec::hamming_scan(&rows, &vec::quantize(&q).0, 100);
            assert_eq!(near.len(), 100);
            assert!(near.windows(2).all(|w| w[0].1 <= w[1].1), "nearest first");
            assert_eq!(
                near[0].0, target as i64,
                "the planted vector is the nearest by bits"
            );
            let cands: Vec<_> = near
                .iter()
                .map(|(n, _)| stored[*n as usize].clone())
                .collect();
            let best = vec::rerank(&cands, &q, 5);
            assert_eq!(best.len(), 5);
            assert_eq!(best[0].0, target as i64);
            assert!(best[0].1 > 0.9, "cosine estimate {}", best[0].1);
            assert!(best.windows(2).all(|w| w[0].1 >= w[1].1), "best first");
        }
    }

    #[test]
    fn hamming_scan_orders_skips_and_breaks_ties_by_n() {
        let rows = vec![
            (7, vec![0b1111_0000]),
            (3, vec![0b0000_0001]),
            (5, vec![0b0000_0001]),
            (9, vec![0, 0]), // another length: skipped
            (1, vec![0b1111_1111]),
        ];
        let got = vec::hamming_scan(&rows, &[0b0000_0001], 3);
        assert_eq!(got, [(3, 0), (5, 0), (7, 5)]);
        assert!(vec::hamming_scan(&rows, &[0], 0).is_empty());
        // More than 8 bytes: the u64 path and the remainder agree with a bit count.
        let a: Vec<u8> = (0..19).collect();
        let b: Vec<u8> = (0..19).map(|i| i ^ 0b101).collect();
        assert_eq!(vec::hamming_scan(&[(1, a)], &b, 1), [(1, 19 * 2)]);
    }

    #[test]
    fn rrf_matches_the_formula() {
        let got = rrf(&[vec![1, 2, 3], vec![3, 1]], 60);
        let want = [
            (1, 1.0 / 61.0 + 1.0 / 62.0),
            (3, 1.0 / 63.0 + 1.0 / 61.0),
            (2, 1.0 / 62.0),
        ];
        assert_eq!(got.len(), 3);
        // 1 and 3: 1/61 + 1/62 = 0.032522…, 1/61 + 1/63 = 0.032266…: 1 first.
        for (g, w) in got.iter().zip(want) {
            assert_eq!(g.0, w.0);
            assert!((g.1 - w.1).abs() < 1e-12, "{g:?} vs {w:?}");
        }
        assert!(rrf(&[], 60).is_empty());
    }

    #[test]
    fn vec_stale_lists_missing_and_other_model() {
        let mut c = db();
        let a = put(&mut c, "task:a", Some("a"), None);
        let b = put(&mut c, "task:b", Some("b"), None);
        let d = put(&mut c, "task:d", Some("d"), None);
        let blank = put(&mut c, "task:blank", None, None);
        {
            let mut tx = Tx::for_test(
                &mut c,
                TxMeta::new("user", Class::User, "test"),
                Arc::default(),
            );
            vec_put(&mut tx, a, "m1", &[0.6, 0.8]).unwrap();
            vec_put(&mut tx, b, "m2", &[0.6, 0.8]).unwrap();
            tx.sql()
                .execute("update entity set retired_tx = 1 where n = ?1", params![d])
                .unwrap();
            tx.commit_for_test().unwrap();
        }
        // m1: a has one; b only has another model's; d is retired; blank has no text.
        assert_eq!(vec_stale(&c, "m1", 10).unwrap(), [b]);
        assert_eq!(vec_stale(&c, "m2", 10).unwrap(), [a]);
        assert_eq!(vec_stale(&c, "m3", 10).unwrap(), [a, b]);
        assert_eq!(vec_stale(&c, "m3", 1).unwrap(), [a]);
        let _ = (d, blank);
        // vec_put stores the quantizer's output, and a second put replaces the first.
        {
            let mut tx = Tx::for_test(
                &mut c,
                TxMeta::new("user", Class::User, "test"),
                Arc::default(),
            );
            vec_put(&mut tx, a, "m1", &[-1.0, 0.25]).unwrap();
            tx.commit_for_test().unwrap();
        }
        let (bits, blob, scale): (Vec<u8>, Vec<u8>, f64) = c
            .query_row(
                "select bits, vec, scale from entity_vec where n = ?1 and model = 'm1'",
                [a],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(bits, [0b10]);
        assert_eq!(
            blob.iter().map(|&b| b as i8).collect::<Vec<_>>(),
            [-127, 32]
        );
        assert_eq!(scale, 1.0 / 127.0);
    }
}
