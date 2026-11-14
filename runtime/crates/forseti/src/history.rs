//! History and expected times: every finished job leaves a row, and the next run's expected time, CPU and memory come
//! from the rows of the same key.

use serde::{Deserialize, Serialize};

use crate::model::{Expected, Grant, JobSpec, Verdict};

/// With no history at all, a job is expected to take this long.
pub const DEFAULT_MINUTES: f64 = 10.0;
/// The runs a median is taken over.
pub const LAST_RUNS: usize = 5;

/// One finished run.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct HistRow {
    pub key: String,
    pub machine: String,
    pub grant: Grant,
    pub wall_s: f64,
    pub cpu_s: f64,
    /// The job slice's `memory.peak`.
    pub mem_peak_mib: u64,
    pub verdict: Verdict,
    /// Paused, evicted or squeezed while it ran: its time says little.
    pub disturbed: bool,
    pub at: u64,
    /// It found its slot and images in place (a warm start).
    pub warm: bool,
}

/// The key runs of the same work share: the kind, then the suite and the rows selected, or else the command with
/// paths normalised (the job's tree and any `.claude/worktrees/<name>` path become `{tree}`, a `.claude/tmp` path
/// `{tmp}`), so a command run from two worktrees has one history.
pub fn history_key(spec: &JobSpec) -> String {
    const SEP: char = '\u{1f}';
    let kind = spec.kind.name();
    if let Some(suite) = &spec.suite {
        let rows = spec.select.as_deref().unwrap_or("");
        return format!("{kind}{SEP}suite{SEP}{suite}{SEP}{rows}");
    }
    let tree = spec.tree.to_string_lossy();
    let args: Vec<String> = spec.command.iter().map(|a| normalise(a, &tree)).collect();
    format!("{kind}{SEP}cmd{SEP}{}", args.join(&SEP.to_string()))
}

/// The start of the path that contains byte `at`: the arg's start, or just after a space, `=` or `:`.
fn path_start(s: &str, at: usize) -> usize {
    s[..at].rfind([' ', '=', ':']).map(|i| i + 1).unwrap_or(0)
}

/// Replaces each path through `marker` (from its start up to the end of `marker`, plus one more component when
/// `with_name`) by `token`.
fn replace_through(s: &str, marker: &str, with_name: bool, token: &str) -> String {
    let mut out = String::new();
    let mut rest = s;
    while let Some(i) = rest.find(marker) {
        let start = path_start(rest, i);
        let mut end = i + marker.len();
        if with_name {
            end += rest[end..].find('/').unwrap_or(rest.len() - end);
        }
        out.push_str(&rest[..start]);
        out.push_str(token);
        rest = &rest[end..];
    }
    out.push_str(rest);
    out
}

fn normalise(arg: &str, tree: &str) -> String {
    let mut a = if tree.len() > 1 {
        arg.replace(tree.trim_end_matches('/'), "{tree}")
    } else {
        arg.to_string()
    };
    a = replace_through(&a, "/.claude/worktrees/", true, "{tree}");
    replace_through(&a, "/.claude/tmp", false, "{tmp}")
}

/// The last [`LAST_RUNS`] undisturbed rows, newest first.
fn last_undisturbed(rows: &[HistRow]) -> Vec<&HistRow> {
    let mut good: Vec<&HistRow> = rows.iter().filter(|r| !r.disturbed).collect();
    good.sort_by_key(|r| std::cmp::Reverse(r.at));
    good.truncate(LAST_RUNS);
    good
}

fn median(mut xs: Vec<f64>) -> f64 {
    xs.sort_by(f64::total_cmp);
    let n = xs.len();
    if n.is_multiple_of(2) {
        (xs[n / 2 - 1] + xs[n / 2]) / 2.0
    } else {
        xs[n / 2]
    }
}

/// Time (minutes, × `ratio`), mean CPU and p95 peak memory (nearest rank) of non-empty `rows`.
fn from_rows(rows: &[&HistRow], ratio: f64) -> Expected {
    let minutes = median(rows.iter().map(|r| r.wall_s / 60.0).collect()) * ratio;
    let cpu = rows
        .iter()
        .map(|r| {
            if r.wall_s > 0.0 {
                r.cpu_s / r.wall_s
            } else {
                0.0
            }
        })
        .sum::<f64>()
        / rows.len() as f64;
    let mut peaks: Vec<u64> = rows.iter().map(|r| r.mem_peak_mib).collect();
    peaks.sort_unstable();
    let rank = (peaks.len() * 95).div_ceil(100).max(1);
    Expected {
        minutes,
        cpu,
        mem_p95_mib: Some(peaks[rank - 1]),
    }
}

/// The expected time, CPU and memory:
///
/// - the median of the last 5 undisturbed `rows` (this machine's), with their mean CPU (cores) and the p95 of their
///   peak memory;
/// - else the same from `other` machines' rows, the time × `speed_ratio`;
/// - else `suite_default` minutes;
/// - else 10 minutes.
///
/// The last two know no CPU or memory (`Expected::known()` is false).
pub fn expected(
    rows: &[HistRow],
    other: &[HistRow],
    speed_ratio: f64,
    suite_default: Option<f64>,
) -> Expected {
    let own = last_undisturbed(rows);
    if !own.is_empty() {
        return from_rows(&own, 1.0);
    }
    let elsewhere = last_undisturbed(other);
    if !elsewhere.is_empty() {
        return from_rows(&elsewhere, speed_ratio);
    }
    Expected {
        minutes: suite_default.unwrap_or(DEFAULT_MINUTES),
        cpu: 0.0,
        mem_p95_mib: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testkit::spec;

    fn row(wall_min: f64, cpu: f64, peak: u64, at: u64, disturbed: bool) -> HistRow {
        HistRow {
            key: "k".into(),
            machine: "m".into(),
            grant: Grant {
                cores: 2,
                mem_cap_mib: 4096,
                reserve_mib: 2048,
            },
            wall_s: wall_min * 60.0,
            cpu_s: wall_min * 60.0 * cpu,
            mem_peak_mib: peak,
            verdict: Verdict::Pass,
            disturbed,
            at,
            warm: true,
        }
    }

    #[test]
    fn expected_uses_median_of_last_5_undisturbed() {
        // [D] pure: the oldest run and the disturbed one are left out.
        let rows = [
            row(100.0, 1.0, 9000, 1, false), // older than the last 5
            row(10.0, 1.0, 1000, 2, false),
            row(12.0, 1.0, 1200, 3, false),
            row(500.0, 4.0, 8000, 4, true), // disturbed
            row(11.0, 2.0, 1100, 5, false),
            row(30.0, 1.0, 3000, 6, false),
            row(9.0, 0.0, 900, 7, false),
        ];
        let e = expected(&rows, &[], 1.6, Some(99.0));
        assert_eq!(e.minutes, 11.0);
        assert_eq!(e.cpu, 1.0);
        assert_eq!(e.mem_p95_mib, Some(3000));
        assert!(e.known());
        // An even count takes the middle two.
        let e = expected(&rows[1..3], &[], 1.6, None);
        assert_eq!(e.minutes, 11.0);
    }

    #[test]
    fn expected_falls_back_through_ratio_suite_and_10_minutes() {
        // [D] pure
        let other = [
            row(10.0, 2.0, 2000, 1, false),
            row(20.0, 2.0, 2500, 2, false),
        ];
        let disturbed = [row(1.0, 1.0, 100, 9, true)];
        let e = expected(&disturbed, &other, 1.6, Some(30.0));
        assert_eq!(e.minutes, 15.0 * 1.6);
        assert_eq!(e.cpu, 2.0);
        assert_eq!(e.mem_p95_mib, Some(2500));
        let e = expected(&[], &[], 1.6, Some(30.0));
        assert_eq!((e.minutes, e.known()), (30.0, false));
        let e = expected(&[], &disturbed, 1.6, None);
        assert_eq!((e.minutes, e.known()), (DEFAULT_MINUTES, false));
    }

    #[test]
    fn history_key_normalises_worktree_paths() {
        // [D] pure
        let at = |tree: &str, cmd: &[&str]| {
            let mut s = spec("j");
            s.tree = tree.into();
            s.command = cmd.iter().map(|c| c.to_string()).collect();
            history_key(&s)
        };
        let a = at(
            "/src/a/.claude/worktrees/one",
            &[
                "bash",
                "/src/a/.claude/worktrees/one/test/run.sh",
                "--out=/src/a/.claude/tmp/run-1/out.log",
            ],
        );
        let b = at(
            "/work/b/.claude/worktrees/two",
            &[
                "bash",
                "/work/b/.claude/worktrees/two/test/run.sh",
                "--out=/work/b/.claude/tmp/run-1/out.log",
            ],
        );
        assert_eq!(a, b);
        // Another worktree named in an argument is a token too.
        let c = at(
            "/src/main",
            &[
                "bash",
                "/src/a/.claude/worktrees/one/test/run.sh",
                "--out=/src/a/.claude/tmp/run-1/out.log",
            ],
        );
        assert_eq!(a, c);
        assert_ne!(a, at("/src/main", &["bash", "test/other.sh"]));
        // A suite's key is its suite and rows, whatever the command.
        let mut s = spec("j");
        s.suite = Some("ert".into());
        s.select = Some("^drgnx-a".into());
        let k = history_key(&s);
        s.command = vec!["anything".into()];
        assert_eq!(history_key(&s), k);
        s.select = Some("^drgnx-b".into());
        assert_ne!(history_key(&s), k);
    }
}
