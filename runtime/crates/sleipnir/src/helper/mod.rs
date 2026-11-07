//! The job helper (`sleipnir job-helper --dir D [--hub-allow FILE]`, docs/develop/sleipnir.md, "The job helper"): one
//! per attempt, started by job-exec inside the job's own unit and slice, so it lives exactly as long as the job. It
//! owns what the job may use and must never keep:
//!
//! - the job's keys ([`keys`]): `serve` hands them over `D/helper.sock`, the helper holds them in locked memory (no
//!   swap, no core dump: the process is not dumpable) and answers `drgnx-key`'s requests, which come as key streams
//!   of the job's relay (its sidecar's `@drgnx-key`), zeroed at the end;
//! - the job's relay ([`net`], with the `runner` feature), for a networked or keyed job: its sidecar (`drgnx-px`,
//!   started here before the job, whose namespace the job joins), Gleipnir's CONNECT proxy on the relay's streams with
//!   the hub's allow-list (empty for a job without network), never a link-local or cloud metadata address, and the
//!   key streams; a relay that ends before the job ends it `infra: proxy`;
//! - the disk watch ([`disk`]): below the runner folder's floor the job that grew most since its start is stopped,
//!   `infra: disk`.
//!
//! It announces itself with one line on stdout (`ready <pid>`) once its sockets listen (and the sidecar sent its
//! `READY`), and ends when its stdin does:
//! job-exec holds that pipe, so the helper goes with job-exec, and with the job's unit.

pub mod disk;
pub mod keys;
#[cfg(feature = "runner")]
pub mod net;

use crate::linux::jobexec::JobExec;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

/// The helper's pid, written once it is ready.
pub const PID: &str = "helper.pid";
/// Where the helper's own messages go (never a key's value).
pub const LOG: &str = "helper.log";

/// How the helper was started.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Args {
    /// The attempt's folder: its `job.json` names the keys, the runner folder and the container.
    pub dir: PathBuf,
    /// The hub's allow-list (`host:port` per line): the job has network through the proxy.
    pub hub_allow: Option<PathBuf>,
    /// How long a key request waits for its key ([`keys::KEY_WAIT`]; shorter only in test builds).
    pub key_wait: Duration,
}

impl Args {
    /// `--dir D [--hub-allow FILE]`, and in test builds `--key-wait-s N`.
    pub fn parse(args: &[&str]) -> Result<Args, String> {
        let mut a = Args {
            dir: PathBuf::new(),
            hub_allow: None,
            key_wait: keys::KEY_WAIT,
        };
        let mut it = args.iter();
        while let Some(o) = it.next() {
            let mut val = || it.next().ok_or_else(|| format!("{o} needs a value"));
            match *o {
                "--dir" => a.dir = PathBuf::from(val()?),
                "--hub-allow" => a.hub_allow = Some(PathBuf::from(val()?)),
                #[cfg(feature = "test-hooks")]
                "--key-wait-s" => {
                    a.key_wait =
                        Duration::from_secs(val()?.parse().map_err(|_| "--key-wait-s: seconds")?)
                }
                other => return Err(format!("unknown option {other}")),
            }
        }
        if !a.dir.is_absolute() {
            return Err("--dir must be absolute".into());
        }
        Ok(a)
    }
}

/// No core dump and no ptrace by another process of this user: `PR_SET_DUMPABLE` 0 (a piped `core_pattern` ignores
/// `RLIMIT_CORE`), and `RLIMIT_CORE` 0 besides.
pub fn harden() -> io::Result<()> {
    // SAFETY: plain prctl/setrlimit calls with constant arguments
    unsafe {
        if libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) != 0 {
            return Err(io::Error::last_os_error());
        }
        let none = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        if libc::setrlimit(libc::RLIMIT_CORE, &none) != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

fn say(dir: &Path, what: &str) {
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join(LOG))
        .and_then(|mut f| writeln!(f, "sleipnir job-helper: {what}"));
}

/// Runs the helper until its stdin ends; the exit status.
pub fn run(a: &Args) -> i32 {
    match serve(a) {
        Ok(()) => 0,
        Err(e) => {
            say(&a.dir, &e);
            eprintln!("sleipnir job-helper: {e}");
            2
        }
    }
}

fn serve(a: &Args) -> Result<(), String> {
    harden().map_err(|e| format!("not dumpable: {e}"))?;
    let spec = JobExec::read(&a.dir).map_err(|e| format!("job.json: {e}"))?;
    let h = spec.helper.unwrap_or_default();
    let store = Arc::new(keys::KeyStore::new(h.keys.clone()));
    let hub =
        keys::bind(&a.dir, keys::HELPER_SOCK).map_err(|e| format!("{}: {e}", keys::HELPER_SOCK))?;
    let keyed = !h.keys.is_empty();
    #[cfg(feature = "runner")]
    let relay = match (a.hub_allow.is_some() || keyed, &h.net) {
        (false, _) => None,
        (true, None) => return Err("a networked or keyed job's spec names no sidecar".into()),
        (true, Some(n)) => {
            let allow = match &a.hub_allow {
                Some(f) => {
                    let text =
                        std::fs::read_to_string(f).map_err(|e| format!("{}: {e}", f.display()))?;
                    net::allow_list(&text)?
                }
                // a keyed job without network: the relay carries its keys, and its proxy reaches nothing
                None => vec![],
            };
            let keys = keyed.then(|| {
                Arc::new(net::KeyServer {
                    store: store.clone(),
                    dir: a.dir.clone(),
                    wait: a.key_wait,
                }) as Arc<dyn drgnx_px::owner::KeySource>
            });
            Some(net::Relay::start(
                &a.dir,
                allow,
                &h.sidecar_argv,
                &n.sidecar,
                h.container.clone(),
                keys,
            )?)
        }
    };
    #[cfg(not(feature = "runner"))]
    if a.hub_allow.is_some() || keyed {
        return Err(
            "this sleipnir has no relay for a job's network or keys (built without the runner feature)".into(),
        );
    }
    keys::serve_hub(hub, store.clone());
    if !h.root.as_os_str().is_empty() {
        disk::watch(h.root.clone(), a.dir.clone(), h.container.clone());
    }
    let pid = std::process::id();
    let _ = std::fs::write(a.dir.join(PID), pid.to_string());
    {
        let mut out = io::stdout().lock();
        writeln!(out, "ready {pid}")
            .and_then(|()| out.flush())
            .map_err(|e| format!("the ready line: {e}"))?;
    }
    let _ = io::copy(&mut io::stdin().lock().take(u64::MAX), &mut io::sink());
    // the end: the job's container, then its sidecar; the keys are zeroed now, whatever thread still holds the store
    #[cfg(feature = "runner")]
    if let Some(r) = relay {
        r.end();
    }
    store.clear();
    let _ = std::fs::remove_file(a.dir.join(keys::HELPER_SOCK));
    Ok(())
}
