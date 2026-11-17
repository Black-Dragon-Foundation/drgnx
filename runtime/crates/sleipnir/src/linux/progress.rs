//! The progress guard: whether a job still makes progress, from its cgroup and log readings (design §5.7).
//!
//! Pure policy. Its two hosts (job-exec on a runner, the hub's job supervision on its own machine) read the job's
//! slice and log once a minute and pass each [`Reading`] to a [`Tracker`]. Progress is new log bytes or a parsed row
//! (output), CPU above [`GuardLimits::cpu_floor`] of one core over the window since the last reading, or new IO
//! bytes. The rules, first hit wins:
//!
//! - **stall**: no output, no CPU above the floor and no IO for `stall_s`;
//! - **silent**: no output for `silent_s`, whatever the CPU (a livelock);
//! - **wall**: `wall_s` since the start (the time box: [`wall_limit`]).
//!
//! A stop is `infra: stuck (<rule>)` ([`verdict_text`]): not the job's fault, never red, never rerun.

/// The guard's limits, in seconds; `cpu_floor` is a share of one core.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GuardLimits {
    pub stall_s: u64,
    pub silent_s: u64,
    pub wall_s: u64,
    pub cpu_floor: f64,
}

/// The defaults (design §5.7): stall 20 min, silent 45 min, below 10 % of a core; the wall is the job's time box.
pub const STALL_S: u64 = 20 * 60;
pub const SILENT_S: u64 = 45 * 60;
pub const CPU_FLOOR: f64 = 0.10;

impl GuardLimits {
    /// The defaults with WALL_S as the time box.
    pub fn defaults(wall_s: u64) -> GuardLimits {
        GuardLimits {
            stall_s: STALL_S,
            silent_s: SILENT_S,
            wall_s,
            cpu_floor: CPU_FLOOR,
        }
    }
}

/// One reading of a job: AT in seconds (any epoch, the same for all readings), the log's size, the slice's
/// `cpu.stat usage_usec` and `io.stat` bytes, and the rows parsed so far.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Reading {
    pub at: u64,
    pub log_bytes: u64,
    pub cpu_usec: u64,
    pub io_bytes: u64,
    pub rows: u64,
}

/// The rule that stopped a job.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rule {
    Stall,
    Silent,
    Wall,
}

impl Rule {
    pub fn name(self) -> &'static str {
        match self {
            Rule::Stall => "stall",
            Rule::Silent => "silent",
            Rule::Wall => "wall",
        }
    }
}

/// A stop: its rule and how many whole minutes the job went without the progress the rule asks for (for the wall,
/// since its start).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stop {
    pub rule: Rule,
    pub minutes: u64,
}

/// A job's progress so far.
#[derive(Clone, Debug)]
pub struct Tracker {
    start: u64,
    last: Reading,
    /// The last time the job printed (log bytes or a row).
    output_at: u64,
    /// The last time it made any progress (output, CPU above the floor, IO).
    active_at: u64,
}

impl Tracker {
    /// A tracker from the job's first reading.
    pub fn new(start: Reading) -> Tracker {
        let _ = start;
        unimplemented!()
    }

    /// Takes reading R; the stop when a rule of L is hit.
    pub fn see(&mut self, r: Reading, l: &GuardLimits) -> Option<Stop> {
        let _ = (r, l);
        unimplemented!()
    }
}

/// The wall limit: three times the history's p95, at most the pack's maximum; the pack's maximum without history.
pub fn wall_limit(pack_max_s: u64, p95_s: Option<u64>) -> u64 {
    let _ = (pack_max_s, p95_s);
    unimplemented!()
}

/// The verdict's reason for a stop, without the `infra: ` prefix: `stuck (stall)`.
pub fn verdict_text(s: &Stop) -> String {
    let _ = s;
    unimplemented!()
}

/// The line appended to the job's log on a stop.
pub fn log_line(s: &Stop) -> String {
    let _ = s;
    unimplemented!()
}

#[cfg(test)]
mod tests {
    use super::*;
    use forseti::Verdict;
    use forseti::classify::{ExitEvidence, classify};

    /// Short limits, as the host rows pass them: stall 20 min, silent 45 min, wall 2 h.
    fn limits() -> GuardLimits {
        GuardLimits::defaults(2 * 3600)
    }

    /// Readings once a minute for MINUTES, each from STEP (the change over the minute); the first stop and its
    /// minute.
    fn run(minutes: u64, step: impl Fn(u64) -> Reading) -> Option<(u64, Stop)> {
        let mut now = Reading::default();
        let mut t = Tracker::new(now);
        for m in 1..=minutes {
            let d = step(m);
            now = Reading {
                at: m * 60,
                log_bytes: now.log_bytes + d.log_bytes,
                cpu_usec: now.cpu_usec + d.cpu_usec,
                io_bytes: now.io_bytes + d.io_bytes,
                rows: now.rows + d.rows,
            };
            if let Some(s) = t.see(now, &limits()) {
                return Some((m, s));
            }
        }
        None
    }

    const MINUTE_USEC: u64 = 60_000_000;

    /// [D] A busy loop that prints nothing (a livelock) is never stalled — it uses a whole core — but it stops at
    /// silent, 45 min after its last output.
    #[test]
    fn silent_but_busy_stops_at_silent() {
        let busy = |_| Reading {
            cpu_usec: MINUTE_USEC,
            ..Reading::default()
        };
        let stop = run(120, busy);
        assert_eq!(
            stop,
            Some((
                45,
                Stop {
                    rule: Rule::Silent,
                    minutes: 45
                }
            ))
        );
        // its output before the loop counts from then
        let stop = run(120, |m| Reading {
            log_bytes: u64::from(m <= 10) * 100,
            ..busy(m)
        });
        assert_eq!(stop.map(|(m, s)| (m, s.rule)), Some((55, Rule::Silent)));
    }

    /// [D] `sleep 600`: no output, no CPU, no IO stops at stall after 20 min; CPU under the floor (an idle VM's 5 %)
    /// is no progress.
    #[test]
    fn idle_sleep_stops_at_stall() {
        let stop = run(120, |_| Reading::default());
        assert_eq!(
            stop,
            Some((
                20,
                Stop {
                    rule: Rule::Stall,
                    minutes: 20
                }
            ))
        );
        let idle_vm = |_| Reading {
            cpu_usec: MINUTE_USEC / 20,
            ..Reading::default()
        };
        assert_eq!(
            run(120, idle_vm).map(|(m, s)| (m, s.rule)),
            Some((20, Rule::Stall))
        );
        // at the floor it is busy
        let at_floor = |_| Reading {
            cpu_usec: MINUTE_USEC / 10,
            ..Reading::default()
        };
        assert_eq!(
            run(120, at_floor).map(|(m, s)| (m, s.rule)),
            Some((45, Rule::Silent))
        );
    }

    /// [D] A slow job that prints a line every few minutes and does little else is never stopped before its wall;
    /// a parsed row is output too.
    #[test]
    fn slow_but_printing_never_stops() {
        let slow = |m: u64| Reading {
            log_bytes: u64::from(m % 15 == 0) * 2,
            ..Reading::default()
        };
        assert_eq!(run(119, slow), None);
        let rows = |m: u64| Reading {
            rows: u64::from(m % 15 == 0),
            ..Reading::default()
        };
        assert_eq!(run(119, rows), None);
        // the wall still ends it
        assert_eq!(
            run(180, slow),
            Some((
                120,
                Stop {
                    rule: Rule::Wall,
                    minutes: 120
                }
            ))
        );
    }

    /// [D] IO alone (a build writing to a file) keeps a job from stalling, but not from going silent.
    #[test]
    fn io_alone_is_progress_for_stall_but_not_for_silent() {
        let io = |_| Reading {
            io_bytes: 4096,
            ..Reading::default()
        };
        assert_eq!(
            run(120, io).map(|(m, s)| (m, s.rule)),
            Some((45, Rule::Silent))
        );
        // IO that stops: stall 20 min after the last write
        let io_then_idle = |m: u64| Reading {
            io_bytes: u64::from(m <= 30) * 4096,
            ..Reading::default()
        };
        assert_eq!(
            run(120, io_then_idle),
            Some((
                45,
                Stop {
                    rule: Rule::Silent,
                    minutes: 45
                }
            ))
        );
        let io_then_idle = |m: u64| Reading {
            io_bytes: u64::from(m <= 10) * 4096,
            ..Reading::default()
        };
        assert_eq!(
            run(120, io_then_idle),
            Some((
                30,
                Stop {
                    rule: Rule::Stall,
                    minutes: 20
                }
            ))
        );
    }

    /// [D] With history the wall is three p95s, at most the pack's maximum; without, the pack's.
    #[test]
    fn wall_is_three_p95_capped_by_the_pack() {
        assert_eq!(wall_limit(5400, Some(600)), 1800);
        assert_eq!(wall_limit(5400, Some(3600)), 5400);
        assert_eq!(wall_limit(5400, None), 5400);
        assert_eq!(wall_limit(9000, Some(0)), 0);
    }

    /// [D] A stop's verdict is `infra: stuck (<rule>)` through `forseti::classify`, whatever the exit (the kill's
    /// SIGKILL, a timeout): never red, never a timeout; the log line says so.
    #[test]
    fn the_verdict_is_infra_never_red() {
        for rule in [Rule::Stall, Rule::Silent, Rule::Wall] {
            let s = Stop { rule, minutes: 20 };
            let ev = ExitEvidence {
                kill_reason: Some(format!("infra: {}", verdict_text(&s))),
                exit_code: Some(137),
                timed_out: rule == Rule::Wall,
                ..ExitEvidence::default()
            };
            assert_eq!(
                classify(&ev),
                Verdict::Infra(format!("stuck ({})", rule.name()))
            );
        }
        let s = Stop {
            rule: Rule::Stall,
            minutes: 20,
        };
        assert_eq!(verdict_text(&s), "stuck (stall)");
        assert_eq!(
            log_line(&s),
            "=== stopped as stuck (stall, 20 min): not a test result"
        );
    }
}
