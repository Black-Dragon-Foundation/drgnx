//! gleipnir-probe: tries one channel per probe and prints one JSON line each (Task 14; docs/develop/gleipnir.md,
//! "Proving it"). Probes are separated by `--and`. A probe never prints file contents.
//!
//! The attempts themselves are `gleipnir::probe`'s, raw on purpose: an owner crate's guards would change what the
//! sandbox is measured against. This bin's own work (arguments, errors, output, the browser-layer handshake's files and
//! waits) goes through the owner crates. It builds static for a musl target or against an older glibc, so the probe
//! runs inside a VM that has no toolchain.

use std::io::Write;
use std::net::TcpListener;
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::process::ExitCode;
use std::time::Duration;

use gleipnir::probe::{Usage, probe};
use gleipnir_escape::{ProbeLine, errno_name};
use villa::{Error, Kind};

/// What a browser-layer probe line writes `{agent-pid}` as: the stand-in agent's pid, which only the processes
/// inside know (the escape rows' `${PARENT}`).
const AGENT_PID: &str = "{agent-pid}";

/// How long the browser probe and the stand-in agent wait for each other.
const HANDSHAKE: Duration = Duration::from_secs(40);

/// How often the handshake looks again.
const POLL: Duration = Duration::from_millis(20);

/// What a handshake file may hold (a pid; the lines of a few probes).
const READ_CAP: u64 = 1 << 20;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let done = match args.first().map(String::as_str) {
        Some("--as-browser") => as_browser(&args[1..]),
        Some("--stand-in") => stand_in(&args[1..]),
        _ if args.is_empty() => Err(Error::invalid("needs probes separated by --and")),
        _ => run_probes(&args, &mut annall::raw_out(), None),
    };
    match done {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            drop(annall::cli_err(&format!("gleipnir-probe: {e}")));
            // a malformed line is the caller's (2); a failed step is the run's (1)
            ExitCode::from(if e.kind() == Kind::Invalid { 2 } else { 1 })
        }
    }
}

/// R's error with WHAT it was doing, in MODE (`--as-browser` or `--stand-in`).
fn step<T, E: std::fmt::Display>(mode: &str, what: &str, r: Result<T, E>) -> villa::Result<T> {
    r.map_err(|e| Error::io(format!("{mode}: {what}: {e}")))
}

/// `--as-browser DIR [PROBES]`: the escape probe as the browser host, under the browser layer. It writes its pid
/// to `DIR/browser.pid`, says `ready` on fd 4 (the helper then runs the agent), waits for the stand-in agent's
/// `DIR/go`, and runs its probes with `{agent-pid}` as its parent's pid (the agent: the helper forked this process
/// and then became the agent). Its stdout is `/dev/null`, so the lines go to `DIR/lines`, which the agent prints.
fn as_browser(a: &[String]) -> villa::Result<()> {
    const MODE: &str = "--as-browser";
    let Some(dir) = a.first().map(Path::new) else {
        return Err(Error::invalid("--as-browser needs DIR"));
    };
    step(
        MODE,
        "browser.pid",
        eitri::replace_file(
            &dir.join("browser.pid"),
            std::process::id().to_string().as_bytes(),
        ),
    )?;
    // SAFETY: fd 4 is the ready pipe the helper gave this process; it is written once and closed.
    unsafe {
        if libc::write(4, b"ready\n".as_ptr().cast(), 6) != 6 {
            return step(MODE, "the ready pipe", Err(std::io::Error::last_os_error()));
        }
        libc::close(4);
    }
    if !wait_for(|| dir.join("go").exists()) {
        return Err(Error::timeout(format!("{MODE}: the stand-in agent's go")));
    }
    let mut out = Vec::new();
    if a.len() > 1 {
        // SAFETY: getppid has no failure mode.
        run_probes(&a[1..], &mut out, Some(unsafe { libc::getppid() }))?;
    }
    step(MODE, "lines", eitri::replace_file(&dir.join("lines"), &out))
}

/// `--stand-in DIR ABSTRACT PORT [PROBES]`: the agent of a browser-layer row. It holds what a browser must not
/// reach: `/tmp/agent-file`, the abstract socket `ABSTRACT` and a TCP listener on `127.0.0.1:PORT` (the agent's
/// local server). With probes it runs them itself first (the control run: the agent reaches each), with
/// `{agent-pid}` as its own pid. Then it tells the browser probe to go, waits for it to exit and prints its lines.
fn stand_in(a: &[String]) -> villa::Result<()> {
    const MODE: &str = "--stand-in";
    if a.len() < 3 {
        return Err(Error::invalid("--stand-in needs DIR ABSTRACT PORT"));
    }
    let dir = Path::new(&a[0]);
    let port: u16 = a[2]
        .parse()
        .map_err(|_| Error::invalid("--stand-in: PORT is a number"))?;
    step(
        MODE,
        "/tmp/agent-file",
        eitri::replace_file(Path::new("/tmp/agent-file"), b"the agent's own file\n"),
    )?;
    let _abstract = step(MODE, "the abstract socket", listen_abstract(&a[1]))?;
    let _local = step(
        MODE,
        "the local server",
        TcpListener::bind(("127.0.0.1", port)),
    )?;
    let mut stdout = annall::raw_out();
    if a.len() > 3 {
        run_probes(&a[3..], &mut stdout, Some(std::process::id() as i32))?;
    }
    let text = step(
        MODE,
        "browser.pid",
        eitri::read_string(&dir.join("browser.pid"), READ_CAP),
    )?;
    let pid: i32 = step(MODE, "browser.pid", text.trim().parse())?;
    step(MODE, "go", eitri::replace_file(&dir.join("go"), b""))?;
    let mut status = 0;
    // SAFETY: waitpid on the browser probe, this process's child (forked by the helper before it became this).
    let gone = wait_for(|| unsafe { libc::waitpid(pid, &raw mut status, libc::WNOHANG) } == pid);
    if !gone {
        // SAFETY: kill(2) of our own child.
        unsafe { libc::kill(pid, libc::SIGKILL) };
        return Err(Error::timeout(format!("{MODE}: the browser probe")));
    }
    // no lines file: the browser probe had none to say
    if let Ok(lines) = eitri::read_file(&dir.join("lines"), READ_CAP) {
        step(
            MODE,
            "stdout",
            stdout.write_all(&lines).and_then(|()| stdout.flush()),
        )?;
    }
    Ok(())
}

/// Polls `done` every [`POLL`] for at most [`HANDSHAKE`]: real time, because the processes it waits for run in it.
fn wait_for(mut done: impl FnMut() -> bool) -> bool {
    let end = stund::real::instant() + HANDSHAKE;
    while stund::real::instant() < end {
        if done() {
            return true;
        }
        stund::real::sleep_blocking(POLL);
    }
    false
}

#[cfg(target_os = "linux")]
fn listen_abstract(name: &str) -> std::io::Result<UnixListener> {
    use std::os::linux::net::SocketAddrExt;
    let addr = std::os::unix::net::SocketAddr::from_abstract_name(name.trim_start_matches('@'))?;
    UnixListener::bind_addr(&addr)
}

#[cfg(not(target_os = "linux"))]
fn listen_abstract(_: &str) -> std::io::Result<UnixListener> {
    Err(std::io::ErrorKind::Unsupported.into())
}

/// The probes in `args` (separated by `--and`), one JSON line each to `out`. With `agent`, `{agent-pid}` in an
/// argument is that pid.
fn run_probes(args: &[String], out: &mut dyn Write, agent: Option<i32>) -> villa::Result<()> {
    let args: Vec<String> = match agent {
        Some(pid) => args
            .iter()
            .map(|a| a.replace(AGENT_PID, &pid.to_string()))
            .collect(),
        None => args.to_vec(),
    };
    let groups: Vec<&[String]> = args.split(|a| a == "--and").collect();
    if groups.iter().any(|g| g.is_empty()) {
        return Err(Error::invalid("needs probes separated by --and"));
    }
    for g in groups {
        let (name, rest) = (g[0].as_str(), &g[1..]);
        let outcome = probe(name, rest).map_err(|Usage(why)| Error::invalid(why))?;
        let mut line = ProbeLine {
            probe: name.to_string(),
            arg: rest.join(" "),
            result: "reached".into(),
            errno: None,
            detail: None,
            out_bytes: None,
        };
        match outcome {
            Ok((detail, bytes)) => {
                line.detail = detail;
                line.out_bytes = bytes;
            }
            Err((n, detail)) => {
                line.result = "blocked".into();
                line.errno = (n != 0).then(|| errno_name(n));
                line.detail = detail;
            }
        }
        let json = serde_json::to_string(&line).map_err(|e| Error::internal(e.to_string()))?;
        // a reader that went away has nothing left to hear the rest
        drop(writeln!(out, "{json}"));
        drop(out.flush());
    }
    Ok(())
}
