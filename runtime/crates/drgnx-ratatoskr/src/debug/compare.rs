//! How far a fork matched its run (spec §19.3, "matched on N hits"), and the What-if tab's lanes.
//!
//! An `output` event carries no thread, so each probe hit names its thread by the thread expression's value
//! ([`super::fork_probes::thread_expr`]). Those values differ between two runs (`threading.get_ident()`), so threads
//! are paired by the order of their first hit: the fork's stopping thread is the k-th thread to hit a probe in the
//! fork, and is compared with the k-th thread of the run. Matching is a count, not a yes or no: the hits of that
//! thread before the fork point, in order, until the first difference.

use super::fork_run::{RunHit, RunProbe};

/// The first hit that differs: the probe, its how-manyth hit on the thread (1-based), the run's value and the fork's
/// (none: the fork had fewer hits).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FirstDiff {
    pub probe: String,
    pub hit: u32,
    pub then: String,
    pub now: Option<String>,
}

/// "matched on `matched` of `of` hits", and where it first differed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Matched {
    pub matched: u32,
    pub of: u32,
    pub first: Option<FirstDiff>,
}

/// The threads of HITS in the order of their first hit.
fn threads(hits: &[RunHit]) -> Vec<&str> {
    let mut out: Vec<&str> = vec![];
    for h in hits {
        if !out.contains(&h.thread.as_str()) {
            out.push(&h.thread);
        }
    }
    out
}

/// THEN (the run's hits before the fork point) against NOW (the fork's), on the fork's stopping thread NOW_THREAD
/// (none: the first thread to hit) and the run's thread of the same rank.
pub fn matched(then: &[RunHit], now: &[RunHit], now_thread: Option<&str>) -> Matched {
    let now_threads = threads(now);
    let rank = now_thread
        .and_then(|t| now_threads.iter().position(|x| *x == t))
        .unwrap_or(0);
    let then_thread = threads(then).get(rank).copied();
    let now_thread = now_threads.get(rank).copied();
    let a: Vec<&RunHit> = then
        .iter()
        .filter(|h| Some(h.thread.as_str()) == then_thread)
        .collect();
    let b: Vec<&RunHit> = now
        .iter()
        .filter(|h| Some(h.thread.as_str()) == now_thread)
        .collect();
    let mut first = None;
    let mut matched = 0u32;
    for (i, h) in a.iter().enumerate() {
        let other = b.get(i);
        if other.is_some_and(|o| o.probe == h.probe && o.value == h.value) {
            matched += 1;
            continue;
        }
        let hit = a[..=i].iter().filter(|x| x.probe == h.probe).count() as u32;
        first = Some(FirstDiff {
            probe: h.probe.clone(),
            hit,
            then: h.value.clone(),
            now: other.map(|o| o.value.clone()),
        });
        break;
    }
    Matched {
        matched,
        of: a.len() as u32,
        first,
    }
}

/// One probe's values after the fork point, in the run and in the fork.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Lane {
    pub probe: String,
    pub then: Vec<String>,
    pub now: Vec<String>,
}

/// The lanes of PROBES: THEN's and NOW's hits after the fork point, per probe, in PROBES' order.
pub fn lanes(probes: &[RunProbe], then: &[RunHit], now: &[RunHit]) -> Vec<Lane> {
    let of = |hits: &[RunHit], p: &str| {
        hits.iter()
            .filter(|h| h.probe == p)
            .map(|h| h.value.clone())
            .collect()
    };
    probes
        .iter()
        .map(|p| Lane {
            probe: p.id.clone(),
            then: of(then, &p.id),
            now: of(now, &p.id),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hit(probe: &str, thread: &str, value: &str, seq: u64) -> RunHit {
        RunHit {
            probe: probe.into(),
            thread: thread.into(),
            value: value.into(),
            seq,
        }
    }

    /// A deterministic run: 20 of 20, nothing differs.
    #[test]
    fn deterministic_matches_every_hit() {
        let then: Vec<RunHit> = (0..20)
            .map(|i| hit("p", "111", &i.to_string(), i))
            .collect();
        let now: Vec<RunHit> = (0..20)
            .map(|i| hit("p", "999", &i.to_string(), i + 5))
            .collect();
        let m = matched(&then, &now, Some("999"));
        assert_eq!(
            m,
            Matched {
                matched: 20,
                of: 20,
                first: None
            }
        );
    }

    /// The first difference names the probe and its hit: "probe shortfall, hit 2: 12 then, 11 now".
    #[test]
    fn first_difference_named() {
        let then = vec![
            hit("total", "1", "4", 0),
            hit("shortfall", "1", "16", 1),
            hit("shortfall", "1", "12", 2),
            hit("shortfall", "1", "9", 3),
        ];
        let now = vec![
            hit("total", "7", "4", 0),
            hit("shortfall", "7", "16", 1),
            hit("shortfall", "7", "11", 2),
        ];
        let m = matched(&then, &now, Some("7"));
        assert_eq!(m.matched, 2);
        assert_eq!(m.of, 4);
        assert_eq!(
            m.first,
            Some(FirstDiff {
                probe: "shortfall".into(),
                hit: 2,
                then: "12".into(),
                now: Some("11".into()),
            })
        );
    }

    /// Fewer hits in the fork: the difference has no value now.
    #[test]
    fn fewer_hits_now() {
        let then = vec![hit("p", "1", "a", 0), hit("p", "1", "b", 1)];
        let now = vec![hit("p", "2", "a", 0)];
        let m = matched(&then, &now, None);
        assert_eq!(m.matched, 1);
        assert_eq!(m.first.unwrap().now, None);
    }

    /// Threads pair by the order of their first hit; the other thread's hits do not count.
    #[test]
    fn stopping_thread_paired_by_rank() {
        let then = vec![
            hit("p", "A", "1", 0),
            hit("p", "B", "x", 1),
            hit("p", "B", "y", 2),
            hit("p", "A", "2", 3),
        ];
        let now = vec![
            hit("p", "a", "1", 0),
            hit("p", "b", "x", 1),
            hit("p", "a", "2", 2),
            hit("p", "b", "DIFFERENT", 3),
        ];
        // the fork stopped on its first thread: A against a, both 2 of 2
        let m = matched(&then, &now, Some("a"));
        assert_eq!((m.matched, m.of, m.first), (2, 2, None));
        // on its second: B against b, the second hit differs
        let m = matched(&then, &now, Some("b"));
        assert_eq!((m.matched, m.of), (1, 2));
        assert_eq!(m.first.unwrap().now.as_deref(), Some("DIFFERENT"));
    }

    #[test]
    fn lanes_per_probe() {
        let probes = vec![
            RunProbe {
                id: "a".into(),
                path: "/p/x.py".into(),
                line: 3,
                expr: "x".into(),
            },
            RunProbe {
                id: "b".into(),
                path: "/p/x.py".into(),
                line: 4,
                expr: "y".into(),
            },
        ];
        let then = vec![hit("a", "1", "1", 0), hit("b", "1", "2", 1)];
        let now = vec![hit("b", "1", "3", 0)];
        assert_eq!(
            lanes(&probes, &then, &now),
            vec![
                Lane {
                    probe: "a".into(),
                    then: vec!["1".into()],
                    now: vec![],
                },
                Lane {
                    probe: "b".into(),
                    then: vec!["2".into()],
                    now: vec!["3".into()],
                },
            ]
        );
    }
}
