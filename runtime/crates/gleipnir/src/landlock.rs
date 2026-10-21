//! Landlock rule sets per ABI for the full and reduced tiers, applied as a hard requirement with a minimum ABI
//! (Task 5). The plan and the rule sets are pure; applying them is Linux only.
//!
//! The applying code is gated `#[cfg(target_os = "linux")]` here, with an `Unsupported` stub elsewhere (Android: no
//! backend; apps get no user namespaces; fails closed). The `landlock` crate is a Linux-only dependency; name it
//! `::landlock` in this module.
//!
//! Three steps (docs/develop/gleipnir.md, "Landlock"):
//! - [`plan_for`] turns a spec into a [`LandlockPlan`]: which paths are read, written, connected to, for one tier.
//! - [`rules_for_abi`] turns a plan into the [`RulesetDesc`] for one ABI: only rights that ABI has.
//! - [`restrict`] checks the floor, then applies the description for the effective ABI to the calling thread.

use crate::spec::{
    LANDLOCK_ABI_MAX, LANDLOCK_FLOOR_FULL, LANDLOCK_FLOOR_REDUCED, LANDLOCK_FLOOR_SHARED_NET, Mode,
    Net, ValidSpec,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::PathBuf;

/// Which Linux tier a plan is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Tier {
    /// Under bwrap: paths are the inside paths (bind dests) of a mount namespace gleipnir built.
    Full,
    /// No namespaces: paths are the host's own (the sources).
    Reduced,
}

impl Tier {
    /// The lowest Landlock ABI this tier runs on, whatever a plan says (the user's rulings, 2026-10-21).
    pub const fn floor(self) -> u8 {
        match self {
            Tier::Full => LANDLOCK_FLOOR_FULL,
            Tier::Reduced => LANDLOCK_FLOOR_REDUCED,
        }
    }
}

/// What the sandboxed program may touch, for one tier. Travels in the inner spec.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LandlockPlan {
    pub tier: Tier,
    /// The lowest ABI the run accepts. [`restrict`] also holds it to the tier's floor.
    pub min_abi: u8,
    /// Read and execute beneath these.
    pub read_roots: Vec<PathBuf>,
    /// Every write right gleipnir grants, beneath these.
    pub write_roots: Vec<PathBuf>,
    /// Device files that may be opened for writing (and nothing else written).
    pub dev_write_files: Vec<PathBuf>,
    /// Pathname Unix sockets beneath these may be connected to (ABI ≥ 9).
    pub unix_connect_roots: Vec<PathBuf>,
    /// `Some`: TCP connects only to these ports (ABI ≥ 4). `None`: TCP is not handled.
    pub tcp_connect_ports: Option<Vec<u16>>,
    /// `Some`: TCP binds only to these ports (ABI ≥ 4), the relay's; the inner helper then adds a layer that refuses
    /// every bind before the program runs ([`forbid_tcp_bind`]). `None`: binds are not handled (the full tier, whose
    /// network namespace isolates a server inside).
    pub tcp_bind_ports: Option<Vec<u16>>,
}

/// One Landlock filesystem right, by the `landlock` crate's name. Ordered as the kernel's bits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FsRight {
    Execute,
    WriteFile,
    ReadFile,
    ReadDir,
    RemoveDir,
    RemoveFile,
    MakeChar,
    MakeDir,
    MakeReg,
    MakeSock,
    MakeFifo,
    MakeBlock,
    MakeSym,
    Refer,
    Truncate,
    IoctlDev,
    ResolveUnix,
}

impl FsRight {
    pub const ALL: [FsRight; 17] = [
        FsRight::Execute,
        FsRight::WriteFile,
        FsRight::ReadFile,
        FsRight::ReadDir,
        FsRight::RemoveDir,
        FsRight::RemoveFile,
        FsRight::MakeChar,
        FsRight::MakeDir,
        FsRight::MakeReg,
        FsRight::MakeSock,
        FsRight::MakeFifo,
        FsRight::MakeBlock,
        FsRight::MakeSym,
        FsRight::Refer,
        FsRight::Truncate,
        FsRight::IoctlDev,
        FsRight::ResolveUnix,
    ];

    /// The ABI that introduced the right.
    pub const fn since(self) -> u8 {
        match self {
            FsRight::Refer => 2,
            FsRight::Truncate => 3,
            FsRight::IoctlDev => 5,
            FsRight::ResolveUnix => 9,
            _ => 1,
        }
    }
}

/// A Landlock network right, ordered as the kernel's bits. The full tier handles `connect_tcp` under
/// `Net::Isolated` and never `bind_tcp` (servers inside its network namespace must work); the reduced tier handles
/// both.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NetRight {
    BindTcp,
    ConnectTcp,
}

/// A Landlock scope (ABI ≥ 6).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScopeRight {
    AbstractUnixSocket,
    Signal,
}

/// The rights allowed beneath one path.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PathRule {
    pub path: PathBuf,
    pub allow: Vec<FsRight>,
}

/// The rule set for one ABI: what is handled (denied unless allowed), and what is allowed where. Pure data; only
/// rights the ABI has appear in it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RulesetDesc {
    pub abi: u8,
    pub handled_fs: Vec<FsRight>,
    pub handled_net: Vec<NetRight>,
    pub scoped: Vec<ScopeRight>,
    /// Sorted by path, one entry per path.
    pub path_rules: Vec<PathRule>,
    /// Allowed when `handled_net` has `connect_tcp`; empty otherwise.
    pub tcp_connect_ports: Vec<u16>,
    /// Allowed when `handled_net` has `bind_tcp`; empty otherwise.
    pub tcp_bind_ports: Vec<u16>,
}

/// What [`restrict`] applied.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Applied {
    /// The effective ABI whose rule set is in force.
    pub abi: u8,
}

/// Why Landlock was not applied. Each is a refusal: nothing may be exec'd after one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LandlockError {
    /// The effective ABI is below what the plan and its tier require.
    BelowFloor { need: u8, effective: u8, kernel: u8 },
    /// Not Linux.
    Unsupported,
    /// A rule's path could not be opened (other than missing or a link, which are skipped).
    Open { path: PathBuf, errno: i32 },
    /// The `landlock` crate or the kernel refused the rule set.
    Ruleset(String),
}

impl fmt::Display for LandlockError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LandlockError::BelowFloor {
                need,
                effective,
                kernel,
            } => write!(
                f,
                "Landlock ABI {effective} is below the {need} this run requires (the kernel reports {kernel})"
            ),
            LandlockError::Unsupported => write!(f, "Landlock is Linux only"),
            LandlockError::Open { path, errno } => write!(
                f,
                "cannot open {} for a Landlock rule: {}",
                path.display(),
                std::io::Error::from_raw_os_error(*errno)
            ),
            LandlockError::Ruleset(why) => write!(f, "Landlock refused the rule set: {why}"),
        }
    }
}

impl std::error::Error for LandlockError {}

/// The reduced tier's system roots: read and execute only. Missing ones and links (`/bin` → `usr/bin`) are skipped
/// when applied; what they point to is covered by `/usr`.
pub const REDUCED_SYSTEM_ROOTS: &[&str] = &[
    "/usr", "/etc", "/opt", "/nix", "/gnu", "/bin", "/lib", "/lib64", "/sbin", "/proc",
];

/// Device files the reduced tier may read.
pub const REDUCED_DEV_READ: &[&str] = &[
    "/dev/null",
    "/dev/zero",
    "/dev/full",
    "/dev/random",
    "/dev/urandom",
    "/dev/tty",
];

/// Device files the reduced tier may write: the sinks every shell script uses. Not the host's `/dev/tty`.
pub const REDUCED_DEV_WRITE: &[&str] = &["/dev/null", "/dev/zero", "/dev/full"];

/// The full tier's private mounts that must be writable: temporary dirs, POSIX shared memory, ptys (review M14).
pub const FULL_PRIVATE_WRITE: &[&str] = &["/tmp", "/var/tmp", "/dev/shm", "/dev/pts"];

/// Device files the full tier may write (bwrap's own `/dev`).
pub const FULL_DEV_WRITE: &[&str] = &[
    "/dev/null",
    "/dev/zero",
    "/dev/full",
    "/dev/tty",
    "/dev/ptmx",
];

fn path_list<'a>(it: impl IntoIterator<Item = &'a PathBuf>, more: &[&str]) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = it.into_iter().cloned().collect();
    v.extend(more.iter().map(PathBuf::from));
    v.sort();
    v.dedup();
    v
}

/// The plan for `spec` in `tier` (pure). `min_abi` is the spec's, raised to the tier's floor, and in the full tier
/// under `Net::Shared` to [`LANDLOCK_FLOOR_SHARED_NET`]: the host's abstract sockets are reachable there unless ABI 6
/// scopes them, so a kernel below it refuses the run (review S3).
pub fn plan_for(spec: &ValidSpec, tier: Tier) -> LandlockPlan {
    let s = spec.spec();
    let shared_floor = match (tier, &s.net) {
        (Tier::Full, Net::Shared) => LANDLOCK_FLOOR_SHARED_NET,
        _ => 0,
    };
    let min_abi = s
        .layers
        .landlock_min_abi
        .max(tier.floor())
        .max(shared_floor);
    let rw_binds = s.binds.iter().filter(|b| b.mode == Mode::Rw);
    let rw_home = s.home.iter().filter(|b| b.mode == Mode::Rw);
    match tier {
        Tier::Full => {
            // Inside paths: `write` entries are bound at their own path, binds and the home at their dests.
            let write = s
                .write
                .iter()
                .chain(rw_binds.map(|b| &b.dest))
                .chain(rw_home.map(|b| &b.dest));
            let tcp_connect_ports = match &s.net {
                Net::Shared => None,
                Net::Isolated { relay, .. } => {
                    let mut ports: Vec<u16> = relay
                        .iter()
                        .map(|r| r.port)
                        .chain(s.extra_tcp_ports.iter().copied())
                        .collect();
                    ports.sort_unstable();
                    ports.dedup();
                    Some(ports)
                }
            };
            LandlockPlan {
                tier,
                min_abi,
                read_roots: path_list([], &["/"]),
                write_roots: path_list(write, FULL_PRIVATE_WRITE),
                dev_write_files: path_list([], FULL_DEV_WRITE),
                unix_connect_roots: path_list(s.run.iter().map(|b| &b.dest), &[]),
                tcp_connect_ports,
                tcp_bind_ports: None,
            }
        }
        Tier::Reduced => {
            // The host's own paths (sources). Never the host's /tmp, /var/tmp or /dev/shm (review B1).
            let read = s
                .read
                .iter()
                .chain(&s.write)
                .chain(s.binds.iter().map(|b| &b.source))
                .chain(s.home.iter().map(|b| &b.source))
                .chain(s.run.iter().map(|b| &b.source))
                .chain(&s.tmp);
            let mut read_more: Vec<&str> = REDUCED_SYSTEM_ROOTS.to_vec();
            read_more.extend(REDUCED_DEV_READ);
            let write = s
                .write
                .iter()
                .chain(rw_binds.map(|b| &b.source))
                .chain(rw_home.map(|b| &b.source))
                .chain(&s.tmp);
            // Not network-open (the manager's call on Task 5, 2026-10-21): TCP connects only to the relay's ports,
            // which forward to the proxy, and binds only there too (the relay's own; the helper then refuses every
            // bind before the program runs). `extra_tcp_ports` are not granted: without a network namespace a port
            // rule reaches every host, and with binds refused there is no server inside to reach. `Net::Shared`
            // gets no TCP at all.
            let mut relay_ports: Vec<u16> = match &s.net {
                Net::Shared => vec![],
                Net::Isolated { relay, .. } => relay.iter().map(|r| r.port).collect(),
            };
            relay_ports.sort_unstable();
            relay_ports.dedup();
            LandlockPlan {
                tier,
                min_abi,
                read_roots: path_list(read, &read_more),
                write_roots: path_list(write, &[]),
                dev_write_files: path_list([], REDUCED_DEV_WRITE),
                unix_connect_roots: path_list(s.run.iter().map(|b| &b.source), &[]),
                tcp_connect_ports: Some(relay_ports.clone()),
                tcp_bind_ports: Some(relay_ports),
            }
        }
    }
}

const READ_RIGHTS: [FsRight; 3] = [FsRight::Execute, FsRight::ReadFile, FsRight::ReadDir];

/// The rule set of `plan` for `abi` (pure). An ABI above [`LANDLOCK_ABI_MAX`] gets the max's set.
///
/// Handled: every fs right of the ABI except `ioctl_dev` (seccomp covers TIOCSTI; ioctls on ttys and pipes must
/// work). Granted: read and execute on the read roots; every write right on the write roots except making device
/// nodes; `write_file` on the device files; `resolve_unix` (ABI 9) on the connect roots only. `connect_tcp` and
/// `bind_tcp` (ABI 4) are each handled only when the plan has ports for them; scopes (ABI 6) always.
pub fn rules_for_abi(plan: &LandlockPlan, abi: u8) -> RulesetDesc {
    let abi = abi.min(LANDLOCK_ABI_MAX);
    let handled: BTreeSet<FsRight> = FsRight::ALL
        .into_iter()
        .filter(|r| r.since() <= abi && *r != FsRight::IoctlDev)
        .collect();
    let only = |rs: &[FsRight]| -> BTreeSet<FsRight> {
        rs.iter().copied().filter(|r| handled.contains(r)).collect()
    };
    let write: BTreeSet<FsRight> = handled
        .iter()
        .copied()
        .filter(|r| {
            !READ_RIGHTS.contains(r)
                && !matches!(
                    r,
                    FsRight::ResolveUnix | FsRight::MakeChar | FsRight::MakeBlock
                )
        })
        .collect();
    let mut rules: BTreeMap<PathBuf, BTreeSet<FsRight>> = BTreeMap::new();
    let mut grant = |paths: &[PathBuf], rights: &BTreeSet<FsRight>| {
        if rights.is_empty() {
            return;
        }
        for p in paths {
            rules.entry(p.clone()).or_default().extend(rights);
        }
    };
    grant(&plan.read_roots, &only(&READ_RIGHTS));
    grant(&plan.write_roots, &write);
    grant(&plan.dev_write_files, &only(&[FsRight::WriteFile]));
    grant(&plan.unix_connect_roots, &only(&[FsRight::ResolveUnix]));
    let mut handled_net = vec![];
    let mut net = |ports: &Option<Vec<u16>>, right: NetRight| -> Vec<u16> {
        match ports {
            Some(ports) if abi >= 4 => {
                handled_net.push(right);
                let mut ports = ports.clone();
                ports.sort_unstable();
                ports.dedup();
                ports
            }
            _ => vec![],
        }
    };
    let tcp_bind_ports = net(&plan.tcp_bind_ports, NetRight::BindTcp);
    let tcp_connect_ports = net(&plan.tcp_connect_ports, NetRight::ConnectTcp);
    let scoped = if abi >= 6 {
        vec![ScopeRight::AbstractUnixSocket, ScopeRight::Signal]
    } else {
        vec![]
    };
    RulesetDesc {
        abi,
        handled_fs: handled.into_iter().collect(),
        handled_net,
        scoped,
        path_rules: rules
            .into_iter()
            .map(|(path, allow)| PathRule {
                path,
                allow: allow.into_iter().collect(),
            })
            .collect(),
        tcp_connect_ports,
        tcp_bind_ports,
    }
}

/// The ABI a run gets: the kernel's, lowered by the test hook's cap, and never above [`LANDLOCK_ABI_MAX`].
pub fn effective_abi(kernel: u8, abi_cap: Option<u8>) -> u8 {
    kernel.min(abi_cap.unwrap_or(u8::MAX)).min(LANDLOCK_ABI_MAX)
}

/// The floor: the effective ABI for `kernel` and `abi_cap`, or a refusal when it is below the plan's `min_abi` or
/// its tier's floor (pure; [`restrict`] calls it before anything is restricted).
pub fn gate(plan: &LandlockPlan, kernel: u8, abi_cap: Option<u8>) -> Result<u8, LandlockError> {
    let need = plan.min_abi.max(plan.tier.floor());
    let effective = effective_abi(kernel, abi_cap);
    if effective < need {
        return Err(LandlockError::BelowFloor {
            need,
            effective,
            kernel,
        });
    }
    Ok(effective)
}

/// The running kernel's Landlock ABI: 0 when Landlock is off or not built (or not Linux).
// Linux only: Landlock is a Linux LSM. Android: no backend; apps get no user namespaces; fails closed (0).
#[cfg(target_os = "linux")]
pub fn kernel_abi() -> u8 {
    linux::kernel_abi()
}

/// The running kernel's Landlock ABI: always 0 here.
// Not Linux (Android among them: no backend; fails closed).
#[cfg(not(target_os = "linux"))]
pub fn kernel_abi() -> u8 {
    0
}

/// Apply `plan` to the calling thread (and what it execs), for the effective ABI, as a hard requirement.
/// `abi_cap` comes only from `InnerSpec.abi_cap` (the `test-hooks` feature); it is `None` otherwise.
///
/// The floor is checked first, so a refusal restricts nothing. Each rule's path is opened without following any
/// link; one that is missing or a link is skipped (a skipped grant only narrows), and any other open error refuses.
// Linux only. Android: no backend; apps get no user namespaces; fails closed.
#[cfg(target_os = "linux")]
pub fn restrict(plan: &LandlockPlan, abi_cap: Option<u8>) -> Result<Applied, LandlockError> {
    let abi = gate(plan, kernel_abi(), abi_cap)?;
    linux::apply(&rules_for_abi(plan, abi))?;
    Ok(Applied { abi })
}

/// Not Linux: always [`LandlockError::Unsupported`].
// Android among them: no backend; apps get no user namespaces; fails closed.
#[cfg(not(target_os = "linux"))]
pub fn restrict(plan: &LandlockPlan, abi_cap: Option<u8>) -> Result<Applied, LandlockError> {
    let _ = (plan, abi_cap);
    Err(LandlockError::Unsupported)
}

/// One more layer on the calling thread: `bind_tcp` handled with no port allowed, so nothing it execs can bind a TCP
/// port. The inner helper adds it after the relay has bound its ports under the first layer, when the plan has
/// `tcp_bind_ports` (the reduced tier). Layers only ever narrow; a hard requirement (ABI ≥ 4).
// Linux only. Android: no backend; apps get no user namespaces; fails closed.
#[cfg(target_os = "linux")]
pub fn forbid_tcp_bind() -> Result<(), LandlockError> {
    linux::forbid_tcp_bind()
}

/// Not Linux: always [`LandlockError::Unsupported`].
// Android among them: no backend; apps get no user namespaces; fails closed.
#[cfg(not(target_os = "linux"))]
pub fn forbid_tcp_bind() -> Result<(), LandlockError> {
    Err(LandlockError::Unsupported)
}

// Linux only: the `landlock` crate is a Linux-only dependency. Android: no backend; fails closed.
#[cfg(target_os = "linux")]
mod linux {
    use super::{FsRight, LandlockError, NetRight, RulesetDesc, ScopeRight};
    use ::landlock::{
        AccessFs, AccessNet, BitFlags, CompatLevel, Compatible, NetPort, PathBeneath, Ruleset,
        RulesetAttr, RulesetCreatedAttr, RulesetError, RulesetStatus, Scope,
    };
    use rustix::fs::{FileType, Mode, OFlags, ResolveFlags};
    use rustix::io::Errno;
    use std::os::fd::OwnedFd;
    use std::path::Path;

    /// The rights that apply to a file that is not a directory (the kernel refuses the others there).
    const FILE_RIGHTS: [FsRight; 6] = [
        FsRight::Execute,
        FsRight::WriteFile,
        FsRight::ReadFile,
        FsRight::Truncate,
        FsRight::IoctlDev,
        FsRight::ResolveUnix,
    ];

    pub(super) fn access_fs(r: FsRight) -> BitFlags<AccessFs> {
        BitFlags::from_flag(match r {
            FsRight::Execute => AccessFs::Execute,
            FsRight::WriteFile => AccessFs::WriteFile,
            FsRight::ReadFile => AccessFs::ReadFile,
            FsRight::ReadDir => AccessFs::ReadDir,
            FsRight::RemoveDir => AccessFs::RemoveDir,
            FsRight::RemoveFile => AccessFs::RemoveFile,
            FsRight::MakeChar => AccessFs::MakeChar,
            FsRight::MakeDir => AccessFs::MakeDir,
            FsRight::MakeReg => AccessFs::MakeReg,
            FsRight::MakeSock => AccessFs::MakeSock,
            FsRight::MakeFifo => AccessFs::MakeFifo,
            FsRight::MakeBlock => AccessFs::MakeBlock,
            FsRight::MakeSym => AccessFs::MakeSym,
            FsRight::Refer => AccessFs::Refer,
            FsRight::Truncate => AccessFs::Truncate,
            FsRight::IoctlDev => AccessFs::IoctlDev,
            FsRight::ResolveUnix => AccessFs::ResolveUnix,
        })
    }

    fn fs_bits<'a>(rights: impl IntoIterator<Item = &'a FsRight>) -> BitFlags<AccessFs> {
        rights
            .into_iter()
            .fold(BitFlags::EMPTY, |a, r| a | access_fs(*r))
    }

    pub(super) fn kernel_abi() -> u8 {
        const LANDLOCK_CREATE_RULESET_VERSION: libc::c_uint = 1;
        // SAFETY: landlock_create_ruleset(NULL, 0, VERSION) reads no memory and only returns the ABI or an error.
        let v = unsafe {
            libc::syscall(
                libc::SYS_landlock_create_ruleset,
                std::ptr::null::<libc::c_void>(),
                0usize,
                LANDLOCK_CREATE_RULESET_VERSION,
            )
        };
        if v <= 0 {
            0
        } else {
            u8::try_from(v).unwrap_or(u8::MAX)
        }
    }

    fn ruleset_err(e: RulesetError) -> LandlockError {
        LandlockError::Ruleset(e.to_string())
    }

    /// `path` as an `O_PATH` fd, with no link followed anywhere in it. `None`: missing or a link (skipped).
    fn open_no_links(path: &Path) -> Result<Option<OwnedFd>, LandlockError> {
        match rustix::fs::openat2(
            rustix::fs::CWD,
            path,
            OFlags::PATH | OFlags::CLOEXEC,
            Mode::empty(),
            ResolveFlags::NO_SYMLINKS | ResolveFlags::NO_MAGICLINKS,
        ) {
            Ok(fd) => Ok(Some(fd)),
            Err(Errno::NOENT | Errno::LOOP | Errno::NOTDIR) => Ok(None),
            Err(e) => Err(LandlockError::Open {
                path: path.to_owned(),
                errno: e.raw_os_error(),
            }),
        }
    }

    /// Apply `desc` to the calling thread with `CompatLevel::HardRequirement`: `desc` asks only for rights its ABI
    /// has, so on a correct kernel the compat level decides nothing; it is the backstop (review S3).
    pub(super) fn apply(desc: &RulesetDesc) -> Result<(), LandlockError> {
        let mut ruleset = Ruleset::default()
            .set_compatibility(CompatLevel::HardRequirement)
            .handle_access(fs_bits(&desc.handled_fs))
            .map_err(ruleset_err)?;
        if desc.handled_net.contains(&NetRight::ConnectTcp) {
            ruleset = ruleset
                .handle_access(AccessNet::ConnectTcp)
                .map_err(ruleset_err)?;
        }
        if desc.handled_net.contains(&NetRight::BindTcp) {
            ruleset = ruleset
                .handle_access(AccessNet::BindTcp)
                .map_err(ruleset_err)?;
        }
        if !desc.scoped.is_empty() {
            let scopes = desc.scoped.iter().fold(BitFlags::<Scope>::EMPTY, |a, s| {
                a | match s {
                    ScopeRight::AbstractUnixSocket => Scope::AbstractUnixSocket,
                    ScopeRight::Signal => Scope::Signal,
                }
            });
            ruleset = ruleset.scope(scopes).map_err(ruleset_err)?;
        }
        let mut created = ruleset.create().map_err(ruleset_err)?;
        for rule in &desc.path_rules {
            let Some(fd) = open_no_links(&rule.path)? else {
                continue;
            };
            let is_dir = rustix::fs::fstat(&fd)
                .map(|st| FileType::from_raw_mode(st.st_mode).is_dir())
                .map_err(|e| LandlockError::Open {
                    path: rule.path.clone(),
                    errno: e.raw_os_error(),
                })?;
            let allow: Vec<&FsRight> = rule
                .allow
                .iter()
                .filter(|r| is_dir || FILE_RIGHTS.contains(r))
                .collect();
            if allow.is_empty() {
                continue;
            }
            created = created
                .add_rule(PathBeneath::new(fd, fs_bits(allow)))
                .map_err(ruleset_err)?;
        }
        for port in &desc.tcp_connect_ports {
            created = created
                .add_rule(NetPort::new(*port, AccessNet::ConnectTcp))
                .map_err(ruleset_err)?;
        }
        for port in &desc.tcp_bind_ports {
            created = created
                .add_rule(NetPort::new(*port, AccessNet::BindTcp))
                .map_err(ruleset_err)?;
        }
        enforced(created.restrict_self().map_err(ruleset_err)?.ruleset)
    }

    fn enforced(status: RulesetStatus) -> Result<(), LandlockError> {
        if status != RulesetStatus::FullyEnforced {
            return Err(LandlockError::Ruleset(format!(
                "not fully enforced ({status:?})"
            )));
        }
        Ok(())
    }

    /// A layer that handles `bind_tcp` and allows no port, and scopes signals and abstract sockets to itself: the
    /// relay, started under the first layer, is outside it, so the program can neither kill the relay (and free its
    /// port for another user) nor reach its sockets (gate review M12).
    pub(super) fn forbid_tcp_bind() -> Result<(), LandlockError> {
        let created = Ruleset::default()
            .set_compatibility(CompatLevel::HardRequirement)
            .handle_access(AccessNet::BindTcp)
            .map_err(ruleset_err)?
            .scope(Scope::Signal | Scope::AbstractUnixSocket)
            .map_err(ruleset_err)?
            .create()
            .map_err(ruleset_err)?;
        enforced(created.restrict_self().map_err(ruleset_err)?.ruleset)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::{Bind, Layers, RelayPort, Spec, Target};
    use std::fmt::Write as _;
    use std::path::Path;

    fn bind(mode: Mode, source: &str, dest: &str) -> Bind {
        Bind {
            mode,
            source: source.into(),
            dest: dest.into(),
        }
    }

    /// The one fixture spec of the goldens. Under the full tier the home and the extra bind are seen elsewhere.
    fn fixture(net: Net) -> Spec {
        Spec {
            read: vec!["/srv/docs".into()],
            write: vec!["/work/task".into()],
            hide: vec!["/work/task/.env".into()],
            sockets: vec!["/rt/s/S1/proxy.sock".into()],
            binds: vec![
                bind(Mode::Ro, "/work/lib", "/mnt/lib"),
                bind(Mode::Rw, "/work/out", "/mnt/out"),
            ],
            home: Some(bind(Mode::Rw, "/state/home-1", "/home/agent")),
            run: Some(bind(Mode::Ro, "/rt/s/S1", "/run/drgnx")),
            env: vec![("PATH".into(), "/usr/bin".into())],
            chdir: "/work/task".into(),
            net,
            tmp: Some("/state/tmp-1".into()),
            layers: Layers::for_target(Target::LinuxBwrap),
            extra_tcp_ports: vec![8080, 3128],
        }
    }

    fn isolated() -> Net {
        Net::Isolated {
            relay: vec![
                RelayPort {
                    port: 3129,
                    socket: "/run/drgnx/relay-b.sock".into(),
                },
                RelayPort {
                    port: 3128,
                    socket: "/run/drgnx/proxy.sock".into(),
                },
            ],
            mac_tcp_ports: vec![],
        }
    }

    fn plan(spec: Spec, target: Target, tier: Tier) -> LandlockPlan {
        plan_for(&ValidSpec::assume_valid(spec, target), tier)
    }

    fn paths(v: &[&str]) -> Vec<PathBuf> {
        v.iter().map(PathBuf::from).collect()
    }

    fn rights_at<'a>(desc: &'a RulesetDesc, path: &str) -> &'a [FsRight] {
        desc.path_rules
            .iter()
            .find(|r| r.path == Path::new(path))
            .map(|r| r.allow.as_slice())
            .unwrap_or(&[])
    }

    fn names<T: Serialize>(v: &[T]) -> String {
        let s: Vec<String> = v
            .iter()
            .map(|x| {
                serde_json::to_value(x)
                    .unwrap()
                    .as_str()
                    .unwrap()
                    .to_owned()
            })
            .collect();
        if s.is_empty() {
            "-".into()
        } else {
            s.join(" ")
        }
    }

    /// The golden's text: the plan, then each ABI's handled rights and rules.
    fn render(plan: &LandlockPlan) -> String {
        let mut out = String::new();
        let ps = |v: &[PathBuf]| -> String {
            v.iter()
                .map(|p| p.display().to_string())
                .collect::<Vec<_>>()
                .join(" ")
        };
        writeln!(out, "tier {:?}, min_abi {}", plan.tier, plan.min_abi).unwrap();
        writeln!(out, "read_roots: {}", ps(&plan.read_roots)).unwrap();
        writeln!(out, "write_roots: {}", ps(&plan.write_roots)).unwrap();
        writeln!(out, "dev_write_files: {}", ps(&plan.dev_write_files)).unwrap();
        writeln!(out, "unix_connect_roots: {}", ps(&plan.unix_connect_roots)).unwrap();
        writeln!(out, "tcp_connect_ports: {:?}", plan.tcp_connect_ports).unwrap();
        // Only plans that handle binds show them, so the full tier's goldens stay as Task 5 made them.
        if plan.tcp_bind_ports.is_some() {
            writeln!(out, "tcp_bind_ports: {:?}", plan.tcp_bind_ports).unwrap();
        }
        for abi in 1..=9 {
            let d = rules_for_abi(plan, abi);
            writeln!(out, "\n== ABI {abi}").unwrap();
            writeln!(out, "handled fs: {}", names(&d.handled_fs)).unwrap();
            writeln!(out, "handled net: {}", names(&d.handled_net)).unwrap();
            writeln!(out, "scoped: {}", names(&d.scoped)).unwrap();
            writeln!(out, "tcp ports: {:?}", d.tcp_connect_ports).unwrap();
            if plan.tcp_bind_ports.is_some() {
                writeln!(out, "tcp bind ports: {:?}", d.tcp_bind_ports).unwrap();
            }
            for r in &d.path_rules {
                writeln!(out, "{}: {}", r.path.display(), names(&r.allow)).unwrap();
            }
        }
        out
    }

    #[test]
    fn rules_per_abi_golden() {
        let full_shared = plan(fixture(Net::Shared), Target::LinuxBwrap, Tier::Full);
        insta::assert_snapshot!("rules_per_abi_full_shared", render(&full_shared));
        let full_isolated = plan(fixture(isolated()), Target::LinuxBwrap, Tier::Full);
        insta::assert_snapshot!("rules_per_abi_full_isolated", render(&full_isolated));
        let reduced = plan(reduced_spec(), Target::LinuxReduced, Tier::Reduced);
        insta::assert_snapshot!("rules_per_abi_reduced", render(&reduced));
    }

    fn sorted(mut v: Vec<PathBuf>) -> Vec<PathBuf> {
        v.sort();
        v.dedup();
        v
    }

    /// Every ABI asks only for rights it has, handles every fs right it has except `ioctl_dev`, and an ABI above
    /// the crate's last gets the last's set: nothing is silently dropped or asked of a kernel that lacks it.
    #[test]
    fn rules_fit_the_abi() {
        let p = plan(fixture(isolated()), Target::LinuxBwrap, Tier::Full);
        for abi in 1..=9u8 {
            let d = rules_for_abi(&p, abi);
            assert_eq!(d.abi, abi);
            let want: Vec<FsRight> = FsRight::ALL
                .into_iter()
                .filter(|r| r.since() <= abi && *r != FsRight::IoctlDev)
                .collect();
            assert_eq!(d.handled_fs, want, "abi {abi}");
            for r in &d.path_rules {
                assert!(
                    !r.allow.is_empty(),
                    "abi {abi}: empty rule at {}",
                    r.path.display()
                );
                for a in &r.allow {
                    assert!(
                        d.handled_fs.contains(a),
                        "abi {abi}: {a:?} allowed but not handled"
                    );
                }
            }
            assert_eq!(d.handled_net.is_empty(), abi < 4, "abi {abi}");
            assert_eq!(d.scoped.is_empty(), abi < 6, "abi {abi}");
        }
        for abi in [10, 11, 255] {
            assert_eq!(rules_for_abi(&p, abi), rules_for_abi(&p, 9), "abi {abi}");
        }
    }

    #[test]
    fn isolated_tcp_only_relay_ports() {
        let p = plan(fixture(isolated()), Target::LinuxBwrap, Tier::Full);
        assert_eq!(p.tcp_connect_ports, Some(vec![3128, 3129, 8080]));
        let d = rules_for_abi(&p, 4);
        assert_eq!(d.handled_net, vec![NetRight::ConnectTcp]);
        assert_eq!(d.tcp_connect_ports, vec![3128, 3129, 8080]);
        // Below ABI 4 there is no TCP right; isolation is the network namespace, never Landlock.
        let d3 = rules_for_abi(&p, 3);
        assert!(d3.handled_net.is_empty() && d3.tcp_connect_ports.is_empty());
    }

    #[test]
    fn shared_net_handles_no_tcp() {
        let p = plan(fixture(Net::Shared), Target::LinuxBwrap, Tier::Full);
        assert_eq!(p.tcp_connect_ports, None);
        for abi in 1..=9 {
            let d = rules_for_abi(&p, abi);
            assert!(d.handled_net.is_empty(), "abi {abi}");
            assert!(d.tcp_connect_ports.is_empty(), "abi {abi}");
        }
        assert_eq!(p.tcp_bind_ports, None, "the full tier never handles binds");
    }

    /// The reduced tier is not network-open (the manager's call on Task 5): TCP connects and binds only on the relay's
    /// ports, never `extra_tcp_ports`; `Net::Shared` gets no TCP at all.
    #[test]
    fn reduced_tcp_only_relay_ports_and_binds_handled() {
        let mut red = reduced_spec();
        red.net = isolated();
        let p = plan(red, Target::LinuxReduced, Tier::Reduced);
        assert_eq!(p.tcp_connect_ports, Some(vec![3128, 3129]));
        assert_eq!(p.tcp_bind_ports, Some(vec![3128, 3129]));
        let d = rules_for_abi(&p, 9);
        assert_eq!(d.handled_net, vec![NetRight::BindTcp, NetRight::ConnectTcp]);
        assert_eq!(d.tcp_connect_ports, vec![3128, 3129]);
        assert_eq!(d.tcp_bind_ports, vec![3128, 3129]);
        let shared = plan(reduced_spec(), Target::LinuxReduced, Tier::Reduced);
        assert_eq!(shared.tcp_connect_ports, Some(vec![]));
        assert_eq!(shared.tcp_bind_ports, Some(vec![]));
        let d = rules_for_abi(&shared, 9);
        assert_eq!(d.handled_net, vec![NetRight::BindTcp, NetRight::ConnectTcp]);
        assert!(d.tcp_connect_ports.is_empty() && d.tcp_bind_ports.is_empty());
    }

    #[test]
    fn full_roots_are_the_inside_paths() {
        let mut s = fixture(Net::Shared);
        s.binds.push(bind(Mode::Rw, "/work/out2", "/mnt/out2"));
        let p = plan(s, Target::LinuxBwrap, Tier::Full);
        assert_eq!(p.tier, Tier::Full);
        assert_eq!(p.min_abi, 6, "a shared network needs ABI 6");
        assert_eq!(p.read_roots, paths(&["/"]));
        assert_eq!(
            p.write_roots,
            paths(&[
                "/dev/pts",
                "/dev/shm",
                "/home/agent",
                "/mnt/out",
                "/mnt/out2",
                "/tmp",
                "/var/tmp",
                "/work/task"
            ])
        );
        assert_eq!(p.dev_write_files, sorted(paths(FULL_DEV_WRITE)));
        assert_eq!(p.unix_connect_roots, paths(&["/run/drgnx"]));
        // A home given read-only is not written (least privilege; Task 0's note).
        let mut ro = fixture(Net::Shared);
        ro.home.as_mut().unwrap().mode = Mode::Ro;
        let p = plan(ro, Target::LinuxBwrap, Tier::Full);
        assert!(!p.write_roots.contains(&"/home/agent".into()));
    }

    /// Review S3: the full tier under a shared network shares the host's abstract sockets, which only ABI 6 scopes,
    /// so its plan needs 6 whatever the spec says; isolated keeps the floor (1) and a higher spec minimum is kept.
    #[test]
    fn full_shared_net_needs_abi_6() {
        assert_eq!(LANDLOCK_FLOOR_SHARED_NET, 6);
        let shared = plan(fixture(Net::Shared), Target::LinuxBwrap, Tier::Full);
        assert_eq!(shared.min_abi, 6);
        assert_eq!(
            gate(&shared, 9, Some(5)),
            Err(LandlockError::BelowFloor {
                need: 6,
                effective: 5,
                kernel: 9
            })
        );
        assert_eq!(gate(&shared, 9, Some(6)), Ok(6));
        assert_eq!(
            plan(fixture(isolated()), Target::LinuxBwrap, Tier::Full).min_abi,
            1
        );
        let mut high = fixture(Net::Shared);
        high.layers.landlock_min_abi = 8;
        assert_eq!(plan(high, Target::LinuxBwrap, Tier::Full).min_abi, 8);
        // The reduced tier's own floor (9) is above it either way.
        assert_eq!(
            plan(reduced_spec(), Target::LinuxReduced, Tier::Reduced).min_abi,
            9
        );
    }

    fn reduced_spec() -> Spec {
        let mut s = fixture(Net::Shared);
        s.layers = Layers::for_target(Target::LinuxReduced);
        for b in s.binds.iter_mut().chain(&mut s.home).chain(&mut s.run) {
            b.dest = b.source.clone();
        }
        s
    }

    #[test]
    fn reduced_reads_only_named_roots() {
        let p = plan(reduced_spec(), Target::LinuxReduced, Tier::Reduced);
        let mut want = paths(REDUCED_SYSTEM_ROOTS);
        want.extend(paths(REDUCED_DEV_READ));
        want.extend(paths(&[
            "/srv/docs",
            "/work/task",
            "/work/lib",
            "/work/out",
            "/state/home-1",
            "/rt/s/S1",
            "/state/tmp-1",
        ]));
        assert_eq!(p.read_roots, sorted(want));
        assert!(!p.read_roots.contains(&"/".into()));
        let d = rules_for_abi(&p, 9);
        assert!(rights_at(&d, "/").is_empty());
        assert!(rights_at(&d, "/home").is_empty());
        assert!(rights_at(&d, "/run").is_empty());
        assert_eq!(
            rights_at(&d, "/usr"),
            [FsRight::Execute, FsRight::ReadFile, FsRight::ReadDir]
        );
    }

    /// Without a mount namespace the host's /tmp, /var/tmp and /dev/shm are the user's own (review B1).
    #[test]
    fn reduced_never_writes_host_tmp() {
        let p = plan(reduced_spec(), Target::LinuxReduced, Tier::Reduced);
        assert_eq!(
            p.write_roots,
            paths(&["/state/home-1", "/state/tmp-1", "/work/out", "/work/task"])
        );
        assert_eq!(p.dev_write_files, sorted(paths(REDUCED_DEV_WRITE)));
        for abi in 1..=9 {
            let d = rules_for_abi(&p, abi);
            for host in [
                "/tmp",
                "/var/tmp",
                "/dev/shm",
                "/dev/pts",
                "/dev/tty",
                "/dev/ptmx",
                "/",
            ] {
                let r = rights_at(&d, host);
                assert!(
                    !r.iter().any(|a| !matches!(
                        a,
                        FsRight::Execute | FsRight::ReadFile | FsRight::ReadDir
                    )),
                    "abi {abi}: {host} gets {r:?}"
                );
            }
        }
        // The reduced plan's min_abi is the floor even when the spec says less.
        let mut low = reduced_spec();
        low.layers.landlock_min_abi = 6;
        assert_eq!(plan(low, Target::LinuxReduced, Tier::Reduced).min_abi, 9);
    }

    /// Only the run source may be connected to: not the home, not a write root, not the host's sockets.
    #[test]
    fn reduced_unix_only_the_run_source() {
        let p = plan(reduced_spec(), Target::LinuxReduced, Tier::Reduced);
        assert_eq!(p.unix_connect_roots, paths(&["/rt/s/S1"]));
        let d = rules_for_abi(&p, 9);
        assert!(d.handled_fs.contains(&FsRight::ResolveUnix));
        let with: Vec<&Path> = d
            .path_rules
            .iter()
            .filter(|r| r.allow.contains(&FsRight::ResolveUnix))
            .map(|r| r.path.as_path())
            .collect();
        assert_eq!(with, [Path::new("/rt/s/S1")]);
        // Below 9 the right does not exist; the reduced tier never runs there (gate).
        assert!(
            !rules_for_abi(&p, 8)
                .handled_fs
                .contains(&FsRight::ResolveUnix)
        );
    }

    /// Write roots get every write right except device nodes; never `resolve_unix`, never `ioctl_dev`.
    #[test]
    fn write_roots_get_write_rights_only() {
        let p = plan(fixture(Net::Shared), Target::LinuxBwrap, Tier::Full);
        let d = rules_for_abi(&p, 9);
        let w = rights_at(&d, "/work/task");
        use FsRight::*;
        assert_eq!(
            w,
            [
                WriteFile, RemoveDir, RemoveFile, MakeDir, MakeReg, MakeSock, MakeFifo, MakeSym,
                Refer, Truncate
            ]
        );
        assert_eq!(rights_at(&d, "/dev/null"), [WriteFile]);
        assert_eq!(rights_at(&d, "/"), [Execute, ReadFile, ReadDir]);
        assert_eq!(rights_at(&d, "/run/drgnx"), [ResolveUnix]);
        let d1 = rules_for_abi(&p, 1);
        assert_eq!(
            rights_at(&d1, "/work/task"),
            [
                WriteFile, RemoveDir, RemoveFile, MakeDir, MakeReg, MakeSock, MakeFifo, MakeSym
            ]
        );
        assert!(
            rights_at(&d1, "/run/drgnx").is_empty(),
            "no rule without a right"
        );
    }

    fn bare(tier: Tier, min_abi: u8) -> LandlockPlan {
        LandlockPlan {
            tier,
            min_abi,
            read_roots: vec![],
            write_roots: vec![],
            dev_write_files: vec![],
            unix_connect_roots: vec![],
            tcp_connect_ports: None,
            tcp_bind_ports: None,
        }
    }

    /// The floor, as a table: the kernel's ABI, the cap, the plan's minimum and the tier's floor.
    #[test]
    fn floor_gate_table() {
        use Tier::*;
        /// tier, min_abi, kernel, cap, Some(effective) or None (refused)
        type Row = (Tier, u8, u8, Option<u8>, Option<u8>);
        let rows: &[Row] = &[
            (Full, 1, 0, None, None),
            (Full, 1, 1, None, Some(1)),
            (Full, 1, 10, None, Some(9)),
            (Full, 1, 10, Some(3), Some(3)),
            (Full, 1, 10, Some(0), None),
            (Full, 4, 3, None, None),
            (Full, 99, 10, None, None),
            (Full, 0, 0, None, None),
            (Reduced, 9, 8, None, None),
            (Reduced, 9, 9, None, Some(9)),
            (Reduced, 9, 10, None, Some(9)),
            (Reduced, 9, 10, Some(8), None),
            (Reduced, 9, 10, Some(6), None),
            // A plan that says less than its tier's floor is held to the floor.
            (Reduced, 6, 8, None, None),
            (Reduced, 1, 7, None, None),
        ];
        for &(tier, min, kernel, cap, want) in rows {
            let got = gate(&bare(tier, min), kernel, cap);
            match want {
                Some(abi) => assert_eq!(
                    got,
                    Ok(abi),
                    "{tier:?} min {min} kernel {kernel} cap {cap:?}"
                ),
                None => assert!(
                    matches!(got, Err(LandlockError::BelowFloor { .. })),
                    "{tier:?} min {min} kernel {kernel} cap {cap:?}: {got:?}"
                ),
            }
        }
        assert_eq!(effective_abi(10, None), 9);
        assert_eq!(effective_abi(7, Some(9)), 7);
        assert_eq!(effective_abi(9, Some(2)), 2);
        let e = gate(&bare(Reduced, 9), 10, Some(8))
            .unwrap_err()
            .to_string();
        assert!(e.contains("Landlock ABI 8") && e.contains("9"), "{e}");
    }

    #[test]
    fn plan_wire_form_refuses_unknown_fields() {
        let p = plan(fixture(isolated()), Target::LinuxBwrap, Tier::Full);
        let mut v = serde_json::to_value(&p).unwrap();
        assert_eq!(
            serde_json::from_value::<LandlockPlan>(v.clone()).unwrap(),
            p
        );
        v["allow_all"] = serde_json::json!(true);
        assert!(serde_json::from_value::<LandlockPlan>(v).is_err());
    }

    /// The handled set equals the crate's `AccessFs::from_all` for that ABI, minus `IoctlDev`.
    #[cfg(target_os = "linux")]
    #[test]
    fn handled_matches_the_crate_per_abi() {
        use ::landlock::{ABI, Access, AccessFs};
        let p = bare(Tier::Full, 1);
        for abi in 1..=9u8 {
            let d = rules_for_abi(&p, abi);
            let ours = d
                .handled_fs
                .iter()
                .fold(::landlock::BitFlags::<AccessFs>::EMPTY, |a, r| {
                    a | linux::access_fs(*r)
                });
            let theirs = AccessFs::from_all(ABI::from(i32::from(abi))) & !AccessFs::IoctlDev;
            assert_eq!(ours, theirs, "abi {abi}");
        }
        for r in FsRight::ALL {
            assert_eq!(linux::access_fs(r).bits().count_ones(), 1, "{r:?}");
        }
    }

    // ---- Real tests: each runs in a re-exec'd child of this test binary, since Landlock cannot be undone.

    const CHILD: &str = "GLEIPNIR_LANDLOCK_TEST_CHILD";

    /// In the parent: run this test again in a child (skipped with the reason when the kernel's ABI is below
    /// `need`) and require that exactly that one test passed there. In the child: run `body`.
    fn in_child(name: &str, need: u8, env: &[(&str, String)], body: impl FnOnce()) {
        if std::env::var_os(CHILD).is_some() {
            body();
            return;
        }
        let k = kernel_abi();
        if k < need.max(1) {
            eprintln!(
                "SKIP {name}: the kernel's Landlock ABI is {k}, this needs {}",
                need.max(1)
            );
            return;
        }
        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                &format!("landlock::tests::{name}"),
                "--exact",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(CHILD, "1")
            .envs(env.iter().map(|(k, v)| (*k, v)))
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            out.status.success() && stdout.contains("test result: ok. 1 passed"),
            "child {name}: {:?}\n{stdout}\n{stderr}",
            out.status
        );
    }

    fn fixture_dir() -> tempfile::TempDir {
        tempfile::Builder::new()
            .prefix("glp-")
            .tempdir_in("/tmp")
            .unwrap()
    }

    fn errno<T: fmt::Debug>(r: std::io::Result<T>) -> Option<i32> {
        r.err().and_then(|e| e.raw_os_error())
    }

    /// A plan with read on "/" and write on `writable` only.
    fn write_plan(min_abi: u8, writable: &Path) -> LandlockPlan {
        LandlockPlan {
            read_roots: vec!["/".into()],
            write_roots: vec![writable.to_owned()],
            ..bare(Tier::Full, min_abi)
        }
    }

    /// A reduced plan for a spec rooted in `dir`: write `dir/w`, tmp `dir/t`, run `dir/run`.
    fn reduced_plan_in(dir: &Path) -> LandlockPlan {
        reduced_plan_net(dir, Net::Shared)
    }

    fn reduced_plan_net(dir: &Path, net: Net) -> LandlockPlan {
        for d in ["w", "t", "run", "out"] {
            std::fs::create_dir(dir.join(d)).unwrap();
        }
        let p = |s: &str| dir.join(s);
        let run = p("run");
        let spec = Spec {
            read: vec![],
            write: vec![p("w")],
            hide: vec![],
            sockets: vec![],
            binds: vec![],
            home: None,
            run: Some(Bind {
                mode: Mode::Ro,
                source: run.clone(),
                dest: run,
            }),
            env: vec![],
            chdir: p("w"),
            net,
            tmp: Some(p("t")),
            layers: Layers::for_target(Target::LinuxReduced),
            extra_tcp_ports: vec![],
        };
        plan(spec, Target::LinuxReduced, Tier::Reduced)
    }

    #[test]
    fn writes_outside_roots_denied() {
        in_child("writes_outside_roots_denied", 1, &[], || {
            let dir = fixture_dir();
            let (inside, outside) = (dir.path().join("in"), dir.path().join("out"));
            std::fs::create_dir(&inside).unwrap();
            std::fs::create_dir(&outside).unwrap();
            restrict(&write_plan(1, &inside), None).unwrap();
            assert_eq!(
                errno(std::fs::write(outside.join("f"), "x")),
                Some(libc::EACCES)
            );
            assert_eq!(
                errno(std::fs::create_dir(outside.join("d"))),
                Some(libc::EACCES)
            );
        });
    }

    #[test]
    fn writes_inside_allowed() {
        in_child("writes_inside_allowed", 1, &[], || {
            let dir = fixture_dir();
            let inside = dir.path().join("in");
            std::fs::create_dir(&inside).unwrap();
            let applied = restrict(&write_plan(1, &inside), None).unwrap();
            assert_eq!(applied.abi, effective_abi(kernel_abi(), None));
            std::fs::write(inside.join("f"), "x").unwrap();
            std::fs::create_dir(inside.join("d")).unwrap();
            std::fs::rename(inside.join("f"), inside.join("d/g")).unwrap();
            std::fs::remove_file(inside.join("d/g")).unwrap();
        });
    }

    /// The floor refuses before anything is restricted: a write outside the plan still works after the `Err`.
    #[test]
    fn below_min_abi_refused() {
        in_child("below_min_abi_refused", 1, &[], || {
            let dir = fixture_dir();
            let inside = dir.path().join("in");
            std::fs::create_dir(&inside).unwrap();
            let err = restrict(&write_plan(99, &inside), None).unwrap_err();
            assert!(
                matches!(err, LandlockError::BelowFloor { need: 99, .. }),
                "{err:?}"
            );
            std::fs::write(dir.path().join("outside"), "x").expect("nothing was restricted");
        });
    }

    /// A reduced plan with the ABI capped at 8 (the escape rows' hook) is refused: the reduced floor is 9.
    #[test]
    fn below_floor_by_cap_refused() {
        in_child("below_floor_by_cap_refused", 1, &[], || {
            let dir = fixture_dir();
            let p = reduced_plan_in(dir.path());
            assert_eq!(p.min_abi, 9);
            let err = restrict(&p, Some(8)).unwrap_err();
            assert!(
                matches!(err, LandlockError::BelowFloor { need: 9, effective, .. } if effective <= 8),
                "{err:?}"
            );
            std::fs::write(dir.path().join("out/f"), "x").expect("nothing was restricted");
        });
    }

    /// ABI 9: a listener in a write root (made outside the domain) is refused; one in the run source is reached.
    #[test]
    fn reduced_user_socket_denied() {
        in_child("reduced_user_socket_denied", 9, &[], || {
            use std::os::unix::net::{UnixListener, UnixStream};
            let dir = fixture_dir();
            let p = reduced_plan_in(dir.path());
            let (user, run) = (
                dir.path().join("w/user.sock"),
                dir.path().join("run/hub.sock"),
            );
            let (_l1, _l2) = (
                UnixListener::bind(&user).unwrap(),
                UnixListener::bind(&run).unwrap(),
            );
            UnixStream::connect(&user).expect("control: reachable before");
            assert_eq!(restrict(&p, None).unwrap().abi, 9);
            assert_eq!(errno(UnixStream::connect(&user)), Some(libc::EACCES));
            UnixStream::connect(&run).expect("the run source is reached");
            // The write root is still writable, and the host's /tmp is not.
            std::fs::write(dir.path().join("w/f"), "x").unwrap();
            assert_eq!(
                errno(std::fs::write(dir.path().join("out/f"), "x")),
                Some(libc::EACCES)
            );
        });
    }

    /// The reduced tier's TCP (ABI 9): a connect reaches a relay port and nothing else; a bind works only on a relay
    /// port (the relay's own, under the first layer), and after [`forbid_tcp_bind`] on none.
    #[test]
    fn reduced_tcp_relay_ports_only_then_no_bind() {
        in_child("reduced_tcp_relay_ports_only_then_no_bind", 9, &[], || {
            use std::net::{TcpListener, TcpStream};
            let dir = fixture_dir();
            let port = |l: &TcpListener| l.local_addr().unwrap().port();
            let other = TcpListener::bind("127.0.0.1:0").unwrap();
            let relay_up = TcpListener::bind("127.0.0.1:0").unwrap();
            let relay_free = port(&TcpListener::bind("127.0.0.1:0").unwrap());
            let relay = [port(&relay_up), relay_free]
                .into_iter()
                .map(|port| RelayPort {
                    port,
                    socket: dir.path().join("run/proxy.sock"),
                })
                .collect();
            let p = reduced_plan_net(
                dir.path(),
                Net::Isolated {
                    relay,
                    mac_tcp_ports: vec![],
                },
            );
            TcpStream::connect(other.local_addr().unwrap()).expect("control: reachable before");
            assert_eq!(restrict(&p, None).unwrap().abi, 9);
            assert_eq!(
                errno(TcpStream::connect(other.local_addr().unwrap())),
                Some(libc::EACCES)
            );
            TcpStream::connect(relay_up.local_addr().unwrap()).expect("a relay port is reached");
            drop(
                TcpListener::bind(("127.0.0.1", relay_free)).expect("the relay may bind its port"),
            );
            assert_eq!(errno(TcpListener::bind("127.0.0.1:0")), Some(libc::EACCES));
            // A relay stand-in, started under the first layer only, as the helper starts the relay. It holds none of
            // the test's pipes and ends by itself (this test cannot signal it once the second layer is on).
            // SAFETY: fork in a single-purpose test process; the child only calls open, dup2, prctl, sleep, _exit.
            let relay_pid = unsafe { libc::fork() };
            assert!(relay_pid >= 0);
            if relay_pid == 0 {
                // SAFETY: the forked child's own descriptors and state; it never returns into the test.
                unsafe {
                    let null = libc::open(c"/dev/null".as_ptr(), libc::O_RDWR);
                    for fd in 0..3 {
                        libc::dup2(null, fd);
                    }
                    // Linux only; elsewhere every real test skips anyway (kernel_abi() == 0).
                    #[cfg(target_os = "linux")]
                    libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);
                    libc::sleep(20);
                    libc::_exit(0);
                }
            }
            // SAFETY: kill(2) with signal 0 only asks.
            let signal = || unsafe { libc::kill(relay_pid, 0) == 0 };
            assert!(signal(), "control: the relay can be signalled before");
            forbid_tcp_bind().unwrap();
            assert_eq!(
                errno(TcpListener::bind(("127.0.0.1", relay_free))),
                Some(libc::EACCES)
            );
            TcpStream::connect(relay_up.local_addr().unwrap()).expect("connects are unchanged");
            // Gate review M12: the second layer scopes signals, so the relay is out of reach.
            assert!(!signal(), "the relay can still be signalled");
            assert_eq!(
                std::io::Error::last_os_error().raw_os_error(),
                Some(libc::EPERM)
            );
        });
    }

    /// ABI 6: an abstract socket made outside the domain is refused (EPERM).
    // Abstract sockets are Linux's (std::os::linux); elsewhere every real test skips anyway (kernel_abi() == 0).
    #[cfg(target_os = "linux")]
    #[test]
    fn abstract_socket_scoped() {
        in_child("abstract_socket_scoped", 6, &[], || {
            use std::os::linux::net::SocketAddrExt;
            use std::os::unix::net::{SocketAddr, UnixListener, UnixStream};
            let dir = fixture_dir();
            let name = format!("glp-abstract-{}", std::process::id());
            let addr = SocketAddr::from_abstract_name(name.as_bytes()).unwrap();
            let _l = UnixListener::bind_addr(&addr).unwrap();
            UnixStream::connect_addr(&addr).expect("control: reachable before");
            restrict(&write_plan(1, dir.path()), None).unwrap();
            assert_eq!(errno(UnixStream::connect_addr(&addr)), Some(libc::EPERM));
        });
    }

    /// A `sleep` the parent started, for the /proc rows; killed when dropped.
    struct Sleeper(std::process::Child);

    impl Sleeper {
        fn start() -> Sleeper {
            Sleeper(
                std::process::Command::new("sleep")
                    .arg("60")
                    .env("GLP_CANARY", "c4n4ry")
                    .spawn()
                    .unwrap(),
            )
        }
        fn pid(&self) -> String {
            self.0.id().to_string()
        }
    }

    impl Drop for Sleeper {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    /// Without a pid namespace, Landlock's ptrace scoping denies another process's `environ`.
    #[test]
    fn reduced_proc_other_environ_denied() {
        let s = (std::env::var_os(CHILD).is_none()).then(Sleeper::start);
        let env = s
            .as_ref()
            .map(|s| vec![("GLP_SLEEP_PID", s.pid())])
            .unwrap_or_default();
        in_child("reduced_proc_other_environ_denied", 9, &env, || {
            let pid = std::env::var("GLP_SLEEP_PID").unwrap();
            let environ = format!("/proc/{pid}/environ");
            let before = std::fs::read(&environ).expect("control: readable before");
            assert!(String::from_utf8_lossy(&before).contains("c4n4ry"));
            let dir = fixture_dir();
            restrict(&reduced_plan_in(dir.path()), None).unwrap();
            assert_eq!(errno(std::fs::read(&environ)), Some(libc::EACCES));
        });
    }

    /// The gap the user accepted (answer 3): the same process's `cmdline` stays readable.
    #[test]
    fn reduced_proc_other_cmdline_is_the_gap() {
        let s = (std::env::var_os(CHILD).is_none()).then(Sleeper::start);
        let env = s
            .as_ref()
            .map(|s| vec![("GLP_SLEEP_PID", s.pid())])
            .unwrap_or_default();
        in_child("reduced_proc_other_cmdline_is_the_gap", 9, &env, || {
            let pid = std::env::var("GLP_SLEEP_PID").unwrap();
            let dir = fixture_dir();
            restrict(&reduced_plan_in(dir.path()), None).unwrap();
            let cmdline =
                std::fs::read(format!("/proc/{pid}/cmdline")).expect("the gap: cmdline readable");
            assert_eq!(cmdline, b"sleep\x0060\x00");
        });
    }
}
