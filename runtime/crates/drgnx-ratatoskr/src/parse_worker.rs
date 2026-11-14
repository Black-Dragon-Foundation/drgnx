//! The sandboxed launcher of the `hrafn-parse` worker (language packs Task 6b-1): what puts a fetched pack's grammar under
//! Gleipnir. The worker is this binary (`ratatoskr hrafn-parse`); its sandbox is the narrowest one a spec can say:
//!
//! - **reads** only its library and this binary (and the system's, which every spec gets);
//! - **writes** nothing: no write root, no home, no session dir, no socket;
//! - **no network**: a network namespace of its own with no relay (loopback inside it only);
//! - **stdin and stdout** are the whole interface: the framed protocol of `hrafn::chunk::worker`; stderr is kept (its
//!   tail goes into the reason of a failure);
//! - time is capped by the hub (the request deadline kills the process group); **memory is not capped yet**: the sandbox's
//!   own limits (Landlock, seccomp, the namespaces) bound what the worker can reach, not what it can allocate. An address-space
//!   limit goes in as soon as a Gleipnir spec can carry one.
//!
//! Only the full tier runs one: on the reduced tier (no mount or network namespace to keep the grammar out of the user's
//! files and the network) the launcher refuses, and the pack's files read as text with a doctor line saying why.

use hrafn::chunk::worker::{Launch, Started, WorkerSpec};
use std::io::{Read, Write};
use std::os::fd::OwnedFd;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

/// The runtime the spawns and the reaping run on: the chunker calls the launcher from threads that have none of their own.
fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name("hrafn-parse-launch")
            .enable_all()
            .build()
            .expect("the worker launcher's runtime")
    })
}

/// How long the sandbox gets to say it started.
const START_STATUS: Duration = Duration::from_secs(20);

pub struct Sandboxed {
    sandbox: gleipnir::Sandbox,
    ctx: gleipnir::Context,
    exe: PathBuf,
    /// Environment the worker gets besides its fixed one: tests' probes only.
    pub extra_env: Vec<(String, String)>,
}

impl Sandboxed {
    /// A launcher on SANDBOX, for the hub binary EXE (the helper of the sandbox and the worker's program).
    pub fn new(sandbox: gleipnir::Sandbox, ctx: gleipnir::Context, exe: PathBuf) -> Sandboxed {
        Sandboxed {
            sandbox,
            ctx,
            exe,
            extra_env: Vec::new(),
        }
    }

    /// The spec of one worker: see the module doc. `None` when this tier cannot hold it.
    fn spec(&self, w: &WorkerSpec, target: gleipnir::Target) -> Result<gleipnir::Spec, String> {
        // two files and nothing else: the library, and this binary (the helper and the worker)
        let read = vec![w.lib.clone(), self.exe.clone()];
        let mut env = vec![
            ("PATH".to_owned(), "/usr/bin:/bin".to_owned()),
            ("LANG".to_owned(), "C.UTF-8".to_owned()),
        ];
        env.extend(self.extra_env.iter().cloned());
        Ok(gleipnir::Spec {
            read,
            write: vec![],
            hide: vec![],
            sockets: vec![],
            binds: vec![],
            home: None,
            run: None,
            env,
            chdir: PathBuf::from("/"),
            net: gleipnir::Net::Isolated {
                relay: vec![],
                mac_tcp_ports: vec![],
                // Linux: a namespace with no way out (no relay) is only valid with its own loopback; macOS: no port at all
                loopback: cfg!(target_os = "linux"),
                mac_loopback_ports: vec![],
            },
            tmp: None,
            layers: gleipnir::Layers::for_target(target),
            extra_tcp_ports: vec![],
            trace: gleipnir::Trace::Off,
            browser: None,
        })
    }
}

impl Launch for Sandboxed {
    fn start(&self, w: &WorkerSpec) -> Result<Started, String> {
        if self.sandbox.tier() != gleipnir::Tier::Full {
            return Err(
                "the sandbox is on its reduced tier: a fetched pack's grammar does not run".into(),
            );
        }
        let target = self
            .sandbox
            .target()
            .ok_or("there is no sandbox backend here: a fetched pack's grammar does not run")?;
        let spec = self.spec(w, target)?;
        let valid = gleipnir::validate(spec, &self.ctx, target).map_err(|r| r.message)?;
        let command: Vec<String> = [
            self.exe.to_string_lossy().into_owned(),
            "hrafn-parse".into(),
            "--lib".into(),
            w.lib.to_string_lossy().into_owned(),
            "--grammar".into(),
            w.grammar.clone(),
            "--sha256".into(),
            w.sha256.clone(),
        ]
        .into();
        let prepared = self
            .sandbox
            .prepare(
                valid,
                command,
                None,
                #[cfg(feature = "test-hooks")]
                gleipnir::TestHooks::default(),
            )
            .map_err(|r| r.message)?;
        let mut dspec = crate::sandbox::to_draugr(prepared.invocation);
        // the worker's stdin is the protocol's request end (a sandboxed one-shot reads /dev/null)
        dspec.stdin_null = false;
        let status = prepared.status;
        runtime().block_on(async move {
            let mut child = draugr::spawn_pinned(dspec)
                .await
                .map_err(|e| format!("the sandbox did not start: {e}"))?;
            if let Some(fd) = status {
                gleipnir::inner::read_status_for(fd, &|| child.stderr_tail(), START_STATUS, false)
                    .map_err(|r| format!("the sandbox did not start: {r}"))?;
            }
            let (Some(stdin), Some(stdout)) = (child.take_stdin(), child.take_stdout()) else {
                return Err("the worker has no stdio".to_owned());
            };
            let pid = child.id();
            let blocking = |fd: OwnedFd| -> Result<std::fs::File, String> {
                // tokio made the pipe non-blocking; the hub's side of this protocol is plain blocking reads and writes
                // SAFETY: fcntl(2) on a descriptor this function owns.
                unsafe {
                    let flags = libc::fcntl(std::os::fd::AsRawFd::as_raw_fd(&fd), libc::F_GETFL);
                    if flags < 0
                        || libc::fcntl(
                            std::os::fd::AsRawFd::as_raw_fd(&fd),
                            libc::F_SETFL,
                            flags & !libc::O_NONBLOCK,
                        ) < 0
                    {
                        return Err(format!("fcntl: {}", std::io::Error::last_os_error()));
                    }
                }
                Ok(std::fs::File::from(fd))
            };
            let stdin: Box<dyn Write + Send> =
                Box::new(blocking(stdin.into_owned_fd().map_err(|e| e.to_string())?)?);
            let stdout: Box<dyn Read + Send> = Box::new(blocking(
                stdout.into_owned_fd().map_err(|e| e.to_string())?,
            )?);
            let child = Arc::new(Mutex::new(child));
            let tail = child.clone();
            let ender = child;
            Ok(Started {
                stdin,
                stdout,
                kill: Box::new(move || {
                    // the group: the worker and anything it started; then reap it
                    let _ = runtime().block_on(draugr::kill_group(
                        pid,
                        draugr::reap::GRACE,
                        &draugr::RealSignaller,
                    ));
                    let mut c = ender.lock().unwrap_or_else(|e| e.into_inner());
                    let _ = runtime().block_on(async {
                        crate::clock::timeout(Duration::from_secs(5), c.wait()).await
                    });
                }),
                stderr: Box::new(move || {
                    tail.lock().unwrap_or_else(|e| e.into_inner()).stderr_tail()
                }),
            })
        })
    }
}

/// The fetched packs the hub chunks with a worker (`active.eld`: the installed packs the built-in set does not have, whose
/// manifest names `:hrafn` queries and which have a built grammar), each with the library the lock hashes. A pack that
/// does not read, lacks its library or its lock entry, or has no `:hrafn :chunks` is left out: its files read as text.
pub fn fetched(env: &runstav::paths::Env) -> Vec<hrafn::chunk::worker::Fetched> {
    use hrafn::chunk::worker::{Fetched, Init};
    let Ok(active) = std::fs::read(runstav::paths::state_dir(env).join("packs/active.eld")) else {
        return Vec::new();
    };
    let Ok(packs) = skald::registry::active_from(&active) else {
        return Vec::new();
    };
    let grammars = runstav::paths::data_dir(env).join("grammars");
    let locked = std::fs::read(runstav::paths::config_dir(env).join("drgnx.lock.eld"))
        .ok()
        .and_then(|b| skald::registry::from_lock(&b, &grammars).ok())
        .unwrap_or_default();
    let mut out = Vec::new();
    for p in packs {
        if skald::builtin::get(&p.name).is_some() {
            continue;
        }
        let Ok(bytes) = std::fs::read(&p.manifest) else {
            continue;
        };
        let Ok(m) = skald::read(&bytes) else { continue };
        let (Some(h), Some(g), Some(dir)) = (&m.hrafn, m.grammars.first(), p.manifest.parent())
        else {
            continue;
        };
        let Some(chunks) = h.chunks.as_deref() else {
            continue;
        };
        let Some(entry) = locked.iter().find(|e| e.name == g.name) else {
            continue;
        };
        let (Ok(chunks_scm), true) = (
            std::fs::read_to_string(dir.join(chunks)),
            entry.lib.is_file(),
        ) else {
            continue;
        };
        // the references' queries are `queries/tags.scm` unless the manifest names another file; a pack may have none
        let tags_scm =
            std::fs::read_to_string(dir.join(h.tags.as_deref().unwrap_or("queries/tags.scm"))).ok();
        out.push(Fetched {
            spec: hrafn::chunk::worker::WorkerSpec {
                pack: p.name.clone(),
                lib: entry.lib.clone(),
                grammar: g.name.clone(),
                sha256: entry.sha256.clone(),
            },
            init: Init {
                chunks_scm,
                tags_scm,
                docs: h.docs.clone().unwrap_or_default(),
            },
            extensions: m.files.extensions.clone(),
        });
    }
    out
}

/// A launcher that never starts one, saying why: the hub has no usable sandbox.
struct Unavailable(String);

impl Launch for Unavailable {
    fn start(&self, _: &WorkerSpec) -> Result<Started, String> {
        Err(self.0.clone())
    }
}

/// The hub's side at start: the fetched packs installed for the chunker, their workers under this binary's sandbox (the
/// full tier) or, where there is none, a launcher that says why (each pack then reads as text, with the reason in the
/// doctor). Nothing starts until a file of a pack is chunked.
pub fn install_hub(env: &runstav::paths::Env) {
    let packs = fetched(env);
    if packs.is_empty() {
        return;
    }
    let launcher: Arc<dyn Launch> = match std::env::current_exe() {
        Err(e) => Arc::new(Unavailable(format!("no path for the hub's binary: {e}"))),
        Ok(exe) => {
            match gleipnir::Sandbox::detect(
                gleipnir::Tier::Full,
                crate::sandbox::helper_at(&exe),
                None,
            ) {
                Ok(sb) => Arc::new(Sandboxed::new(sb, crate::sandbox::context(env), exe)),
                Err(r) => Arc::new(Unavailable(format!(
                    "no full-tier sandbox for a fetched pack's grammar: {}",
                    r.message
                ))),
            }
        }
    };
    hrafn::chunk::worker::install(packs, launcher);
}
