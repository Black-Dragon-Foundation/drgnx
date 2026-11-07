//! Strikes, the bench and the health check (docs/develop/hub.md, "Runners: health"; design §6.9).
//!
//! A **strike** is an infrastructure failure that is the runner's ([`is_strike`]); reds, crashes, a job's own OOM,
//! timeouts, preemptions and evictions never are. Two consecutive strikes, or two within an hour, take the runner out
//! of rotation (benched: [`Strikes`]). Every 5 minutes the hub checks each runner ([`judge`] over [`Facts`]: the probe
//! and the contract, a canary `true` in its image under the caps, disk above the guard, its clock within 2 s); a pass
//! returns it with zero strikes.

use forseti::Verdict;
use forseti::classify::infra;

/// Two strikes within this many seconds bench a runner.
pub const BENCH_WINDOW_S: u64 = 3600;
/// How often a runner's health is checked.
pub const CHECK_EVERY_S: u64 = 300;
/// How long a check waits for its answers before judging what it has.
pub const CHECK_WAIT_S: u64 = 120;
/// How far a runner's clock may be off the hub's.
pub const CLOCK_SKEW_S: i64 = 2;
/// The disk that stays free on a runner: at least this many GB, and [`DISK_FLOOR_PCT`] of its filesystem.
pub const DISK_FLOOR_GB: u64 = 20;
pub const DISK_FLOOR_PCT: u64 = 10;

/// The infra reasons the hub adds to forseti's: the job's image missing or its pull failed, sync failed, and the
/// health check (or `check_limits`) failed.
pub const IMAGE: &str = "image";
pub const SYNC: &str = "sync";
pub const CHECK: &str = "health check";

/// What decides a strike besides the verdict.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct StrikeCtx {
    /// How many times the runner's link was lost with jobs running today, this one included.
    pub link_lost_today: u32,
    /// The runner's link stayed up through the job.
    pub link_stayed_up: bool,
}

/// Whether V is the runner's fault (design §6.9): setup or sync failed, the image is missing or its pull failed, the
/// disk guard couldn't free room, the runner's ladder killed jobs, the link was lost while jobs ran (twice the same
/// day), the health check failed, a key not delivered on a link that stayed up.
pub fn is_strike(v: &Verdict, ctx: &StrikeCtx) -> bool {
    let Verdict::Infra(why) = v else {
        return false;
    };
    match why.as_str() {
        infra::SETUP | SYNC | IMAGE | infra::DISK | infra::KILLED | CHECK => true,
        infra::RUNNER_LOST => ctx.link_lost_today >= 2,
        infra::KEY_NOT_DELIVERED => ctx.link_stayed_up,
        _ => false,
    }
}

/// A verdict that shows the runner ran a job: it ends a run of strikes.
fn ran(v: &Verdict) -> bool {
    matches!(
        v,
        Verdict::Pass
            | Verdict::Red
            | Verdict::Crash
            | Verdict::Timeout
            | Verdict::Oom
            | Verdict::Evicted
            | Verdict::Cancelled
    )
}

/// One runner's strikes since its last passing check, and its bench.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Strikes {
    /// Each strike: when, and why.
    at: Vec<(u64, String)>,
    in_a_row: u32,
    benched: Option<String>,
    /// The day (since the epoch) and how many links were lost with jobs running on it.
    lost: (u64, u32),
}

impl Strikes {
    /// A verdict of one of the runner's jobs at NOW; true when it benches the runner now.
    pub fn record(&mut self, now: u64, v: &Verdict, ctx: &StrikeCtx) -> bool {
        if is_strike(v, ctx) {
            return self.strike(now, &v.to_string());
        }
        if ran(v) {
            self.in_a_row = 0;
        }
        false
    }

    /// A strike at NOW for REASON; true when it benches the runner now.
    pub fn strike(&mut self, now: u64, reason: &str) -> bool {
        self.in_a_row += 1;
        self.at.push((now, reason.to_string()));
        let recent = self
            .at
            .iter()
            .filter(|(t, _)| now.saturating_sub(*t) <= BENCH_WINDOW_S)
            .count();
        if (self.in_a_row >= 2 || recent >= 2) && self.benched.is_none() {
            self.benched = Some(reason.to_string());
            return true;
        }
        false
    }

    /// The runner's link was lost with jobs running at NOW: how many times today, this one included.
    pub fn lost_link(&mut self, now: u64) -> u32 {
        let day = now / 86_400;
        if self.lost.0 != day {
            self.lost = (day, 0);
        }
        self.lost.1 += 1;
        self.lost.1
    }

    /// A passing check, or the user's `unbench`: no strikes, back in rotation.
    pub fn clear(&mut self) {
        *self = Strikes {
            lost: self.lost,
            ..Strikes::default()
        };
    }

    /// The reason of the strike that benched the runner, while it is benched.
    pub fn benched(&self) -> Option<&str> {
        self.benched.as_deref()
    }

    /// Strikes since the last clear.
    pub fn count(&self) -> u32 {
        self.at.len() as u32
    }

    /// The last strike's reason.
    pub fn last(&self) -> Option<&str> {
        self.at.last().map(|(_, r)| r.as_str())
    }

    /// The runner list's words: `benched: REASON (HH:MM, HH:MM)`, the times of its last two strikes (UTC).
    pub fn text(&self) -> Option<String> {
        let reason = self.benched.as_ref()?;
        let times: Vec<String> = self
            .at
            .iter()
            .rev()
            .take(2)
            .rev()
            .map(|(t, _)| format!("{:02}:{:02}", (t / 3600) % 24, (t / 60) % 60))
            .collect();
        Some(format!("benched: {reason} ({})", times.join(", ")))
    }
}

/// What a health check found.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Facts {
    /// The probe's answer came.
    pub probed: bool,
    /// What the runner contract finds missing.
    pub missing: Vec<String>,
    /// Why container jobs can't be capped there (`check_limits`), if they can't.
    pub limits: Option<String>,
    /// Why a keyed container job would be refused there (the key socket's SELinux self-check), if it would.
    pub key_socket: Option<String>,
    pub disk_free_gb: u64,
    pub disk_total_gb: u64,
    /// The canary's verdict.
    pub canary: Option<Verdict>,
    /// The runner's clock minus the hub's, in seconds.
    pub skew_s: Option<i64>,
}

impl Facts {
    /// Every answer is in.
    pub fn complete(&self) -> bool {
        self.probed && self.canary.is_some() && self.skew_s.is_some()
    }
}

/// The check's verdict on F: a pass, or every part that failed, in words (`; ` between them).
pub fn judge(f: &Facts) -> Result<(), String> {
    let mut failed = Vec::new();
    if !f.probed {
        failed.push("the probe didn't answer".to_string());
    } else {
        if !f.missing.is_empty() {
            failed.push(format!("the runner lacks {}", f.missing.join(", ")));
        }
        if let Some(why) = &f.limits {
            failed.push(format!("container jobs can't be capped: {why}"));
        }
        if let Some(why) = &f.key_socket {
            failed.push(format!("keyed container jobs would be refused: {why}"));
        }
        let floor = DISK_FLOOR_GB.max((f.disk_total_gb * DISK_FLOOR_PCT).div_ceil(100));
        if f.disk_free_gb < floor {
            failed.push(format!(
                "{} GB of disk free, under the floor of {floor} GB",
                f.disk_free_gb
            ));
        }
    }
    match &f.canary {
        None => failed.push("the canary `true` didn't finish".into()),
        Some(Verdict::Pass) => {}
        Some(v) => failed.push(format!("the canary `true` ended {v}")),
    }
    match f.skew_s {
        None => failed.push("the runner's clock wasn't read".into()),
        Some(s) if s.abs() > CLOCK_SKEW_S => failed.push(format!(
            "the runner's clock is {s} s off the hub's (at most {CLOCK_SKEW_S} s)"
        )),
        Some(_) => {}
    }
    if failed.is_empty() {
        Ok(())
    } else {
        Err(failed.join("; "))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn infra(why: &str) -> Verdict {
        Verdict::Infra(why.into())
    }

    // [D] pure: §6.9's strikes, and what never is one
    #[test]
    fn strike_table_is_the_designs() {
        let ctx = StrikeCtx::default();
        let up = StrikeCtx {
            link_stayed_up: true,
            ..ctx
        };
        let twice = StrikeCtx {
            link_lost_today: 2,
            ..ctx
        };
        let strikes: &[(Verdict, StrikeCtx)] = &[
            // setup or sync failed; the image missing or its pull failed
            (infra(infra::SETUP), ctx),
            (infra(SYNC), ctx),
            (infra(IMAGE), ctx),
            // the disk guard couldn't free room; the runner's ladder killed jobs at danger level
            (infra(infra::DISK), ctx),
            (infra(infra::KILLED), ctx),
            // the link lost while jobs ran, twice the same day
            (infra(infra::RUNNER_LOST), twice),
            // the health check (or check_limits) failed
            (infra(CHECK), ctx),
            // a key not delivered on a link that stayed up
            (infra(infra::KEY_NOT_DELIVERED), up),
        ];
        for (v, c) in strikes {
            assert!(is_strike(v, c), "{v} with {c:?} is a strike");
        }
        let never: &[(Verdict, StrikeCtx)] = &[
            (Verdict::Pass, ctx),
            (Verdict::Red, ctx),
            (Verdict::Crash, ctx),
            // the job's own OOM, timeouts, preemptions and evictions
            (Verdict::Oom, ctx),
            (infra(infra::OOMD_KILLED), ctx),
            (Verdict::Timeout, ctx),
            (infra(infra::PREEMPTED), ctx),
            (Verdict::Evicted, ctx),
            (Verdict::Cancelled, ctx),
            // a link lost once today, a key lost with its link
            (
                infra(infra::RUNNER_LOST),
                StrikeCtx {
                    link_lost_today: 1,
                    ..ctx
                },
            ),
            (infra(infra::KEY_NOT_DELIVERED), ctx),
        ];
        for (v, c) in never {
            assert!(!is_strike(v, c), "{v} with {c:?} is not a strike");
        }
    }

    // [D] pure: two consecutive strikes, or two within 3600 s, bench; a passing job between them breaks the run only
    #[test]
    fn two_in_an_hour_benches() {
        let c = StrikeCtx::default();
        let bad = infra(infra::SETUP);
        // two in a row, hours apart: benched
        let mut s = Strikes::default();
        assert!(!s.record(0, &bad, &c));
        assert!(s.record(7200, &bad, &c));
        assert_eq!(s.benched(), Some("infra: setup"));
        // a pass between, within the hour: benched
        let mut s = Strikes::default();
        assert!(!s.record(0, &bad, &c));
        assert!(!s.record(100, &Verdict::Pass, &c));
        assert!(s.record(3600, &bad, &c));
        // a pass between, past the hour: not benched
        let mut s = Strikes::default();
        assert!(!s.record(0, &bad, &c));
        assert!(!s.record(100, &Verdict::Pass, &c));
        assert!(!s.record(3601, &bad, &c));
        assert_eq!(s.benched(), None);
        // a preemption between is no pass: still in a row
        let mut s = Strikes::default();
        assert!(!s.record(0, &bad, &c));
        assert!(!s.record(100, &infra(infra::PREEMPTED), &c));
        assert!(s.record(7200, &bad, &c));
        // the list's words, and a pass of the check clears it all
        assert_eq!(
            s.text().as_deref(),
            Some("benched: infra: setup (00:00, 02:00)")
        );
        s.clear();
        assert_eq!((s.benched(), s.count(), s.text()), (None, 0, None));
    }

    // [D] pure: the check passes only with every part, and names each that failed
    #[test]
    fn the_check_judges_each_part() {
        let ok = Facts {
            probed: true,
            missing: vec![],
            limits: None,
            key_socket: None,
            disk_free_gb: 100,
            disk_total_gb: 200,
            canary: Some(Verdict::Pass),
            skew_s: Some(1),
        };
        assert_eq!(judge(&ok), Ok(()));
        let fails = |f: Facts, word: &str| {
            let e = judge(&f).unwrap_err();
            assert!(e.contains(word), "{e}");
        };
        fails(
            Facts {
                probed: false,
                ..ok.clone()
            },
            "probe",
        );
        fails(
            Facts {
                missing: vec!["linger".into()],
                ..ok.clone()
            },
            "linger",
        );
        fails(
            Facts {
                limits: Some("no memory controller".into()),
                ..ok.clone()
            },
            "capped",
        );
        fails(
            Facts {
                key_socket: Some("Permission denied".into()),
                ..ok.clone()
            },
            "keyed container jobs would be refused",
        );
        // the floor is 20 GB and 10 %: 25 GB of 400 is under 40
        fails(
            Facts {
                disk_free_gb: 25,
                disk_total_gb: 400,
                ..ok.clone()
            },
            "floor of 40 GB",
        );
        fails(
            Facts {
                canary: Some(Verdict::Infra("setup".into())),
                ..ok.clone()
            },
            "canary",
        );
        fails(
            Facts {
                canary: None,
                ..ok.clone()
            },
            "canary",
        );
        fails(
            Facts {
                skew_s: Some(-3),
                ..ok.clone()
            },
            "clock",
        );
        fails(
            Facts {
                skew_s: None,
                ..ok.clone()
            },
            "clock",
        );
        assert_eq!(
            judge(&Facts {
                skew_s: Some(-2),
                ..ok
            }),
            Ok(())
        );
    }
}
