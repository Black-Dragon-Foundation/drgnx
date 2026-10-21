//! Whether the sandbox can start here: host facts, the real invocation as the probe, and the reason and the fix
//! when it cannot (docs/develop/gleipnir.md, "The check").
//!
//! The probe is the same run a job gets, around `/bin/sh` instead of an agent: the isolated network with a relay
//! port, the tier's Landlock floor, seccomp, and a canary file the spec does not grant. A sandbox that starts but
//! lets the program read the canary fails the check. Gleipnir does not spawn: the caller passes `run`, which spawns
//! a [`Prepared`] the way it spawns jobs (Ratatoskr: `draugr::spawn_pinned`) and reports what happened as a [`Ran`].

use crate::backend::{self, BackendKind, Prepared, Sandbox};
use crate::bwrap::InnerCommand;
use crate::inner::LayersReport;
use crate::landlock::{self, Tier};
use crate::spec::{Bind, Layers, Mode, Net, RelayPort, Spec, Target};
use crate::validate::{Context, Refusal, validate};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The lowest bubblewrap the check accepts (`crate::bwrap::FLOOR`).
const BWRAP_FLOOR: (u32, u32, u32) = (0, 12, 0);

/// The probe's command: exit 9 when it could read the canary (`$1`), else 0.
const PROBE_SCRIPT: &str = "cat \"$1\" >/dev/null 2>&1 && exit 9; exit 0";

/// The exit that says the sandbox ran the program but let it read the canary.
const READ_CANARY: i32 = 9;

/// What the machine says about the sandbox, read once. Pure data: [`explain`] reads nothing else.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HostFacts {
    /// `/run/.containerenv` or `/.dockerenv` exists.
    pub container: bool,
    /// `ID`, then `ID_LIKE`, of `/etc/os-release`.
    pub os_ids: Vec<String>,
    /// `VERSION_ID`.
    pub os_version: Option<String>,
    /// `kernel.apparmor_restrict_unprivileged_userns` is 1.
    pub apparmor_restrict_userns: Option<bool>,
    pub max_user_namespaces: Option<u64>,
    /// Debian's `kernel.unprivileged_userns_clone`.
    pub unprivileged_userns_clone: Option<bool>,
    /// A bwrap only root can change, and the version it prints (any version).
    pub bwrap: Option<(PathBuf, (u32, u32, u32))>,
    /// The kernel's Landlock ABI (0: none).
    pub landlock_abi: u8,
    pub macos: bool,
    /// macOS: `/usr/bin/sandbox-exec` is there where only root can change it.
    pub sandbox_exec: bool,
}

/// The facts of this host.
pub fn facts() -> HostFacts {
    facts_with(None)
}

/// [`facts`] with `bwrap_override` as the only bwrap candidate (a test hook; still held to the root-owned rule).
pub fn facts_with(bwrap_override: Option<&Path>) -> HostFacts {
    let read = |p: &str| std::fs::read_to_string(p).ok();
    let (ids, version) = read("/etc/os-release")
        .map(|t| parse_os_release(&t))
        .unwrap_or_default();
    let (macos, sandbox_exec) = backend::host_macos();
    HostFacts {
        container: ["/run/.containerenv", "/.dockerenv"]
            .iter()
            .any(|p| Path::new(p).exists()),
        os_ids: ids,
        os_version: version,
        apparmor_restrict_userns: read("/proc/sys/kernel/apparmor_restrict_unprivileged_userns")
            .and_then(|t| flag(&t)),
        max_user_namespaces: read("/proc/sys/user/max_user_namespaces")
            .and_then(|t| t.trim().parse().ok()),
        unprivileged_userns_clone: read("/proc/sys/kernel/unprivileged_userns_clone")
            .and_then(|t| flag(&t)),
        bwrap: backend::host_bwrap(bwrap_override),
        landlock_abi: landlock::kernel_abi(),
        macos,
        sandbox_exec,
    }
}

fn flag(text: &str) -> Option<bool> {
    match text.trim() {
        "0" => Some(false),
        "1" => Some(true),
        _ => None,
    }
}

/// `/etc/os-release`: the ids (`ID` first, then each word of `ID_LIKE`) and `VERSION_ID`.
fn parse_os_release(text: &str) -> (Vec<String>, Option<String>) {
    let value = |key: &str| {
        text.lines().find_map(|l| {
            let v = l.strip_prefix(key)?.strip_prefix('=')?;
            Some(v.trim().trim_matches(['"', '\'']).to_string())
        })
    };
    let mut ids: Vec<String> = value("ID").into_iter().filter(|s| !s.is_empty()).collect();
    ids.extend(
        value("ID_LIKE")
            .iter()
            .flat_map(|v| v.split_whitespace().map(str::to_string)),
    );
    (ids, value("VERSION_ID").filter(|v| !v.is_empty()))
}

/// How to install bubblewrap on the distribution `ids` name.
fn install_fix(ids: &[String]) -> String {
    for id in ids {
        let cmd = match id.as_str() {
            "fedora" | "rhel" | "centos" => "sudo dnf install bubblewrap",
            "debian" | "ubuntu" => "sudo apt install bubblewrap",
            "arch" => "sudo pacman -S bubblewrap",
            "suse" | "opensuse" => "sudo zypper install bubblewrap",
            _ => continue,
        };
        return cmd.to_string();
    }
    "install bubblewrap 0.12.0 or newer with your package manager".to_string()
}

/// The fix for Ubuntu's (23.10 and later) rule on unprivileged user namespaces: the narrow AppArmor profile, never the
/// global sysctl.
const APPARMOR_FIX: &str = "let bwrap make user namespaces with Ubuntu's bwrap-userns-restrict AppArmor profile: \
    sudo cp /usr/share/apparmor/extra-profiles/bwrap-userns-restrict /etc/apparmor.d/ && \
    sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict  \
    (https://discourse.ubuntu.com/t/understanding-apparmor-user-namespace-restriction/58007)";

/// Why the sandbox cannot start here, and what to do about it (`None`: nothing to do). `stderr` is what the failed
/// start printed (`None`: it was not started); `tier` and `need_abi` say what was asked. The first row that matches
/// wins, and a container comes first.
///
/// bwrap's own rows (a missing or old bubblewrap, user namespaces) apply to the full tier only: the reduced tier
/// makes no namespaces. The facts about user namespaces count only when `stderr` is bwrap's or absent, so a Landlock
/// failure on a restricted Ubuntu is not blamed on AppArmor.
pub fn explain(
    stderr: Option<&str>,
    f: &HostFacts,
    tier: Tier,
    need_abi: u8,
) -> (String, Option<String>) {
    let full = tier == Tier::Full && !f.macos;
    let lower = stderr.map(str::to_lowercase).unwrap_or_default();
    let bwrap_failed = stderr.is_none_or(|s| s.contains("bwrap:"));
    if f.container {
        return (
            "inside a container: bubblewrap needs user namespaces the container does not give"
                .into(),
            None,
        );
    }
    if f.macos && !f.sandbox_exec {
        return (
            "sandbox-exec was not found where only root can change it".into(),
            Some("it ships with macOS at /usr/bin/sandbox-exec: check that it is there".into()),
        );
    }
    if full && f.bwrap.is_none() {
        return (
            "bubblewrap (bwrap) is not installed where only root can change it".into(),
            Some(install_fix(&f.os_ids)),
        );
    }
    if let Some((_, v @ (a, b, c))) = f.bwrap.as_ref().filter(|_| full)
        && *v < BWRAP_FLOOR
    {
        let mut fix =
            "install bubblewrap 0.12.0 or newer; drgnx accepts no older version, even with a \
            distribution's backport"
                .to_string();
        if f.os_ids.iter().any(|i| i == "ubuntu") && f.os_version.as_deref() == Some("26.04") {
            fix.push_str(
                ". Ubuntu 26.04's update removed this fix again (0.11.1-1ubuntu0.3); Ubuntu 26.10 ships 0.12.0",
            );
        }
        return (
            format!(
                "bubblewrap {a}.{b}.{c} is older than 0.12.0, which fixes a sandbox escape (CVE-2026-87766)"
            ),
            Some(fix),
        );
    }
    if lower.contains("setting up uid map: permission denied")
        || (full && bwrap_failed && f.apparmor_restrict_userns == Some(true))
    {
        return (
            "AppArmor restricts unprivileged user namespaces (Ubuntu 23.10 and later)".into(),
            Some(APPARMOR_FIX.into()),
        );
    }
    if lower.contains("no permissions to create new namespace")
        || lower.contains("creating new namespace failed")
        || (full
            && bwrap_failed
            && (f.max_user_namespaces == Some(0) || f.unprivileged_userns_clone == Some(false)))
    {
        return (
            "the kernel does not allow unprivileged user namespaces".into(),
            Some(
                "allow them: sudo sysctl -w user.max_user_namespaces=15000 (Debian: \
                 kernel.unprivileged_userns_clone=1)"
                    .into(),
            ),
        );
    }
    if !f.macos && f.landlock_abi < need_abi {
        return (
            format!(
                "Landlock is off or too old (ABI {}; the sandbox needs ABI {need_abi})",
                f.landlock_abi
            ),
            Some(format!(
                "boot with Landlock in the kernel's lsm= list (and a kernel with Landlock ABI {need_abi} or newer)"
            )),
        );
    }
    let first = stderr
        .and_then(|s| s.lines().map(str::trim).find(|l| !l.is_empty()))
        .unwrap_or("no message");
    (
        format!("the sandbox cannot start here: {first}"),
        Some("run ratatoskr sandbox check --json and see the stderr".into()),
    )
}

/// What a caller's spawn of the probe saw.
#[derive(Debug)]
pub struct Ran {
    /// The helper's status line (or Seatbelt's known layers), or why there was none.
    pub layers: Result<LayersReport, Refusal>,
    /// The program's exit code (`128 + signal` when killed); `None`: it did not finish in time.
    pub exit: Option<i32>,
    /// The start's stderr (a tail), for [`explain`].
    pub stderr: String,
}

/// The check's answer. `reason` and `fix` are set exactly when `ok` is false.
#[derive(Debug, Clone)]
pub struct Check {
    pub backend: BackendKind,
    pub program: Option<PathBuf>,
    pub version: Option<String>,
    pub ok: bool,
    pub reason: Option<String>,
    pub fix: Option<String>,
    pub layers: Option<LayersReport>,
    pub landlock_abi: u8,
    pub container: bool,
    /// What the failed start printed, as `explain` read it (the JSON form only).
    pub stderr: Option<String>,
}

impl Check {
    /// A failed check with `reason` and `fix`, for a caller that cannot even start one.
    pub fn failed(reason: String, fix: Option<String>) -> Check {
        Check {
            backend: BackendKind::None,
            program: None,
            version: None,
            ok: false,
            reason: Some(reason),
            fix,
            layers: None,
            landlock_abi: 0,
            container: false,
            stderr: None,
        }
    }

    /// The text form: `"backend X version: ok (Landlock ABI N, seccomp)"`, or `"not available: REASON"` and
    /// `"fix: FIX"` on the next line.
    pub fn text(&self) -> String {
        if self.ok {
            let name = match &self.version {
                Some(v) => format!("{} {v}", self.backend.name()),
                None => self.backend.name().to_string(),
            };
            format!("backend {name}: ok ({})", self.layers_text())
        } else {
            let mut out = format!(
                "not available: {}",
                self.reason.as_deref().unwrap_or("unknown")
            );
            if let Some(fix) = &self.fix {
                out.push_str(&format!("\nfix: {fix}"));
            }
            out
        }
    }

    /// `"Landlock ABI N, seccomp"`, or `"Seatbelt"`.
    pub fn layers_text(&self) -> String {
        match &self.layers {
            Some(l) if l.seatbelt => "Seatbelt".to_string(),
            Some(l) => format!("Landlock ABI {}, seccomp", l.landlock_abi),
            None => String::new(),
        }
    }

    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "backend": self.backend.name(),
            "program": self.program.as_ref().map(|p| p.to_string_lossy()),
            "version": self.version,
            "ok": self.ok,
            "reason": self.reason,
            "fix": self.fix,
            "layers": self.layers,
            "landlock_abi": self.landlock_abi,
            "container": self.container,
            "stderr": self.stderr,
        })
    }
}

fn version_text(v: (u32, u32, u32)) -> String {
    format!("{}.{}.{}", v.0, v.1, v.2)
}

/// Whether the sandbox starts here for `tier`: facts, then the real run. `run` spawns the prepared probe and reports
/// within `timeout` (`probe_dir` is made and removed here; a socket in it is held until `run` returns).
pub async fn check<F, Fut>(
    helper: InnerCommand,
    tier: Tier,
    bwrap_override: Option<PathBuf>,
    timeout: Duration,
    run: F,
) -> Check
where
    F: FnOnce(Prepared, Duration) -> Fut,
    Fut: Future<Output = Ran>,
{
    let f = facts_with(bwrap_override.as_deref());
    check_with(f, helper, tier, bwrap_override, timeout, run).await
}

/// [`check`] with the host's `facts` given (they explain a failure; the run itself is always the real one).
pub async fn check_with<F, Fut>(
    f: HostFacts,
    helper: InnerCommand,
    tier: Tier,
    bwrap_override: Option<PathBuf>,
    timeout: Duration,
    run: F,
) -> Check
where
    F: FnOnce(Prepared, Duration) -> Fut,
    Fut: Future<Output = Ran>,
{
    let need_abi = if f.macos {
        0
    } else {
        match tier {
            Tier::Full => crate::spec::LANDLOCK_FLOOR_FULL,
            Tier::Reduced => crate::spec::LANDLOCK_FLOOR_REDUCED,
        }
    };
    let fail = |kind: BackendKind, stderr: Option<&str>, layers: Option<LayersReport>| {
        let (reason, fix) = explain(stderr, &f, tier, need_abi);
        Check {
            backend: kind,
            program: program_of(&f, tier),
            version: (tier == Tier::Full)
                .then(|| f.bwrap.as_ref().map(|(_, v)| version_text(*v)))
                .flatten(),
            ok: false,
            reason: Some(reason),
            fix,
            layers,
            landlock_abi: f.landlock_abi,
            container: f.container,
            stderr: stderr.map(str::to_string),
        }
    };
    let sandbox = match Sandbox::detect(tier, helper, bwrap_override) {
        Ok(s) => s,
        Err(r) => return fail(BackendKind::None, Some(&r.message), None),
    };
    let kind = sandbox.kind();
    let ran = match start(&sandbox, tier, timeout, run).await {
        Ok(ran) => ran,
        Err(r) => return fail(kind, Some(&r.message), None),
    };
    match ran.layers {
        Err(r) => {
            let both = format!("{}\n{}", ran.stderr.trim(), r.message);
            fail(kind, Some(both.trim()), None)
        }
        Ok(layers) => match ran.exit {
            Some(0) => Check {
                backend: kind,
                program: program_of(&f, tier),
                version: (kind == BackendKind::Bwrap)
                    .then(|| f.bwrap.as_ref().map(|(_, v)| version_text(*v)))
                    .flatten(),
                ok: true,
                reason: None,
                fix: None,
                layers: Some(layers),
                landlock_abi: f.landlock_abi,
                container: f.container,
                stderr: None,
            },
            exit => {
                let reason = match exit {
                    Some(READ_CANARY) => "the sandbox ran but did not block a read".to_string(),
                    Some(code) => format!("the sandbox's probe ended with exit {code}"),
                    None => format!(
                        "the sandbox's probe did not finish within {} ms",
                        timeout.as_millis()
                    ),
                };
                let mut c = fail(kind, None, Some(layers));
                c.reason = Some(reason);
                c.stderr = Some(ran.stderr).filter(|s| !s.is_empty());
                c.fix = Some("run ratatoskr sandbox check --json and see the stderr".into());
                c
            }
        },
    }
}

/// The program a backend runs under: bwrap (full tier) or sandbox-exec (macOS); the reduced tier has none.
fn program_of(f: &HostFacts, tier: Tier) -> Option<PathBuf> {
    match (&f.bwrap, f.macos, tier) {
        (_, true, _) => Some(PathBuf::from("/usr/bin/sandbox-exec")),
        (Some((p, _)), false, Tier::Full) => Some(p.clone()),
        _ => None,
    }
}

/// Make the probe's spec in a temp dir, validate it, prepare it and hand it to `run`.
async fn start<F, Fut>(
    sandbox: &Sandbox,
    tier: Tier,
    timeout: Duration,
    run: F,
) -> Result<Ran, Refusal>
where
    F: FnOnce(Prepared, Duration) -> Fut,
    Fut: Future<Output = Ran>,
{
    let target = sandbox
        .target()
        .ok_or_else(|| backend::none::refusal("no backend"))?;
    let dir =
        ProbeDir::new().map_err(|e| setup(format!("cannot make the probe's directory: {e}")))?;
    let base = &dir.base;
    let linux = target != Target::Macos;
    let session = base.join("s/S1");
    // A real socket for the relay to forward to; held until the probe is over.
    let _listener = if linux {
        Some(
            std::os::unix::net::UnixListener::bind(session.join("proxy.sock"))
                .map_err(|e| setup(format!("cannot make the probe's socket: {e}")))?,
        )
    } else {
        None
    };
    let run_dest = if target == Target::LinuxBwrap {
        PathBuf::from("/run/drgnx")
    } else {
        session.clone()
    };
    let port = backend::relay_ports(tier, &[3128])
        .map_err(|e| setup(format!("cannot take a relay port: {e}")))?[0];
    let spec = Spec {
        read: vec![],
        write: vec![base.join("w")],
        hide: vec![],
        sockets: if linux {
            vec![session.join("proxy.sock")]
        } else {
            vec![]
        },
        binds: vec![],
        home: None,
        run: Some(Bind {
            mode: Mode::Ro,
            source: session.clone(),
            dest: run_dest.clone(),
        }),
        env: vec![("PATH".into(), "/usr/bin:/bin".into())],
        chdir: base.join("w"),
        net: Net::Isolated {
            relay: if linux {
                vec![RelayPort {
                    port,
                    socket: run_dest.join("proxy.sock"),
                }]
            } else {
                vec![]
            },
            mac_tcp_ports: vec![],
        },
        tmp: (target != Target::LinuxBwrap).then(|| base.join("t")),
        layers: Layers::for_target(target),
        extra_tcp_ports: vec![],
    };
    // The probe's own paths only: a home that exists nowhere, so nothing real is named or protected here.
    let ctx = Context {
        home: PathBuf::from("/nonexistent-gleipnir-check-home"),
        run_parents: vec![base.join("s")],
        ..Context::default()
    };
    let valid = validate(spec, &ctx, target)?;
    let canary = base.join("outside/canary");
    let command = vec![
        "/bin/sh".to_string(),
        "-c".to_string(),
        PROBE_SCRIPT.to_string(),
        "sh".to_string(),
        canary.to_string_lossy().into_owned(),
    ];
    #[cfg(feature = "test-hooks")]
    let prepared = sandbox.prepare(valid, command, crate::backend::TestHooks::default())?;
    #[cfg(not(feature = "test-hooks"))]
    let prepared = sandbox.prepare(valid, command)?;
    Ok(run(prepared, timeout).await)
}

fn setup(message: String) -> Refusal {
    Refusal {
        rule: crate::validate::Rule::Setup,
        path: None,
        message,
    }
}

/// The probe's directory: `w` (written), `t` (the reduced tier's tmp), `s/S1` (the session dir), `outside/canary`
/// (a file no spec grants). Removed when dropped.
struct ProbeDir {
    base: PathBuf,
}

impl ProbeDir {
    fn new() -> std::io::Result<ProbeDir> {
        use std::os::unix::fs::DirBuilderExt;
        // A socket path is limited to about 100 bytes: a long TMPDIR falls back to /tmp.
        let mut parent = std::env::temp_dir();
        if parent.as_os_str().len() > 40 {
            parent = PathBuf::from("/tmp");
        }
        static COUNT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let n = COUNT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let raw = parent.join(format!("gleipnir-check-{}-{n}", std::process::id()));
        std::fs::DirBuilder::new().mode(0o700).create(&raw)?;
        let dir = ProbeDir {
            base: std::fs::canonicalize(&raw)?,
        };
        for d in ["w", "t", "s", "s/S1", "outside"] {
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(dir.base.join(d))?;
        }
        std::fs::write(dir.base.join("outside/canary"), "canary\n")?;
        Ok(dir)
    }
}

impl Drop for ProbeDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.base);
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests;
