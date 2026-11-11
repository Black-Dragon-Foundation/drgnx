//! job-exec on a Mac: the process [`super::attempt::launch`] starts in a session of its own. It runs the job's
//! command, always under `sandbox-exec` (never unconfined: a command that isn't is refused), with its output in the
//! attempt's log; keeps the Mac from idle sleep while it runs (`caffeinate -i -w`); stops it at its timeout, counted
//! on `CLOCK_MONOTONIC` (which counts sleep: Rust's `Instant` on macOS doesn't), or when a kill reason appears; and
//! writes `result.json` judged as on Linux (`forseti::classify`). On a stop the verdict is written first, then the
//! whole process group goes, job-exec with it. Its memory cap is [`super::memwatch`]'s: past it every process of the
//! job is killed, the verdict is `oom` and the overshoot is recorded. It watches the runner folder's disk too (Linux's
//! job helper does it there, [`disk`]): below the floor, the running job that grew most is stopped `infra: disk`.
//!
//! The job's processes are job-exec's session (it leads one: `attempt::launch`) less job-exec; a job-exec that leads
//! none (a test, a hand run) starts the command in a session of its own instead, so the watchdog never takes a
//! stranger's.
//!
//! It reads the same `job.json` ([`JobExec`]) as Linux's: the slice is unused, and a keyed job or one with a helper
//! is refused (a Mac runner never gets keys). Plain Unix: the rows run on Linux.

use super::memwatch::{self, MARKER};
use crate::linux::disk;
use crate::linux::jobexec::{HelperSpec, JobExec, KILL_REASON, read_kill_reason};
use crate::linux::parse::{self, RowVerdict};
use crate::linux::probe::Probe;
use crate::linux::result::{ResultJson, RowResult};
use forseti::Verdict;
use forseti::classify::{ExitEvidence, infra};
use std::fs;
use std::io::Read;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

/// How often job-exec looks at the command, the clock and the kill reason.
const TICK: Duration = Duration::from_millis(100);
/// The only program a Mac job's command may start with.
pub const SANDBOX_EXEC: &str = "/usr/bin/sandbox-exec";

/// Seconds on `CLOCK_MONOTONIC`.
fn mono_s() -> f64 {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: a valid timespec to fill
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    ts.tv_sec as f64 + ts.tv_nsec as f64 / 1e9
}

/// Why SPEC can't run on a Mac: no command, a command not under `sandbox-exec -f <profile>`, keys, or a helper that
/// is anything but the job's proxy (its allow-list, socket and port: `darwin::proxy`).
pub fn refusal(spec: &JobExec) -> Option<String> {
    if spec.keyed {
        return Some("a Mac runner takes no keyed job".into());
    }
    if let Some(h) = &spec.helper {
        let proxy_only = HelperSpec {
            hub_allow: h.hub_allow.clone(),
            proxy_fd: h.proxy_fd,
            proxy_port: h.proxy_port,
            ..HelperSpec::default()
        };
        if *h != proxy_only
            || h.hub_allow.is_none()
            || h.proxy_fd.is_none()
            || h.proxy_port.is_none()
        {
            return Some("a Mac job's only helper is its proxy".into());
        }
    }
    match spec.argv.as_slice() {
        [] => Some("the job has no command".into()),
        [p, f, profile, cmd, ..]
            if p == SANDBOX_EXEC && f == "-f" && !profile.is_empty() && !cmd.is_empty() =>
        {
            None
        }
        _ => Some(format!(
            "a Mac job runs only under {SANDBOX_EXEC} -f <profile>: refused, never run unconfined"
        )),
    }
}

/// What the run saw, for the verdict.
#[derive(Default)]
struct Seen {
    timed_out: bool,
    stopped: bool,
    signal: Option<i32>,
    exit_code: Option<i32>,
    setup: Option<String>,
    /// The watchdog killed it past its cap.
    oom: bool,
    /// The job's largest footprint the watchdog saw, bytes.
    peak: u64,
}

/// Whether this process leads its session (job-exec as `attempt::launch` starts it).
fn leads_session() -> bool {
    // SAFETY: getsid(0) and getpid have no failure
    unsafe { libc::getsid(0) == libc::getpid() }
}

/// Runs SPEC from the attempt's folder DIR and writes `result.json` there; the result. However the job ended (by
/// itself, a timeout, a kill reason), this process's group goes after the result is written: nothing of it lives on.
pub fn run(dir: &Path, spec: &JobExec) -> ResultJson {
    run_with(dir, spec, None)
}

/// [`run`], with SETUP as a failure found before it (the job's proxy couldn't start): the job then runs nothing.
pub fn run_with(dir: &Path, spec: &JobExec, setup: Option<String>) -> ResultJson {
    let (result, _stop) = run_unchecked(dir, spec, refusal(spec).or(setup));
    if leads_session() {
        // SAFETY: SIGKILL to our own process group (job-exec and every process of the job that stayed in it)
        unsafe { libc::killpg(0, libc::SIGKILL) };
    }
    result
}

/// [`run`] with REFUSED as the setup failure (none: it runs), returning whether the group must be stopped.
fn run_unchecked(dir: &Path, spec: &JobExec, refused: Option<String>) -> (ResultJson, bool) {
    let t0 = mono_s();
    let mut seen = Seen {
        setup: refused,
        ..Seen::default()
    };
    if seen.setup.is_none() {
        let log = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&spec.log);
        match log {
            Err(e) => seen.setup = Some(format!("the log {}: {e}", spec.log.display())),
            Ok(log) => {
                let mut cmd = Command::new(&spec.argv[0]);
                cmd.args(&spec.argv[1..])
                    .env_clear()
                    .envs(spec.env.iter().map(|(k, v)| (k, v)))
                    .stdin(Stdio::null());
                match log.try_clone() {
                    Ok(out) => {
                        cmd.stdout(out).stderr(log);
                    }
                    Err(e) => seen.setup = Some(format!("the log: {e}")),
                }
                if let Some(c) = &spec.cwd {
                    cmd.current_dir(c);
                }
                // the marker, from the spec (`sandbox::spec` sets it) or made here: the attempt's folder, unique
                let marker = match spec.env.iter().find(|(k, _)| k == MARKER) {
                    Some((_, v)) => v.clone(),
                    None => {
                        let v = dir.display().to_string();
                        cmd.env(MARKER, &v);
                        v
                    }
                };
                if !leads_session() {
                    // SAFETY: setsid is async-signal-safe and touches nothing of the parent's
                    unsafe {
                        cmd.pre_exec(|| {
                            rustix::process::setsid()
                                .map(|_| ())
                                .map_err(std::io::Error::from)
                        });
                    }
                }
                if seen.setup.is_none() {
                    watch(
                        dir,
                        spec,
                        &mut cmd,
                        &format!("{MARKER}={marker}"),
                        t0,
                        &mut seen,
                    );
                }
            }
        }
    }
    let stop = seen.timed_out || seen.stopped;
    let result = judge(dir, spec, &seen, mono_s() - t0);
    let _ = result.write(dir);
    (result, stop)
}

fn watch(dir: &Path, spec: &JobExec, cmd: &mut Command, marker: &str, t0: f64, seen: &mut Seen) {
    // SAFETY: getpid has no failure
    let me = unsafe { libc::getpid() };
    // what the disk watch counts this job's growth from
    let _ = fs::write(dir.join(disk::DISK_START), disk::size(dir).to_string());
    let mut child = match cmd.spawn() {
        Err(e) => {
            seen.setup = Some(format!("{}: {e}", spec.argv[0]));
            return;
        }
        Ok(c) => c,
    };
    // the job's session: job-exec's, or the command's own
    let leader = leads_session();
    let sid = if leader { me } else { child.id() as i32 };
    // a process that left the session counts when born after the command
    let born = memwatch::start_of(child.id() as i32);
    let cap = memwatch::cap_bytes(spec.grant.mem_cap_mib);
    let every = (memwatch::TICK.as_millis() / TICK.as_millis()).max(1) as u32;
    // the runner folder is the attempt folder's grandparent (`<root>/jobs/<id>.<attempt>`)
    let root = dir.parent().and_then(Path::parent).map(Path::to_path_buf);
    let probe = root
        .as_ref()
        .and_then(|r| Probe::system("", "", "drgnx-runner", r, forseti::Profile::Dedicated).ok());
    let disk_every = (disk::EVERY.as_millis() / TICK.as_millis()).max(1) as u32;
    // idle sleep held off while job-exec lives (a Mac on battery still sleeps at lid close)
    let awake = cfg!(target_os = "macos")
        .then(|| {
            Command::new("/usr/bin/caffeinate")
                .args(["-i", "-w", &std::process::id().to_string()])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .ok()
        })
        .flatten();
    let mut tick = 0u32;
    loop {
        if tick > 0
            && tick.is_multiple_of(disk_every)
            && let (Some(p), Some(r)) = (&probe, &root)
        {
            // writes the kill reason when it is this job's to stop; the check below stops it
            disk::check(p, r, dir, None);
        }
        if tick.is_multiple_of(every) {
            let s = memwatch::scan(me, sid, born, marker);
            seen.peak = seen.peak.max(s.bytes);
            if s.bytes > cap {
                memwatch::kill_all(&s.pids);
                seen.oom = true;
                seen.stopped = true;
                break;
            }
        }
        tick += 1;
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
        if mono_s() - t0 >= spec.timeout_s.max(1) as f64 {
            seen.timed_out = true;
            break;
        }
        if dir.join(KILL_REASON).exists() {
            seen.stopped = true;
            break;
        }
        std::thread::sleep(TICK);
    }
    if seen.timed_out || seen.stopped {
        let _ = child.kill();
        if let Ok(st) = child.wait() {
            seen.exit_code = st.code();
            seen.signal = st.signal();
        }
    }
    // however it ended, nothing of the job outlives it: what stayed in job-exec's group goes once the result is
    // written (`run`), or, in a session of its own, the command's group now; then the session and the marked
    // escapees the scan finds (and what the job started between a watchdog scan and its kill)
    if !leader {
        // SAFETY: SIGKILL to the command's own process group (it led its session; the group id isn't reused while
        // a member lives)
        unsafe { libc::killpg(child.id() as i32, libc::SIGKILL) };
    }
    memwatch::kill_all(&memwatch::scan(me, sid, born, marker).pids);
    if let Some(mut c) = awake {
        let _ = c.kill();
        let _ = c.wait();
    }
}

fn judge(dir: &Path, spec: &JobExec, seen: &Seen, wall_s: f64) -> ResultJson {
    let mut log = vec![];
    if let Ok(f) = fs::File::open(&spec.log) {
        let _ = f.take(crate::linux::jobexec::LOG_CAP).read_to_end(&mut log);
    }
    let parsed = parse::parse(spec.parser, &log);
    let reason = read_kill_reason(dir);
    let evicted = reason.as_deref() == Some(crate::linux::jobexec::EVICTED);
    let ev = ExitEvidence {
        evicted,
        kill_reason: match (&seen.setup, reason) {
            (Some(_), _) => Some(infra::SETUP.to_string()),
            (None, Some(r)) if !evicted => Some(r),
            _ => None,
        },
        // the watchdog's kill is the job's own OOM (the kernel's counter on Linux), never `red`
        oom_kill_grew: seen.oom,
        oomd_line: None,
        signal: seen.signal,
        exit_code: seen.exit_code,
        timed_out: seen.timed_out,
        parsed: parsed
            .counts_rows
            .then(|| parse::judge(&parsed, &spec.expect)),
    };
    let disturbed = dir.join(crate::linux::jobexec::DISTURBED).exists();
    let verdict = match forseti::classify::classify(&ev) {
        Verdict::Red if disturbed => Verdict::Suspect("disturbed: evicted while it ran".into()),
        v => v,
    };
    let infra = match &verdict {
        Verdict::Infra(why) => Some(format!("infra: {why}")),
        _ => None,
    };
    if let Some(why) = &seen.setup {
        eprintln!("sleipnir job-exec: {why}");
    }
    // the children's CPU and peak memory (ru_maxrss: bytes on macOS, KiB on Linux)
    // SAFETY: a valid rusage to fill
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_CHILDREN, &mut ru) };
    let tv = |t: libc::timeval| t.tv_sec as f64 + t.tv_usec as f64 / 1e6;
    let peak_bytes = if cfg!(target_os = "macos") {
        ru.ru_maxrss as u64
    } else {
        ru.ru_maxrss as u64 * 1024
    }
    .max(seen.peak);
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
        rows: parsed
            .rows
            .iter()
            .map(|(name, v)| RowResult {
                name: name.clone(),
                verdict: *v,
                attempt: spec.attempt,
                machine: spec.machine.clone(),
            })
            .collect(),
        machine: spec.machine.clone(),
        grant: spec.grant,
        wall_s,
        cpu_s: tv(ru.ru_utime) + tv(ru.ru_stime),
        mem_peak_mib: peak_bytes / (1024 * 1024),
        mem_overshoot_mib: Some(seen.peak.saturating_sub(spec.grant.mem_cap_mib << 20) >> 20),
        disturbed,
        log: spec.log.display().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::linux::parse::Parser;
    use forseti::{Expect, Grant};
    use std::path::PathBuf;

    fn spec(dir: &Path, argv: &[&str]) -> JobExec {
        JobExec {
            id: "m1".into(),
            attempt: 1,
            machine: "mac".into(),
            slice: String::new(),
            argv: argv.iter().map(|s| s.to_string()).collect(),
            env: vec![("PATH".into(), "/usr/bin:/bin".into())],
            cwd: Some(dir.to_path_buf()),
            log: dir.join("log"),
            state_logs: vec![],
            keyed: false,
            parser: Parser::Exit,
            expect: Expect::default(),
            grant: Grant {
                cores: 1,
                mem_cap_mib: 512,
                reserve_mib: 512,
            },
            timeout_s: 600,
            helper: None,
        }
    }

    /// [D] Never unconfined: a command not under `sandbox-exec -f <profile>`, a keyed job and one with a helper are
    /// refused; a confined one passes.
    #[test]
    fn only_a_confined_command_runs() {
        let d = PathBuf::from("/x");
        assert!(refusal(&spec(&d, &["/bin/sh", "-c", "true"])).is_some());
        assert!(
            refusal(&spec(
                &d,
                &[SANDBOX_EXEC, "-p", "(allow default)", "/bin/true"]
            ))
            .is_some()
        );
        assert!(refusal(&spec(&d, &[])).is_some());
        let ok = spec(&d, &[SANDBOX_EXEC, "-f", "/x/job.sb", "/bin/true"]);
        assert_eq!(refusal(&ok), None);
        let mut keyed = ok.clone();
        keyed.keyed = true;
        assert!(refusal(&keyed).unwrap().contains("keyed"));
    }

    /// [D] A Mac job's only helper is its proxy (its allow-list, its socket and port, all three); anything of
    /// Linux's helper (keys, a relay, a container) or a part of the proxy alone is refused.
    #[test]
    fn a_mac_jobs_only_helper_is_its_proxy() {
        let d = PathBuf::from("/x");
        let proxy = HelperSpec {
            hub_allow: Some("/x/net.allow".into()),
            proxy_fd: Some(5),
            proxy_port: Some(41234),
            ..Default::default()
        };
        let mut s = spec(&d, &[SANDBOX_EXEC, "-f", "/x/job.sb", "/bin/true"]);
        s.helper = Some(proxy.clone());
        assert_eq!(refusal(&s), None);
        for bad in [
            HelperSpec {
                keys: vec!["K".into()],
                ..proxy.clone()
            },
            HelperSpec {
                container: Some("c".into()),
                ..proxy.clone()
            },
            HelperSpec {
                sidecar_argv: vec!["run".into()],
                ..proxy.clone()
            },
            HelperSpec {
                proxy_fd: None,
                ..proxy.clone()
            },
            HelperSpec {
                hub_allow: None,
                ..proxy.clone()
            },
            HelperSpec::default(),
        ] {
            s.helper = Some(bad.clone());
            assert!(refusal(&s).is_some(), "{bad:?}");
        }
    }

    /// [D] A refused job writes an infra result (setup) and runs nothing.
    #[test]
    fn a_refused_job_is_infra_and_runs_nothing() {
        let d = tempfile::tempdir().unwrap();
        let marker = d.path().join("ran");
        let s = spec(
            d.path(),
            &["/bin/sh", "-c", &format!("touch '{}'", marker.display())],
        );
        let (r, stop) = run_unchecked(d.path(), &s, refusal(&s));
        assert!(matches!(r.verdict, Verdict::Infra(_)), "{:?}", r.verdict);
        assert!(!stop && !marker.exists());
        assert!(d.path().join(crate::linux::result::RESULT).exists());
    }

    /// [D] The command's output lands in the log and its exit judges it: 0 passes, 3 is red; its environment is the
    /// spec's alone.
    #[test]
    fn the_command_runs_with_its_log_and_verdict() {
        let d = tempfile::tempdir().unwrap();
        let s = spec(
            d.path(),
            &[
                "/bin/sh",
                "-c",
                "echo out; echo err >&2; echo \"home=${HOME-unset}\"",
            ],
        );
        let (r, stop) = run_unchecked(d.path(), &s, None);
        assert_eq!(r.verdict, Verdict::Pass);
        assert!(!stop);
        let log = fs::read_to_string(d.path().join("log")).unwrap();
        assert!(
            log.contains("out") && log.contains("err") && log.contains("home=unset"),
            "{log}"
        );
        let red = spec(d.path(), &["/bin/sh", "-c", "exit 3"]);
        assert_eq!(run_unchecked(d.path(), &red, None).0.verdict, Verdict::Red);
    }

    /// [D] A job that ends by itself leaves nothing running: what it left in the background is killed with it.
    #[test]
    fn a_job_that_exits_leaves_nothing_behind() {
        let d = tempfile::tempdir().unwrap();
        let s = spec(
            d.path(),
            &["/bin/sh", "-c", "sleep 300 & echo $! > left; exit 0"],
        );
        let (r, stop) = run_unchecked(d.path(), &s, None);
        assert_eq!(r.verdict, Verdict::Pass, "{r:?}");
        assert!(!stop);
        let pid = fs::read_to_string(d.path().join("left")).unwrap();
        // gone, or a zombie its new parent hasn't reaped yet: either way not running
        let ps = Command::new("ps")
            .args(["-o", "stat=", "-p", pid.trim()])
            .output()
            .unwrap();
        let stat = String::from_utf8_lossy(&ps.stdout);
        assert!(
            stat.trim().is_empty() || stat.trim().starts_with('Z'),
            "the background sleep {} still runs: {stat}",
            pid.trim()
        );
    }

    /// [D] A job past its grant is killed by the watchdog: verdict `oom` (never `red`), its overshoot recorded, nothing
    /// of it left. 400 MiB held (a `dd` buffer blocked on a pipe nobody reads) against a 256 MiB grant.
    #[test]
    fn a_job_past_its_grant_is_killed_oom() {
        let d = tempfile::tempdir().unwrap();
        let mut s = spec(
            d.path(),
            &[
                "/bin/sh",
                "-c",
                "dd if=/dev/zero bs=419430400 count=1 2>/dev/null | sleep 30",
            ],
        );
        s.grant.mem_cap_mib = 256;
        let (r, stop) = run_unchecked(d.path(), &s, None);
        assert_eq!(r.verdict, Verdict::Oom, "{r:?}");
        assert!(stop);
        assert!(r.mem_overshoot_mib.is_some(), "{r:?}");
    }

    /// [D] Below the runner folder's disk floor (a test build's facts), the running job that grew most is stopped
    /// `infra: disk`: a Mac has no job helper, so job-exec watches the disk itself.
    #[cfg(feature = "test-hooks")]
    #[test]
    fn a_job_below_the_disk_floor_is_stopped() {
        let root = tempfile::tempdir().unwrap();
        fs::write(
            root.path().join(crate::linux::probe::TEST_MACHINE),
            r#"{"psi": {"mem_some10": 0.0, "cpu_some10": 0.0, "io_full10": 0.0, "app_mem_some10": null},
                "disk_free_gb": 1, "disk_total_gb": 475, "mem_available_mib": 8192}"#,
        )
        .unwrap();
        let dir = root.path().join("jobs").join("m1.1");
        fs::create_dir_all(&dir).unwrap();
        let s = spec(
            &dir,
            &[
                "/bin/sh",
                "-c",
                "head -c 100000 /dev/zero > grown; sleep 60",
            ],
        );
        let (r, stop) = run_unchecked(&dir, &s, None);
        assert!(stop);
        assert!(
            matches!(&r.verdict, Verdict::Infra(w) if w == infra::DISK),
            "{:?}",
            r.verdict
        );
    }

    /// [D] A kill reason written while the command runs stops it: the verdict names the reason, and the group is to
    /// be stopped.
    #[test]
    fn a_kill_reason_stops_the_job() {
        let d = tempfile::tempdir().unwrap();
        let reason = d.path().join(KILL_REASON);
        let s = spec(
            d.path(),
            &[
                "/bin/sh",
                "-c",
                &format!("echo 'infra: disk' > '{}'; sleep 300", reason.display()),
            ],
        );
        let (r, stop) = run_unchecked(d.path(), &s, None);
        assert!(stop);
        assert!(
            matches!(&r.verdict, Verdict::Infra(w) if w.contains("disk")),
            "{:?}",
            r.verdict
        );
    }
}
