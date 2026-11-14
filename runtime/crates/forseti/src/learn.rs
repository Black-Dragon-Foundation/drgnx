//! Learned placement (jobq §5.8, phase 3; runners design §6.8.2 "with F2"): link rates and speed ratios learned from
//! finished work, and expected times split warm and cold. Learning only changes estimates: [`crate::place::filter`]
//! (trust, the pin, features, state, modes, the matrix cell) and the cloud's terms decide as before, and with nothing
//! learned and no warmth known the estimate is the static rule's.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::history::{HistRow, expected};
use crate::model::Expected;
use crate::place::Candidate;

/// How far one sample moves an average.
pub const ALPHA: f64 = 0.3;

/// An exponentially weighted moving average; `None` until its first sample.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Ewma {
    pub value: Option<f64>,
}

impl Ewma {
    /// Takes a sample: the first becomes the average, each later one moves it by [`ALPHA`] of the difference. A
    /// sample that isn't a positive finite number is ignored.
    pub fn observe(&mut self, x: f64) {
        if !x.is_finite() || x <= 0.0 {
            return;
        }
        self.value = Some(match self.value {
            None => x,
            Some(v) => v + ALPHA * (x - v),
        });
    }
}

/// How a job would start on a runner: its slot is present at a near key, and its images are present.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Warmth {
    pub slot_near: bool,
    pub images_present: bool,
}

impl Warmth {
    /// A warm start needs both.
    pub fn warm(self) -> bool {
        self.slot_near && self.images_present
    }
}

/// What placement has learned: per runner the rate its transfers reached (bytes per second), and per `(machine,
/// other)` how much longer `machine` takes than `other` on the same history key (1.6: 60 % longer).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Learned {
    pub link_bps: HashMap<String, Ewma>,
    pub speed: HashMap<(String, String), Ewma>,
}

impl Learned {
    /// A transfer of `bytes` to `runner` took `secs`. An empty or timeless one teaches nothing.
    pub fn observe_transfer(&mut self, runner: &str, bytes: u64, secs: f64) {
        if bytes == 0 || secs.is_nan() || secs <= 0.0 {
            return;
        }
        self.link_bps
            .entry(runner.to_string())
            .or_default()
            .observe(bytes as f64 / secs);
    }

    /// A run finished as `row`; `rows` is its key's history. For each other machine with undisturbed runs of the
    /// key, `row`'s time over that machine's median is a sample of `(row.machine, other)`. A disturbed run teaches
    /// nothing.
    pub fn observe_run(&mut self, row: &HistRow, rows: &[HistRow]) {
        if row.disturbed || row.wall_s.is_nan() || row.wall_s <= 0.0 {
            return;
        }
        let same_key = |r: &&HistRow| r.key == row.key && r.machine != row.machine;
        let mut others: Vec<&str> = rows
            .iter()
            .filter(same_key)
            .filter(|r| !r.disturbed)
            .map(|r| r.machine.as_str())
            .collect();
        others.sort_unstable();
        others.dedup();
        for other in others {
            let theirs: Vec<HistRow> = rows
                .iter()
                .filter(same_key)
                .filter(|r| r.machine == other)
                .cloned()
                .collect();
            let median_s = expected(&theirs, &[], 1.0, None).minutes * 60.0;
            if median_s > 0.0 {
                self.speed
                    .entry((row.machine.clone(), other.to_string()))
                    .or_default()
                    .observe(row.wall_s / median_s);
            }
        }
    }

    /// The learned link rate to `runner`, bytes per second.
    pub fn link(&self, runner: &str) -> Option<f64> {
        self.link_bps.get(runner).and_then(|e| e.value)
    }

    /// The learned ratio of `machine`'s time to `other`'s.
    pub fn ratio(&self, machine: &str, other: &str) -> Option<f64> {
        self.speed
            .get(&(machine.to_string(), other.to_string()))
            .and_then(|e| e.value)
    }

    /// The expected time on `c` for a start that is warm (`slot_near` and `images_present`) or cold: from `c`'s
    /// history rows of the same kind of start, else from all of them ([`Learned::expected_for`]).
    pub fn expected_warm_cold(
        &self,
        c: &Candidate,
        slot_near: bool,
        images_present: bool,
    ) -> Expected {
        self.expected_for(
            c,
            Some(Warmth {
                slot_near,
                images_present,
            }),
        )
    }

    /// The expected time on `c`. With `warmth` known, only the rows of that kind of start count while there are
    /// undisturbed ones; else every row. From those rows:
    ///
    /// - `c`'s own runs (the median of the last 5 undisturbed);
    /// - else another machine's runs × the learned ratio of `c` to it: the machine with a learned ratio whose
    ///   undisturbed run is newest, ties going to the name first in order;
    /// - else the static rule ([`expected`]: other machines' runs × `c.speed`, else 10 minutes).
    pub fn expected_for(&self, c: &Candidate, warmth: Option<Warmth>) -> Expected {
        if let Some(w) = warmth {
            let like: Vec<HistRow> = c
                .history
                .iter()
                .filter(|r| r.warm == w.warm())
                .cloned()
                .collect();
            if like.iter().any(|r| !r.disturbed) {
                return self.estimate(c, &like);
            }
        }
        self.estimate(c, &c.history)
    }

    fn estimate(&self, c: &Candidate, rows: &[HistRow]) -> Expected {
        let (own, other): (Vec<HistRow>, Vec<HistRow>) =
            rows.iter().cloned().partition(|r| r.machine == c.name);
        if own.iter().any(|r| !r.disturbed) {
            return expected(&own, &[], 1.0, None);
        }
        let learned = other
            .iter()
            .filter(|r| !r.disturbed)
            .filter_map(|r| {
                self.ratio(&c.name, &r.machine)
                    .map(|k| (r.at, r.machine.as_str(), k))
            })
            .max_by(|a, b| a.0.cmp(&b.0).then(b.1.cmp(a.1)));
        if let Some((_, machine, k)) = learned {
            let theirs: Vec<HistRow> = other
                .iter()
                .filter(|r| r.machine == machine)
                .cloned()
                .collect();
            let mut e = expected(&theirs, &[], 1.0, None);
            e.minutes *= k;
            return e;
        }
        expected(&own, &other, c.speed, None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Grant, Priority, RunnerTrust, Verdict};
    use crate::place::{Accept, Pick, PlaceCtx, RunnerState, Send, finish_with, pick, pick_with};
    use crate::testkit::job;

    fn cand(name: &str) -> Candidate {
        Candidate {
            name: name.into(),
            local: false,
            trust: RunnerTrust::Mine,
            keys_allowed: vec![],
            os: Default::default(),
            features: vec![],
            state: RunnerState::Ready,
            accept: Accept::All,
            link_bps: None,
            missing_bytes: 0,
            start_s: 0.0,
            wait_s: 0.0,
            speed: 1.0,
            history: vec![],
            cloud: None,
        }
    }

    fn ctx() -> PlaceCtx {
        PlaceCtx {
            eff: Priority::P3,
            send: Send::All,
            machines_cell_allows: true,
            gates_allowed: false,
            cloud_after_s: 120.0,
            now: 1_000_000,
            commits_not_on_origin: 0,
        }
    }

    fn row(machine: &str, wall_s: f64, warm: bool, at: u64) -> HistRow {
        HistRow {
            key: "k".into(),
            machine: machine.into(),
            grant: Grant {
                cores: 1,
                mem_cap_mib: 1024,
                reserve_mib: 1024,
            },
            wall_s,
            cpu_s: wall_s,
            mem_peak_mib: 512,
            verdict: Verdict::Pass,
            disturbed: false,
            at,
            warm,
        }
    }

    fn warmth(warm: bool) -> Option<Warmth> {
        Some(Warmth {
            slot_near: warm,
            images_present: warm,
        })
    }

    #[test]
    fn a_warm_runner_wins_a_tie_on_speed() {
        // [D] pure. Two of my runners at the same speed with no history: equal estimates, and the warm one wins.
        let j = job("j", Priority::P3, 0);
        let none = Learned::default();
        let (a, b) = (cand("a"), cand("b"));
        let both = [a.clone(), b.clone()];
        assert_eq!(
            pick(&j, &both, &ctx()),
            Pick::Runner("a".into()),
            "by name alone"
        );
        let b_warm = |c: &Candidate| warmth(c.name == "b");
        assert_eq!(
            pick_with(&j, &both, &ctx(), &none, &b_warm),
            Pick::Runner("b".into())
        );
        // With history, a warm start is expected from the warm runs, a cold one from the cold runs.
        let rows = vec![
            row("a", 300.0, true, 1),
            row("a", 900.0, false, 2),
            row("b", 300.0, true, 3),
            row("b", 900.0, false, 4),
        ];
        let (mut a, mut b) = (a, b);
        a.history = rows.clone();
        b.history = rows;
        assert_eq!(
            none.expected_warm_cold(&a, true, true).minutes * 60.0,
            300.0
        );
        assert_eq!(
            none.expected_warm_cold(&a, true, false).minutes * 60.0,
            900.0
        );
        assert_eq!(
            none.expected_warm_cold(&a, false, true).minutes * 60.0,
            900.0
        );
        let both = [a.clone(), b.clone()];
        assert_eq!(
            pick_with(&j, &both, &ctx(), &none, &b_warm),
            Pick::Runner("b".into())
        );
        let a_warm = |c: &Candidate| warmth(c.name == "a");
        assert_eq!(
            pick_with(&j, &both, &ctx(), &none, &a_warm),
            Pick::Runner("a".into())
        );
        // Only warm runs known and a cold start: the static rule, every run of this machine.
        let mut only_warm = cand("a");
        only_warm.history = vec![row("a", 300.0, true, 1)];
        assert_eq!(
            none.expected_warm_cold(&only_warm, false, false).minutes * 60.0,
            300.0
        );
        // Cold here, but other machines know cold runs: theirs, at the static speed ratio.
        only_warm.history.push(row("z", 800.0, false, 2));
        only_warm.speed = 1.5;
        assert_eq!(
            none.expected_warm_cold(&only_warm, false, false).minutes * 60.0,
            1200.0
        );
    }

    #[test]
    fn learned_link_rate_changes_transfer() {
        // [D] pure
        let j = job("j", Priority::P3, 0);
        let mut c = cand("desktop");
        c.missing_bytes = 1_000_000_000;
        c.link_bps = Some(100_000_000.0);
        let mut l = Learned::default();
        assert_eq!(
            finish_with(&j, &c, 0, &l, None).transfer_s,
            10.0,
            "the measured rate"
        );
        l.observe_transfer("desktop", 1_000_000_000, 5.0);
        assert_eq!(
            l.link("desktop"),
            Some(200_000_000.0),
            "the first sample is the average"
        );
        assert_eq!(finish_with(&j, &c, 0, &l, None).transfer_s, 5.0);
        l.observe_transfer("desktop", 1_000_000_000, 20.0);
        let rate = l.link("desktop").unwrap();
        assert!(
            (rate - 155_000_000.0).abs() < 1e-3,
            "2e8 + 0.3 × (5e7 − 2e8): {rate}"
        );
        // Nothing learned from an empty or timeless transfer; another runner's rate doesn't apply.
        l.observe_transfer("desktop", 0, 3.0);
        l.observe_transfer("desktop", 1000, 0.0);
        assert_eq!(l.link("desktop"), Some(rate));
        assert_eq!(l.link("laptop"), None);
        let mut other = cand("laptop");
        other.missing_bytes = 1_000_000_000;
        other.link_bps = Some(100_000_000.0);
        assert_eq!(finish_with(&j, &other, 0, &l, None).transfer_s, 10.0);
        // The local machine transfers nothing.
        let mut local = cand("local");
        local.local = true;
        local.missing_bytes = 1_000_000_000;
        l.observe_transfer("local", 1, 1000.0);
        assert_eq!(finish_with(&j, &local, 0, &l, None).transfer_s, 0.0);
        // In the pick: a fast measured link wins; once the link is learned to be slow, the other runner wins.
        let mut slow_link = Learned::default();
        c.link_bps = Some(1_000_000_000.0);
        let mut near = cand("near");
        near.wait_s = 50.0;
        let cands = [c, near];
        let none = |_: &Candidate| None;
        assert_eq!(
            pick_with(&j, &cands, &ctx(), &slow_link, &none),
            Pick::Runner("desktop".into())
        );
        slow_link.observe_transfer("desktop", 1_000_000_000, 100.0);
        assert_eq!(
            pick_with(&j, &cands, &ctx(), &slow_link, &none),
            Pick::Runner("near".into())
        );
    }

    #[test]
    fn learned_speed_ratio_replaces_the_static_one() {
        // [D] pure
        let j = job("j", Priority::P3, 0);
        let mut c = cand("laptop");
        c.speed = 1.6;
        c.history = vec![row("desktop", 600.0, true, 1)];
        let mut l = Learned::default();
        assert_eq!(
            finish_with(&j, &c, 0, &l, None).expected_s,
            960.0,
            "the static ratio"
        );
        // A run of this key on the laptop took 900 s where the desktop's median is 600 s: 1.5.
        let ran = row("laptop", 900.0, true, 2);
        l.observe_run(&ran, &c.history);
        assert_eq!(l.ratio("laptop", "desktop"), Some(1.5));
        assert_eq!(l.ratio("desktop", "laptop"), None);
        assert_eq!(finish_with(&j, &c, 0, &l, None).expected_s, 900.0);
        // A disturbed run, another key's rows or the machine's own rows teach nothing.
        let mut disturbed = row("laptop", 6000.0, true, 3);
        disturbed.disturbed = true;
        l.observe_run(&disturbed, &c.history);
        let mut elsewhere = row("server", 100.0, true, 1);
        elsewhere.key = "other".into();
        l.observe_run(
            &row("laptop", 100.0, true, 4),
            &[elsewhere, row("laptop", 50.0, true, 1)],
        );
        assert_eq!(l.ratio("laptop", "desktop"), Some(1.5));
        assert_eq!(l.ratio("laptop", "server"), None);
        // With two learned machines, the one with the newest run counts.
        c.history.push(row("server", 400.0, true, 9));
        l.speed.insert(
            ("laptop".into(), "server".into()),
            Ewma { value: Some(2.0) },
        );
        assert_eq!(finish_with(&j, &c, 0, &l, None).expected_s, 800.0);
        // A ratio to a machine with no rows of this key changes nothing: the static rule.
        let mut fresh = cand("laptop");
        fresh.speed = 1.6;
        fresh.history = vec![row("desktop", 600.0, true, 1), row("box", 300.0, true, 2)];
        let mut only_desktop = Learned::default();
        only_desktop.speed.insert(
            ("laptop".into(), "elsewhere".into()),
            Ewma { value: Some(9.0) },
        );
        assert_eq!(
            finish_with(&j, &fresh, 0, &only_desktop, None).expected_s,
            finish_with(&j, &fresh, 0, &Learned::default(), None).expected_s
        );
    }
}
