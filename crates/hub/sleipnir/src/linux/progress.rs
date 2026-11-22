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
//! A stop is `infra: stuck (<rule>)` ([`verdict_text`]): not the job's fault, never red, never rerun. The hosts share
//! [`read`] and [`stuck_report`].

#[cfg(any(target_os = "linux", target_os = "macos"))]
use super::probe::CgroupStat;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

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

/// One reading of a job: AT (since any epoch, the same for all readings), the log's size, the slice's
/// `cpu.stat usage_usec` and `io.stat` bytes, and the rows parsed so far.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Reading {
    pub at: Duration,
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
    start: Duration,
    last: Reading,
    /// The last time the job printed (log bytes or a row).
    output_at: Duration,
    /// The last time it made any progress (output, CPU above the floor, IO).
    active_at: Duration,
}

impl Tracker {
    /// A tracker from the job's first reading.
    pub fn new(start: Reading) -> Tracker {
        Tracker {
            start: start.at,
            last: start,
            output_at: start.at,
            active_at: start.at,
        }
    }

    /// Takes reading R; the stop when a rule of L is hit.
    pub fn see(&mut self, r: Reading, l: &GuardLimits) -> Option<Stop> {
        let window_usec = r.at.saturating_sub(self.last.at).as_micros() as u64;
        let cpu = r.cpu_usec.saturating_sub(self.last.cpu_usec);
        let output = r.log_bytes > self.last.log_bytes || r.rows > self.last.rows;
        let busy = window_usec > 0 && cpu as f64 >= l.cpu_floor * window_usec as f64;
        let io = r.io_bytes > self.last.io_bytes;
        if output {
            self.output_at = r.at;
        }
        if output || busy || io {
            self.active_at = r.at;
        }
        self.last = r;
        let since = |t: Duration| r.at.saturating_sub(t);
        let stop = |rule, s: Duration| {
            Some(Stop {
                rule,
                minutes: s.as_secs() / 60,
            })
        };
        let secs = Duration::from_secs;
        if since(self.active_at) >= secs(l.stall_s) {
            return stop(Rule::Stall, since(self.active_at));
        }
        if since(self.output_at) >= secs(l.silent_s) {
            return stop(Rule::Silent, since(self.output_at));
        }
        if since(self.start) >= secs(l.wall_s) {
            return stop(Rule::Wall, since(self.start));
        }
        None
    }
}

/// The wall limit: three times the history's p95, at most the pack's maximum; the pack's maximum without history.
pub fn wall_limit(pack_max_s: u64, p95_s: Option<u64>) -> u64 {
    p95_s.map_or(pack_max_s, |p| pack_max_s.min(p.saturating_mul(3)))
}

/// The verdict's reason for a stop, without the `infra: ` prefix: `stuck (stall)`.
pub fn verdict_text(s: &Stop) -> String {
    format!("stuck ({})", s.rule.name())
}

/// The line appended to the job's log on a stop.
pub fn log_line(s: &Stop) -> String {
    format!(
        "=== stopped as stuck ({}, {} min): not a test result",
        s.rule.name(),
        s.minutes
    )
}

/// The report's file name in the attempt's (or local job's) folder.
pub const STUCK: &str = "stuck.txt";

/// How often a host reads a job: once a minute, or four times within the shortest of L's limits when that is shorter
/// (at least once a second).
pub fn period_s(l: &GuardLimits) -> u64 {
    READ_EVERY_S.min(l.stall_s / 4).min(l.silent_s / 4).max(1)
}

/// How often a host reads a job with the default limits.
pub const READ_EVERY_S: u64 = 60;

/// A reading at AT of the job's SLICE (its cgroup folder) and LOGS, after PREV. A slice that can't be read counts a
/// whole core since PREV and no IO: an unknown is never idle, so such a job can only go silent.
pub fn read(at: Duration, slice: Option<&Path>, logs: &[PathBuf], prev: &Reading) -> Reading {
    let log_bytes = logs
        .iter()
        .map(|p| fs::metadata(p).map(|m| m.len()).unwrap_or(0))
        .sum();
    // no cgroups to read without the probe (Android): every slice is one that can't be read
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    let stat = slice.map(|p| CgroupStat::read(p).map(|s| (s.cpu_usec, s.io_bytes)));
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    let stat: Option<io::Result<(u64, u64)>> =
        slice.map(|_| Err(io::ErrorKind::Unsupported.into()));
    let (cpu_usec, io_bytes) = match stat {
        Some(Ok(s)) => s,
        _ => (
            prev.cpu_usec + at.saturating_sub(prev.at).as_micros() as u64,
            prev.io_bytes,
        ),
    };
    Reading {
        at,
        log_bytes,
        cpu_usec,
        io_bytes,
        rows: 0,
    }
}

/// How long `podman top` may take for one container of the report.
#[cfg(any(target_os = "linux", target_os = "macos"))]
const TOP_LIMIT: Duration = Duration::from_secs(20);

/// Writes [`STUCK`] into DIR for STOP of the job in SLICE (its cgroup folder) with LOG: the rule, the slice's
/// processes (pid, state, CPU seconds, name), `podman top` of each container in it, the log's last 60 lines and the
/// slice's `memory.events`.
pub fn stuck_report(dir: &Path, stop: &Stop, slice: Option<&Path>, log: &Path) -> io::Result<()> {
    let mut t = format!(
        "{}: no progress for {} min\n",
        verdict_text(stop),
        stop.minutes
    );
    let (mut procs, mut containers) = (vec![], vec![]);
    if let Some(s) = slice {
        walk(s, &mut procs, &mut containers);
    }
    t.push_str("\n== processes (pid state cpu_s name)\n");
    // /proc counts in USER_HZ, 100 on every Linux the runner supports
    let tick = 100.0;
    for pid in &procs {
        let stat = fs::read_to_string(format!("/proc/{pid}/stat")).unwrap_or_default();
        // `pid (comm) state …`, comm may hold spaces: the fields after its closing parenthesis
        let (name, rest) = match (stat.find('('), stat.rfind(')')) {
            (Some(a), Some(b)) if a < b => (&stat[a + 1..b], &stat[b + 1..]),
            _ => ("?", ""),
        };
        let f: Vec<&str> = rest.split_whitespace().collect();
        let ticks = |i: usize| f.get(i).and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
        let cpu = (ticks(11) + ticks(12)) as f64 / tick;
        let state = f.first().copied().unwrap_or("?");
        t.push_str(&format!("{pid} {state} {cpu:.1} {name}\n"));
    }
    t.push_str("\n== containers\n");
    if containers.is_empty() {
        t.push_str("none\n");
    }
    for c in &containers {
        #[cfg(any(target_os = "linux", target_os = "macos"))]
        let top = super::run::limited(Path::new("podman"), &["top", c.as_str()], &[], TOP_LIMIT)
            .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
            .unwrap_or_else(|e| format!("({e})\n"));
        // no podman to ask where jobs never run (Android)
        #[cfg(not(any(target_os = "linux", target_os = "macos")))]
        let top = String::from("(no podman here)\n");
        t.push_str(&format!("-- {c}\n{top}"));
    }
    t.push_str("\n== log (last 60 lines)\n");
    let text = fs::read(log).unwrap_or_default();
    let text = String::from_utf8_lossy(&text);
    let lines: Vec<&str> = text.lines().collect();
    for l in &lines[lines.len().saturating_sub(60)..] {
        t.push_str(l);
        t.push('\n');
    }
    t.push_str("\n== memory.events\n");
    if let Some(s) = slice {
        t.push_str(&fs::read_to_string(s.join("memory.events")).unwrap_or_default());
    }
    let tmp = dir.join(format!(".{STUCK}.tmp"));
    fs::write(&tmp, t)?;
    fs::rename(&tmp, dir.join(STUCK))
}

/// The pids under cgroup DIR, and the containers (podman's `libpod-<id>.scope`).
fn walk(dir: &Path, procs: &mut Vec<u32>, containers: &mut Vec<String>) {
    if let Ok(t) = fs::read_to_string(dir.join("cgroup.procs")) {
        procs.extend(t.lines().filter_map(|l| l.trim().parse::<u32>().ok()));
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut subs: Vec<PathBuf> = entries
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| e.path())
        .collect();
    subs.sort();
    for s in subs {
        if let Some(id) = s
            .file_name()
            .and_then(|n| n.to_str())
            .and_then(|n| n.strip_prefix("libpod-")?.strip_suffix(".scope"))
            .filter(|id| !id.starts_with("conmon"))
        {
            containers.push(id.to_string());
        }
        walk(&s, procs, containers);
    }
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
                at: Duration::from_secs(m * 60),
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
            log_bytes: u64::from(m.is_multiple_of(15)) * 2,
            ..Reading::default()
        };
        assert_eq!(run(119, slow), None);
        let rows = |m: u64| Reading {
            rows: u64::from(m.is_multiple_of(15)),
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

    /// [D] pure: a host reads between whole seconds (the hub's rows read every second, stall 2 s): output seen at
    /// 4.99 s and none at 6.0 s is 1.01 s without output, not 2; at 6.99 s it is 2
    #[test]
    fn a_reading_counts_the_fraction_of_its_second() {
        let l = GuardLimits {
            stall_s: 2,
            silent_s: 4,
            ..limits()
        };
        let at = |ms| Reading {
            at: Duration::from_millis(ms),
            log_bytes: 1,
            ..Reading::default()
        };
        let mut t = Tracker::new(Reading::default());
        assert_eq!(t.see(at(4990), &l), None);
        assert_eq!(t.see(at(6000), &l), None, "1.01 s without output");
        assert_eq!(t.see(at(6990), &l).map(|s| s.rule), Some(Rule::Stall));
    }

    /// [D] With history the wall is three p95s, at most the pack's maximum; without, the pack's.
    #[test]
    fn wall_is_three_p95_capped_by_the_pack() {
        assert_eq!(wall_limit(5400, Some(600)), 1800);
        assert_eq!(wall_limit(5400, Some(3600)), 5400);
        assert_eq!(wall_limit(5400, None), 5400);
        assert_eq!(wall_limit(9000, Some(0)), 0);
    }

    /// [D] The hosts read once a minute, or four times within the shortest limit when that is shorter (the host rows'
    /// short limits); a reading takes the slice's CPU and IO and the logs' sizes; a slice that can't be read counts as
    /// a busy core (an unknown is never idle), so it can only go silent.
    #[test]
    fn a_host_reads_the_slice_and_its_logs() {
        assert_eq!(period_s(&limits()), 60);
        let short = GuardLimits {
            stall_s: 20,
            silent_s: 40,
            ..limits()
        };
        assert_eq!(period_s(&short), 5);
        let tiny = GuardLimits {
            stall_s: 2,
            silent_s: 4,
            ..limits()
        };
        assert_eq!(period_s(&tiny), 1);

        let d = tempfile::tempdir().unwrap();
        let slice = d.path().join("slice");
        std::fs::create_dir_all(&slice).unwrap();
        for (f, s) in [
            ("memory.current", "1048576\n"),
            ("cpu.stat", "usage_usec 5000000\n"),
            (
                "io.stat",
                "8:0 rbytes=10 wbytes=20 rios=1 wios=1 dbytes=0 dios=0\n",
            ),
        ] {
            std::fs::write(slice.join(f), s).unwrap();
        }
        let (a, b) = (d.path().join("a.log"), d.path().join("b.log"));
        std::fs::write(&a, "12345").unwrap();
        std::fs::write(&b, "678").unwrap();
        let prev = Reading {
            at: Duration::from_secs(60),
            cpu_usec: 1,
            ..Reading::default()
        };
        let logs = [a, b, d.path().join("none.log")];
        let r = read(Duration::from_secs(120), Some(&slice), &logs, &prev);
        assert_eq!(
            r,
            Reading {
                at: Duration::from_secs(120),
                log_bytes: 8,
                cpu_usec: 5_000_000,
                io_bytes: 30,
                rows: 0
            }
        );
        let unread = read(
            Duration::from_secs(120),
            Some(&d.path().join("gone")),
            &logs,
            &prev,
        );
        assert_eq!((unread.cpu_usec, unread.io_bytes), (60_000_001, 0));
        assert_eq!(
            read(Duration::from_secs(120), None, &logs, &prev).cpu_usec,
            60_000_001
        );
    }

    /// [D] `stuck.txt`: the rule, the slice's processes with their state and CPU, each container's `podman top`, the
    /// log's last 60 lines and the slice's `memory.events`.
    #[test]
    fn a_stuck_report_has_its_sections() {
        let d = tempfile::tempdir().unwrap();
        let slice = d.path().join("slice");
        let svc = slice.join("job.service");
        std::fs::create_dir_all(&svc).unwrap();
        std::fs::write(
            svc.join("cgroup.procs"),
            format!("{}\n", std::process::id()),
        )
        .unwrap();
        std::fs::write(slice.join("memory.events"), "oom 0\noom_kill 0\n").unwrap();
        let log = d.path().join("job.log");
        let lines: String = (1..=100).map(|i| format!("line {i}\n")).collect();
        std::fs::write(&log, lines).unwrap();
        let stop = Stop {
            rule: Rule::Stall,
            minutes: 20,
        };
        stuck_report(d.path(), &stop, Some(&slice), &log).unwrap();
        let t = std::fs::read_to_string(d.path().join(STUCK)).unwrap();
        assert!(
            t.starts_with("stuck (stall): no progress for 20 min\n"),
            "{t}"
        );
        let me = format!("\n{} ", std::process::id());
        let procs = t.split("== processes").nth(1).unwrap();
        assert!(procs.contains(&me), "{t}");
        assert!(t.contains("== containers\nnone\n"), "{t}");
        let tail = t.split("== log (last 60 lines)\n").nth(1).unwrap();
        assert!(
            tail.starts_with("line 41\n") && tail.contains("line 100\n"),
            "{t}"
        );
        assert!(!tail.contains("line 40\n"));
        assert!(t.contains("== memory.events\noom 0\noom_kill 0\n"), "{t}");
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
