//! job-exec: the process a job's unit runs (`sleipnir job-exec <dir>`). It runs the job's command inside its own
//! service, so the podman client and conmon land there too, at its OOM score (900) and in the job's slice; the
//! containers sit beside it at 1000. It watches the job slice's `memory.events`; when the kernel kills anything of
//! the job for memory it writes `oom`, then stops the whole job slice, since one container's OOM is the job's. At the
//! end it writes `result.json`, whatever happened, unless it was killed itself.
//!
//! The attempt's folder holds `job.json` (the [`JobExec`] spec), the attempt's log, `offsets.json` (where each state
//! dir's `check.log` stood at the start, so only this attempt's part is read), a `kill_reason` when the scheduler
//! killed the job (written before the kill; `evicted` for an eviction), and `result.json`.

use super::parse::{self, Parser, RowVerdict};
use super::probe::CgroupStat;
use super::result::{ResultJson, RowResult};
use super::slices;
use forseti::classify::{ExitEvidence, infra};
use forseti::{Expect, Grant, Verdict};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{self, Read};
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// The spec's file name in the attempt's folder.
pub const SPEC: &str = "job.json";
/// The kill reason's file name.
pub const KILL_REASON: &str = "kill_reason";
/// The state logs' start offsets.
pub const OFFSETS: &str = "offsets.json";
/// The kill reason the scheduler writes for an eviction.
pub const EVICTED: &str = "evicted";
/// The most of the attempt's log the parser reads (the live log's cap).
pub const LOG_CAP: u64 = 64 << 20;
/// How often job-exec looks at the job slice while the command runs.
const TICK: Duration = Duration::from_millis(100);

/// What job-exec runs, and how it judges it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct JobExec {
    pub id: String,
    pub attempt: u32,
    /// The machine's name in the result.
    pub machine: String,
    /// The job's slice: stopped whole on an OOM or the timeout.
    pub slice: String,
    pub argv: Vec<String>,
    pub env: Vec<(String, String)>,
    pub cwd: Option<PathBuf>,
    /// The attempt's log (the unit appends the command's output to it).
    pub log: PathBuf,
    /// The `check.log` files of the job's state dirs.
    pub state_logs: Vec<PathBuf>,
    /// The job gets keys: refused unless its service can't swap.
    pub keyed: bool,
    pub parser: Parser,
    pub expect: Expect,
    pub grant: Grant,
    pub timeout_s: u64,
}

impl JobExec {
    /// Writes the spec into the attempt's folder DIR.
    pub fn write(&self, dir: &Path) -> io::Result<()> {
        write_atomic(
            dir,
            SPEC,
            &serde_json::to_vec_pretty(self).map_err(io::Error::other)?,
        )
    }

    /// Reads DIR's spec.
    pub fn read(dir: &Path) -> io::Result<JobExec> {
        serde_json::from_slice(&fs::read(dir.join(SPEC))?).map_err(io::Error::other)
    }
}

fn write_atomic(dir: &Path, name: &str, body: &[u8]) -> io::Result<()> {
    let tmp = dir.join(format!(".{name}.tmp"));
    fs::write(&tmp, body)?;
    fs::rename(&tmp, dir.join(name))
}

/// Records REASON (`infra: disk`, `evicted`, …) in DIR before the scheduler kills the job, so the verdict names it.
pub fn kill_reason(dir: &Path, reason: &str) -> io::Result<()> {
    write_atomic(dir, KILL_REASON, reason.as_bytes())
}

fn read_kill_reason(dir: &Path) -> Option<String> {
    fs::read_to_string(dir.join(KILL_REASON))
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// This process's own cgroup directory (its service), from `/proc/self/cgroup`.
fn own_cgroup() -> io::Result<PathBuf> {
    let text = fs::read_to_string("/proc/self/cgroup")?;
    let rel = text
        .lines()
        .find_map(|l| l.strip_prefix("0::"))
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "no cgroup v2 line in /proc/self/cgroup",
            )
        })?;
    Ok(Path::new("/sys/fs/cgroup").join(rel.trim_start_matches('/')))
}

/// The job slice's directory: the parent of job-exec's own service, which must be SLICE.
fn job_slice_dir(slice: &str) -> Result<PathBuf, String> {
    let own = own_cgroup().map_err(|e| format!("job-exec's cgroup: {e}"))?;
    let parent = own.parent().map(Path::to_path_buf).unwrap_or_default();
    if parent.file_name().and_then(|n| n.to_str()) != Some(slice) {
        return Err(format!(
            "job-exec runs in {}, not in its slice {slice}",
            own.display()
        ));
    }
    Ok(parent)
}

fn file_len(p: &Path) -> u64 {
    fs::metadata(p).map(|m| m.len()).unwrap_or(0)
}

fn read_log(p: &Path) -> Vec<u8> {
    let mut out = vec![];
    if let Ok(f) = fs::File::open(p) {
        let _ = f.take(LOG_CAP).read_to_end(&mut out);
    }
    out
}

/// What the run saw, for the verdict.
#[derive(Default)]
struct Seen {
    oom: bool,
    timed_out: bool,
    signal: Option<i32>,
    exit_code: Option<i32>,
    setup: Option<String>,
}

/// Runs SPEC from the attempt's folder DIR and writes `result.json` there; the result.
pub fn run(dir: &Path, spec: &JobExec) -> ResultJson {
    let t0 = Instant::now();
    let offsets: Vec<(PathBuf, u64)> = spec
        .state_logs
        .iter()
        .map(|p| (p.clone(), file_len(p)))
        .collect();
    let _ = write_atomic(
        dir,
        OFFSETS,
        &serde_json::to_vec(&offsets).unwrap_or_default(),
    );
    let mut seen = Seen::default();
    let slice = job_slice_dir(&spec.slice);
    let before = slice
        .as_ref()
        .ok()
        .and_then(|d| CgroupStat::read(d).ok())
        .unwrap_or_default();
    let killed =
        |s: &CgroupStat| s.oom_kill > before.oom_kill || s.oom_group_kill > before.oom_group_kill;
    match (&slice, spec.keyed) {
        (Err(e), _) => seen.setup = Some(e.clone()),
        (Ok(_), true) => {
            // a keyed job's secrets must never reach swap: its service is capped at no swap before the first key
            let swap = own_cgroup().and_then(|c| fs::read_to_string(c.join("memory.swap.max")));
            match swap.as_deref().map(str::trim) {
                Ok("0") => {}
                Ok(v) => {
                    seen.setup = Some(format!(
                        "memory.swap.max is {v}, not 0: a keyed job never runs where it can swap"
                    ))
                }
                Err(e) => {
                    seen.setup = Some(format!(
                        "memory.swap.max can't be read ({e}): a keyed job never runs where it can swap"
                    ))
                }
            }
        }
        _ => {}
    }
    if spec.argv.is_empty() {
        seen.setup = Some("the job has no command".into());
    }
    if seen.setup.is_none() {
        let mut cmd = Command::new(&spec.argv[0]);
        cmd.args(&spec.argv[1..])
            .envs(spec.env.iter().map(|(k, v)| (k, v)))
            .stdin(Stdio::null());
        if let Some(c) = &spec.cwd {
            cmd.current_dir(c);
        }
        match cmd.spawn() {
            Err(e) => seen.setup = Some(format!("{}: {e}", spec.argv[0])),
            Ok(mut child) => loop {
                match child.try_wait() {
                    Ok(Some(st)) => {
                        seen.exit_code = st.code();
                        seen.signal = st.signal();
                        break;
                    }
                    Ok(None) => {}
                    Err(e) => {
                        seen.setup = Some(format!("waiting for the job: {e}"));
                        break;
                    }
                }
                if slice
                    .as_ref()
                    .ok()
                    .and_then(|d| CgroupStat::read(d).ok())
                    .is_some_and(|s| killed(&s))
                {
                    seen.oom = true;
                    break;
                }
                if t0.elapsed() >= Duration::from_secs(spec.timeout_s.max(1)) {
                    seen.timed_out = true;
                    break;
                }
                std::thread::sleep(TICK);
            },
        }
    }
    let after = slice
        .as_ref()
        .ok()
        .and_then(|d| CgroupStat::read(d).ok())
        .unwrap_or_default();
    seen.oom |= killed(&after);
    let stop_slice = seen.oom || seen.timed_out;
    let result = judge_run(dir, spec, &seen, &before, &after, t0.elapsed());
    let _ = result.write(dir);
    if stop_slice {
        // the job is one OOM group: the rest of it (its other containers, the podman client) goes with it, and
        // job-exec with them, now that the verdict is written
        let _ = slices::stop(&spec.slice);
    }
    result
}

fn judge_run(
    dir: &Path,
    spec: &JobExec,
    seen: &Seen,
    before: &CgroupStat,
    after: &CgroupStat,
    wall: Duration,
) -> ResultJson {
    let parsed = parse::parse(spec.parser, &read_log(&spec.log));
    let reason = read_kill_reason(dir);
    let ev = ExitEvidence {
        evicted: reason.as_deref() == Some(EVICTED),
        kill_reason: match (&seen.setup, reason) {
            (Some(_), _) => Some(infra::SETUP.to_string()),
            (None, Some(r)) if r != EVICTED => Some(r),
            _ => None,
        },
        oom_kill_grew: seen.oom,
        oomd_line: None,
        signal: seen.signal,
        exit_code: seen.exit_code,
        timed_out: seen.timed_out,
        parsed: parsed
            .counts_rows
            .then(|| parse::judge(&parsed, &spec.expect)),
    };
    let verdict = forseti::classify::classify(&ev);
    let infra = match &verdict {
        Verdict::Infra(why) => Some(format!("infra: {why}")),
        _ => None,
    };
    if let Some(why) = &seen.setup {
        eprintln!("sleipnir job-exec: {why}");
    }
    let rows: Vec<RowResult> = parsed
        .rows
        .iter()
        .map(|(name, v)| RowResult {
            name: name.clone(),
            verdict: *v,
            attempt: spec.attempt,
            machine: spec.machine.clone(),
        })
        .collect();
    ResultJson {
        verdict,
        infra,
        counts: parsed.counts,
        failing: parsed
            .rows
            .iter()
            .filter(|(_, v)| matches!(v, RowVerdict::Fail | RowVerdict::Crash))
            .map(|(n, _)| n.clone())
            .collect(),
        rows,
        machine: spec.machine.clone(),
        grant: spec.grant,
        wall_s: wall.as_secs_f64(),
        cpu_s: after.cpu_usec.saturating_sub(before.cpu_usec) as f64 / 1e6,
        mem_peak_mib: after.peak / (1024 * 1024),
        disturbed: false,
        log: spec.log.display().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(log: &Path) -> JobExec {
        JobExec {
            id: "a3f".into(),
            attempt: 1,
            machine: "desk".into(),
            slice: "t-work-a3f.slice".into(),
            argv: vec!["true".into()],
            env: vec![],
            cwd: None,
            log: log.to_path_buf(),
            state_logs: vec![],
            keyed: false,
            parser: Parser::CargoTest,
            expect: Expect::default(),
            grant: Grant {
                cores: 1,
                mem_cap_mib: 512,
                reserve_mib: 256,
            },
            timeout_s: 60,
        }
    }

    /// [D] A reason written before a kill names the verdict, whatever the exit and the rows say; an eviction stays an
    /// eviction; without one, the rows and the exit decide.
    #[test]
    fn a_written_kill_reason_wins() {
        let d = tempfile::tempdir().unwrap();
        let log = d.path().join("a3f.1.log");
        fs::write(&log, "test a ... ok\ntest b ... FAILED\n").unwrap();
        let s = spec(&log);
        let st = CgroupStat::default();
        let killed = Seen {
            signal: Some(9),
            ..Default::default()
        };
        let exited = |c: i32| Seen {
            exit_code: Some(c),
            ..Default::default()
        };
        // no reason: the failed row makes it red
        let r = judge_run(d.path(), &s, &exited(101), &st, &st, Duration::from_secs(1));
        assert_eq!(
            (r.verdict, r.failing),
            (Verdict::Red, vec!["b".to_string()])
        );
        kill_reason(d.path(), "infra: disk").unwrap();
        let r = judge_run(d.path(), &s, &killed, &st, &st, Duration::from_secs(1));
        assert_eq!(
            (r.verdict, r.infra.as_deref()),
            (Verdict::Infra("disk".into()), Some("infra: disk"))
        );
        assert_eq!(r.counts.failed, 1, "the rows are still reported");
        let r = judge_run(d.path(), &s, &exited(1), &st, &st, Duration::from_secs(1));
        assert_eq!(r.verdict, Verdict::Infra("disk".into()));
        kill_reason(d.path(), EVICTED).unwrap();
        assert_eq!(
            judge_run(d.path(), &s, &killed, &st, &st, Duration::from_secs(1)).verdict,
            Verdict::Evicted
        );
        // a setup refusal is infra: setup, never red
        fs::remove_file(d.path().join(KILL_REASON)).unwrap();
        let setup = Seen {
            setup: Some("memory.swap.max is max".into()),
            ..Default::default()
        };
        assert_eq!(
            judge_run(d.path(), &s, &setup, &st, &st, Duration::from_secs(1)).verdict,
            Verdict::Infra("setup".into())
        );
        // the job slice's OOM is the job's OOM
        let oom = Seen {
            oom: true,
            exit_code: Some(137),
            ..Default::default()
        };
        assert_eq!(
            judge_run(d.path(), &s, &oom, &st, &st, Duration::from_secs(1)).verdict,
            Verdict::Oom
        );
        // the spec round-trips through its file
        s.write(d.path()).unwrap();
        assert_eq!(JobExec::read(d.path()).unwrap(), s);
    }
}
