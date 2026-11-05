//! Sets: cutting a suite's rows into chunks, and splitting a chunk that crashed around the row that did it
//! (job-scheduler design §8.1, §8.2 steps 1–4 and 6). Pure.
//!
//! A suite's listed rows become a **probe chunk** (priority 2: last time's reds, the rows the suite marks as probes,
//! the first few rows) and **the rest**, cut into chunks. When a chunk's verdict is `crash`, [`split_on_crash`] names
//! the suspect (the first listed row with no result) and what follows it; only a crash splits ([`splits`]). A set may
//! spawn at most [`split_budget`] extra jobs; past that its rows are `not run (split budget)`.

use crate::model::Verdict;

/// At most this many names go into one chunk's selector.
pub const MAX_NAMES: usize = 40;
/// The probe chunk always holds at least this many of the first rows.
pub const FIRST_ROWS: usize = 5;
/// What a row past the split budget is reported as.
pub const NOT_RUN_BUDGET: &str = "not run (split budget)";

/// A cut of a set's rows: run as one job. `probe` chunks are priority 2, the rest keep the set's own.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chunk {
    pub rows: Vec<String>,
    pub probe: bool,
}

impl Chunk {
    /// The selector that picks this chunk's rows: `^\(a\|b\)$` (Emacs alternation).
    pub fn selector(&self) -> String {
        selector(&self.rows)
    }
}

/// `regexp-quote`: what Emacs escapes in a literal.
fn quote(name: &str) -> String {
    let mut s = String::with_capacity(name.len());
    for c in name.chars() {
        if matches!(c, '[' | '*' | '.' | '\\' | '?' | '+' | '^' | '$') {
            s.push('\\');
        }
        s.push(c);
    }
    s
}

/// The selector for ROWS, as an Emacs regexp read from a string: `^\(a\|b\)$`, each name quoted. Never `|`.
pub fn selector(rows: &[String]) -> String {
    let names: Vec<String> = rows.iter().map(|r| quote(r)).collect();
    format!("^\\({}\\)$", names.join("\\|"))
}

/// How many chunks the rest is cut into: `clamp(set_minutes / max(8 min, 4 × overhead), 1, rows)`, raised to the free
/// parallel capacity when the machine is quiet (`quiet_parallel`), and to what [`MAX_NAMES`] needs.
pub fn chunk_count(
    rows: usize,
    set_minutes: f64,
    overhead_s: u64,
    quiet_parallel: Option<u32>,
) -> usize {
    if rows == 0 {
        return 0;
    }
    let overhead_min = overhead_s as f64 / 60.0;
    let per = (4.0 * overhead_min).max(8.0);
    let mut n = (set_minutes / per).floor().max(1.0) as usize;
    if let Some(p) = quiet_parallel {
        n = n.max(p as usize);
    }
    n = n.max(rows.div_ceil(MAX_NAMES));
    n.clamp(1, rows)
}

/// Cuts ROWS (in listing order) into chunks.
///
/// - The probe chunk: the rows in `red_last` or `probes`, and the first `max(5, 10 %)` rows, in listing order, split
///   at [`MAX_NAMES`] (each part a probe chunk).
/// - The rest: [`chunk_count`] near-equal contiguous chunks.
///
/// Every row is in exactly one chunk. A name in `red_last` or `probes` that isn't a listed row is ignored.
pub fn chunks(
    rows: &[String],
    set_minutes: f64,
    overhead_s: u64,
    quiet_parallel: Option<u32>,
    red_last: &[String],
    probes: &[String],
) -> Vec<Chunk> {
    let first = rows.len().min(FIRST_ROWS.max(rows.len().div_ceil(10)));
    let is_probe = |i: usize, r: &String| i < first || red_last.contains(r) || probes.contains(r);
    let (mut probe, mut rest) = (Vec::new(), Vec::new());
    for (i, r) in rows.iter().enumerate() {
        if is_probe(i, r) {
            probe.push(r.clone());
        } else {
            rest.push(r.clone());
        }
    }
    let mut out: Vec<Chunk> = probe
        .chunks(MAX_NAMES)
        .map(|c| Chunk {
            rows: c.to_vec(),
            probe: true,
        })
        .collect();
    let n = chunk_count(rest.len(), set_minutes, overhead_s, quiet_parallel);
    let (base, extra) = if n == 0 {
        (0, 0)
    } else {
        (rest.len() / n, rest.len() % n)
    };
    let mut at = 0;
    for i in 0..n {
        let len = base + usize::from(i < extra);
        out.push(Chunk {
            rows: rest[at..at + len].to_vec(),
            probe: false,
        });
        at += len;
    }
    out
}

/// Whether a chunk that ended with V is split: only a crash. An eviction, an OOM and an oomd kill (an `infra` end) are
/// the machine's, never the row's.
pub fn splits(v: &Verdict) -> bool {
    matches!(v, Verdict::Crash)
}

/// The job that runs the suspect alone (priority 2).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IsolateJob {
    pub row: String,
}

/// The job that runs the rows after the suspect (the chunk's own priority).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RestJob {
    pub rows: Vec<String>,
}

/// A crashed CHUNK whose rows `done_rows` have a result: the suspect is the first row of LISTED (the chunk's rows in
/// run order) without one, and the rest are the listed rows after it that have none. Nothing to split when every
/// listed row is done. The chunk keeps its done rows' results.
pub fn split_on_crash(
    chunk: &Chunk,
    done_rows: &[String],
    listed: &[String],
) -> (Option<IsolateJob>, Option<RestJob>) {
    let in_chunk = |r: &&String| chunk.rows.contains(*r);
    let pending: Vec<&String> = listed
        .iter()
        .filter(in_chunk)
        .filter(|r| !done_rows.contains(*r))
        .collect();
    let Some((suspect, rest)) = pending.split_first() else {
        return (None, None);
    };
    let rest: Vec<String> = rest.iter().map(|r| (*r).clone()).collect();
    (
        Some(IsolateJob {
            row: (*suspect).clone(),
        }),
        (!rest.is_empty()).then_some(RestJob { rows: rest }),
    )
}

/// How many extra jobs a set of ROWS rows may spawn from splitting: `max(3, rows / 10)`.
pub fn split_budget(rows: usize) -> u32 {
    (rows / 10).max(3) as u32
}

/// A set's splitting budget.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SplitBudget {
    left: u32,
}

/// What [`SplitBudget::split`] decided.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Split {
    /// The jobs to start.
    Jobs {
        isolate: IsolateJob,
        rest: Option<RestJob>,
    },
    /// The budget is spent: these rows are `not run (split budget)`.
    NotRun(Vec<String>),
    /// Every row has a result.
    Nothing,
}

impl SplitBudget {
    pub fn new(set_rows: usize) -> SplitBudget {
        SplitBudget {
            left: split_budget(set_rows),
        }
    }

    pub fn left(&self) -> u32 {
        self.left
    }

    /// [`split_on_crash`] charged to the budget: one job for the isolated row, one for the rest. When it doesn't pay,
    /// nothing is charged and the pending rows are `NotRun`.
    pub fn split(&mut self, chunk: &Chunk, done_rows: &[String], listed: &[String]) -> Split {
        match split_on_crash(chunk, done_rows, listed) {
            (None, _) => Split::Nothing,
            (Some(isolate), rest) => {
                let cost = 1 + u32::from(rest.is_some());
                if cost > self.left {
                    let mut rows = vec![isolate.row];
                    rows.extend(rest.map(|r| r.rows).unwrap_or_default());
                    return Split::NotRun(rows);
                }
                self.left -= cost;
                Split::Jobs { isolate, rest }
            }
        }
    }
}

/// What an isolated row's run says.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Isolated {
    /// It crashed alone: `crash`, with its log.
    Crash,
    /// It passed alone: the crash depends on order. With bisecting ([`crate::bisect`]) the done rows are searched; before
    /// it, the row is reported `crash (order-dependent?)` and the rest still runs.
    OrderDependent,
}

/// The isolated row's run ended with V.
pub fn after_isolate(v: &Verdict) -> Isolated {
    if matches!(v, Verdict::Pass) {
        Isolated::OrderDependent
    } else {
        Isolated::Crash
    }
}

/// The rows of LISTED that have no result in DONE, in listing order: what a lost attempt's requeue runs, so rows
/// already done are never run again and none is dropped.
pub fn remaining_rows(listed: &[String], done: &[RowResult]) -> Vec<String> {
    listed
        .iter()
        .filter(|r| !done.iter().any(|d| &d.row == *r))
        .cloned()
        .collect()
}

/// A row's result as the parser read it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RowResult {
    pub row: String,
    pub pass: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn names(n: usize) -> Vec<String> {
        (0..n).map(|i| format!("t{i}")).collect()
    }

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    // [D] pure
    #[test]
    fn probe_chunk_takes_reds_probes_and_first_5() {
        let rows = names(100);
        let out = chunks(&rows, 80.0, 60, None, &s(&["t50"]), &s(&["t70", "nope"]));
        assert!(out[0].probe);
        assert_eq!(
            out[0].rows,
            s(&[
                "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t50", "t70"
            ])
        );
        assert!(out[1..].iter().all(|c| !c.probe));
        // a small suite: the first 5 and nothing else is a probe unless marked
        let small = chunks(&names(20), 80.0, 60, None, &[], &[]);
        assert_eq!(small[0].rows, names(5));
    }

    // [D] pure
    #[test]
    fn chunk_count_formula() {
        // 80 min / max(8, 4 x 1) = 10
        assert_eq!(chunk_count(200, 80.0, 60, None), 10);
        // a 5 min overhead: 80 / 20 = 4, but 200 rows need 5 chunks of at most 40
        assert_eq!(chunk_count(200, 80.0, 300, None), 5);
        assert_eq!(chunk_count(100, 80.0, 300, None), 4);
        // quiet parallel capacity raises it
        assert_eq!(chunk_count(100, 80.0, 300, Some(6)), 6);
        // never more than the rows, never fewer than one
        assert_eq!(chunk_count(3, 800.0, 60, None), 3);
        assert_eq!(chunk_count(50, 1.0, 60, None), 2);
        assert_eq!(chunk_count(0, 80.0, 60, None), 0);
        let rest = chunks(&names(105), 80.0, 300, None, &[], &[]);
        assert_eq!(
            rest.iter().filter(|c| !c.probe).count(),
            chunk_count(94, 80.0, 300, None)
        );
    }

    // [D] pure
    #[test]
    fn selector_uses_backslash_bar_and_at_most_40() {
        let c = Chunk {
            rows: s(&["a", "b.c", "d+e"]),
            probe: false,
        };
        assert_eq!(c.selector(), "^\\(a\\|b\\.c\\|d\\+e\\)$");
        assert!(!c.selector().contains('|') || c.selector().contains("\\|"));
        let all = chunks(&names(500), 800.0, 60, None, &[], &[]);
        assert!(
            all.iter().all(|c| c.rows.len() <= MAX_NAMES),
            "{:?}",
            all.iter().map(|c| c.rows.len()).collect::<Vec<_>>()
        );
    }

    // [D] pure
    #[test]
    fn evicted_oom_and_oomd_never_split() {
        assert!(splits(&Verdict::Crash));
        for v in [
            Verdict::Evicted,
            Verdict::Oom,
            Verdict::Pass,
            Verdict::Red,
            Verdict::Timeout,
            Verdict::Cancelled,
            Verdict::Infra("oomd/killed".into()),
            Verdict::Infra("killed".into()),
        ] {
            assert!(!splits(&v), "{v}");
        }
    }

    // [D] pure
    #[test]
    fn the_suspect_is_the_first_row_without_a_result() {
        let listed = names(6);
        let chunk = Chunk {
            rows: listed.clone(),
            probe: false,
        };
        let (iso, rest) = split_on_crash(&chunk, &s(&["t0", "t1"]), &listed);
        assert_eq!(iso, Some(IsolateJob { row: "t2".into() }));
        assert_eq!(
            rest,
            Some(RestJob {
                rows: s(&["t3", "t4", "t5"])
            })
        );
        let (iso, rest) = split_on_crash(&chunk, &s(&["t0", "t1", "t2", "t3", "t4"]), &listed);
        assert_eq!((iso, rest), (Some(IsolateJob { row: "t5".into() }), None));
        assert_eq!(split_on_crash(&chunk, &listed, &listed), (None, None));
        assert_eq!(after_isolate(&Verdict::Pass), Isolated::OrderDependent);
        assert_eq!(after_isolate(&Verdict::Crash), Isolated::Crash);
    }

    // [D] pure
    #[test]
    fn split_budget_stops_at_max_3_or_tenth() {
        assert_eq!(split_budget(5), 3);
        assert_eq!(split_budget(30), 3);
        assert_eq!(split_budget(100), 10);
        let listed = names(30);
        let chunk = Chunk {
            rows: listed.clone(),
            probe: false,
        };
        let mut b = SplitBudget::new(30);
        let mut done: Vec<String> = vec![];
        // each crash costs 2 jobs (isolate + rest): one split fits in 3, the second doesn't
        match b.split(&chunk, &done, &listed) {
            Split::Jobs { isolate, rest } => {
                assert_eq!(isolate.row, "t0");
                assert_eq!(rest.unwrap().rows.len(), 29);
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(b.left(), 1);
        done.push("t0".into());
        match b.split(&chunk, &done, &listed) {
            Split::NotRun(rows) => assert_eq!(rows.len(), 29),
            other => panic!("{other:?}"),
        }
        assert_eq!(b.left(), 1, "a refused split charges nothing");
        // a last row alone costs one job
        let last = Chunk {
            rows: s(&["z"]),
            probe: false,
        };
        assert!(matches!(
            b.split(&last, &[], &s(&["z"])),
            Split::Jobs { rest: None, .. }
        ));
        assert_eq!(b.left(), 0);
        assert_eq!(b.split(&last, &s(&["z"]), &s(&["z"])), Split::Nothing);
    }

    // [D] pure
    #[test]
    fn a_requeue_plan_skips_done_rows() {
        let listed = names(5);
        let done = vec![
            RowResult {
                row: "t1".into(),
                pass: true,
            },
            RowResult {
                row: "t3".into(),
                pass: false,
            },
        ];
        assert_eq!(remaining_rows(&listed, &done), s(&["t0", "t2", "t4"]));
    }

    proptest! {
        // [D] property
        #[test]
        fn split_covers_every_row_exactly_once(
            n in 0usize..300,
            minutes in 1.0f64..400.0,
            overhead in 0u64..900,
            parallel in proptest::option::of(1u32..20),
            reds in proptest::collection::vec(0usize..300, 0..10),
            probes in proptest::collection::vec(0usize..300, 0..10),
        ) {
            let rows = names(n);
            let pick = |ix: &[usize]| ix.iter().filter(|i| **i < n).map(|i| rows[*i].clone()).collect::<Vec<_>>();
            let out = chunks(&rows, minutes, overhead, parallel, &pick(&reds), &pick(&probes));
            let mut seen: Vec<String> = out.iter().flat_map(|c| c.rows.clone()).collect();
            prop_assert!(out.iter().all(|c| !c.rows.is_empty() && c.rows.len() <= MAX_NAMES));
            seen.sort();
            let mut want = rows.clone();
            want.sort();
            prop_assert_eq!(seen, want);
        }

        // [D] property
        #[test]
        fn a_requeue_plan_covers_every_row_exactly_once(n in 0usize..100, mask in proptest::collection::vec(any::<bool>(), 100)) {
            let listed = names(n);
            let done: Vec<RowResult> = listed.iter().zip(&mask).filter(|(_, m)| **m).map(|(r, _)| RowResult { row: r.clone(), pass: true }).collect();
            let rest = remaining_rows(&listed, &done);
            let mut all: Vec<String> = done.iter().map(|d| d.row.clone()).chain(rest).collect();
            all.sort();
            let mut want = listed.clone();
            want.sort();
            prop_assert_eq!(all, want);
        }
    }
}
