//! The seccomp deny-list, compiled to BPF per architecture, and its install (Task 4).
//!
//! The compiling and installing code is gated `#[cfg(target_os = "linux")]` here, with an `Unsupported` stub
//! elsewhere (Android: no backend; apps get no user namespaces; fails closed). `seccompiler` is a Linux-only
//! dependency. The policy itself ([`rules`], [`DenyRule`], [`Arch`]) is plain data and builds everywhere.
//!
//! The filter allows by default and denies a fixed list (docs/develop/gleipnir.md, "seccomp"). No spec can turn it
//! off or change it.

use std::fmt;

/// An architecture the filter is compiled for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Arch {
    X86_64,
    Aarch64,
}

impl Arch {
    /// The `AUDIT_ARCH_*` value the kernel puts in `seccomp_data.arch` for a native call.
    pub const fn audit(self) -> u32 {
        match self {
            Self::X86_64 => 0xC000_003E, // EM_X86_64 | __AUDIT_ARCH_64BIT | __AUDIT_ARCH_LE
            Self::Aarch64 => 0xC000_00B7, // EM_AARCH64 | __AUDIT_ARCH_64BIT | __AUDIT_ARCH_LE
        }
    }

    /// The number of the call `name` on this architecture, for the calls the policy names (and `getpid`).
    pub fn syscall_nr(self, name: &str) -> Option<u32> {
        let (_, x86_64, aarch64) = SYSCALLS.iter().find(|(n, _, _)| *n == name)?;
        Some(match self {
            Self::X86_64 => *x86_64,
            Self::Aarch64 => *aarch64,
        })
    }
}

/// `(name, x86_64, aarch64)`. Checked against seccompiler 0.5.0's generated tables (kernel 6.12), and the native
/// column against `libc::SYS_*` by a test. The table is per architecture, not taken from the host's libc, so both
/// filters compile (and their goldens run) on any Linux host.
const SYSCALLS: &[(&str, u32, u32)] = &[
    ("add_key", 248, 217),
    ("bpf", 321, 280),
    ("clone", 56, 220),
    ("clone3", 435, 435),
    ("fsconfig", 431, 431),
    ("fsmount", 432, 432),
    ("fsopen", 430, 430),
    ("fspick", 433, 433),
    ("getpid", 39, 172),
    ("io_uring_enter", 426, 426),
    ("io_uring_register", 427, 427),
    ("io_uring_setup", 425, 425),
    ("ioctl", 16, 29),
    ("keyctl", 250, 219),
    ("mount", 165, 40),
    ("mount_setattr", 442, 442),
    ("move_mount", 429, 429),
    ("open_tree", 428, 428),
    ("perf_event_open", 298, 241),
    ("pivot_root", 155, 41),
    ("ptrace", 101, 117),
    ("request_key", 249, 218),
    ("setns", 308, 268),
    ("socket", 41, 198),
    ("umount2", 166, 39),
    ("unshare", 272, 97),
    ("userfaultfd", 323, 282),
];

/// Linux's errno values: the filter returns Linux's numbers, whatever host compiles it.
const EPERM: i32 = 1;
const ENOSYS: i32 = 38;

// `SECCOMP_RET_*`, for the hand-written prologue (Linux only, like `compile`; Android: no backend; fails closed).
#[cfg(target_os = "linux")]
const RET_ERRNO: u32 = 0x0005_0000;
#[cfg(target_os = "linux")]
const RET_KILL_PROCESS: u32 = 0x8000_0000;

/// The architecture this process runs as, if gleipnir has a seccomp filter for it.
pub fn native() -> Option<Arch> {
    // seccomp is a Linux layer. Android: no backend; apps get no user namespaces; fails closed (None).
    if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        Some(Arch::X86_64)
    } else if cfg!(all(target_os = "linux", target_arch = "aarch64")) {
        Some(Arch::Aarch64)
    } else {
        None
    }
}

/// A condition on one argument. Both compare the argument's **low 32 bits** only (a seccomp "Dword"): the kernel
/// reads `ioctl`'s request and `socket`'s domain as 32-bit ints, so `TIOCSTI | 1 << 32` is TIOCSTI to the kernel and
/// must be TIOCSTI to the filter too; `clone`'s `CLONE_NEW*` bits all sit in the low half, and legacy `clone`
/// ignores the high half.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ArgMatch {
    /// `args[index] as u32 == value`.
    Eq { index: u8, value: u32 },
    /// `args[index] as u32 & mask == mask`.
    MaskedEq { index: u8, mask: u32 },
}

/// One entry of the deny-list: `syscall` fails with `errno` (Linux's number), when `arg` holds or always.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct DenyRule {
    pub syscall: &'static str,
    pub errno: i32,
    pub arg: Option<ArgMatch>,
}

/// One classic-BPF instruction, a plain copy of the kernel's `struct sock_filter`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SockFilter {
    pub code: u16,
    pub jt: u8,
    pub jf: u8,
    pub k: u32,
}

/// Why a filter could not be compiled or installed. Each one means the sandbox does not start (fail closed).
#[derive(Debug)]
pub enum SeccompError {
    /// Not Linux: there is no seccomp here.
    Unsupported,
    /// A rule names a call the table has no number for.
    UnknownSyscall { syscall: &'static str, arch: Arch },
    /// A rule this compiler cannot express: an errno other than EPERM with an argument condition, or an errno out of
    /// range.
    Unexpressible(DenyRule),
    /// seccompiler refused the filter.
    Compile(String),
    /// The program is longer than the kernel takes (`BPF_MAXINSNS`).
    TooLong(usize),
    /// The kernel refused the filter (`prctl` or `seccomp`).
    Install(String),
}

impl fmt::Display for SeccompError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unsupported => write!(f, "seccomp is Linux only"),
            Self::UnknownSyscall { syscall, arch } => {
                write!(f, "no {arch:?} number for the call {syscall}")
            }
            Self::Unexpressible(rule) => write!(f, "the seccomp rule {rule:?} cannot be compiled"),
            Self::Compile(why) => write!(f, "the seccomp filter does not compile: {why}"),
            Self::TooLong(n) => write!(
                f,
                "the seccomp filter has {n} instructions, more than the kernel takes"
            ),
            Self::Install(why) => write!(f, "the seccomp filter cannot be installed: {why}"),
        }
    }
}

impl std::error::Error for SeccompError {}

/// Calls denied whatever their arguments, with EPERM.
const DENIED_ALWAYS: &[&str] = &[
    // process and keys
    "ptrace",
    "keyctl",
    "add_key",
    "request_key",
    "perf_event_open",
    "bpf",
    "userfaultfd",
    // io_uring
    "io_uring_setup",
    "io_uring_enter",
    "io_uring_register",
    // namespaces and mounts, the old API and the new
    "unshare",
    "setns",
    "mount",
    "umount2",
    "pivot_root",
    "open_tree",
    "move_mount",
    "fsopen",
    "fsconfig",
    "fsmount",
    "fspick",
    "mount_setattr",
];

/// `CLONE_NEWNS`, `NEWCGROUP`, `NEWUTS`, `NEWIPC`, `NEWUSER`, `NEWPID`, `NEWNET` (together `0x7E020000`): one
/// `MaskedEq` rule each, because seccompiler has no masked-not-equal comparison.
const CLONE_NEW: [u32; 7] = [
    0x0002_0000,
    0x0200_0000,
    0x0400_0000,
    0x0800_0000,
    0x1000_0000,
    0x2000_0000,
    0x4000_0000,
];

const TIOCSTI: u32 = 0x5412;
const TIOCLINUX: u32 = 0x541C;
const AF_VSOCK: u32 = 40;

/// The deny-list (design §5.11, library evaluation §7, plus the new mount API); docs/develop/gleipnir.md says why
/// each entry is on it.
pub fn rules() -> Vec<DenyRule> {
    let deny = |syscall, errno, arg| DenyRule {
        syscall,
        errno,
        arg,
    };
    let mut rules: Vec<DenyRule> = DENIED_ALWAYS
        .iter()
        .map(|&s| deny(s, EPERM, None))
        .collect();
    for mask in CLONE_NEW {
        rules.push(deny(
            "clone",
            EPERM,
            Some(ArgMatch::MaskedEq { index: 0, mask }),
        ));
    }
    for value in [TIOCSTI, TIOCLINUX] {
        rules.push(deny("ioctl", EPERM, Some(ArgMatch::Eq { index: 1, value })));
    }
    rules.push(deny(
        "socket",
        EPERM,
        Some(ArgMatch::Eq {
            index: 0,
            value: AF_VSOCK,
        }),
    ));
    // Its flags sit in a struct seccomp cannot read; on ENOSYS libc falls back to clone, which the rules above see.
    rules.push(deny("clone3", ENOSYS, None));
    rules
}

/// Compiles [`rules`] for `arch`: allow by default, the EPERM rules through seccompiler `=0.5.0` (whose own
/// architecture check kills a non-native audit arch), and in front of that a short hand-written prologue:
///
/// - x86_64: `ld arch; jeq AUDIT_ARCH_X86_64 ? next : skip two; ld nr; jset 0x40000000 ? next : skip one;
///   ret KILL_PROCESS`. A foreign arch and an x32 call (`AUDIT_ARCH_X86_64` with bit 30 set in the number, which a
///   deny-list keyed on x86_64 numbers would otherwise let through) both land on the kill.
/// - aarch64: `ld arch; jeq AUDIT_ARCH_AARCH64 ? skip one : next; ret KILL_PROCESS; ld nr`.
/// - then, for each rule with another errno (clone3's ENOSYS): `jeq nr ? next : skip one; ret ERRNO(errno)`.
///
/// No jump crosses from one part into the other: the prologue's jumps stay inside it, and seccompiler's program
/// follows it unchanged.
#[cfg(target_os = "linux")]
pub fn compile(arch: Arch) -> Result<Vec<SockFilter>, SeccompError> {
    use seccompiler::{
        BpfProgram, SeccompAction, SeccompCmpArgLen, SeccompCmpOp, SeccompCondition, SeccompFilter,
        SeccompRule, TargetArch,
    };
    use std::collections::BTreeMap;

    const LD_W_ABS: u16 = 0x20;
    const JEQ_K: u16 = 0x15;
    const JSET_K: u16 = 0x45;
    const RET_K: u16 = 0x06;
    const DATA_NR: u32 = 0;
    const DATA_ARCH: u32 = 4;
    const X32_SYSCALL_BIT: u32 = 0x4000_0000;
    const BPF_MAXINSNS: usize = 4096;
    let op = |code, k, jt, jf| SockFilter { code, jt, jf, k };

    let mut prog = match arch {
        Arch::X86_64 => vec![
            op(LD_W_ABS, DATA_ARCH, 0, 0),
            op(JEQ_K, arch.audit(), 0, 2),
            op(LD_W_ABS, DATA_NR, 0, 0),
            op(JSET_K, X32_SYSCALL_BIT, 0, 1),
            op(RET_K, RET_KILL_PROCESS, 0, 0),
        ],
        Arch::Aarch64 => vec![
            op(LD_W_ABS, DATA_ARCH, 0, 0),
            op(JEQ_K, arch.audit(), 1, 0),
            op(RET_K, RET_KILL_PROCESS, 0, 0),
            op(LD_W_ABS, DATA_NR, 0, 0),
        ],
    };

    // Per call: None = denied whatever the arguments; Some(conditions) = denied when any of them holds. An
    // unconditional entry wins over conditional ones for the same call (never narrows a denial).
    let mut eperm: BTreeMap<i64, Option<Vec<ArgMatch>>> = BTreeMap::new();
    for rule in rules() {
        let nr = arch
            .syscall_nr(rule.syscall)
            .ok_or(SeccompError::UnknownSyscall {
                syscall: rule.syscall,
                arch,
            })?;
        match (rule.errno, rule.arg) {
            (EPERM, None) => {
                eperm.insert(i64::from(nr), None);
            }
            (EPERM, Some(arg)) => {
                if let Some(conditions) = eperm
                    .entry(i64::from(nr))
                    .or_insert_with(|| Some(Vec::new()))
                {
                    conditions.push(arg);
                }
            }
            (errno @ 1..=4095, None) => {
                prog.push(op(JEQ_K, nr, 0, 1));
                prog.push(op(RET_K, RET_ERRNO | errno as u32, 0, 0));
            }
            _ => return Err(SeccompError::Unexpressible(rule)),
        }
    }

    let compile_err = |e: seccompiler::BackendError| SeccompError::Compile(e.to_string());
    let mut chains = BTreeMap::new();
    for (nr, conditions) in eperm {
        let chain = conditions
            .unwrap_or_default()
            .into_iter()
            .map(|arg| {
                let (index, cmp, value) = match arg {
                    ArgMatch::Eq { index, value } => (index, SeccompCmpOp::Eq, value),
                    ArgMatch::MaskedEq { index, mask } => {
                        (index, SeccompCmpOp::MaskedEq(u64::from(mask)), mask)
                    }
                };
                let cond =
                    SeccompCondition::new(index, SeccompCmpArgLen::Dword, cmp, u64::from(value));
                SeccompRule::new(vec![cond.map_err(compile_err)?]).map_err(compile_err)
            })
            .collect::<Result<Vec<_>, _>>()?;
        chains.insert(nr, chain);
    }
    let target = match arch {
        Arch::X86_64 => TargetArch::x86_64,
        Arch::Aarch64 => TargetArch::aarch64,
    };
    let filter = SeccompFilter::new(
        chains,
        SeccompAction::Allow,
        SeccompAction::Errno(EPERM as u32),
        target,
    )
    .map_err(compile_err)?;
    let body: BpfProgram = filter.try_into().map_err(compile_err)?;
    prog.extend(body.into_iter().map(|i| SockFilter {
        code: i.code,
        jt: i.jt,
        jf: i.jf,
        k: i.k,
    }));
    if prog.len() > BPF_MAXINSNS {
        return Err(SeccompError::TooLong(prog.len()));
    }
    Ok(prog)
}

/// Compiles [`rules`] for `arch`: Unsupported off Linux (Android: no backend; apps get no user namespaces; fails
/// closed).
#[cfg(not(target_os = "linux"))]
pub fn compile(arch: Arch) -> Result<Vec<SockFilter>, SeccompError> {
    let _ = arch;
    Err(SeccompError::Unsupported)
}

/// Installs `prog` on every thread of this process (`SECCOMP_FILTER_FLAG_TSYNC`). It sets `PR_SET_NO_NEW_PRIVS`
/// itself first (seccompiler does, before the `seccomp` call), as the inner helper also does, so no caller can
/// install without it. Irreversible: the filter stays on this process and every child it starts.
#[cfg(target_os = "linux")]
pub fn install(prog: &[SockFilter]) -> Result<(), SeccompError> {
    let bpf: seccompiler::BpfProgram = prog
        .iter()
        .map(|i| seccompiler::sock_filter {
            code: i.code,
            jt: i.jt,
            jf: i.jf,
            k: i.k,
        })
        .collect();
    seccompiler::apply_filter_all_threads(&bpf).map_err(|e| SeccompError::Install(e.to_string()))
}

/// Installs `prog`: Unsupported off Linux (Android: no backend; apps get no user namespaces; fails closed).
#[cfg(not(target_os = "linux"))]
pub fn install(prog: &[SockFilter]) -> Result<(), SeccompError> {
    let _ = prog;
    Err(SeccompError::Unsupported)
}

// The tests compile and install filters, which exist only on Linux (Android: no backend; fails closed).
#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::process::Command;

    // Written out here, not taken from the module, so a slip in either is caught.
    const EPERM_: i32 = 1;
    const ENOSYS_: i32 = 38;
    const DENIED_ALWAYS: &[&str] = &[
        "ptrace",
        "keyctl",
        "add_key",
        "request_key",
        "perf_event_open",
        "bpf",
        "userfaultfd",
        "io_uring_setup",
        "io_uring_enter",
        "io_uring_register",
        "unshare",
        "setns",
        "mount",
        "umount2",
        "pivot_root",
        "open_tree",
        "move_mount",
        "fsopen",
        "fsconfig",
        "fsmount",
        "fspick",
        "mount_setattr",
    ];
    // CLONE_NEWNS, NEWCGROUP, NEWUTS, NEWIPC, NEWUSER, NEWPID, NEWNET: together 0x7E020000.
    const CLONE_NEW: [u32; 7] = [
        0x0002_0000,
        0x0200_0000,
        0x0400_0000,
        0x0800_0000,
        0x1000_0000,
        0x2000_0000,
        0x4000_0000,
    ];
    const TIOCSTI: u64 = 0x5412;
    const TIOCLINUX: u64 = 0x541C;
    const AF_VSOCK: u64 = 40;
    const AUDIT_X86_64: u32 = 0xC000_003E;
    const AUDIT_AARCH64: u32 = 0xC000_00B7;
    const AUDIT_I386: u32 = 0x4000_0003;
    const AUDIT_ARM: u32 = 0x4000_0028;
    const X32_BIT: u32 = 0x4000_0000;
    const ARCHES: [Arch; 2] = [Arch::X86_64, Arch::Aarch64];

    fn nr(arch: Arch, name: &str) -> u32 {
        arch.syscall_nr(name)
            .unwrap_or_else(|| panic!("no {arch:?} number for {name}"))
    }

    #[test]
    fn rules_are_the_design_set() {
        let mut want: Vec<DenyRule> = DENIED_ALWAYS
            .iter()
            .map(|&syscall| DenyRule {
                syscall,
                errno: EPERM_,
                arg: None,
            })
            .collect();
        for mask in CLONE_NEW {
            let arg = Some(ArgMatch::MaskedEq { index: 0, mask });
            want.push(DenyRule {
                syscall: "clone",
                errno: EPERM_,
                arg,
            });
        }
        for value in [0x5412, 0x541C] {
            let arg = Some(ArgMatch::Eq { index: 1, value });
            want.push(DenyRule {
                syscall: "ioctl",
                errno: EPERM_,
                arg,
            });
        }
        let arg = Some(ArgMatch::Eq {
            index: 0,
            value: 40,
        });
        want.push(DenyRule {
            syscall: "socket",
            errno: EPERM_,
            arg,
        });
        want.push(DenyRule {
            syscall: "clone3",
            errno: ENOSYS_,
            arg: None,
        });
        assert_eq!(CLONE_NEW.iter().fold(0, |a, b| a | b), 0x7E02_0000);
        let mut got = rules();
        want.sort();
        got.sort();
        assert_eq!(got, want);
    }

    #[test]
    fn constants_match_libc() {
        assert_eq!(EPERM, libc::EPERM);
        assert_eq!(ENOSYS, libc::ENOSYS);
        let clone_new = [
            libc::CLONE_NEWNS,
            libc::CLONE_NEWCGROUP,
            libc::CLONE_NEWUTS,
            libc::CLONE_NEWIPC,
            libc::CLONE_NEWUSER,
            libc::CLONE_NEWPID,
            libc::CLONE_NEWNET,
        ];
        assert_eq!(clone_new.map(|b| b as u32), CLONE_NEW);
        assert_eq!(libc::TIOCSTI, TIOCSTI);
        assert_eq!(libc::TIOCLINUX, TIOCLINUX);
        assert_eq!(libc::AF_VSOCK as u64, AF_VSOCK);
        assert_eq!(libc::TIOCSTI, u64::from(super::TIOCSTI));
        assert_eq!(libc::TIOCLINUX, u64::from(super::TIOCLINUX));
        assert_eq!(libc::AF_VSOCK as u32, super::AF_VSOCK);
        assert_eq!(0x7FFF_0000, libc::SECCOMP_RET_ALLOW); // the interpreter's Allow
        assert_eq!(RET_ERRNO, libc::SECCOMP_RET_ERRNO);
        assert_eq!(RET_KILL_PROCESS, libc::SECCOMP_RET_KILL_PROCESS);
    }

    /// The native table rows against libc's `SYS_*`; the other arch's were checked against seccompiler 0.5.0's
    /// generated tables (kernel 6.12) when written.
    #[test]
    fn syscall_numbers_match_libc() {
        let native = native().expect("tests run on x86_64 or aarch64 Linux");
        let libc_nrs = [
            ("add_key", libc::SYS_add_key),
            ("bpf", libc::SYS_bpf),
            ("clone", libc::SYS_clone),
            ("clone3", libc::SYS_clone3),
            ("fsconfig", libc::SYS_fsconfig),
            ("fsmount", libc::SYS_fsmount),
            ("fsopen", libc::SYS_fsopen),
            ("fspick", libc::SYS_fspick),
            ("io_uring_enter", libc::SYS_io_uring_enter),
            ("io_uring_register", libc::SYS_io_uring_register),
            ("io_uring_setup", libc::SYS_io_uring_setup),
            ("ioctl", libc::SYS_ioctl),
            ("keyctl", libc::SYS_keyctl),
            ("mount", libc::SYS_mount),
            ("mount_setattr", libc::SYS_mount_setattr),
            ("move_mount", libc::SYS_move_mount),
            ("open_tree", libc::SYS_open_tree),
            ("perf_event_open", libc::SYS_perf_event_open),
            ("pivot_root", libc::SYS_pivot_root),
            ("ptrace", libc::SYS_ptrace),
            ("request_key", libc::SYS_request_key),
            ("setns", libc::SYS_setns),
            ("socket", libc::SYS_socket),
            ("umount2", libc::SYS_umount2),
            ("unshare", libc::SYS_unshare),
            ("userfaultfd", libc::SYS_userfaultfd),
            ("getpid", libc::SYS_getpid),
        ];
        for (name, want) in libc_nrs {
            assert_eq!(native.syscall_nr(name).map(i64::from), Some(want), "{name}");
        }
        for rule in rules() {
            assert!(
                Arch::Aarch64.syscall_nr(rule.syscall).is_some(),
                "{}",
                rule.syscall
            );
        }
    }

    // ---- the golden ----

    fn listing(prog: &[SockFilter]) -> Vec<String> {
        prog.iter()
            .map(|i| {
                let op = match i.code {
                    0x20 => "ld [k]",
                    0x54 => "and #k",
                    0x05 => "ja +k",
                    0x15 => "jeq #k",
                    0x25 => "jgt #k",
                    0x35 => "jge #k",
                    0x45 => "jset #k",
                    0x06 => "ret #k",
                    _ => "?",
                };
                format!("{:#06x} {:3} {:3} {:#010x}  {op}", i.code, i.jt, i.jf, i.k)
            })
            .collect()
    }

    #[test]
    fn bpf_golden_x86_64() {
        insta::assert_json_snapshot!(listing(&compile(Arch::X86_64).unwrap()));
    }

    #[test]
    fn bpf_golden_aarch64() {
        insta::assert_json_snapshot!(listing(&compile(Arch::Aarch64).unwrap()));
    }

    // ---- a classic-BPF interpreter over the compiled program (review B2) ----

    /// `struct seccomp_data`: nr, arch, instruction_pointer, args[6], as 32-bit little-endian words.
    #[derive(Clone, Copy, Debug)]
    struct Data {
        nr: u32,
        arch: u32,
        args: [u64; 6],
    }

    impl Data {
        fn call(arch: Arch, nr: u32, args: &[u64]) -> Self {
            let mut a = [0; 6];
            a[..args.len()].copy_from_slice(args);
            Data {
                nr,
                arch: arch.audit(),
                args: a,
            }
        }

        fn word(&self, k: u32) -> u32 {
            match k {
                0 => self.nr,
                4 => self.arch,
                8 | 12 => 0,
                16..=63 if k.is_multiple_of(4) => {
                    let arg = self.args[(k as usize - 16) / 8];
                    if k.is_multiple_of(8) {
                        arg as u32
                    } else {
                        (arg >> 32) as u32
                    }
                }
                _ => panic!("load at offset {k}"),
            }
        }
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum Act {
        Allow,
        Errno(i32),
        Kill,
    }

    fn run(prog: &[SockFilter], d: &Data) -> Act {
        let (mut pc, mut a) = (0usize, 0u32);
        loop {
            let i = prog
                .get(pc)
                .unwrap_or_else(|| panic!("fell off the program at {pc}"));
            pc += 1;
            match i.code {
                0x20 => a = d.word(i.k),
                0x54 => a &= i.k,
                0x05 => pc += i.k as usize,
                0x15 | 0x25 | 0x35 | 0x45 => {
                    let taken = match i.code {
                        0x15 => a == i.k,
                        0x25 => a > i.k,
                        0x35 => a >= i.k,
                        _ => a & i.k != 0,
                    };
                    pc += usize::from(if taken { i.jt } else { i.jf });
                }
                0x06 => {
                    return match i.k & 0xFFFF_0000 {
                        0x7FFF_0000 => Act::Allow,
                        0x0005_0000 => Act::Errno((i.k & 0xFFFF) as i32),
                        0x8000_0000 => Act::Kill,
                        other => panic!("return {other:#x} at {}", pc - 1),
                    };
                }
                code => panic!("opcode {code:#x} at {} is not in the interpreter", pc - 1),
            }
        }
    }

    #[test]
    fn bpf_interpreter_table() {
        let mut cases: Vec<(String, Arch, Data, Act)> = Vec::new();
        let mut add =
            |label: String, arch: Arch, d: Data, want: Act| cases.push((label, arch, d, want));
        let ones = [u64::MAX; 6];
        for arch in ARCHES {
            // Every number a call can have, with zero arguments: only the list is denied.
            for n in 0..1024 {
                let name = DENIED_ALWAYS.iter().copied().find(|s| nr(arch, s) == n);
                let want = match name {
                    Some(_) => Act::Errno(EPERM_),
                    None if n == nr(arch, "clone3") => Act::Errno(ENOSYS_),
                    None => Act::Allow,
                };
                add(
                    format!("nr {n} ({name:?})"),
                    arch,
                    Data::call(arch, n, &[]),
                    want,
                );
            }
            for &name in DENIED_ALWAYS {
                let d = Data::call(arch, nr(arch, name), &ones);
                add(format!("{name} all-ones args"), arch, d, Act::Errno(EPERM_));
            }
            let clone = nr(arch, "clone");
            for bit in CLONE_NEW {
                let label = format!("clone {bit:#x}");
                add(
                    label.clone(),
                    arch,
                    Data::call(arch, clone, &[u64::from(bit)]),
                    Act::Errno(EPERM_),
                );
                let with = u64::from(bit) | 0x11 | 0x003D_0F00;
                add(
                    label + " with thread flags",
                    arch,
                    Data::call(arch, clone, &[with]),
                    Act::Errno(EPERM_),
                );
                // Legacy clone reads only the low half of its flags, so the high half is not a namespace.
                let high = u64::from(bit) << 32;
                add(
                    format!("clone {high:#x}"),
                    arch,
                    Data::call(arch, clone, &[high]),
                    Act::Allow,
                );
            }
            add(
                "clone all seven".into(),
                arch,
                Data::call(arch, clone, &[0x7E02_0000]),
                Act::Errno(EPERM_),
            );
            add(
                "clone 0".into(),
                arch,
                Data::call(arch, clone, &[0]),
                Act::Allow,
            );
            add(
                "clone fork".into(),
                arch,
                Data::call(arch, clone, &[0x11]),
                Act::Allow,
            );
            add(
                "clone thread".into(),
                arch,
                Data::call(arch, clone, &[0x003D_0F00]),
                Act::Allow,
            );
            let ioctl = nr(arch, "ioctl");
            for (req, want) in [
                (TIOCSTI, Act::Errno(EPERM_)),
                (TIOCSTI | 1 << 32, Act::Errno(EPERM_)),
                (TIOCSTI | 0xFFFF_FFFF << 32, Act::Errno(EPERM_)),
                (TIOCLINUX, Act::Errno(EPERM_)),
                (TIOCLINUX | 1 << 32, Act::Errno(EPERM_)),
                (0x5401, Act::Allow),
                (0x5413, Act::Allow),
                (0x541B, Act::Allow),
            ] {
                add(
                    format!("ioctl {req:#x}"),
                    arch,
                    Data::call(arch, ioctl, &[0, req]),
                    want,
                );
            }
            add(
                "ioctl TIOCSTI as the fd".into(),
                arch,
                Data::call(arch, ioctl, &[TIOCSTI, 0]),
                Act::Allow,
            );
            let socket = nr(arch, "socket");
            for (domain, want) in [
                (AF_VSOCK, Act::Errno(EPERM_)),
                (AF_VSOCK | 1 << 32, Act::Errno(EPERM_)),
                (1, Act::Allow),
                (2, Act::Allow),
                (10, Act::Allow),
                (16, Act::Allow),
            ] {
                add(
                    format!("socket {domain:#x}"),
                    arch,
                    Data::call(arch, socket, &[domain, 1]),
                    want,
                );
            }
            let clone3 = nr(arch, "clone3");
            add(
                "clone3 any args".into(),
                arch,
                Data::call(arch, clone3, &ones),
                Act::Errno(ENOSYS_),
            );
            // A foreign audit arch is killed, whatever the call.
            let other = match arch {
                Arch::X86_64 => AUDIT_AARCH64,
                Arch::Aarch64 => AUDIT_X86_64,
            };
            for foreign in [other, AUDIT_I386, AUDIT_ARM, 0] {
                for n in [0, nr(arch, "getpid"), clone3, nr(arch, "ptrace")] {
                    let d = Data {
                        arch: foreign,
                        ..Data::call(arch, n, &[])
                    };
                    add(format!("arch {foreign:#x} nr {n}"), arch, d, Act::Kill);
                }
            }
            add(
                "getpid".into(),
                arch,
                Data::call(arch, nr(arch, "getpid"), &[]),
                Act::Allow,
            );
        }
        // x32: AUDIT_ARCH_X86_64 with bit 30 set in the number is killed, every number.
        for n in 0..1024 {
            let d = Data::call(Arch::X86_64, n | X32_BIT, &[]);
            add(format!("x32 nr {n}"), Arch::X86_64, d, Act::Kill);
        }

        let mut progs = std::collections::HashMap::new();
        for arch in ARCHES {
            progs.insert(arch, compile(arch).expect("compiles"));
        }
        let wrong: Vec<String> = cases
            .iter()
            .filter_map(|(label, arch, d, want)| {
                let got = run(&progs[arch], d);
                (got != *want).then(|| format!("{arch:?} {label}: got {got:?}, want {want:?}"))
            })
            .collect();
        assert!(
            wrong.is_empty(),
            "{} of {} cases wrong:\n{}",
            wrong.len(),
            cases.len(),
            wrong.join("\n")
        );
    }

    #[test]
    fn ioctl_compares_low_32_bits() {
        let ioctls: Vec<_> = rules()
            .into_iter()
            .filter(|r| r.syscall == "ioctl")
            .collect();
        assert_eq!(ioctls.len(), 2);
        for arch in ARCHES {
            let prog = compile(arch).unwrap();
            let ioctl = nr(arch, "ioctl");
            for req in [TIOCSTI, TIOCLINUX] {
                for high in [0, 1, 0xFFFF_FFFF] {
                    let d = Data::call(arch, ioctl, &[3, req | high << 32]);
                    assert_eq!(
                        run(&prog, &d),
                        Act::Errno(EPERM_),
                        "{arch:?} {req:#x} high {high:#x}"
                    );
                }
            }
        }
    }

    #[test]
    fn clone3_is_enosys() {
        let rule = rules()
            .into_iter()
            .find(|r| r.syscall == "clone3")
            .expect("clone3 is in the list");
        assert_eq!((rule.errno, rule.arg), (ENOSYS_, None));
        for arch in ARCHES {
            let prog = compile(arch).unwrap();
            let d = Data::call(arch, nr(arch, "clone3"), &[0, 0]);
            assert_eq!(run(&prog, &d), Act::Errno(ENOSYS_), "{arch:?}");
        }
    }

    // ---- the real install, in a child process per case ----
    //
    // `installed_filter_denies` re-runs this test binary once per case, selecting only `seccomp_case_child`, with
    // the case's name in GLEIPNIR_SECCOMP_CASE. That child forks twice: once without the filter (the control) and
    // once with it, so neither the test process nor the child is ever filtered, and each forked process is
    // single-threaded (unshare(CLONE_NEWUSER) needs that). Only calls whose unfiltered result differs from the
    // filtered one are used (review B2); a case whose control does not give its unfiltered result (a container's own
    // filter, a kernel without vsock …) is skipped with that reason.

    const CASE_ENV: &str = "GLEIPNIR_SECCOMP_CASE";
    const SKIP: i32 = 77;

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum Outcome {
        Ok,
        Errno(i32),
        Killed(i32),
        Setup(i32),
    }

    struct Case {
        name: &'static str,
        unfiltered: &'static [Outcome],
        filtered: Outcome,
    }

    const CASES: &[Case] = &[
        Case {
            name: "unshare-newuser",
            unfiltered: &[Outcome::Ok],
            filtered: Outcome::Errno(EPERM_),
        },
        Case {
            name: "io-uring-setup",
            unfiltered: &[Outcome::Ok],
            filtered: Outcome::Errno(EPERM_),
        },
        Case {
            name: "keyctl",
            unfiltered: &[Outcome::Ok],
            filtered: Outcome::Errno(EPERM_),
        },
        Case {
            name: "add-key",
            unfiltered: &[Outcome::Ok],
            filtered: Outcome::Errno(EPERM_),
        },
        Case {
            name: "socket-vsock",
            unfiltered: &[Outcome::Ok, Outcome::Errno(libc::EAFNOSUPPORT)],
            filtered: Outcome::Errno(EPERM_),
        },
        Case {
            name: "ptrace-attach-own-child",
            unfiltered: &[Outcome::Ok],
            filtered: Outcome::Errno(EPERM_),
        },
        // clone3(NULL, 0): EINVAL from the kernel (size too small), ENOSYS from the filter; nothing is created.
        Case {
            name: "clone3",
            unfiltered: &[Outcome::Errno(libc::EINVAL)],
            filtered: Outcome::Errno(ENOSYS_),
        },
        Case {
            name: "mount-missing-target",
            unfiltered: &[Outcome::Errno(libc::ENOENT)],
            filtered: Outcome::Errno(EPERM_),
        },
        // On its own controlling pty: injected (legacy TIOCSTI on) or EIO (dev.tty.legacy_tiocsti = 0).
        Case {
            name: "tiocsti-high-bits",
            unfiltered: &[Outcome::Ok, Outcome::Errno(libc::EIO)],
            filtered: Outcome::Errno(EPERM_),
        },
        // Runs (x32 on) or ENOSYS (x32 off, as on Fedora); the filter sees the number before the kernel's x32 check,
        // so it kills either way.
        Case {
            name: "x32-getpid",
            unfiltered: &[Outcome::Ok, Outcome::Errno(libc::ENOSYS)],
            filtered: Outcome::Killed(libc::SIGSYS),
        },
        Case {
            name: "getpid",
            unfiltered: &[Outcome::Ok],
            filtered: Outcome::Ok,
        },
        Case {
            name: "socket-unix",
            unfiltered: &[Outcome::Ok],
            filtered: Outcome::Ok,
        },
    ];

    fn errno() -> i32 {
        std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
    }

    fn result(r: i64) -> i32 {
        if r >= 0 { 0 } else { errno() }
    }

    /// Runs in the forked process: the case's setup, the filter when given, then the one call. Returns the exit
    /// code: 0 success, an errno, 200 + step for a setup step that failed, 254 when the filter would not install.
    fn case_body(name: &str, filter: Option<&[SockFilter]>) -> i32 {
        let install_now = || filter.is_none_or(|p| install(p).is_ok());
        // SAFETY: raw calls on this process's own state; every pointer is to a live local.
        unsafe {
            match name {
                "unshare-newuser" => {
                    if !install_now() {
                        return 254;
                    }
                    result(i64::from(libc::unshare(libc::CLONE_NEWUSER)))
                }
                "io-uring-setup" => {
                    let mut params = [0u8; 120];
                    if !install_now() {
                        return 254;
                    }
                    let entries: libc::c_long = 1;
                    result(libc::syscall(
                        libc::SYS_io_uring_setup,
                        entries,
                        params.as_mut_ptr(),
                    ))
                }
                "keyctl" => {
                    if !install_now() {
                        return 254;
                    }
                    // KEYCTL_GET_KEYRING_ID (0) of KEY_SPEC_THREAD_KEYRING (-1), create: this process's own keyring.
                    let (get_keyring_id, thread_keyring, create): (
                        libc::c_long,
                        libc::c_long,
                        libc::c_long,
                    ) = (0, -1, 1);
                    result(libc::syscall(
                        libc::SYS_keyctl,
                        get_keyring_id,
                        thread_keyring,
                        create,
                    ))
                }
                "add-key" => {
                    if !install_now() {
                        return 254;
                    }
                    let (kind, desc, data) = (c"user", c"gleipnir-seccomp-test", b"x");
                    let (len, thread_keyring): (libc::size_t, libc::c_long) = (1, -1);
                    result(libc::syscall(
                        libc::SYS_add_key,
                        kind.as_ptr(),
                        desc.as_ptr(),
                        data.as_ptr(),
                        len,
                        thread_keyring,
                    ))
                }
                "socket-vsock" => {
                    if !install_now() {
                        return 254;
                    }
                    result(i64::from(libc::socket(
                        libc::AF_VSOCK,
                        libc::SOCK_STREAM,
                        0,
                    )))
                }
                "ptrace-attach-own-child" => {
                    let child = libc::fork();
                    if child < 0 {
                        return 201;
                    }
                    if child == 0 {
                        loop {
                            libc::pause();
                        }
                    }
                    let code = if install_now() {
                        let null = std::ptr::null_mut::<libc::c_void>();
                        result(libc::ptrace(libc::PTRACE_ATTACH, child, null, null))
                    } else {
                        254
                    };
                    libc::kill(child, libc::SIGKILL);
                    libc::waitpid(child, std::ptr::null_mut(), 0);
                    code
                }
                "clone3" => {
                    if !install_now() {
                        return 254;
                    }
                    let size: libc::size_t = 0;
                    result(libc::syscall(
                        libc::SYS_clone3,
                        std::ptr::null::<u8>(),
                        size,
                    ))
                }
                "mount-missing-target" => {
                    if !install_now() {
                        return 254;
                    }
                    let target = c"/nonexistent/gleipnir-seccomp-test";
                    result(i64::from(libc::mount(
                        c"none".as_ptr(),
                        target.as_ptr(),
                        c"tmpfs".as_ptr(),
                        0,
                        std::ptr::null(),
                    )))
                }
                "tiocsti-high-bits" => {
                    if libc::setsid() < 0 {
                        return 201;
                    }
                    let master = libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY);
                    if master < 0 || libc::unlockpt(master) != 0 {
                        return 202;
                    }
                    let mut path = [0 as libc::c_char; 64];
                    if libc::ptsname_r(master, path.as_mut_ptr(), path.len()) != 0 {
                        return 203;
                    }
                    let tty = libc::open(path.as_ptr(), libc::O_RDWR);
                    if tty < 0 || libc::ioctl(tty, libc::TIOCSCTTY, 0) != 0 {
                        return 204;
                    }
                    if !install_now() {
                        return 254;
                    }
                    let c = b'x';
                    let (fd, request): (libc::c_long, u64) =
                        (libc::c_long::from(tty), TIOCSTI | 1 << 32);
                    result(libc::syscall(libc::SYS_ioctl, fd, request, &c as *const u8))
                }
                "x32-getpid" => {
                    if !install_now() {
                        return 254;
                    }
                    result(libc::syscall(
                        libc::c_long::from(X32_BIT) | libc::SYS_getpid,
                    ))
                }
                "getpid" => {
                    if !install_now() {
                        return 254;
                    }
                    result(libc::syscall(libc::SYS_getpid))
                }
                "socket-unix" => {
                    if !install_now() {
                        return 254;
                    }
                    result(i64::from(libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0)))
                }
                _ => 200,
            }
        }
    }

    fn fork_run(name: &str, filter: Option<&[SockFilter]>) -> Outcome {
        // SAFETY: this process runs one test (libtest's main thread only waits); the forked process runs the case
        // and `_exit`s, never returning into the harness, even on a panic.
        let pid = unsafe { libc::fork() };
        assert!(pid >= 0, "fork: {}", std::io::Error::last_os_error());
        if pid == 0 {
            let code = std::panic::catch_unwind(|| case_body(name, filter)).unwrap_or(253);
            unsafe { libc::_exit(code) }
        }
        let mut status = 0;
        // SAFETY: waits for the child forked above.
        let waited = unsafe { libc::waitpid(pid, &mut status, 0) };
        assert_eq!(waited, pid, "waitpid: {}", std::io::Error::last_os_error());
        if libc::WIFSIGNALED(status) {
            return Outcome::Killed(libc::WTERMSIG(status));
        }
        match libc::WEXITSTATUS(status) {
            0 => Outcome::Ok,
            code @ 200.. => Outcome::Setup(code - 200),
            errno => Outcome::Errno(errno),
        }
    }

    #[test]
    #[ignore = "run by installed_filter_denies, in a child process of its own"]
    fn seccomp_case_child() {
        let Ok(name) = std::env::var(CASE_ENV) else {
            return;
        };
        let case = CASES.iter().find(|c| c.name == name).expect("a known case");
        let prog = compile(native().expect("a native arch")).expect("compiles");
        let control = fork_run(case.name, None);
        if !case.unfiltered.contains(&control) {
            eprintln!(
                "skip {name}: unfiltered gave {control:?}, not one of {:?}",
                case.unfiltered
            );
            std::process::exit(SKIP);
        }
        let filtered = fork_run(case.name, Some(&prog));
        if filtered != case.filtered {
            eprintln!(
                "FAIL {name}: filtered gave {filtered:?}, want {:?} (unfiltered {control:?})",
                case.filtered
            );
            std::process::exit(1);
        }
        eprintln!("pass {name}: unfiltered {control:?}, filtered {filtered:?}");
        std::process::exit(0);
    }

    #[test]
    fn installed_filter_denies() {
        let exe = std::env::current_exe().unwrap();
        let (mut passed, mut skipped, mut failed) = (Vec::new(), Vec::new(), Vec::new());
        for case in CASES {
            if case.name == "x32-getpid" && native() != Some(Arch::X86_64) {
                continue;
            }
            let out = Command::new(&exe)
                .args([
                    "--exact",
                    "seccomp::tests::seccomp_case_child",
                    "--ignored",
                    "--nocapture",
                ])
                .args(["--test-threads=1", "-q"])
                .env(CASE_ENV, case.name)
                .output()
                .unwrap();
            let said = String::from_utf8_lossy(&out.stderr).trim().to_string();
            match out.status.code() {
                Some(0) => passed.push(said),
                Some(SKIP) => skipped.push(said),
                _ => failed.push(format!("{}: {:?}: {said}", case.name, out.status)),
            }
        }
        eprintln!(
            "seccomp real install: {} passed, {} skipped",
            passed.len(),
            skipped.len()
        );
        for line in passed.iter().chain(&skipped) {
            eprintln!("  {line}");
        }
        assert!(failed.is_empty(), "failed:\n{}", failed.join("\n"));
        // getpid and socket(AF_UNIX) cannot skip, so the filter was installed and ran at least there.
        assert!(passed.len() >= 2, "passed: {passed:?}");
    }
}
