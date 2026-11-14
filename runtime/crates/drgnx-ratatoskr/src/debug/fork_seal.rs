//! A fork's tree and its sealed session on Linux (spec §19.3, items 1–3).
//!
//! - [`DirTrees`]: a fork's folder under the runs root, `<runs>/debug-forks/<fork>/` with the tree in `w/` (the run's
//!   launch snapshot restored into an empty folder: no git branch is made) and the session's temp in `tmp/`. A
//!   trace's tree is the same (`t<n>/`); a plain run in a caller's tree has only its temp here (`r<n>/tmp`); D5's
//!   bisect slots live under [`slots_root`]. None of it outlives the hub: [`sweep`] clears it all at the hub's start.
//! - [`Sealed`]: the adapter and the program inside Gleipnir's full tier with an isolated network and its own loopback
//!   (`net.isolated.loopback`, no relay: nothing gets out), writing only the tree and the temp. The hub speaks to a
//!   small shim on stdio ([`super::fork_mux`]) that starts the adapter inside, in the adapter's own runtime (the hub's
//!   program and its folder stay closed to sandboxes): `etc/debug-fork-shim.py` for debugpy (one adapter per
//!   connection: sub-processes too), `etc/debug-fork-shim.js` for js-debug (one connection to its server per session).
//!   The project's `.env` files and the configuration's `envFile` are bound into the tree read-only, at their places:
//!   the program reads them, and they are never copied.

use super::adapters::{self, Found, Table};
use super::fork_hub::{Sealer, Trees};
use super::fork_mux::Mux;
use super::record::RunInfo;
use super::session::NoProc;
use super::{BoxFut, Connected, Launcher};
use gleipnir::{Bind, Layers, Mode, Net, Spec, Target, Trace};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// debugpy's shim.
pub const SHIM_PY: &str = include_str!("../../../../../etc/debug-fork-shim.py");
/// js-debug's shim.
pub const SHIM_JS: &str = include_str!("../../../../../etc/debug-fork-shim.js");
/// How long the sandbox has to say it started.
pub const STATUS_WITHIN: Duration = Duration::from_secs(10);

/// The most files a fork's tree is compared by.
pub const MANIFEST_MAX: usize = 100_000;

/// Forks' folders under ROOT (`<runs>/debug-forks`), with each tree's files as restored (relative name, hash): what a
/// code what-if changed is measured from them.
pub struct DirTrees {
    pub root: PathBuf,
    made: Mutex<HashMap<PathBuf, BTreeMap<String, u64>>>,
}

/// The forks' root: `<runs>/debug-forks`.
pub fn forks_root(env: &runstav::paths::Env) -> PathBuf {
    crate::sandbox::runs_root(env).join("debug-forks")
}

/// Where D5's bisect slots are made (`<forks root>/slots/<bisect>/slot-N/`, …): the only trees a plain run takes.
pub fn slots_root(env: &runstav::paths::Env) -> PathBuf {
    forks_root(env).join("slots")
}

/// Everything under ROOT (the forks' root) goes: an earlier hub's forks, traces and slots, none of which outlives it.
/// The folder is moved aside at once (a fork made right after starts empty) and removed in the background.
pub fn sweep(root: &Path) {
    if !root.exists() {
        return;
    }
    let aside = root.with_extension(format!("swept-{}", std::process::id()));
    if let Err(e) = std::fs::rename(root, &aside) {
        tracing::warn!(target: "drgnx::debug", "the forks' folder {} stays: {e}", root.display());
        return;
    }
    crate::clock::spawn("debug:fork-sweep", async move {
        let _ = crate::clock::blocking(move || std::fs::remove_dir_all(aside)).await;
    });
}

impl DirTrees {
    pub fn new(root: PathBuf) -> DirTrees {
        DirTrees {
            root,
            made: Mutex::default(),
        }
    }
}

/// A `.env` file's name: bound over an empty file in a tree, never compared.
fn env_name(n: &str) -> bool {
    n == ".env" || n.starts_with(".env.")
}

/// TREE's regular files (relative names) and their contents' hashes; links and `.env` files are left out.
pub fn manifest(tree: &Path) -> BTreeMap<String, u64> {
    let mut out = BTreeMap::new();
    let mut dirs = vec![tree.to_path_buf()];
    while let Some(d) = dirs.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else {
            continue;
        };
        for e in rd.flatten() {
            let (p, Ok(t)) = (e.path(), e.file_type()) else {
                continue;
            };
            if t.is_dir() {
                dirs.push(p);
            } else if t.is_file()
                && !e.file_name().to_str().is_some_and(env_name)
                && out.len() < MANIFEST_MAX
                && let (Ok(rel), Ok(bytes)) = (p.strip_prefix(tree), std::fs::read(&p))
            {
                out.insert(
                    rel.to_string_lossy().into_owned(),
                    xxhash_rust::xxh3::xxh3_64(&bytes),
                );
            }
        }
    }
    out
}

/// The names whose files differ between manifests A and B (changed, added or gone), sorted.
pub fn differ(a: &BTreeMap<String, u64>, b: &BTreeMap<String, u64>) -> Vec<String> {
    let mut out: Vec<String> = a
        .iter()
        .filter(|(k, v)| b.get(*k) != Some(v))
        .map(|(k, _)| k.clone())
        .chain(b.keys().filter(|k| !a.contains_key(*k)).cloned())
        .collect();
    out.sort();
    out
}

impl Trees for DirTrees {
    fn make<'a>(&'a self, run: &'a RunInfo, id: &'a str) -> BoxFut<'a, Result<PathBuf, String>> {
        Box::pin(async move {
            let snap = run
                .snapshot
                .clone()
                .ok_or("the run has no launch snapshot")?;
            let dir = self.root.join(id);
            let (w, tmp) = (dir.join("w"), dir.join("tmp"));
            for d in [&w, &tmp] {
                std::fs::create_dir_all(d).map_err(|e| format!("{}: {e}", d.display()))?;
            }
            let target = w.clone();
            let r = crate::clock::blocking(move || {
                crate::timeline::snapshot::restore_into(
                    &snap.checkpoints,
                    &snap.source,
                    &target,
                    &snap.tree,
                    None,
                    &[],
                )
            })
            .await
            .map_err(|e| e.to_string())??;
            if !r.skipped.is_empty() {
                tracing::info!(target: "drgnx::debug", fork = id, skipped = ?r.skipped, "the fork's tree leaves paths out");
            }
            let at = w.clone();
            let m = crate::clock::blocking(move || manifest(&at))
                .await
                .map_err(|e| e.to_string())?;
            self.made
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .insert(w.clone(), m);
            Ok(w)
        })
    }

    fn changed<'a>(&'a self, tree: &'a Path) -> BoxFut<'a, Vec<String>> {
        Box::pin(async move {
            let Some(before) = self
                .made
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(tree)
                .cloned()
            else {
                return vec![];
            };
            let at = tree.to_path_buf();
            crate::clock::blocking(move || differ(&before, &manifest(&at)))
                .await
                .unwrap_or_default()
        })
    }

    fn scratch(&self, id: &str) -> Result<PathBuf, String> {
        let tmp = self.root.join(id).join("tmp");
        std::fs::create_dir_all(&tmp).map_err(|e| format!("{}: {e}", tmp.display()))?;
        Ok(tmp)
    }

    fn remove<'a>(&'a self, tree: &'a Path) -> BoxFut<'a, ()> {
        Box::pin(async move {
            self.made
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(tree);
            // the fork's own folder (the tree's parent), never anything outside the forks' root
            if let Some(dir) = tree
                .parent()
                .filter(|d| d.starts_with(&self.root) && *d != self.root)
            {
                let dir = dir.to_path_buf();
                let _ = crate::clock::blocking(move || std::fs::remove_dir_all(dir)).await;
            }
        })
    }
}

/// The project's files a fork's program may read but never gets a copy of: `.env` and `.env.*` at ROOT and in the
/// configuration's cwd, and its `envFile`; as (source in ROOT, place in TREE).
pub fn env_files(root: &Path, tree: &Path, config: &Value) -> Vec<(PathBuf, PathBuf)> {
    let mut dirs = vec![root.to_path_buf()];
    if let Some(cwd) = config.get("cwd").and_then(Value::as_str) {
        let back = PathBuf::from(super::fork::from_tree(cwd, root, tree));
        if back.starts_with(root) && !dirs.contains(&back) {
            dirs.push(back);
        }
    }
    let mut out: Vec<(PathBuf, PathBuf)> = vec![];
    let mut add = |src: PathBuf| {
        if src.is_file() && !src.is_symlink() && !out.iter().any(|(s, _)| *s == src) {
            let dst = PathBuf::from(super::fork::into_tree(&src.to_string_lossy(), root, tree));
            if dst != src {
                out.push((src, dst));
            }
        }
    };
    for d in dirs {
        if let Ok(rd) = std::fs::read_dir(&d) {
            let mut names: Vec<PathBuf> = rd
                .flatten()
                .map(|e| e.path())
                .filter(|p| p.file_name().and_then(|n| n.to_str()).is_some_and(env_name))
                .collect();
            names.sort();
            names.into_iter().for_each(&mut add);
        }
    }
    if let Some(f) = config.get("envFile").and_then(Value::as_str) {
        let src = PathBuf::from(super::fork::from_tree(f, root, tree));
        if src.starts_with(root) {
            add(src);
        }
    }
    out
}

/// What a fork's spec is made of.
pub struct Shape<'a> {
    pub tree: &'a Path,
    pub tmp: &'a Path,
    /// Read-only roots beside the system's: the adapter's and its runtime's installs.
    pub read: Vec<PathBuf>,
    /// (source, place in the tree) of [`env_files`].
    pub env_files: Vec<(PathBuf, PathBuf)>,
    pub path: String,
    pub cwd: PathBuf,
}

/// The system folders a fork reads, by their true names, found once: Gleipnir takes no path with a link in it, and a
/// system may put one above them (macOS's `/etc` is `/private/etc`). One that is not there is left out.
fn system_roots() -> &'static [PathBuf] {
    static ROOTS: std::sync::OnceLock<Vec<PathBuf>> = std::sync::OnceLock::new();
    ROOTS.get_or_init(|| {
        ["/usr", "/etc", "/opt"]
            .iter()
            .filter_map(|p| std::fs::canonicalize(p).ok())
            .collect()
    })
}

/// A fork's Gleipnir spec: the system and S's roots read-only, the tree and the temp writable, the `.env` files bound
/// read-only over empty files in the tree, an isolated network with its own loopback and no relay.
pub fn spec(s: &Shape<'_>, target: Target) -> Spec {
    let mut read: Vec<PathBuf> = system_roots().to_vec();
    for r in &s.read {
        if !read.iter().any(|x| r.starts_with(x)) {
            read.push(r.clone());
        }
    }
    let tmp = s.tmp.display().to_string();
    Spec {
        read,
        write: vec![s.tree.to_path_buf(), s.tmp.to_path_buf()],
        hide: vec![],
        sockets: vec![],
        binds: s
            .env_files
            .iter()
            .map(|(src, dst)| Bind {
                mode: Mode::Ro,
                source: src.clone(),
                dest: dst.clone(),
            })
            .collect(),
        home: None,
        run: None,
        env: vec![
            ("PATH".into(), s.path.clone()),
            ("HOME".into(), tmp.clone()),
            ("TMPDIR".into(), tmp),
            ("PYTHONDONTWRITEBYTECODE".into(), "1".into()),
        ],
        chdir: s.cwd.clone(),
        net: Net::Isolated {
            relay: vec![],
            mac_tcp_ports: vec![],
            loopback: true,
            mac_loopback_ports: vec![],
        },
        tmp: Some(s.tmp.to_path_buf()),
        layers: Layers::for_target(target),
        extra_tcp_ports: vec![],
        rlimits: None,
        trace: Trace::Off,
        browser: None,
    }
}

/// A fork's Seatbelt spec on macOS (spec §21): as [`spec`], with PORTS (the session's block) its only loopback ports
/// and each `.env` file pinned read-only where it is (no mount namespace: the tree has a link to it,
/// [`link_env_files`]).
pub fn mac_spec(s: &Shape<'_>, ports: &[u16]) -> Spec {
    let mut out = spec(s, Target::Macos);
    out.binds = s
        .env_files
        .iter()
        .map(|(src, _)| Bind {
            mode: Mode::Ro,
            source: src.clone(),
            dest: src.clone(),
        })
        .collect();
    out.net = Net::Isolated {
        relay: vec![],
        mac_tcp_ports: vec![],
        loopback: true,
        mac_loopback_ports: ports.to_vec(),
    };
    out
}

/// Each `.env` file's place in the tree a link to it (macOS: read where it is, never copied). A link already there
/// stays; anything else at that place in the tree is replaced by the link.
pub fn link_env_files(files: &[(PathBuf, PathBuf)]) -> Result<(), String> {
    for (src, dst) in files {
        let shown = |e: std::io::Error| format!("{}: {e}", dst.display());
        if let Ok(m) = std::fs::symlink_metadata(dst) {
            if m.file_type().is_symlink() && std::fs::read_link(dst).is_ok_and(|t| &t == src) {
                continue;
            }
            std::fs::remove_file(dst).map_err(shown)?;
        }
        if let Some(dir) = dst.parent() {
            std::fs::create_dir_all(dir).map_err(shown)?;
        }
        std::os::unix::fs::symlink(src, dst).map_err(shown)?;
    }
    Ok(())
}

/// The seal of a fork's processes on macOS: each in Seatbelt under SPEC (its environment and folder the process's),
/// checked against CTX.
fn seatbelt(spec: Spec, ctx: gleipnir::Context) -> super::blocked::Seal {
    let (spec, ctx) = (Arc::new(spec), Arc::new(ctx));
    Arc::new(move |d: draugr::Spec| {
        let (spec, ctx) = (spec.clone(), ctx.clone());
        Box::pin(async move {
            let sb = crate::agents::launch::detect()
                .await
                .map_err(|r| r.message)?;
            let target = sb.target().ok_or("no sandbox here")?;
            let mut s = (*spec).clone();
            s.env = d
                .env
                .iter()
                .map(|(k, v)| {
                    (
                        k.to_string_lossy().into_owned(),
                        v.to_string_lossy().into_owned(),
                    )
                })
                .collect();
            if let Some(cwd) = &d.cwd {
                s.chdir = cwd.clone();
            }
            let valid = gleipnir::validate(s, &ctx, target)
                .map_err(|r| format!("the fork's sandbox: {}", r.message))?;
            let mut argv = vec![d.program.display().to_string()];
            argv.extend(d.args.iter().map(|a| a.to_string_lossy().into_owned()));
            let prepared = sb
                .prepare(
                    valid,
                    argv,
                    None,
                    #[cfg(feature = "test-hooks")]
                    gleipnir::TestHooks::default(),
                )
                .map_err(|r| format!("the fork's sandbox: {}", r.message))?;
            Ok(crate::sandbox::to_draugr(prepared.invocation))
        })
    })
}

/// The hub's sealer: the adapters found as `debug/start` finds them (PATH, the tools folder).
pub struct Sealed {
    pub env: runstav::paths::Env,
    pub path: Vec<PathBuf>,
    pub tools: PathBuf,
}

/// The install root of PROGRAM: `PREFIX` of `PREFIX/bin/x`.
fn prefix_of(program: &Path) -> Option<PathBuf> {
    let real = std::fs::canonicalize(program).ok()?;
    real.parent()?.parent().map(Path::to_path_buf)
}

impl Sealer for Sealed {
    fn launcher(
        &self,
        adapter: &str,
        run: &RunInfo,
        tree: &Path,
        config: &Value,
        tmp: &Path,
    ) -> Result<Arc<dyn Launcher>, String> {
        let table = Table::builtin();
        let a = table
            .0
            .iter()
            .find(|a| a.id == adapter)
            .ok_or_else(|| format!("no adapter {adapter}"))?;
        let env = adapters::Env {
            path: self.path.clone(),
            tools: self.tools.clone(),
        };
        let found =
            adapters::find(a, &env).ok_or_else(|| format!("{} is not installed", a.name))?;
        std::fs::create_dir_all(tmp).map_err(|e| format!("{}: {e}", tmp.display()))?;
        let mut read = vec![];
        let argv: Vec<String> = match (adapter, &found) {
            ("debugpy", Found::Python(py)) => {
                let shim = tmp.join("drgnx-debug-fork-shim.py");
                std::fs::write(&shim, SHIM_PY).map_err(|e| format!("{}: {e}", shim.display()))?;
                read.extend(prefix_of(py));
                // the venv itself (its site-packages), besides the Python it links to
                read.extend(py.parent().and_then(Path::parent).map(Path::to_path_buf));
                vec![py.display().to_string(), shim.display().to_string()]
            }
            ("js-debug", Found::Program(server)) => {
                // its true place: the release folder is bound, not a link to it
                let server = std::fs::canonicalize(server).unwrap_or_else(|_| server.clone());
                let node = self
                    .path
                    .iter()
                    .map(|d| d.join("node"))
                    .find(|p| p.is_file())
                    .ok_or("node is not on PATH")?;
                let shim = tmp.join("drgnx-debug-fork-shim.js");
                std::fs::write(&shim, SHIM_JS).map_err(|e| format!("{}: {e}", shim.display()))?;
                read.extend(prefix_of(&node));
                // js-debug's whole release (src/ and its dependencies)
                read.extend(
                    server
                        .parent()
                        .and_then(Path::parent)
                        .map(Path::to_path_buf),
                );
                vec![
                    node.display().to_string(),
                    shim.display().to_string(),
                    server.display().to_string(),
                ]
            }
            _ => return Err(format!("{adapter} does not run in a fork")),
        };
        let cwd = config
            .get("cwd")
            .and_then(Value::as_str)
            .map(PathBuf::from)
            .filter(|c| c.starts_with(tree))
            .unwrap_or_else(|| tree.to_path_buf());
        let path = std::env::join_paths(&self.path)
            .ok()
            .and_then(|p| p.into_string().ok())
            .unwrap_or_else(|| "/usr/local/bin:/usr/bin:/bin".into());
        let env_files = env_files(Path::new(&run.root), tree, config);
        if cfg!(target_os = "macos") {
            // Seatbelt has no namespaces: the session keeps to a port block (spec §21), the .env files are read in
            // place, each by its true name (Gleipnir takes no path through a link)
            let env_files: Vec<(PathBuf, PathBuf)> = env_files
                .into_iter()
                .map(|(src, dst)| (std::fs::canonicalize(&src).unwrap_or(src), dst))
                .collect();
            link_env_files(&env_files)?;
            let shape = Shape {
                tree,
                tmp,
                read,
                env_files,
                path,
                cwd,
            };
            return self.in_block(a, &found, config, &shape);
        }
        // empty files for the binds to land on (the tree never holds their text)
        for (_, dst) in &env_files {
            if !dst.exists() {
                std::fs::write(dst, b"").map_err(|e| format!("{}: {e}", dst.display()))?;
            }
        }
        let shape = Shape {
            tree,
            tmp,
            read,
            env_files,
            path,
            cwd,
        };
        let mut ctx = crate::sandbox::context(&self.env);
        // the adapters drgnx installed are read inside, nothing else of its data folder
        ctx.open_inside_closed.push(self.tools.clone());
        Ok(Arc::new(SealedLauncher {
            spec: spec(&shape, Target::LinuxBwrap),
            ctx,
            argv,
            mux: Mutex::new(None),
        }))
    }
}

impl Sealed {
    /// macOS: ADAPTER's session for CONFIG in SHAPE inside a port block of its own (`debug::blocked`: debugpy
    /// listening for its program, js-debug attached to `--inspect-brk`), the adapter and the program each in Seatbelt
    /// with the block as their only loopback ports.
    fn in_block(
        &self,
        adapter: &adapters::Adapter,
        found: &Found,
        config: &Value,
        shape: &Shape<'_>,
    ) -> Result<Arc<dyn Launcher>, String> {
        let block = super::ports::machine().claim()?;
        let ports = block.ports();
        let preload = shape.tmp.join(super::blocked::PRELOAD_NAME);
        std::fs::write(&preload, super::blocked::PRELOAD)
            .map_err(|e| format!("{}: {e}", preload.display()))?;
        let env = adapters::Env {
            path: self.path.clone(),
            tools: self.tools.clone(),
        };
        let plan = super::blocked::plan(adapter, found, &env, config, &ports, shape.tmp, &preload)?;
        let spec = mac_spec(shape, &ports);
        let base = spec.env.iter().map(|(k, v)| (k.into(), v.into())).collect();
        let mut ctx = crate::sandbox::context(&self.env);
        ctx.open_inside_closed.push(self.tools.clone());
        Ok(Arc::new(
            super::blocked::Blocked::new(plan, base, shape.cwd.clone(), Some(block))
                .sealed(seatbelt(spec, ctx)),
        ))
    }
}

/// A fork's session in its sandbox: the first connection starts it, the rest (child sessions) share its shim.
pub struct SealedLauncher {
    spec: Spec,
    ctx: gleipnir::Context,
    argv: Vec<String>,
    mux: Mutex<Option<Mux>>,
}

impl SealedLauncher {
    fn open(
        mux: &Mux,
    ) -> (
        vor::Client,
        tokio::sync::mpsc::UnboundedReceiver<vor::Incoming>,
    ) {
        let (r, w) = mux.open();
        vor::Client::new(r, w)
    }
}

impl Launcher for SealedLauncher {
    fn connect(&self) -> BoxFut<'_, Result<Connected, String>> {
        Box::pin(async move {
            let sb = crate::agents::launch::detect()
                .await
                .map_err(|r| r.message)?;
            if sb.tier() != gleipnir::Tier::Full {
                return Err(
                    "a fork needs Gleipnir's full tier (a network namespace of its own); this host runs the reduced tier"
                        .into(),
                );
            }
            let target = sb.target().ok_or("no sandbox here")?;
            let valid = gleipnir::validate(self.spec.clone(), &self.ctx, target)
                .map_err(|r| format!("the fork's sandbox: {}", r.message))?;
            let prepared = sb
                .prepare(
                    valid,
                    self.argv.clone(),
                    None,
                    #[cfg(feature = "test-hooks")]
                    gleipnir::TestHooks::default(),
                )
                .map_err(|r| format!("the fork's sandbox: {}", r.message))?;
            let mut spec = crate::sandbox::to_draugr(prepared.invocation);
            spec.stdin_null = false;
            let mut child = draugr::spawn_pinned(spec)
                .await
                .map_err(|e| format!("the fork's sandbox did not start: {e}"))?;
            if let Some(fd) = prepared.status {
                let r = crate::clock::blocking(move || {
                    gleipnir::inner::read_status_for(fd, &String::new, STATUS_WITHIN, false)
                })
                .await
                .map_err(|e| e.to_string())?;
                if let Err(r) = r {
                    let tail = child.stderr_tail();
                    super::session::Proc::signal(&mut child, super::session::Sig::Kill);
                    let _ = child.wait().await;
                    return Err(format!(
                        "the fork's sandbox did not start: {} {tail}",
                        r.message
                    ));
                }
            }
            let (Some(stdin), Some(stdout)) = (child.take_stdin(), child.take_stdout()) else {
                return Err("the fork's sandbox has no stdio".into());
            };
            let mux = Mux::new(stdout, stdin);
            let (client, incoming) = Self::open(&mux);
            *self.mux.lock().unwrap_or_else(|e| e.into_inner()) = Some(mux);
            Ok(Connected {
                client,
                incoming,
                proc: Box::new(child),
            })
        })
    }

    fn child(&self) -> BoxFut<'_, Result<Connected, String>> {
        Box::pin(async move {
            let mux = self
                .mux
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone()
                .ok_or("the fork's sandbox is not running")?;
            let (client, incoming) = Self::open(&mux);
            Ok(Connected {
                client,
                incoming,
                proc: Box::new(NoProc),
            })
        })
    }
}
