//! Kill classes: telling an eviction, an OOM, a guard's kill and a crash apart, so a kill never reads as red.

use serde::{Deserialize, Serialize};

use crate::model::Verdict;

/// The named infrastructure reasons [`Verdict::Infra`] carries (shown with an `infra: ` prefix).
pub mod infra {
    pub const RUNNER_LOST: &str = "runner lost";
    pub const PREEMPTED: &str = "preempted";
    pub const DISK: &str = "disk";
    pub const KEY_NOT_DELIVERED: &str = "key not delivered";
    pub const SETUP: &str = "setup";
    pub const KILLED: &str = "killed";
    pub const OOMD_KILLED: &str = "oomd/killed";
}

/// What is known about how a job's process ended.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExitEvidence {
    /// The scheduler evicted it (recorded before the stop).
    pub evicted: bool,
    /// The reason written before a kill by us (the disk guard, the ladder, a setup refusal, a key not delivered),
    /// with or without its `infra: ` prefix.
    pub kill_reason: Option<String>,
    /// The job slice's `memory.events` `oom_kill` grew.
    pub oom_kill_grew: bool,
    /// A `systemd-oomd` journal line naming the job's cgroup, when the journal is readable.
    pub oomd_line: Option<String>,
    pub signal: Option<i32>,
    pub exit_code: Option<i32>,
    pub timed_out: bool,
    /// The row parser's judgement of the log, when the job has one.
    pub parsed: Option<Verdict>,
}

const SIGABRT: i32 = 6;
const SIGKILL: i32 = 9;
const SIGSEGV: i32 = 11;

/// Whether an oomd line says it killed or marked the cgroup: systemd 259 logs "Killed …", 262 "Marked … for killing"
/// (and may leave the job frozen until its timeout).
pub fn oomd_line_matches(line: &str) -> bool {
    line.contains("Killed ") || (line.contains("Marked ") && line.contains(" for killing"))
}

/// The verdict, first match wins:
///
/// 1. we evicted it → `Evicted`;
/// 2. a reason was written before our kill → `Infra(reason)`;
/// 3. `oom_kill` grew → `Oom` (re-run once at × 1.5);
/// 4. an oomd line that killed or marked it, or a SIGKILL (exit 137) with no `oom_kill` → `Infra("oomd/killed")`;
/// 5. SIGSEGV or SIGABRT (exit 139 or 134) → `Crash`;
/// 6. the timeout → `Timeout`;
/// 7. the parser's verdict, else the exit code (0 `Pass`, other or none `Red`); a parser's pass without exit 0 is
///    `Red`.
pub fn classify(ev: &ExitEvidence) -> Verdict {
    if ev.evicted {
        return Verdict::Evicted;
    }
    if let Some(reason) = &ev.kill_reason {
        let reason = reason.trim();
        let reason = reason.strip_prefix("infra:").unwrap_or(reason).trim();
        return Verdict::Infra(reason.to_string());
    }
    if ev.oom_kill_grew {
        return Verdict::Oom;
    }
    let sigkill = ev.signal == Some(SIGKILL) || ev.exit_code == Some(128 + SIGKILL);
    if ev.oomd_line.as_deref().is_some_and(oomd_line_matches) || sigkill {
        return Verdict::Infra(infra::OOMD_KILLED.into());
    }
    let crash = matches!(ev.signal, Some(SIGSEGV | SIGABRT))
        || matches!(ev.exit_code, Some(c) if c == 128 + SIGSEGV || c == 128 + SIGABRT);
    if crash {
        return Verdict::Crash;
    }
    if ev.timed_out {
        return Verdict::Timeout;
    }
    // No exit code (another signal, nothing recorded) is no pass.
    let failed = ev.exit_code != Some(0);
    match &ev.parsed {
        Some(Verdict::Pass) | None if failed => Verdict::Red,
        Some(v) => v.clone(),
        None => Verdict::Pass,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev() -> ExitEvidence {
        ExitEvidence::default()
    }

    #[test]
    fn classify_table() {
        // [D] pure
        let infra = |r: &str| Verdict::Infra(r.into());
        let rows: Vec<(ExitEvidence, Verdict)> = vec![
            // an eviction with a SIGKILL is Evicted, never Crash or infra
            (
                ExitEvidence {
                    evicted: true,
                    signal: Some(SIGKILL),
                    kill_reason: Some("infra: disk".into()),
                    ..ev()
                },
                Verdict::Evicted,
            ),
            // a written infra: disk beats an exit 1
            (
                ExitEvidence {
                    kill_reason: Some("infra: disk".into()),
                    exit_code: Some(1),
                    ..ev()
                },
                infra(infra::DISK),
            ),
            // a guard kill is never Red, and its reason beats the oom evidence
            (
                ExitEvidence {
                    kill_reason: Some("killed".into()),
                    signal: Some(SIGKILL),
                    oom_kill_grew: true,
                    ..ev()
                },
                infra(infra::KILLED),
            ),
            (
                ExitEvidence {
                    oom_kill_grew: true,
                    exit_code: Some(137),
                    ..ev()
                },
                Verdict::Oom,
            ),
            (
                ExitEvidence {
                    oomd_line: Some(
                        "Killed /user.slice/x.slice/job.service due to memory pressure".into(),
                    ),
                    signal: Some(SIGKILL),
                    ..ev()
                },
                infra(infra::OOMD_KILLED),
            ),
            // marked, not killed: frozen until the timeout, still oomd's
            (
                ExitEvidence {
                    oomd_line: Some(
                        "Marked /user.slice/x.slice/job.service for killing due to memory pressure"
                            .into(),
                    ),
                    timed_out: true,
                    ..ev()
                },
                infra(infra::OOMD_KILLED),
            ),
            (
                ExitEvidence {
                    signal: Some(SIGKILL),
                    ..ev()
                },
                infra(infra::OOMD_KILLED),
            ),
            (
                ExitEvidence {
                    exit_code: Some(137),
                    ..ev()
                },
                infra(infra::OOMD_KILLED),
            ),
            (
                ExitEvidence {
                    signal: Some(SIGSEGV),
                    ..ev()
                },
                Verdict::Crash,
            ),
            (
                ExitEvidence {
                    signal: Some(SIGABRT),
                    ..ev()
                },
                Verdict::Crash,
            ),
            (
                ExitEvidence {
                    exit_code: Some(139),
                    ..ev()
                },
                Verdict::Crash,
            ),
            (
                ExitEvidence {
                    exit_code: Some(134),
                    ..ev()
                },
                Verdict::Crash,
            ),
            (
                ExitEvidence {
                    timed_out: true,
                    exit_code: Some(143),
                    ..ev()
                },
                Verdict::Timeout,
            ),
            (
                ExitEvidence {
                    exit_code: Some(0),
                    parsed: Some(Verdict::Suspect("too few rows".into())),
                    ..ev()
                },
                Verdict::Suspect("too few rows".into()),
            ),
            (
                ExitEvidence {
                    exit_code: Some(1),
                    parsed: Some(Verdict::Pass),
                    ..ev()
                },
                Verdict::Red,
            ),
            (
                ExitEvidence {
                    exit_code: Some(0),
                    ..ev()
                },
                Verdict::Pass,
            ),
            (
                ExitEvidence {
                    exit_code: Some(2),
                    ..ev()
                },
                Verdict::Red,
            ),
        ];
        for (i, (e, want)) in rows.iter().enumerate() {
            assert_eq!(&classify(e), want, "row {i}: {e:?}");
        }
        assert_eq!(infra(infra::DISK).to_string(), "infra: disk");
    }

    #[test]
    fn an_unrelated_oomd_line_is_not_a_kill() {
        // [D] pure
        assert!(oomd_line_matches("Killed /a.slice due to memory used"));
        assert!(oomd_line_matches(
            "Marked /a.slice for killing due to memory pressure"
        ));
        assert!(!oomd_line_matches("Marked /a.slice as idle"));
        assert!(!oomd_line_matches("Swap used (90%) is over the limit"));
    }
}
