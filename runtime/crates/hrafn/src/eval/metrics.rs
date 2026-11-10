//! The eval's numbers: what one query scored, the summaries with bootstrap intervals, and the paired comparison.

use crate::query::Hit;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// Bootstrap resamples, and the seed of their generator: the same reports always give the same interval.
const RESAMPLES: usize = 2000;
const SEED: u64 = 0x5eed_1e57_c0de_0001;

/// What one query scored.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Judged {
    /// Reciprocal rank of the first target in the top 10 (chunk level), else 0.
    pub rr: f64,
    pub ndcg: f64,
    /// The share of the target files found in the top 5, and in the top 10.
    pub file_at5: f64,
    pub file_at10: f64,
    /// Reciprocal rank of the first hit in any target file in the top 10, whatever its symbol, else 0; none in a
    /// report made before it was measured.
    #[serde(default)]
    pub file_rr: Option<f64>,
}

fn is_target(t: &(String, String), h: &Hit) -> bool {
    h.path == t.0 && (t.1.is_empty() || h.symbol.as_deref() == Some(t.1.as_str()))
}

/// Scores HITS against TARGETS, which are `(path, symbol)` of the chunk that holds the change (an empty symbol: any
/// chunk of the file). A target counts once, at the first hit that matches it.
pub fn judge(targets: &[(String, String)], hits: &[Hit]) -> Judged {
    let top = &hits[..hits.len().min(10)];
    let mut found: BTreeSet<usize> = BTreeSet::new();
    let (mut rr, mut dcg) = (0.0, 0.0);
    for (rank, h) in top.iter().enumerate() {
        let Some(i) = targets
            .iter()
            .enumerate()
            .find(|(i, t)| !found.contains(i) && is_target(t, h))
            .map(|(i, _)| i)
        else {
            continue;
        };
        found.insert(i);
        if rr == 0.0 {
            rr = 1.0 / (rank as f64 + 1.0);
        }
        dcg += 1.0 / (rank as f64 + 2.0).log2();
    }
    let ideal: f64 = (0..targets.len().min(10))
        .map(|r| 1.0 / (r as f64 + 2.0).log2())
        .sum();
    let files: BTreeSet<&str> = targets.iter().map(|t| t.0.as_str()).collect();
    let at = |k: usize| {
        let got: BTreeSet<&str> = hits
            .iter()
            .take(k)
            .filter(|h| targets.iter().any(|t| is_target(t, h)))
            .map(|h| h.path.as_str())
            .collect();
        if files.is_empty() {
            0.0
        } else {
            got.len() as f64 / files.len() as f64
        }
    };
    let file_rr = top
        .iter()
        .position(|h| files.contains(h.path.as_str()))
        .map_or(0.0, |r| 1.0 / (r as f64 + 1.0));
    Judged {
        rr,
        ndcg: if ideal > 0.0 { dcg / ideal } else { 0.0 },
        file_at5: at(5),
        file_at10: at(10),
        file_rr: Some(file_rr),
    }
}

/// A seeded generator (splitmix64).
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

fn mean(v: &[f64]) -> f64 {
    if v.is_empty() {
        0.0
    } else {
        v.iter().sum::<f64>() / v.len() as f64
    }
}

/// The 95 % percentile interval of the mean of V, by bootstrap.
pub fn ci(v: &[f64]) -> (f64, f64) {
    if v.is_empty() {
        return (0.0, 0.0);
    }
    let mut rng = Rng(SEED);
    let mut means: Vec<f64> = (0..RESAMPLES)
        .map(|_| {
            mean(
                &(0..v.len())
                    .map(|_| v[rng.below(v.len())])
                    .collect::<Vec<_>>(),
            )
        })
        .collect();
    means.sort_by(f64::total_cmp);
    let at = |q: f64| means[((RESAMPLES as f64 - 1.0) * q).round() as usize];
    (at(0.025), at(0.975))
}

/// A summary of some queries.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Summary {
    pub n: usize,
    pub mrr: f64,
    pub mrr_ci: (f64, f64),
    pub ndcg: f64,
    pub ndcg_ci: (f64, f64),
    pub recall5: f64,
    pub recall10: f64,
    /// File MRR@10 (see [`Judged::file_rr`]); 0 in a report made before it was measured.
    #[serde(default)]
    pub file_mrr: f64,
    #[serde(default)]
    pub file_mrr_ci: (f64, f64),
}

pub(crate) fn summarize<'a>(rows: impl Iterator<Item = &'a RowScore>) -> Summary {
    let rows: Vec<&RowScore> = rows.collect();
    let col = |f: &dyn Fn(&RowScore) -> f64| rows.iter().map(|r| f(r)).collect::<Vec<_>>();
    let (rr, ndcg) = (col(&|r| r.judged.rr), col(&|r| r.judged.ndcg));
    let file_rr = col(&|r| r.judged.file_rr.unwrap_or(0.0));
    Summary {
        file_mrr: mean(&file_rr),
        file_mrr_ci: ci(&file_rr),
        n: rows.len(),
        mrr: mean(&rr),
        mrr_ci: ci(&rr),
        ndcg: mean(&ndcg),
        ndcg_ci: ci(&ndcg),
        recall5: mean(&col(&|r| r.judged.file_at5)),
        recall10: mean(&col(&|r| r.judged.file_at10)),
    }
}

/// One query's score, with its stratum.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RowScore {
    pub stratum: String,
    #[serde(flatten)]
    pub judged: Judged,
}

/// A run: each query's score by row id (so two runs can be compared pairwise), the summaries, and the two floors the
/// gate also reads, which the caller fills in (they need the store).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Report {
    pub rows: BTreeMap<String, RowScore>,
    pub overall: Summary,
    pub strata: BTreeMap<String, Summary>,
    /// What `hrafn::coverage` said of the index this run searched.
    #[serde(default)]
    pub coverage_errors: Vec<String>,
    /// The share of exact symbol names whose first hit is their definition (the gate needs 1.0).
    #[serde(default)]
    pub exact_symbol_r1: Option<f64>,
}

/// A mean difference with its interval.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Delta {
    pub mean: f64,
    pub lo: f64,
    pub hi: f64,
    pub n: usize,
}

fn delta(a: &[f64], b: &[f64]) -> Delta {
    let d: Vec<f64> = a.iter().zip(b).map(|(x, y)| y - x).collect();
    let (lo, hi) = ci(&d);
    Delta {
        mean: mean(&d),
        lo,
        hi,
        n: d.len(),
    }
}

/// The gate's verdict: B against A.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Verdict {
    pub pass: bool,
    pub overall: Delta,
    pub strata: BTreeMap<String, Delta>,
    pub reasons: Vec<String>,
}

/// The lower bound of the overall MRR@10 difference must stay above this, and each stratum's above the second.
pub const OVERALL_FLOOR: f64 = -0.01;
pub const STRATUM_FLOOR: f64 = -0.03;

/// What the gate compares: chunk-level MRR@10 (a target's symbol must match), or file MRR@10 (any hit in a target
/// file), which is fair to a chunker that gives a language no symbols.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Gate {
    Chunk,
    File,
}

/// B against A on the same queries, on chunk-level MRR@10: [`compare_on`] with [`Gate::Chunk`].
pub fn compare(a: &Report, b: &Report) -> Result<Verdict, String> {
    compare_on(a, b, Gate::Chunk)
}

/// B against A on the same queries: paired bootstrap of the difference of GATE's metric. B passes when the interval's
/// lower bound is at least [`OVERALL_FLOOR`] overall and [`STRATUM_FLOOR`] in every stratum, B's index has no coverage
/// error and its exact-symbol recall (when measured) is 1.0. Reports over different queries are refused, and so is the
/// file gate over a report that has no file ranks.
pub fn compare_on(a: &Report, b: &Report, gate: Gate) -> Result<Verdict, String> {
    if a.rows.keys().ne(b.rows.keys()) {
        return Err(format!(
            "the reports are over different queries ({} and {} rows): a paired difference needs the same ones",
            a.rows.len(),
            b.rows.len()
        ));
    }
    if gate == Gate::File
        && a.rows
            .values()
            .chain(b.rows.values())
            .any(|r| r.judged.file_rr.is_none())
    {
        return Err("a report has no file MRR (made before it was measured): run it again".into());
    }
    let (metric, label): (fn(&Judged) -> f64, &str) = match gate {
        Gate::Chunk => (|j| j.rr, "MRR@10"),
        Gate::File => (|j| j.file_rr.unwrap_or(0.0), "file MRR@10"),
    };
    let pair = |filter: &dyn Fn(&RowScore) -> bool| {
        let (mut x, mut y) = (Vec::new(), Vec::new());
        for (id, ra) in &a.rows {
            if filter(ra) {
                x.push(metric(&ra.judged));
                y.push(metric(&b.rows[id].judged));
            }
        }
        delta(&x, &y)
    };
    let overall = pair(&|_| true);
    let mut reasons = Vec::new();
    if overall.lo < OVERALL_FLOOR {
        reasons.push(format!(
            "overall: the lower bound of the {label} difference is {:.4}, below {OVERALL_FLOOR}",
            overall.lo
        ));
    }
    let mut strata = BTreeMap::new();
    for s in a.strata.keys() {
        let d = pair(&|r| &r.stratum == s);
        if d.lo < STRATUM_FLOOR {
            reasons.push(format!(
                "stratum {s}: the lower bound of the {label} difference is {:.4}, below {STRATUM_FLOOR}",
                d.lo
            ));
        }
        strata.insert(s.clone(), d);
    }
    if !b.coverage_errors.is_empty() {
        reasons.push(format!(
            "coverage: {} error(s), e.g. {}",
            b.coverage_errors.len(),
            b.coverage_errors[0]
        ));
    }
    if let Some(r) = b.exact_symbol_r1
        && r < 1.0
    {
        reasons.push(format!("exact-symbol recall@1 is {r:.4}, not 1.0"));
    }
    Ok(Verdict {
        pass: reasons.is_empty(),
        overall,
        strata,
        reasons,
    })
}
