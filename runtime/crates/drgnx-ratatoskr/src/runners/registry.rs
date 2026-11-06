//! The runner registry (docs/develop/hub.md, "Runners: the registry"): which machines run the hub's jobs, and how one
//! becomes a runner.
//!
//! A runner is a [`Record`] the hub keeps (in the graph as kind `runner`, written by the hub only: [`UrdrStore`]) and
//! a link in the queue ([`super::queue::Queue`]). [`Registry::add`] probes the host, refuses one that is the hub's own
//! machine or lacks the runner contract (every missing item with its fix), copies the bundle for its architecture,
//! pulls the images by digest, benches it, records it and connects it. [`Registry::remove`] stops our units and
//! containers there and deletes the runner's folder.
//!
//! Everything the hub does on a host before the runner is connected goes through [`Transport`] as one command on its
//! three sessions (`sh -c` with the script, its standard input and its exit code), so the user's own ssh config
//! applies and nothing is installed but the one folder.

use super::link;
use super::queue::{Queue, RemoteRunner};
use super::ssh_config;
use super::transport::{Channels, LinkError, Transport};
use super::{NAME_MAX, Remote, RunnerCfg};
use forseti::{Accept as FAccept, RunnerTrust};
use mimir::BoxFuture;
use runstav::methods::runners::{
    self as wire, Accept, AddParams, Effective, HostFacts, Missing, Probed, Profile, Trust,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sleipnir::proto::{Frame, FrameWriter, PROTO_VERSION};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufReader};

/// What a runner's units, containers and files are named after, unless the user says otherwise. Letters, digits and
/// inner dashes: a unit's and a slice's name hold it.
pub const DEFAULT_PREFIX: &str = "drgnx";
/// The runner's one folder, under the user's home there, unless the user says otherwise.
pub const DEFAULT_ROOT: &str = ".drgnx-runner";

/// How long a short command on a runner may take.
const SHORT: Duration = Duration::from_secs(120);
/// How long a copy, a pull or a bench may take.
const LONG: Duration = Duration::from_secs(900);
/// How long `serve` may take to answer a `probe` (its contract tools may take 30 s each).
const PROBE: Duration = Duration::from_secs(150);

/// The marker the last line of a command's output carries: its exit code.
const EXIT: &str = "drgnx-exit:";

/// Why a registry call did not do what it was asked.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RegError {
    /// The user's to fix: a name taken, a host that lacks the contract, the hub's own machine, a job still running.
    Refused(String),
    /// The runner or the link failed.
    Failed(String),
}

impl std::fmt::Display for RegError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RegError::Refused(s) | RegError::Failed(s) => f.write_str(s),
        }
    }
}

impl std::error::Error for RegError {}

fn refused(s: impl Into<String>) -> RegError {
    RegError::Refused(s.into())
}

fn failed(s: impl Into<String>) -> RegError {
    RegError::Failed(s.into())
}

impl From<LinkError> for RegError {
    fn from(e: LinkError) -> RegError {
        match e {
            LinkError::Refused(_) => RegError::Refused(e.to_string()),
            e => RegError::Failed(e.to_string()),
        }
    }
}

/// A runner as the hub keeps it. The facts are from the probe at `add` (and each check); the rest is the user's.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Record {
    pub name: String,
    pub host: String,
    pub trust: Trust,
    pub profile: Profile,
    pub accept: Accept,
    pub root: String,
    pub prefix: String,
    /// The folder under `<root>/bin/` the hub copied the bundle to: a hash of its `sleipnir`.
    pub bundle: String,
    pub arch: String,
    pub os: String,
    pub cores: u32,
    pub mem_mib: u64,
    pub disk_free_gb: u64,
    pub podman: String,
    pub linger: bool,
    pub landlock_abi: u32,
    #[serde(default)]
    pub features: Vec<String>,
    #[serde(default)]
    pub speed: Option<f64>,
    #[serde(default)]
    pub checked: Option<f64>,
    /// The image its health check's canary and its bench ran in, by digest.
    #[serde(default)]
    pub image: Option<String>,
}

/// Where the records are kept.
pub trait Store: Send + Sync {
    fn list(&self) -> BoxFuture<'_, Result<Vec<Record>, String>>;
    fn put<'a>(&'a self, r: &'a Record) -> BoxFuture<'a, Result<(), String>>;
    fn remove<'a>(&'a self, name: &'a str) -> BoxFuture<'a, Result<(), String>>;
}

/// Records in memory: the hub's tests and the fleet's.
#[derive(Default)]
pub struct MemStore(Mutex<BTreeMap<String, Record>>);

impl Store for MemStore {
    fn list(&self) -> BoxFuture<'_, Result<Vec<Record>, String>> {
        Box::pin(async move {
            Ok(self
                .0
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .values()
                .cloned()
                .collect())
        })
    }

    fn put<'a>(&'a self, r: &'a Record) -> BoxFuture<'a, Result<(), String>> {
        Box::pin(async move {
            self.0
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .insert(r.name.clone(), r.clone());
            Ok(())
        })
    }

    fn remove<'a>(&'a self, name: &'a str) -> BoxFuture<'a, Result<(), String>> {
        Box::pin(async move {
            self.0
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(name);
            Ok(())
        })
    }
}

/// Records as entities of kind `runner` in the graph, written as `("hub", Class::System)`.
pub struct UrdrStore(pub norn::store::CoordDb);

impl Store for UrdrStore {
    fn list(&self) -> BoxFuture<'_, Result<Vec<Record>, String>> {
        Box::pin(async move {
            let rows = self
                .0
                .read(|c| norn::read::runners::list(c, "runner"))
                .await
                .map_err(|e| e.to_string())?;
            Ok(rows
                .into_iter()
                .filter_map(
                    |(name, data)| match serde_json::from_value::<Record>(data) {
                        Ok(r) => Some(r),
                        Err(e) => {
                            tracing::warn!("runners: the record of {name} is unreadable: {e}");
                            None
                        }
                    },
                )
                .collect())
        })
    }

    fn put<'a>(&'a self, r: &'a Record) -> BoxFuture<'a, Result<(), String>> {
        Box::pin(async move {
            let (name, data) = (
                r.name.clone(),
                serde_json::to_value(r).map_err(|e| e.to_string())?,
            );
            let meta =
                urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "runners/registry");
            self.0
                .write(meta, move |tx| {
                    norn::write::runners::put(tx, "runner", &name, data).map(|_| ())
                })
                .await
                .map_err(|e| e.to_string())
        })
    }

    fn remove<'a>(&'a self, name: &'a str) -> BoxFuture<'a, Result<(), String>> {
        Box::pin(async move {
            let name = name.to_string();
            let meta =
                urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "runners/registry");
            self.0
                .write(meta, move |tx| {
                    norn::write::runners::remove(tx, "runner", &name)
                })
                .await
                .map_err(|e| e.to_string())
        })
    }
}

/// What the registry needs from the hub.
pub struct Cfg {
    pub transport: Arc<dyn Transport>,
    pub store: Arc<dyn Store>,
    pub queue: Arc<Queue>,
    /// The hub's id at a runner's `hello`.
    pub hub_id: String,
    /// This machine's boot id: a runner with the same one is this machine.
    pub hub_boot_id: String,
    /// The hub's `$XDG_RUNTIME_DIR`, where the generated ssh configs are (`ssh -G` reads one).
    pub runtime_dir: PathBuf,
    /// The built bundles: `<arch>/sleipnir` (and `drgnx-key`, `drgnx-fwd`), as `drgnx build runner-bundle` leaves them.
    pub bundles: PathBuf,
    /// The images a new runner pulls, by digest (`name@sha256:...`); the first benches it and runs its canary.
    pub images: Arc<dyn Fn() -> Vec<String> + Send + Sync>,
}

/// The hub's runners.
pub struct Registry {
    cfg: Cfg,
    /// One change at a time: an `add`, `set` or `remove` of a runner never interleaves with another.
    busy: tokio::sync::Mutex<()>,
}

/// What a command printed, and how it ended.
struct Out {
    code: i32,
    stdout: String,
    stderr: String,
}

/// S in single quotes, for a shell on the runner.
fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// The name a host gets when the user gives none: its first label, in the characters a name may have.
pub fn default_name(host: &str) -> String {
    let h = host.rsplit('@').next().unwrap_or(host);
    let label = h.split('.').next().unwrap_or(h);
    let name: String = label
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                c
            } else {
                '-'
            }
        })
        .collect();
    let name = name.trim_start_matches('-');
    let name = &name[..name.len().min(NAME_MAX)];
    if name.is_empty() {
        "runner".into()
    } else {
        name.into()
    }
}

/// What a refused host lacks, as one text: every item with its fix.
pub fn refusal_text(missing: &[Missing]) -> String {
    let mut s = String::from("this host doesn't meet the runner contract:");
    for m in missing {
        s.push_str(&format!("\n  - {}\n    fix: {}", m.what, m.fix));
    }
    s
}

fn forseti_trust(t: Trust) -> RunnerTrust {
    match t {
        Trust::Mine => RunnerTrust::Mine,
        Trust::MyCloud => RunnerTrust::MyCloud,
        Trust::Shared => RunnerTrust::Shared,
    }
}

fn forseti_accept(a: Accept) -> FAccept {
    match a {
        Accept::All => FAccept::All,
        Accept::Heavy => FAccept::Heavy,
    }
}

fn profile_word(p: Profile) -> &'static str {
    match p {
        Profile::Dedicated => "dedicated",
        Profile::Workstation => "workstation",
    }
}

/// What `serve`'s `hello-ok` and `probe-result` said.
struct Probe {
    boot_id: String,
    linger: bool,
    facts: Option<sleipnir::proto::Facts>,
    missing: Vec<Missing>,
    limits: Option<String>,
    features: Vec<String>,
}

impl Registry {
    pub fn new(cfg: Cfg) -> Registry {
        Registry {
            cfg,
            busy: tokio::sync::Mutex::new(()),
        }
    }

    fn base_cfg(&self, name: &str, host: &str) -> RunnerCfg {
        let idle = vec!["true".to_string()];
        RunnerCfg {
            name: name.into(),
            host: host.into(),
            linger: true,
            cloud: None,
            remote: Remote {
                control: idle.clone(),
                bulk_in: idle.clone(),
                bulk_out: idle,
            },
        }
    }

    /// The config that runs `serve` for RECORD on the runner.
    fn serve_cfg(&self, r: &Record) -> RunnerCfg {
        let mut c = self.base_cfg(&r.name, &r.host);
        c.linger = r.linger;
        c.remote.control = vec![
            format!("{}/bin/{}/sleipnir", r.root, r.bundle),
            "serve".into(),
            "--root".into(),
            r.root.clone(),
            "--prefix".into(),
            r.prefix.clone(),
            "--hub-id".into(),
            self.cfg.hub_id.clone(),
            "--profile".into(),
            profile_word(r.profile).into(),
        ];
        // the sync channels are Task 20's; until then they hold the sessions open and carry nothing
        c.remote.bulk_in = vec!["cat".into()];
        c.remote.bulk_out = vec!["cat".into()];
        c
    }

    /// SCRIPT on the runner CFG names, STDIN on its standard input, as one `sh -c` on the runner's control session.
    async fn sh(
        &self,
        cfg: &RunnerCfg,
        script: &str,
        stdin: &[u8],
        limit: Duration,
    ) -> Result<Out, RegError> {
        let mut c = cfg.clone();
        c.remote.control = vec![
            "sh".into(),
            "-c".into(),
            format!("( {script}\n); echo; echo {EXIT}$?"),
        ];
        let channels = self.cfg.transport.open(&c).await?;
        let Channels {
            control,
            bulk_in,
            bulk_out,
        } = channels;
        let _held = (bulk_in, bulk_out);
        let (mut tx, mut rx, err) = (control.tx, control.rx, control.err);
        let run = async {
            let write = async {
                let _ = tx.write_all(stdin).await;
                let _ = tx.shutdown().await;
            };
            let read = async {
                let mut out = Vec::new();
                let _ = rx.read_to_end(&mut out).await;
                out
            };
            let read_err = async {
                let mut out = Vec::new();
                if let Some(mut e) = err {
                    let _ = e.read_to_end(&mut out).await;
                }
                out
            };
            let ((), out, err) = tokio::join!(write, read, read_err);
            (out, err)
        };
        let (out, err) = crate::clock::timeout(limit, run).await.map_err(|_| {
            failed(format!(
                "{}: the command took over {} s",
                cfg.name,
                limit.as_secs()
            ))
        })?;
        let text = String::from_utf8_lossy(&out).into_owned();
        let stderr = String::from_utf8_lossy(&err).trim().to_string();
        let (body, code) = match text.rfind(EXIT) {
            Some(at) => (
                text[..at].trim_end_matches('\n').trim_end().to_string(),
                text[at + EXIT.len()..].trim().parse::<i32>().unwrap_or(-1),
            ),
            None => {
                return Err(failed(format!(
                    "{}: the command ended without an exit code: {stderr}",
                    cfg.name
                )));
            }
        };
        Ok(Out {
            code,
            stdout: body,
            stderr,
        })
    }

    /// Like [`Registry::sh`], and a command that fails is a [`RegError::Failed`] with what it said.
    async fn sh_ok(
        &self,
        cfg: &RunnerCfg,
        script: &str,
        stdin: &[u8],
        limit: Duration,
    ) -> Result<String, RegError> {
        let o = self.sh(cfg, script, stdin, limit).await?;
        if o.code == 0 {
            Ok(o.stdout)
        } else {
            Err(failed(format!(
                "{}: `{}` failed ({}): {}",
                cfg.name,
                script.lines().next().unwrap_or(""),
                o.code,
                if o.stderr.is_empty() {
                    &o.stdout
                } else {
                    &o.stderr
                }
            )))
        }
    }

    /// `serve` of RECORD's folder asked for its `hello-ok` and its `probe`, once, over one set of sessions that end
    /// when it returns.
    async fn probe_serve(&self, r: &Record) -> Result<Probe, RegError> {
        let cfg = self.serve_cfg(r);
        let channels = self.cfg.transport.open(&cfg).await?;
        let Channels {
            control,
            bulk_in,
            bulk_out,
        } = channels;
        let _held = (bulk_in, bulk_out, control.err);
        let (mut tx, rx) = (control.tx, control.rx);
        let mut w = FrameWriter::new(Vec::new());
        for f in [
            Frame::Hello {
                version: PROTO_VERSION,
                hub_id: self.cfg.hub_id.clone(),
            },
            Frame::Probe,
        ] {
            w.write(&f).map_err(|e| failed(e.to_string()))?;
        }
        tx.write_all(&w.into_inner())
            .await
            .map_err(|e| failed(format!("{}: {e}", cfg.name)))?;
        tx.flush()
            .await
            .map_err(|e| failed(format!("{}: {e}", cfg.name)))?;
        let mut rx = BufReader::new(rx);
        let name = cfg.name.clone();
        let read = async {
            let (mut hello, mut result) = (None, None);
            while hello.is_none() || result.is_none() {
                match link::read_frame(&mut rx).await {
                    Ok(Some(Frame::HelloOk {
                        boot_id,
                        linger,
                        missing,
                        ..
                    })) => hello = Some((boot_id, linger, missing)),
                    Ok(Some(Frame::ProbeResult {
                        facts,
                        missing,
                        limits,
                        features,
                    })) => result = Some((facts, missing, limits, features)),
                    Ok(Some(_)) => {}
                    Ok(None) => {
                        return Err(failed(format!("{name}: serve ended before it answered")));
                    }
                    Err(e) => return Err(failed(format!("{name}: {e}"))),
                }
            }
            Ok((hello.expect("hello-ok"), result.expect("probe-result")))
        };
        let ((boot_id, linger, mut missing), (facts, more, limits, features)) =
            crate::clock::timeout(PROBE, read).await.map_err(|_| {
                failed(format!(
                    "{}: serve didn't answer in {} s",
                    cfg.name,
                    PROBE.as_secs()
                ))
            })??;
        for m in more {
            if !missing.iter().any(|x| x.what == m.what) {
                missing.push(m);
            }
        }
        let missing = missing
            .into_iter()
            .map(|m| Missing {
                what: m.what,
                fix: m.fix,
            })
            .collect();
        Ok(Probe {
            boot_id,
            linger,
            facts,
            missing,
            limits,
            features,
        })
    }

    /// What applies to HOST's connection under the generated config (`ssh -G`), and what the host is: the facts of
    /// the runner contract, or everything it lacks. The host is not recorded; the bundle is put in its folder.
    pub async fn probe_host(&self, host: &str) -> Result<Probed, RegError> {
        let name = format!("probe-{:.8}", hex(&Sha256::digest(host.as_bytes())));
        let rc = self.base_cfg(&name, host);
        rc.check().map_err(refused)?;
        let config = ssh_config::write(&self.cfg.runtime_dir, &name, &ssh_config::render(&rc))
            .map_err(|e| failed(format!("writing the ssh config: {e}")))?;
        let effective = super::transport::effective(&config, host).await?;
        let effective = Effective {
            forward_agent: effective.forward_agent,
            forwards: effective.forwards,
            proxy: effective.proxy,
        };
        let _g = self.busy.lock().await;
        let staged = self.stage(&name, host, None, None).await;
        self.cfg.transport.stop(&name).await;
        let (rec, probe) = staged?;
        let _ = rec;
        Ok(match probe.facts {
            Some(f) if probe.missing.is_empty() && probe.limits.is_none() => Probed {
                effective,
                facts: Some(host_facts(&f)),
                missing: vec![],
            },
            _ => Probed {
                effective,
                facts: None,
                missing: all_missing(&probe),
            },
        })
    }

    /// The host's architecture and home, the bundle copied into `<root>/bin/<version>/`, and `serve`'s probe of it:
    /// a record with the facts filled in and no user choices (trust, profile) beyond the defaults.
    async fn stage(
        &self,
        name: &str,
        host: &str,
        root: Option<&str>,
        prefix: Option<&str>,
    ) -> Result<(Record, Probe), RegError> {
        let cfg = self.base_cfg(name, host);
        cfg.check().map_err(refused)?;
        let basics = self
            .sh_ok(&cfg, "uname -m; uname -s; printf %s \"$HOME\"", &[], SHORT)
            .await?;
        let mut lines = basics.lines();
        let (arch, kernel, home) = (
            lines.next().unwrap_or("").trim().to_string(),
            lines.next().unwrap_or("").trim().to_string(),
            lines.next().unwrap_or("").trim().to_string(),
        );
        if kernel != "Linux" {
            return Err(refused(format!(
                "{host} runs {kernel}: runners are Linux machines with a systemd user manager and rootless podman"
            )));
        }
        let arch = match arch.as_str() {
            "x86_64" | "aarch64" => arch,
            other => {
                return Err(refused(format!(
                    "no runner bundle for {other} (x86_64 or aarch64)"
                )));
            }
        };
        let root = match root {
            Some(r) => r.to_string(),
            None => format!("{home}/{DEFAULT_ROOT}"),
        };
        check_root(&root, &home)?;
        let prefix = prefix.unwrap_or(DEFAULT_PREFIX).to_string();
        let dir = self.cfg.bundles.join(&arch);
        let sleipnir = tokio::fs::read(dir.join("sleipnir")).await.map_err(|_| {
            refused(format!(
                "no runner bundle for {arch}: build it with `bin/drgnx build runner-bundle --arch {arch}`"
            ))
        })?;
        let bundle = hex(&Sha256::digest(&sleipnir))[..16].to_string();
        for file in ["sleipnir", "drgnx-key", "drgnx-fwd"] {
            let bytes = if file == "sleipnir" {
                sleipnir.clone()
            } else {
                match tokio::fs::read(dir.join(file)).await {
                    Ok(b) => b,
                    Err(_) => continue,
                }
            };
            let sha = hex(&Sha256::digest(&bytes));
            let script = format!(
                "set -e; d={d}; mkdir -p \"$d\"; head -c {len} > \"$d/{file}.part\"; \
                 echo '{sha}  '\"$d/{file}.part\" | sha256sum -c - >/dev/null; chmod 755 \"$d/{file}.part\"; \
                 mv \"$d/{file}.part\" \"$d/{file}\"",
                d = quote(&format!("{root}/bin/{bundle}")),
                len = bytes.len()
            );
            // exactly LEN bytes are read, so the copy never waits for the end of the input
            self.sh_ok(&cfg, &script, &bytes, LONG).await?;
        }
        let mut rec = Record {
            name: name.into(),
            host: host.into(),
            trust: Trust::Mine,
            profile: Profile::Dedicated,
            accept: Accept::All,
            root,
            prefix,
            bundle,
            arch,
            os: String::new(),
            cores: 0,
            mem_mib: 0,
            disk_free_gb: 0,
            podman: String::new(),
            linger: true,
            landlock_abi: 0,
            features: vec![],
            speed: None,
            checked: None,
            image: None,
        };
        let probe = self.probe_serve(&rec).await?;
        rec.linger = probe.linger;
        if let Some(f) = &probe.facts {
            rec.os = f.os.clone();
            rec.cores = f.cores;
            rec.mem_mib = f.mem_mib;
            rec.disk_free_gb = f.disk_free_gb;
            rec.podman = f.podman_version.clone();
            rec.landlock_abi = f.landlock_abi;
            rec.features = probe.features.clone();
        }
        Ok((rec, probe))
    }

    /// A host made a runner: the probe and the contract, the bundle, the images pulled by digest, a bench, the record,
    /// the link.
    pub async fn add(&self, p: AddParams) -> Result<wire::Runner, RegError> {
        let _g = self.busy.lock().await;
        let host = p.host.as_str().to_string();
        let name = p
            .name
            .as_ref()
            .map(|n| n.as_str().to_string())
            .unwrap_or_else(|| default_name(&host));
        self.base_cfg(&name, &host).check().map_err(refused)?;
        let known = self.cfg.store.list().await.map_err(failed)?;
        if known.iter().any(|r| r.name == name) {
            return Err(refused(format!("{name} is a runner already")));
        }
        let staged = self
            .stage(
                &name,
                &host,
                p.root.as_ref().map(|r| r.as_str()),
                p.prefix.as_ref().map(|r| r.as_str()),
            )
            .await;
        let (mut rec, probe) = match staged {
            Ok(x) => x,
            Err(e) => {
                self.cfg.transport.stop(&name).await;
                return Err(e);
            }
        };
        let done = self.finish_add(&mut rec, &probe, &p).await;
        if done.is_err() {
            self.cfg.transport.stop(&name).await;
        }
        done?;
        self.view(&rec).await
    }

    async fn finish_add(
        &self,
        rec: &mut Record,
        probe: &Probe,
        p: &AddParams,
    ) -> Result<(), RegError> {
        if !self.cfg.hub_boot_id.is_empty() && probe.boot_id == self.cfg.hub_boot_id {
            return Err(refused(
                "this is the hub's own machine; it already runs jobs as `local`",
            ));
        }
        if probe.facts.is_none() || !probe.missing.is_empty() || probe.limits.is_some() {
            return Err(refused(refusal_text(&all_missing(probe))));
        }
        rec.trust = p.trust;
        rec.profile = p.profile.unwrap_or(Profile::Dedicated);
        rec.accept = p.accept.unwrap_or(Accept::All);
        let cfg = self.base_cfg(&rec.name, &rec.host);
        let images = (self.cfg.images)();
        for img in &images {
            if !img.contains("@sha256:")
                || img
                    .chars()
                    .any(|c| c.is_whitespace() || c.is_control() || c == '\'')
            {
                return Err(refused(format!(
                    "the image {img:?} is not pinned by digest (name@sha256:...)"
                )));
            }
            self.sh_ok(
                &cfg,
                &format!("podman pull --quiet {}", quote(img)),
                &[],
                LONG,
            )
            .await?;
        }
        if let Some(img) = images.first() {
            rec.image = Some(img.clone());
            rec.speed = Some(self.bench_run(rec, img).await?);
        }
        rec.checked = Some(crate::clock::wall_secs());
        self.cfg.store.put(rec).await.map_err(failed)?;
        if let Err(e) = self.connect(rec).await {
            let _ = self.cfg.store.remove(&rec.name).await;
            return Err(e);
        }
        Ok(())
    }

    /// The reference workload under the runner's caps, in IMG: its speed.
    async fn bench_run(&self, rec: &Record, img: &str) -> Result<f64, RegError> {
        let cfg = self.base_cfg(&rec.name, &rec.host);
        let script = format!(
            "{}/bin/{}/sleipnir bench --root {} --image {}",
            quote(&rec.root),
            quote(&rec.bundle),
            quote(&rec.root),
            quote(img)
        );
        let out = self.sh_ok(&cfg, &script, &[], LONG).await?;
        let line = out.lines().rev().find(|l| l.trim_start().starts_with('{'));
        let result: serde_json::Value = serde_json::from_str(line.unwrap_or(""))
            .map_err(|e| failed(format!("{}: the bench's answer isn't JSON: {e}", rec.name)))?;
        result["speed"]
            .as_f64()
            .ok_or_else(|| failed(format!("{}: the bench's answer has no speed", rec.name)))
    }

    /// RECORD's runner linked into the queue: `serve` started over the transport, its session the queue's
    /// ([`Queue::dial`]: a login the user must do, or a changed host key, puts it in `needs login`).
    pub async fn connect(&self, rec: &Record) -> Result<(), RegError> {
        let cfg = self.serve_cfg(rec);
        if let Some(old) = self.cfg.queue.session(&rec.name) {
            old.close().await;
        }
        self.cfg
            .queue
            .dial(&*self.cfg.transport, &cfg, self.remote(rec, &cfg))
            .await?;
        Ok(())
    }

    fn remote(&self, rec: &Record, cfg: &RunnerCfg) -> RemoteRunner {
        RemoteRunner {
            name: rec.name.clone(),
            trust: forseti_trust(rec.trust),
            accept: forseti_accept(rec.accept),
            grace_s: cfg.grace().as_secs(),
            image: rec.image.clone(),
        }
    }

    /// Every record linked, as the hub starts. A runner that can't be reached stays recorded (and `unreachable` in
    /// the list); `runners/check` links it again.
    pub async fn connect_all(&self) {
        let recs = match self.cfg.store.list().await {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!("runners: the registry is unreadable: {e}");
                return;
            }
        };
        for rec in recs {
            if let Err(e) = self.connect(&rec).await {
                tracing::warn!("runners: {} isn't connected: {e}", rec.name);
            }
        }
    }

    async fn record(&self, name: &str) -> Result<Record, RegError> {
        self.cfg
            .store
            .list()
            .await
            .map_err(failed)?
            .into_iter()
            .find(|r| r.name == name)
            .ok_or_else(|| refused(format!("no runner named {name}")))
    }

    /// The runner as the list shows it.
    async fn view(&self, r: &Record) -> Result<wire::Runner, RegError> {
        let row = self.cfg.queue.runner(&r.name);
        let (state, strikes, last_strike) = match row {
            Some(row) => (row.state, row.strikes, row.last),
            None => ("not connected".to_string(), 0, None),
        };
        Ok(wire::Runner {
            name: r.name.clone(),
            host: r.host.clone(),
            trust: r.trust,
            profile: r.profile,
            accept: r.accept,
            root: r.root.clone(),
            prefix: r.prefix.clone(),
            arch: r.arch.clone(),
            os: r.os.clone(),
            cores: r.cores,
            mem_mib: r.mem_mib,
            disk_free_gb: r.disk_free_gb,
            podman: r.podman.clone(),
            linger: r.linger,
            landlock_abi: r.landlock_abi,
            features: r.features.clone(),
            speed: r.speed,
            state,
            strikes,
            last_strike,
            jobs: self.cfg.queue.runner_jobs(&r.name),
            checked: r.checked,
        })
    }

    /// The runners, by name.
    pub async fn list(&self) -> Result<Vec<wire::Runner>, RegError> {
        let mut out = Vec::new();
        for r in self.cfg.store.list().await.map_err(failed)? {
            out.push(self.view(&r).await?);
        }
        Ok(out)
    }

    /// NAME's health check now: linked again when its link is gone, then the queue's check at its next tick.
    pub async fn check(&self, name: &str) -> Result<wire::Runner, RegError> {
        let _g = self.busy.lock().await;
        let rec = self.record(name).await?;
        let linked = self
            .cfg
            .queue
            .runner(name)
            .is_some_and(|r| r.state != "unreachable");
        if !linked {
            self.connect(&rec).await?;
        }
        self.cfg.queue.check_now(name);
        self.view(&rec).await
    }

    /// NAME benched again.
    pub async fn bench(&self, name: &str) -> Result<wire::Runner, RegError> {
        let _g = self.busy.lock().await;
        let mut rec = self.record(name).await?;
        let img = rec.image.clone().ok_or_else(|| {
            refused(format!(
                "{name} has no image to bench in: set drgnx-runners-image, then add it again"
            ))
        })?;
        // the sessions are free for one command only while serve isn't running on them
        if let Some(old) = self.cfg.queue.session(name) {
            old.close().await;
        }
        let speed = self.bench_run(&rec, &img).await;
        let again = self.connect(&rec).await;
        rec.speed = Some(speed?);
        self.cfg.store.put(&rec).await.map_err(failed)?;
        again?;
        self.view(&rec).await
    }

    /// NAME's trust, profile or accept changed; a new profile starts `serve` again.
    pub async fn set(&self, p: wire::SetParams) -> Result<wire::Runner, RegError> {
        let _g = self.busy.lock().await;
        let mut rec = self.record(p.name.as_str()).await?;
        let new_profile = p.profile.is_some_and(|x| x != rec.profile);
        rec.trust = p.trust.unwrap_or(rec.trust);
        rec.profile = p.profile.unwrap_or(rec.profile);
        rec.accept = p.accept.unwrap_or(rec.accept);
        self.cfg.store.put(&rec).await.map_err(failed)?;
        self.cfg.queue.set_runner(
            &rec.name,
            forseti_trust(rec.trust),
            forseti_accept(rec.accept),
        );
        if new_profile {
            self.connect(&rec).await?;
        }
        self.view(&rec).await
    }

    /// NAME back in rotation, with no strikes.
    pub async fn unbench(&self, name: &str) -> Result<wire::Runner, RegError> {
        let _g = self.busy.lock().await;
        let rec = self.record(name).await?;
        self.cfg.queue.unbench(name);
        self.view(&rec).await
    }

    /// NAME removed: our units, slices and containers there stopped, its folder deleted, its link and record gone.
    /// Refused while a job is on it.
    pub async fn remove(&self, name: &str) -> Result<(), RegError> {
        let _g = self.busy.lock().await;
        let rec = self.record(name).await?;
        let session = self.cfg.queue.session(name);
        self.cfg.queue.remove_runner(name).map_err(refused)?;
        if let Some(s) = session {
            s.close().await;
        }
        let cfg = self.base_cfg(&rec.name, &rec.host);
        let script = format!(
            "podman ps -a --filter label=drgnx.runner={hub} --format '{{{{.Names}}}}' | grep -E '^{prefix}-' | xargs -r podman rm -f; \
             systemctl --user list-units --all --plain --no-legend '{prefix}*' | awk '{{print $1}}' | xargs -r systemctl --user stop; \
             systemctl --user list-units --all --plain --no-legend 'drgnx-runner*.slice' | awk '{{print $1}}' | xargs -r systemctl --user stop; \
             systemctl --user reset-failed 2>/dev/null; \
             rm -r -- {root}",
            hub = self.cfg.hub_id,
            prefix = rec.prefix,
            root = quote(&rec.root),
        );
        let gone = self.sh_ok(&cfg, &script, &[], LONG).await;
        self.cfg.transport.stop(name).await;
        gone?;
        self.cfg.store.remove(name).await.map_err(failed)
    }
}

/// A root the hub may delete: absolute, plain characters, below the user's home or two folders deep, never the home.
fn check_root(root: &str, home: &str) -> Result<(), RegError> {
    let plain = root
        .chars()
        .all(|c| !c.is_control() && c != '\'' && c != '"' && c != '\\');
    let depth = root.split('/').filter(|s| !s.is_empty()).count();
    if !root.starts_with('/') || !plain || root.contains("/../") || root.ends_with("/..") {
        return Err(refused(format!(
            "the runner folder {root:?} must be an absolute path without quotes, backslashes or `..`"
        )));
    }
    if root.trim_end_matches('/') == home.trim_end_matches('/') || depth < 2 {
        return Err(refused(format!(
            "the runner folder {root:?} must be a folder of its own, never the home folder or a top-level one"
        )));
    }
    Ok(())
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn host_facts(f: &sleipnir::proto::Facts) -> HostFacts {
    HostFacts {
        arch: f.arch.clone(),
        os: f.os.clone(),
        cores: f.cores,
        mem_mib: f.mem_mib,
        disk_free_gb: f.disk_free_gb,
        podman: f.podman_version.clone(),
        linger: f.linger,
        landlock_abi: f.landlock_abi,
        battery: f.battery,
    }
}

/// Everything a probe found missing, `limits` included.
fn all_missing(p: &Probe) -> Vec<Missing> {
    let mut m = p.missing.clone();
    if let Some(why) = &p.limits {
        m.push(Missing {
            what: format!("container jobs can't be capped here: {why}"),
            fix: "run podman on the systemd cgroup manager with the memory, pids and cpu controllers delegated to the user".into(),
        });
    }
    if p.facts.is_none() && m.is_empty() {
        m.push(Missing {
            what: "the host's probe returned no facts".into(),
            fix: "run `sleipnir serve` there by hand and read what it says".into(),
        });
    }
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    // [D] pure
    #[test]
    fn a_name_comes_from_the_hosts_first_label() {
        assert_eq!(default_name("desktop"), "desktop");
        assert_eq!(default_name("me@build-1.tail1234.ts.net"), "build-1");
        assert_eq!(default_name("10.0.0.7"), "10");
        assert_eq!(default_name("-x"), "x");
        assert_eq!(default_name("..."), "runner");
        assert_eq!(default_name(&"a".repeat(80)).len(), NAME_MAX);
    }

    // [D] pure
    #[test]
    fn the_runner_folder_is_never_the_home_or_a_top_level_folder() {
        assert!(check_root("/users/u/.drgnx-runner", "/users/u").is_ok());
        assert!(check_root("/srv/runner", "/users/u").is_ok());
        for bad in [
            "/",
            "/users/u",
            "/users/u/",
            "/tmp",
            "rel/x",
            "/a/../b",
            "/a/b'c",
            "/a/\nb",
        ] {
            assert!(check_root(bad, "/users/u").is_err(), "{bad:?}");
        }
    }

    // [D] pure
    #[test]
    fn a_refusal_lists_every_item_with_its_fix() {
        let t = refusal_text(&[
            Missing {
                what: "cgroup v2 controllers memory pids cpu delegated".into(),
                fix: "enable delegation".into(),
            },
            Missing {
                what: "git".into(),
                fix: "install git".into(),
            },
        ]);
        for want in ["cgroup v2", "enable delegation", "git", "install git"] {
            assert!(t.contains(want), "{want}: {t}");
        }
    }

    // [D] pure
    #[test]
    fn quoting_keeps_a_word_one_word() {
        assert_eq!(quote("a b"), "'a b'");
        assert_eq!(quote("it's"), r"'it'\''s'");
    }
}
