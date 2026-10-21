//! The one platform boundary: which backend runs a spec on this host, and what it runs (docs/develop/gleipnir.md,
//! "Using it" and "Platforms"). [`Sandbox::detect`] picks the backend; [`Sandbox::prepare`] turns a [`ValidSpec`]
//! and a command into an [`Invocation`] for the caller to spawn (Ratatoskr: `draugr::spawn_pinned`), and the read end
//! of the status pipe for [`crate::inner::read_status`].
//!
//! Which file holds what:
//!
//! | Item | File | Gate | Android |
//! |---|---|---|---|
//! | the spec, validation, the bwrap argv, the SBPL text, hosts, relay, proxy | `spec`, `validate`, `bwrap`, `sbpl`, `net` | none: pure, built and tested on every target | builds; nothing runs it |
//! | `Sandbox`, `Prepared`, `Invocation` | `backend` (this file) | none: the choice of backend is `cfg`'d inside | detect refuses (`none`) |
//! | bwrap, the reduced tier | `backend::linux::{bwrap, reduced}` | `target_os = "linux"` | no backend; apps get no user namespaces; fails closed |
//! | the inner helper, Landlock, seccomp | `inner`, `landlock`, `seccomp` | body `target_os = "linux"`, an `Unsupported` stub elsewhere | the stub: fails closed |
//! | Seatbelt | `backend::macos` | `target_os = "macos"` (and `test`, so its tests run on Linux) | not applicable (no Seatbelt) |
//! | everything else | `backend::none` | always built | the answer there: a refusal |
//! | no-link opens (`openat2`), `/proc` | `eitri`, `draugr` | `any(target_os = "linux", target_os = "android")` | a kernel fact: Android has them |
//!
//! Every chain of `cfg`s ends in [`BackendKind::None`] or an `Unsupported` refusal, never in a missing item and
//! never in an unconfined run. Outside `backend`, only `inner`, `landlock` and `seccomp` name a `target_os`.

use crate::bwrap::InnerCommand;
use crate::inner::LayersReport;
use crate::landlock::Tier;
use crate::sbpl::MacContext;
use crate::spec::{Target, ValidSpec};
use crate::validate::{Refusal, Rule};
use eitri::TrustedProgram;
use std::ffi::OsString;
use std::io;
use std::os::fd::OwnedFd;
use std::path::PathBuf;

// bwrap and the reduced tier (Landlock + seccomp through the inner helper). A desktop-distro fact, so `linux` alone.
// Android: no backend; apps get no user namespaces; fails closed (`none`).
#[cfg(target_os = "linux")]
pub mod linux;

// Seatbelt through /usr/bin/sandbox-exec. Android: not applicable (no Seatbelt). Built in tests on every target too:
// its code is plain Unix (a file and an argv), so where the profile goes is tested on Linux; only macOS runs it.
#[cfg(any(target_os = "macos", test))]
pub mod macos;

// Every other target, Android among them: a refusal, never an unconfined run.
pub mod none;

/// The backend that runs a spec. A host where none works gets [`BackendKind::None`], and every run there is refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendKind {
    /// The full tier (Linux): bubblewrap ≥ 0.12.0, then the inner helper with Landlock (ABI ≥ 1) and seccomp.
    Bwrap,
    /// The reduced tier (Linux): the inner helper alone, Landlock ABI ≥ 9 and seccomp, no namespaces.
    Reduced,
    /// macOS: Seatbelt through a root-owned `/usr/bin/sandbox-exec`.
    Seatbelt,
    /// No backend here (Android, other systems, or a host that fails the check): refuse, never run unconfined.
    None,
}

impl BackendKind {
    /// The name the check and the doctor print.
    pub fn name(self) -> &'static str {
        match self {
            BackendKind::Bwrap => "bwrap",
            BackendKind::Reduced => "reduced",
            BackendKind::Seatbelt => "seatbelt",
            BackendKind::None => "none",
        }
    }

    /// The target a spec is validated for to run under this backend; `None` has none.
    pub fn target(self) -> Option<Target> {
        match self {
            BackendKind::Bwrap => Some(Target::LinuxBwrap),
            BackendKind::Reduced => Some(Target::LinuxReduced),
            BackendKind::Seatbelt => Some(Target::Macos),
            BackendKind::None => None,
        }
    }
}

/// The escape rows' hooks (Task 15): write roots Landlock leaves out, and a cap on the kernel's Landlock ABI. They
/// exist only with the `test-hooks` feature, which only Ratatoskr's own `test-hooks` turns on.
#[cfg(feature = "test-hooks")]
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TestHooks {
    pub landlock_omit: Vec<PathBuf>,
    pub abi_cap: Option<u8>,
}

/// What the backends take for the hooks: [`TestHooks`] with the feature, nothing without.
#[cfg(feature = "test-hooks")]
pub(crate) type Hooks = TestHooks;
#[cfg(not(feature = "test-hooks"))]
pub(crate) type Hooks = ();

/// What to spawn: `program` with `args`, exactly `env`, in `cwd` (`None`: the caller's), each of `fds` at its
/// number, and nothing else. With `new_session` the child must lead a session of its own (`setsid` before exec): the
/// reduced tier's helper starts one itself, which a process-group leader cannot.
#[derive(Debug)]
pub struct Invocation {
    pub program: PathBuf,
    pub args: Vec<OsString>,
    pub env: Vec<(OsString, OsString)>,
    pub cwd: Option<PathBuf>,
    pub fds: Vec<(OwnedFd, i32)>,
    pub new_session: bool,
}

/// A prepared run. `status` is the read end of the status pipe (Linux); its write end is in `invocation.fds` at
/// fd 4 and nowhere else, so it moves into the spawn and is gone once the spawn returns (review S6): read it with
/// [`crate::inner::read_status`]. `layers` is the report known without a status line (Seatbelt).
#[derive(Debug)]
pub struct Prepared {
    pub invocation: Invocation,
    pub status: Option<OwnedFd>,
    pub layers: Option<LayersReport>,
}

/// The sandbox of this host, for one tier: the backend and what it runs with. Each field is read only by the
/// backends that need it, hence the per-target `dead_code` allowances.
#[derive(Debug, Clone)]
pub struct Sandbox {
    kind: BackendKind,
    tier: Tier,
    /// The inner helper: Linux only (Android and macOS have none).
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    helper: InnerCommand,
    /// bwrap (full tier) or `sandbox-exec` (Seatbelt), found where only root can change it. Android: never set.
    #[cfg_attr(not(any(target_os = "linux", target_os = "macos")), allow(dead_code))]
    program: Option<TrustedProgram>,
    /// What the Seatbelt profile needs: macOS only.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    mac: MacContext,
}

impl Sandbox {
    /// The backend for `tier` here, or why there is none:
    /// - Linux, full: bwrap ≥ 0.12.0 from a root-owned path (or `bwrap_override`, which only Ratatoskr's test hooks
    ///   pass, held to the same rules). Without it the full tier is refused; it never falls back to the reduced tier,
    ///   which only the caller chooses (review S5).
    /// - Linux, reduced: the inner helper alone.
    /// - macOS: Seatbelt (a root-owned `/usr/bin/sandbox-exec`), whatever the tier.
    /// - anything else: refused.
    ///
    /// `helper` is the inner helper (the `ratatoskr` binary) and how it is started.
    pub fn detect(
        tier: Tier,
        helper: InnerCommand,
        bwrap_override: Option<PathBuf>,
    ) -> Result<Sandbox, Refusal> {
        #[cfg(target_os = "linux")]
        {
            linux::detect(tier, helper, bwrap_override)
        }
        // macOS: one backend. Android: not this branch (see below).
        #[cfg(target_os = "macos")]
        {
            let _ = bwrap_override;
            let program = macos::find()?;
            Ok(Sandbox {
                kind: BackendKind::Seatbelt,
                tier,
                helper,
                program: Some(program),
                mac: MacContext::default(),
            })
        }
        // Android and every other target: no backend; fails closed.
        #[cfg(not(any(target_os = "linux", target_os = "macos")))]
        {
            let _ = (tier, helper, bwrap_override);
            Err(none::refusal("this system has none"))
        }
    }

    /// The macOS facts the Seatbelt profile needs (the developer dir); gleipnir reads none itself.
    pub fn with_mac(mut self, mac: MacContext) -> Sandbox {
        self.mac = mac;
        self
    }

    pub fn kind(&self) -> BackendKind {
        self.kind
    }

    pub fn tier(&self) -> Tier {
        self.tier
    }

    /// The target to validate a spec for, to run here.
    pub fn target(&self) -> Option<Target> {
        self.kind.target()
    }

    /// `command` under `spec`, which must have been validated for this backend's target. Every source is opened now
    /// (the full tier), so what was checked is what gets mounted. Nothing is spawned.
    pub fn prepare(
        &self,
        spec: ValidSpec,
        command: Vec<String>,
        #[cfg(feature = "test-hooks")] hooks: TestHooks,
    ) -> Result<Prepared, Refusal> {
        #[cfg(not(feature = "test-hooks"))]
        let hooks: Hooks = ();
        let Some(target) = self.target() else {
            return Err(none::refusal("this host has none"));
        };
        if spec.target() != target {
            return Err(Refusal {
                rule: Rule::Malformed,
                path: None,
                message: format!(
                    "a spec validated for {:?} cannot run under {:?}",
                    spec.target(),
                    self.kind
                ),
            });
        }
        if command.first().is_none_or(String::is_empty) {
            return Err(Refusal {
                rule: Rule::Malformed,
                path: None,
                message: "the command is empty".into(),
            });
        }
        self.run_on(spec, command, hooks)
    }

    #[cfg(target_os = "linux")]
    fn run_on(
        &self,
        spec: ValidSpec,
        command: Vec<String>,
        hooks: Hooks,
    ) -> Result<Prepared, Refusal> {
        match self.kind {
            BackendKind::Bwrap => linux::prepare_full(self, spec, command, hooks),
            BackendKind::Reduced => linux::prepare_reduced(self, spec, command, hooks),
            BackendKind::Seatbelt | BackendKind::None => Err(none::refusal("not on this system")),
        }
    }

    /// `_hooks` are Landlock's; Seatbelt has none.
    #[cfg(target_os = "macos")]
    fn run_on(
        &self,
        spec: ValidSpec,
        command: Vec<String>,
        _hooks: Hooks,
    ) -> Result<Prepared, Refusal> {
        let program = match (self.kind, &self.program) {
            (BackendKind::Seatbelt, Some(p)) => p,
            _ => return Err(none::refusal("not on this system")),
        };
        macos::prepare(&spec, &self.mac, program, &command).map(seatbelt_prepared)
    }

    // Android and every other target: no backend; fails closed.
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    fn run_on(
        &self,
        spec: ValidSpec,
        command: Vec<String>,
        hooks: Hooks,
    ) -> Result<Prepared, Refusal> {
        let _ = (spec, command, hooks);
        Err(none::refusal("this system has none"))
    }
}

/// Seatbelt's run as an invocation: no fds, no status line, the layers known now (Task 9's hand-off). A session of
/// its own (review S6): Seatbelt lets the program read `/dev/tty` and ioctl its tty, so it must have no controlling
/// terminal to reach (Linux: bwrap's `--new-session`, the reduced helper's `setsid`). Built on Linux in tests too,
/// where the mapping is tested.
#[cfg(any(target_os = "macos", all(test, target_os = "linux")))]
fn seatbelt_prepared(run: macos::Run) -> Prepared {
    Prepared {
        invocation: Invocation {
            program: run.program,
            args: run.args,
            env: run.env,
            cwd: Some(run.cwd),
            fds: vec![],
            new_session: true,
        },
        status: None,
        layers: Some(LayersReport::seatbelt()),
    }
}

/// The bwrap this host has and its version, for the check's facts: root-owned only, any version (Linux; else `None`).
pub(crate) fn host_bwrap(only: Option<&std::path::Path>) -> Option<(PathBuf, (u32, u32, u32))> {
    #[cfg(target_os = "linux")]
    {
        linux::bwrap::probe(only)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = only;
        None
    }
}

/// Whether this host is macOS, and then whether `/usr/bin/sandbox-exec` is there where only root can change it.
pub(crate) fn host_macos() -> (bool, bool) {
    #[cfg(target_os = "macos")]
    {
        (true, macos::find().is_ok())
    }
    #[cfg(not(target_os = "macos"))]
    {
        (false, false)
    }
}

/// The relay ports for one session of `tier`, `wanted.len()` of them (GL-T8-3). The full tier's network namespace
/// is the session's own, so `wanted` is used as given. The reduced tier's relay binds on the host's loopback, where
/// another session's relay may hold the same port: free ports are taken from the kernel instead, all held at once
/// so they differ from each other and from every port bound now. A port taken by someone else between this call
/// and the relay's bind makes the relay, and so the run, fail; it is never shared.
pub fn relay_ports(tier: Tier, wanted: &[u16]) -> io::Result<Vec<u16>> {
    match tier {
        Tier::Full => Ok(wanted.to_vec()),
        Tier::Reduced => {
            let held = wanted
                .iter()
                .map(|_| std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)))
                .collect::<io::Result<Vec<_>>>()?;
            held.iter()
                .map(|l| l.local_addr().map(|a| a.port()))
                .collect()
        }
    }
}

// The tests make real memfds and pipes, which the backends make only on Linux.
#[cfg(all(test, target_os = "linux"))]
mod tests;
