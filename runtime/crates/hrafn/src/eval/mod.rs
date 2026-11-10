//! The eval that ships with drgnx (storage design §12A.3 item 8): questions made from a repository's own history, a run
//! of them against an index, and the non-inferiority gate between two runs.
//!
//! - `gen` makes the questions: each commit subject is a behaviour question whose answer is the top-level forms the
//!   commit changed, found again at HEAD through the symbol table. The sets are frozen once made (`write_sets`).
//! - `metrics` scores a run (MRR@10 and nDCG@10 at chunk level, file MRR@10 and recall@5 and @10 at file level,
//!   bootstrap intervals per stratum) and compares two runs pairwise, on chunk or file MRR@10.
//! - [`run`] asks the questions through a closure, so the caller decides how a query is embedded and which model
//!   answers; this crate has no model.

mod r#gen;
mod metrics;

pub use r#gen::{HISTORY_LIMIT, clean_subject, generate, read_set, write_sets};
pub use metrics::{
    Delta, Gate, Judged, OVERALL_FLOOR, Report, RowScore, STRATUM_FLOOR, Summary, Verdict, ci,
    compare, compare_on, judge,
};

use crate::query::{Answer, Hit, Query, Scope};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// How many hits a question asks for.
pub const K: u32 = 10;

/// One question.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EvalRow {
    /// The commit's first 12 characters.
    pub id: String,
    /// `symbol`, `config`, `cross-file`, `docs` or `tests`.
    pub stratum: String,
    pub query: String,
    /// `(path, symbol)` of the chunks that hold the change, at HEAD; an empty symbol is any chunk of the file.
    pub targets: Vec<(String, String)>,
    /// Days between the commit and the newest one.
    pub age_days: u32,
    /// The first directory of the first target.
    pub dir: String,
    /// `dev` or `test`.
    pub half: String,
}

/// Asks every row of ROWS through ANSWER and scores the answers.
pub fn run(rows: &[EvalRow], answer: &dyn Fn(&Query) -> Answer) -> Report {
    let mut scores: BTreeMap<String, RowScore> = BTreeMap::new();
    for r in rows {
        let q = Query {
            text: r.query.clone(),
            scope: Scope::All,
            k: K,
        };
        let a = answer(&q);
        scores.insert(
            r.id.clone(),
            RowScore {
                stratum: r.stratum.clone(),
                judged: judge(&r.targets, &a.hits),
            },
        );
    }
    let mut strata: BTreeMap<String, Summary> = BTreeMap::new();
    for s in scores.values().map(|r| r.stratum.clone()) {
        strata
            .entry(s.clone())
            .or_insert_with(|| metrics::summarize(scores.values().filter(|r| r.stratum == s)));
    }
    Report {
        overall: metrics::summarize(scores.values()),
        rows: scores,
        strata,
        coverage_errors: Vec::new(),
        exact_symbol_r1: None,
    }
}

/// The share of NAMES (`(name, path, first symbol of its chunk)` of definitions) whose first hit is the chunk that
/// defines it (a hit's `symbol` is its chunk's first one): the gate wants 1.0. The first misses come back too, each as
/// a line saying what answered instead.
pub fn exact_symbol_floor(
    names: &[(String, String, String)],
    answer: &dyn Fn(&Query) -> Answer,
) -> (f64, Vec<String>) {
    if names.is_empty() {
        return (1.0, Vec::new());
    }
    let mut misses = Vec::new();
    let mut ok = 0usize;
    for (name, path, chunk) in names {
        let q = Query {
            text: name.clone(),
            scope: Scope::All,
            k: 1,
        };
        let first: Option<Hit> = answer(&q).hits.into_iter().next();
        if first
            .as_ref()
            .is_some_and(|h| &h.path == path && h.symbol.as_deref() == Some(chunk.as_str()))
        {
            ok += 1;
        } else if misses.len() < 10 {
            misses.push(format!(
                "{name} ({path}, chunk {chunk}) answered by {}",
                first.map_or("nothing".to_string(), |h| format!(
                    "{}:{} {:?} via {:?}",
                    h.path, h.line_start, h.symbol, h.routes
                ))
            ));
        }
    }
    (ok as f64 / names.len() as f64, misses)
}
