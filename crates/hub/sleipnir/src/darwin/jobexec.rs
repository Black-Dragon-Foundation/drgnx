//! job-exec on a Mac: the process [`super::attempt::launch`] starts in a session of its own. It runs the job's
//! command, always under `sandbox-exec` (never unconfined: a command that isn't is refused), with its output on a pipe
//! job-exec copies into the attempt's log (the job can't touch its attempt folder's files); keeps the Mac from idle sleep while it runs (`caffeinate -i -w`); stops it at its timeout, counted
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
use crate::linux::parse;
use crate::linux::probe::Probe;
use crate::linux::result::{ResultJson, RowResult};
use forseti::Verdict;
use forseti::classify::{ExitEvidence, infra};
use std::fs;
use std::io::Read;
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
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
/// is anything but the job's proxy (its allow-list, sockets and port: `darwin::proxy`).
pub fn refusal(spec: &JobExec) -> Option<String> {
    if spec.keyed {
        return Some("a Mac runner takes no keyed job".into());
    }
    if let Some(h) = &spec.helper {
        let proxy_only = HelperSpec {
            hub_allow: h.hub_allow.clone(),
            proxy_fd: h.proxy_fd,
            proxy_v6_fd: h.proxy_v6_fd,
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
        let log = crate::fsio::append(&spec.log, true);
        match log {
            Err(e) => seen.setup = Some(format!("the log {}: {e}", spec.log.display())),
            Ok(log) => {
                let mut env: Vec<(std::ffi::OsString, std::ffi::OsString)> =
                    spec.env.iter().map(|(k, v)| (k.into(), v.into())).collect();
                // a pipe, copied into the log: under Seatbelt the job can't stat or write its attempt folder's
                // files, and a pipe has no path
                let mut copier = None;
                let mut opts = draugr::Opts::default();
                match std::io::pipe().and_then(|(r, w)| Ok((r, w.try_clone()?, w))) {
                    Ok((r, out, err)) => {
                        let fd = |w: std::io::PipeWriter| {
                            std::sync::Arc::new(std::os::fd::OwnedFd::from(w))
                        };
                        opts.stdout = draugr::Redirect::To(fd(out));
                        opts.stderr = draugr::Redirect::To(fd(err));
                        copier = Some(copy_into(r, log));
                    }
                    Err(e) => seen.setup = Some(format!("the log's pipe: {e}")),
                }
                // the marker, from the spec (`sandbox::spec` sets it) or made here: the attempt's folder, unique
                let marker = match spec.env.iter().find(|(k, _)| k == MARKER) {
                    Some((_, v)) => v.clone(),
                    None => {
                        let v = dir.display().to_string();
                        env.push((MARKER.into(), v.clone().into()));
                        v
                    }
                };
                if seen.setup.is_none() {
                    // a job-exec that leads no session starts the command in one of its own
                    let job = draugr::Spec {
                        program: (&spec.argv[0]).into(),
                        args: spec.argv[1..].iter().map(Into::into).collect(),
                        env,
                        cwd: spec.cwd.clone(),
                        stdin_null: true,
                        pass_fds: vec![],
                        new_session: !leads_session(),
                    };
                    watch(
                        dir,
                        spec,
                        (job, opts),
                        &format!("{MARKER}={marker}"),
                        t0,
                        &mut seen,
                    );
                }
                // our ends of the pipe closed (`watch` dropped them at the spawn): the copy ends once the job's processes
                // (killed by `watch`) are gone
                if let Some(done) = copier {
                    // a timeout is the stray process holding the pipe, which the group's kill ends; nothing to add
                    if done.recv_timeout(DRAIN).is_err() {
                        tracing::debug!("the job's log copy did not end within the drain wait");
                    }
                }
            }
        }
    }
    let stop = seen.timed_out || seen.stopped;
    let result = judge(dir, spec, &seen, mono_s() - t0);
    if let Err(e) = result.write(dir) {
        crate::eline!("sleipnir job-exec: result.json: {e}");
    }
    (result, stop)
}

/// How long the log's copy may take to drain once the job is over: a process that slipped past the kill and still
/// holds the pipe can't hold the result back (it dies with the group after the result is written).
const DRAIN: Duration = Duration::from_secs(2);

/// What reaches R copied into LOG on a thread of its own; the receiver hears when R reached its end.
fn copy_into(mut r: std::io::PipeReader, mut log: fs::File) -> std::sync::mpsc::Receiver<()> {
    let (tx, rx) = std::sync::mpsc::channel();
    let started = saman::spawn_thread("job-log-copy", move || {
        // the copy ends when the job's processes are gone; how it ended does not change the verdict
        if let Err(e) = std::io::copy(&mut r, &mut log) {
            tracing::debug!(error = %e, "copying the job's output into its log");
        }
        saman::delivered(tx.send(()), "the log copy's end");
    });
    if let Err(e) = started {
        crate::eline!("sleipnir job-exec: the log copy: {e}");
    }
    rx
}

/// `caffeinate -i -w <our pid>`: idle sleep held off while job-exec lives. Started on a pool of its own that stays
/// until [`Awake::end`], since a blocking caller has no runtime to hold the child.
struct Awake {
    pool: saman::Executor,
    child: draugr::Child,
}

impl Awake {
    fn start() -> Option<Awake> {
        let pool = saman::Executor::new(1).ok()?;
        let pid = std::process::id().to_string();
        let spec =
            crate::linux::run::spec(Path::new("/usr/bin/caffeinate"), &["-i", "-w", &pid], &[]);
        let child = pool.block_on(draugr::spawn(spec)).ok()?;
        Some(Awake { pool, child })
    }

    /// Stops it: its group is killed at once, and it is reaped.
    fn end(mut self) {
        if let Err(e) = self.pool.block_on(self.child.wait_deadline(Duration::ZERO)) {
            crate::eline!("sleipnir job-exec: stopping caffeinate: {e}");
        }
    }
}

fn watch(
    dir: &Path,
    spec: &JobExec,
    (job, opts): (draugr::Spec, draugr::Opts),
    marker: &str,
    t0: f64,
    seen: &mut Seen,
) {
    // SAFETY: getpid has no failure
    let me = unsafe { libc::getpid() };
    // what the disk watch counts this job's growth from
    if let Err(e) = crate::fsio::write(dir.join(disk::DISK_START), disk::size(dir).to_string()) {
        crate::eline!("sleipnir job-exec: the disk start record: {e}");
    }
    let started = draugr::spawn_std(&job, &opts);
    // our ends of the log's pipe closed: only the job holds them now
    drop((job, opts));
    let mut child = match started {
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
    let awake = cfg!(target_os = "macos").then(Awake::start).flatten();
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
        stund::sleep_blocking(TICK);
    }
    if seen.timed_out || seen.stopped {
        // the child may have exited between the last check and now: a failed kill says only that
        drop(child.kill());
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
    if let Some(a) = awake {
        a.end();
    }
}

fn judge(dir: &Path, spec: &JobExec, seen: &Seen, wall_s: f64) -> ResultJson {
    let mut log = vec![];
    if let Ok(f) = fs::File::open(&spec.log) {
        // what could be read is what the parser gets; a log that ends early is no reason to lose the verdict
        if let Err(e) = f.take(crate::linux::jobexec::LOG_CAP).read_to_end(&mut log) {
            tracing::debug!(error = %e, "reading the job's log");
        }
    }
    let parsed = parse::parse(&spec.parser, &log);
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
        crate::eline!("sleipnir job-exec: {why}");
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
        failing: parsed.failing(),
        rows: parsed
            .rows
            .iter()
            .map(|r| RowResult::of(r, spec.attempt, &spec.machine))
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
            stall_s: None,
            silent_s: None,
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

    /// [D] A Mac job's only helper is its proxy (its allow-list, its sockets and port; the `::1` one only where the Mac
    /// has an IPv6 loopback); anything of
    /// Linux's helper (keys, a relay, a container) or a part of the proxy alone is refused.
    #[test]
    fn a_mac_jobs_only_helper_is_its_proxy() {
        let d = PathBuf::from("/x");
        let proxy = HelperSpec {
            hub_allow: Some("/x/net.allow".into()),
            proxy_fd: Some(5),
            proxy_v6_fd: Some(6),
            proxy_port: Some(41234),
            ..Default::default()
        };
        let mut s = spec(&d, &[SANDBOX_EXEC, "-f", "/x/job.sb", "/bin/true"]);
        s.helper = Some(proxy.clone());
        assert_eq!(refusal(&s), None);
        // a Mac without an IPv6 loopback has no listener there to pass
        s.helper = Some(HelperSpec {
            proxy_v6_fd: None,
            ..proxy.clone()
        });
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
        let log = crate::fsio::read_to_string(d.path().join("log")).unwrap();
        assert!(
            log.contains("out") && log.contains("err") && log.contains("home=unset"),
            "{log}"
        );
        let red = spec(d.path(), &["/bin/sh", "-c", "exit 3"]);
        assert_eq!(run_unchecked(d.path(), &red, None).0.verdict, Verdict::Red);
    }

    /// [D] The job writes its output to a pipe that job-exec copies into the log, never to the log file itself: under
    /// Seatbelt a job can't stat or write a file of its attempt folder (`cat` failed with "stdout: Operation not
    /// permitted" on macOS CI), and a pipe has no path. What a job prints last is in the log when it is judged.
    #[test]
    fn the_job_writes_a_pipe_that_job_exec_copies_into_the_log() {
        let d = tempfile::tempdir().unwrap();
        crate::fsio::write(d.path().join("in.txt"), "from a file\n").unwrap();
        let s = spec(
            d.path(),
            &[
                "/bin/sh",
                "-c",
                "if [ -p /dev/stdout ]; then echo piped; else echo not-piped; fi; cat in.txt; echo last >&2",
            ],
        );
        let (r, _) = run_unchecked(d.path(), &s, None);
        let log = crate::fsio::read_to_string(d.path().join("log")).unwrap();
        assert_eq!(r.verdict, Verdict::Pass, "{log}");
        assert_eq!(log, "piped\nfrom a file\nlast\n");
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
        let pid = crate::fsio::read_to_string(d.path().join("left")).unwrap();
        // gone, or a zombie its new parent hasn't reaped yet: either way not running
        let ps = crate::linux::run::limited(
            Path::new("ps"),
            &["-o", "stat=", "-p", pid.trim()],
            &[],
            Duration::from_secs(10),
        )
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
        crate::fsio::write(
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
        // written whole and then renamed, as `kill_reason` writes it: a plain `>` makes the file before the text, and
        // job-exec stopping the shell in between left an empty reason (a SIGKILL with none: `oomd/killed`)
        let s = spec(
            d.path(),
            &[
                "/bin/sh",
                "-c",
                &format!(
                    "echo 'infra: disk' > '{0}.tmp' && mv '{0}.tmp' '{0}'; sleep 300",
                    reason.display()
                ),
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
