//! What a Mac runner reports about itself, and the Mac contract: macOS 15 or newer on Apple silicon, a root-owned
//! `sandbox-exec`, the standard (non-admin) account `drgnx-runner` (another account or an administrator only as the
//! user allowed at `runner add`, [`Allow`]; root never), the Command Line Tools with any Xcode licence accepted, `mise` from
//! Homebrew (the project's toolchains go into the root through it), and 40 GB free on the runner root's volume. Everything is read once into a [`Raw`] (the live read, [`read`], on macOS only);
//! [`facts`], [`features`] and [`contract`] are pure.

use crate::proto::{Facts, Missing};

/// Free space the runner root's volume needs, in GB.
pub const MIN_DISK_GB: u64 = 40;
/// The oldest macOS a runner takes.
pub const MIN_MACOS: u32 = 15;
/// The account a Mac runner runs as unless the user allows their own (`--allow-own-account`).
pub const RUNNER_ACCOUNT: &str = "drgnx-runner";

/// What the user allowed at `runner add` beyond the dedicated standard account: another account
/// (`--allow-own-account`), an administrator (`--allow-admin`). Root is never allowed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Allow {
    pub own_account: bool,
    pub admin: bool,
}

/// The machine as read, before any judgement: each command's output (empty when it failed).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Raw {
    /// `sw_vers -productVersion`: `15.6`.
    pub product_version: String,
    /// `sysctl -n hw.optional.arm64`: `1` on Apple silicon, also under Rosetta.
    pub arm64: String,
    /// `hw.ncpu`, `hw.perflevel0.logicalcpu`, `hw.perflevel1.logicalcpu`: all, performance and efficiency cores.
    pub ncpu: String,
    pub perf_cores: String,
    pub eff_cores: String,
    /// `hw.memsize`, in bytes.
    pub memsize: String,
    /// Free bytes on the runner root's volume (`statvfs`).
    pub disk_free: u64,
    /// `pmset -g batt`.
    pub batt: String,
    /// `kern.bootsessionuuid`: the boot id (the own-machine refusal compares it with the hub's).
    pub boot_session: String,
    /// `id -un`: the account the runner runs as.
    pub user: String,
    /// `dseditgroup -o checkmember admin`: `yes <user> is a member of admin` or `no …`.
    pub admin: String,
    /// `/usr/bin/sandbox-exec` checked as only root can change it: `None` when it passed, else why not.
    pub sandbox_exec: Option<String>,
    /// `xcode-select -p`: the developer dir.
    pub developer_dir: String,
    /// `getconf DARWIN_USER_DIR`: the account's per-user folder (`/var/folders/xx/yyy/0/`); a job's profile reads and
    /// writes its parent.
    pub darwin_user_dir: String,
    /// `/usr/bin/clang --version`, stdout and stderr together: a licence not accepted shows here.
    pub clang: String,
    /// `brew --prefix`, and `brew list --versions` (one call per probe).
    pub brew_prefix: String,
    pub brew_versions: String,
    /// The user's `mise` (empty: none), and the toolchain records under the root (`tools::installed`).
    pub mise: String,
    pub tools: Vec<String>,
}

/// `15.6.1` → (15, 6); none when unreadable.
pub fn parse_version(v: &str) -> Option<(u32, u32)> {
    let mut it = v.trim().split('.');
    let major = it.next()?.parse().ok()?;
    let minor = it.next().map_or(Some(0), |m| m.parse().ok())?;
    Some((major, minor))
}

fn num(s: &str) -> u64 {
    s.trim().parse().unwrap_or(0)
}

/// Whether `pmset -g batt` shows a battery (a laptop).
pub fn has_battery(batt: &str) -> bool {
    batt.contains("InternalBattery")
}

/// Whether `pmset -g batt` says the Mac draws from mains power (a desktop always does).
pub fn on_ac(batt: &str) -> bool {
    !has_battery(batt) || batt.contains("'AC Power'")
}

/// The features of `brew list --versions`: `gnutls 3.8.4 3.8.5` → `brew:gnutls` (any version: what a project's
/// `drgnx-runners-mac-tools` asks) and `brew:gnutls@3.8` (the newest version installed, major and minor; none for a
/// name without a dotted version).
pub fn brew_features(list: &str) -> Vec<String> {
    let mut out: Vec<String> = list
        .lines()
        .flat_map(|l| {
            let mut w = l.split_whitespace();
            let Some(name) = w.next() else {
                return vec![];
            };
            let mut f = vec![format!("brew:{name}")];
            if let Some(((major, minor), _)) =
                w.filter_map(|v| parse_version(v).map(|p| (p, v))).max()
            {
                f.push(format!("brew:{name}@{major}.{minor}"));
            }
            f
        })
        .collect();
    out.sort();
    out.dedup();
    out
}

/// Whether the Command Line Tools answer: a developer dir, and a `clang` that runs (not the licence refusal).
pub fn clt_ok(raw: &Raw) -> bool {
    !raw.developer_dir.trim().is_empty() && raw.clang.contains("clang version")
}

/// Whether `clang` refused for an Xcode licence not yet accepted.
fn licence_pending(clang: &str) -> bool {
    clang.contains("license")
}

/// The facts a Mac reports (the protocol's `Facts`; the Linux-only fields are false or empty).
pub fn facts(raw: &Raw, others_present: Vec<String>) -> Facts {
    Facts {
        arch: "aarch64".into(),
        os: format!("macos {}", raw.product_version.trim()),
        cores: num(&raw.ncpu) as u32,
        mem_mib: num(&raw.memsize) / (1024 * 1024),
        disk_free_gb: raw.disk_free / 1_000_000_000,
        podman_version: String::new(),
        linger: true,
        landlock_abi: 0,
        graphical: false,
        battery: has_battery(&raw.batt),
        swap_max_settable: false,
        cpuset_by_systemd: false,
        others_present,
    }
}

/// The features a Mac advertises: `arch:aarch64`, `host-jobs`, `xcode-clt` when the tools answer, the Homebrew
/// packages with their versions, and `tool:NAME@VER` for each toolchain installed into the root. An account taken by an
/// allowance says so: `account:admin`, `account:own` (the runner list shows what that exposes).
pub fn features(raw: &Raw) -> Vec<String> {
    let mut f = vec!["arch:aarch64".to_string(), "host-jobs".to_string()];
    if clt_ok(raw) {
        f.push("xcode-clt".into());
    }
    if is_admin(raw) {
        f.push("account:admin".into());
    }
    if raw.user.trim() != RUNNER_ACCOUNT {
        f.push("account:own".into());
    }
    f.extend(brew_features(&raw.brew_versions));
    f.extend(super::tools::features(&raw.tools));
    f
}

/// Whether the account is an administrator (`dseditgroup` said anything but `no …`).
fn is_admin(raw: &Raw) -> bool {
    !raw.admin.trim_start().starts_with("no ")
}

/// The Mac contract: every item the machine lacks, each with its fix; none missing gives the facts.
pub fn contract(
    raw: &Raw,
    others_present: Vec<String>,
    allow: Allow,
) -> Result<Facts, Vec<Missing>> {
    let mut missing = vec![];
    let mut miss = |what: &str, fix: &str| {
        missing.push(Missing {
            what: what.into(),
            fix: fix.into(),
        })
    };
    match parse_version(&raw.product_version) {
        Some((major, _)) if major >= MIN_MACOS => {}
        _ => miss(
            &format!(
                "macOS {MIN_MACOS} or newer (this Mac runs {:?})",
                raw.product_version.trim()
            ),
            "refused: update macOS (System Settings, General, Software Update)",
        ),
    }
    if raw.arm64.trim() != "1" {
        miss(
            "a Mac with Apple silicon",
            "refused: Intel Macs are not runners",
        );
    }
    if let Some(why) = &raw.sandbox_exec {
        miss(
            &format!("a root-owned /usr/bin/sandbox-exec ({why})"),
            "refused: jobs never run without Seatbelt",
        );
    }
    const CREATE: &str = "create a standard account `drgnx-runner` (System Settings, Users & Groups), allow it in \
                          Remote Login, and add the hub's key to its ~/.ssh/authorized_keys";
    let user = raw.user.trim();
    if user == "root" {
        miss("an account other than root for the runner", CREATE);
    } else {
        if is_admin(raw) && !allow.admin {
            miss(
                "a standard (non-admin) account for the runner",
                &format!(
                    "{CREATE}; or, to run jobs as this administrator, add the runner with --allow-admin: the account can \
                     gain root through sudo with its password and through admin authorisation prompts (the sandbox \
                     still applies to every job)"
                ),
            );
        }
        if user != RUNNER_ACCOUNT && !allow.own_account {
            miss(
                &format!("the runner's own account `{RUNNER_ACCOUNT}` (this is `{user}`)"),
                &format!(
                    "{CREATE}; or, to run jobs as `{user}`, add the runner with --allow-own-account: that account's \
                     home, keychain and privacy (TCC) grants are reachable by file permissions (the sandbox still \
                     applies to every job)"
                ),
            );
        }
    }
    if licence_pending(&raw.clang) {
        miss(
            "the Xcode licence accepted",
            "run `sudo xcodebuild -license accept` in your own account",
        );
    } else if !clt_ok(raw) {
        miss(
            "the Command Line Tools",
            "run `xcode-select --install` in your own account",
        );
    }
    if raw.mise.trim().is_empty() {
        miss(
            "mise, from Homebrew (the project's toolchains are installed through it)",
            "run `brew install mise` in your own account",
        );
    }
    let free = raw.disk_free / 1_000_000_000;
    if free < MIN_DISK_GB {
        miss(
            &format!("{MIN_DISK_GB} GB free on the runner folder's volume ({free} GB)"),
            "free space on that volume",
        );
    }
    if missing.is_empty() {
        Ok(facts(raw, others_present))
    } else {
        Err(missing)
    }
}

/// The machine read now: one call to each tool, in the runner account. ROOT is the runner folder (its volume's free
/// space).
#[cfg(all(target_os = "macos", feature = "runner"))]
pub fn read(root: &std::path::Path) -> Raw {
    use std::process::Command;
    let out = |prog: &str, args: &[&str]| -> String {
        Command::new(prog)
            .args(args)
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default()
    };
    let both = |prog: &str, args: &[&str]| -> String {
        Command::new(prog)
            .args(args)
            .output()
            .map(|o| {
                format!(
                    "{}{}",
                    String::from_utf8_lossy(&o.stdout),
                    String::from_utf8_lossy(&o.stderr)
                )
            })
            .unwrap_or_default()
    };
    let sysctl = |name: &str| out("/usr/sbin/sysctl", &["-n", name]);
    let disk_free = rustix::fs::statvfs(root)
        .map(|s| s.f_bavail * s.f_frsize)
        .unwrap_or(0);
    let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .into_iter()
        .find(|b| std::path::Path::new(b).is_file());
    let user = out("/usr/bin/id", &["-un"]);
    Raw {
        product_version: out("/usr/bin/sw_vers", &["-productVersion"]),
        arm64: sysctl("hw.optional.arm64"),
        ncpu: sysctl("hw.ncpu"),
        perf_cores: sysctl("hw.perflevel0.logicalcpu"),
        eff_cores: sysctl("hw.perflevel1.logicalcpu"),
        memsize: sysctl("hw.memsize"),
        disk_free,
        batt: out("/usr/bin/pmset", &["-g", "batt"]),
        boot_session: sysctl("kern.bootsessionuuid"),
        user: user.clone(),
        admin: both(
            "/usr/sbin/dseditgroup",
            &["-o", "checkmember", "-m", &user, "admin"],
        ),
        sandbox_exec: gleipnir::backend::macos::find().err().map(|r| r.message),
        developer_dir: out("/usr/bin/xcode-select", &["-p"]),
        darwin_user_dir: out("/usr/bin/getconf", &["DARWIN_USER_DIR"]),
        clang: both("/usr/bin/clang", &["--version"]),
        brew_prefix: brew.map(|b| out(b, &["--prefix"])).unwrap_or_default(),
        brew_versions: brew
            .map(|b| out(b, &["list", "--versions"]))
            .unwrap_or_default(),
        mise: super::tools::find_mise()
            .map(|m| m.display().to_string())
            .unwrap_or_default(),
        tools: super::tools::installed(root),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A Mac mini as the runner account sees it: macOS 15.6, 10 cores, 32 GB, no battery, the tools in place.
    fn mini() -> Raw {
        Raw {
            product_version: "15.6\n".into(),
            arm64: "1".into(),
            ncpu: "10".into(),
            perf_cores: "4".into(),
            eff_cores: "6".into(),
            memsize: "34359738368".into(),
            disk_free: 200_000_000_000,
            batt: "Now drawing from 'AC Power'\n".into(),
            boot_session: "6A1D2C3B-0000-4000-8000-00000000AB12".into(),
            user: "drgnx-runner\n".into(),
            admin: "no drgnx-runner is NOT a member of admin\n".into(),
            sandbox_exec: None,
            developer_dir: "/Library/Developer/CommandLineTools".into(),
            darwin_user_dir: "/var/folders/6m/g3m822tx5754yy400ffqz8km0000gp/0/".into(),
            clang: "Apple clang version 17.0.0 (clang-1700.0.13.5)\nTarget: arm64-apple-darwin24.6.0\n".into(),
            brew_prefix: "/opt/homebrew".into(),
            brew_versions: "gnutls 3.8.4 3.8.10\nautoconf 2.72\ntexinfo 7.2\nlibgccjit 15.1.0\nweird HEAD-abc\n"
                .into(),
            mise: "/opt/homebrew/bin/mise".into(),
            tools: vec!["rust@1.95.json".into()],
        }
    }

    /// [D] A Mac that meets the contract: its facts (macOS version, cores, memory in MiB, disk in GB, no battery) and
    /// features (arch, host jobs, the Command Line Tools, each Homebrew package by name and at its newest major.minor,
    /// each toolchain in the root).
    #[test]
    fn a_mac_that_meets_the_contract_reports_its_facts() {
        let f = contract(&mini(), vec!["jobq".into()], Allow::default()).unwrap();
        assert_eq!(f.os, "macos 15.6");
        assert_eq!(f.arch, "aarch64");
        assert_eq!(f.cores, 10);
        assert_eq!(f.mem_mib, 32_768);
        assert_eq!(f.disk_free_gb, 200);
        assert!(!f.battery);
        assert!(f.linger);
        assert_eq!(f.others_present, vec!["jobq".to_string()]);
        assert_eq!(
            features(&mini()),
            vec![
                "arch:aarch64",
                "host-jobs",
                "xcode-clt",
                "brew:autoconf",
                "brew:autoconf@2.72",
                "brew:gnutls",
                "brew:gnutls@3.8",
                "brew:libgccjit",
                "brew:libgccjit@15.1",
                "brew:texinfo",
                "brew:texinfo@7.2",
                "brew:weird",
                "tool:rust@1.95",
            ]
        );
    }

    /// [D] Every item a Mac lacks is in the refusal, each with its fix: an old macOS, an Intel Mac, a sandbox-exec
    /// anyone could change, an admin account, no Command Line Tools, no `mise`, too little disk.
    #[test]
    fn the_contract_lists_everything_missing() {
        let raw = Raw {
            product_version: "14.7".into(),
            arm64: "0".into(),
            sandbox_exec: Some("owned by uid 501".into()),
            admin: "yes alice is a member of admin".into(),
            developer_dir: String::new(),
            clang: "xcode-select: note: no developer tools were found".into(),
            disk_free: 12_000_000_000,
            mise: String::new(),
            ..mini()
        };
        let missing = contract(&raw, vec![], Allow::default()).unwrap_err();
        let whats: Vec<&str> = missing.iter().map(|m| m.what.as_str()).collect();
        assert_eq!(missing.len(), 7, "{whats:?}");
        for (i, want) in [
            "macOS 15",
            "Apple silicon",
            "sandbox-exec (owned by uid 501)",
            "standard (non-admin)",
            "Command Line Tools",
            "mise, from Homebrew",
            "40 GB free on the runner folder's volume (12 GB)",
        ]
        .iter()
        .enumerate()
        {
            assert!(whats[i].contains(want), "{want}: {whats:?}");
            assert!(!missing[i].fix.is_empty());
        }
        assert!(missing[3].fix.contains("drgnx-runner"));
        assert!(missing[4].fix.contains("xcode-select --install"));
        assert!(missing[5].fix.contains("brew install mise"));
    }

    /// [D] The account: `drgnx-runner` (standard) is taken; another standard account is refused, naming
    /// `--allow-own-account` and what it exposes, and taken with it; an administrator is refused even with that flag,
    /// naming `--allow-admin` and what it exposes, and taken with it; root is refused whatever is allowed. An account
    /// taken by an allowance says so in its features.
    #[test]
    fn the_account_is_drgnx_runner_unless_the_user_allows_another() {
        let none = Allow::default();
        let own = Allow {
            own_account: true,
            admin: false,
        };
        let admin = Allow {
            own_account: false,
            admin: true,
        };
        let both = Allow {
            own_account: true,
            admin: true,
        };
        let f = features(&mini());
        assert!(!f.iter().any(|f| f.starts_with("account:")), "{f:?}");

        let alice = Raw {
            user: "alice".into(),
            admin: "no alice is NOT a member of admin".into(),
            ..mini()
        };
        let m = contract(&alice, vec![], none).unwrap_err();
        assert_eq!(m.len(), 1, "{m:?}");
        assert!(
            m[0].what.contains("drgnx-runner") && m[0].what.contains("alice"),
            "{m:?}"
        );
        assert!(m[0].fix.contains("--allow-own-account"), "{m:?}");
        assert!(
            m[0].fix.contains("keychain") && m[0].fix.contains("TCC"),
            "{m:?}"
        );
        assert!(contract(&alice, vec![], own).is_ok());
        assert!(features(&alice).contains(&"account:own".to_string()));

        let admin_raw = Raw {
            admin: "yes drgnx-runner is a member of admin".into(),
            ..mini()
        };
        for a in [none, own] {
            let m = contract(&admin_raw, vec![], a).unwrap_err();
            assert_eq!(m.len(), 1, "{m:?}");
            assert!(m[0].what.contains("non-admin"), "{m:?}");
            assert!(
                m[0].fix.contains("--allow-admin") && m[0].fix.contains("sudo"),
                "{m:?}"
            );
        }
        assert!(contract(&admin_raw, vec![], admin).is_ok());
        assert!(features(&admin_raw).contains(&"account:admin".to_string()));
        // the user's own administrator account: both allowances
        let own_admin = Raw {
            user: "alice".into(),
            admin: "yes alice is a member of admin".into(),
            ..mini()
        };
        assert_eq!(contract(&own_admin, vec![], admin).unwrap_err().len(), 1);
        assert!(contract(&own_admin, vec![], both).is_ok());

        let root = Raw {
            user: "root".into(),
            admin: "yes root is a member of admin".into(),
            ..mini()
        };
        let m = contract(&root, vec![], both).unwrap_err();
        assert_eq!(m.len(), 1, "{m:?}");
        assert!(m[0].what.contains("root"), "{m:?}");
        assert!(!m[0].fix.contains("--allow"), "{m:?}");
    }

    /// [D] A full Xcode whose licence is not accepted: `clang` refuses, the contract names the licence (not the tools),
    /// and no `xcode-clt` feature is advertised.
    #[test]
    fn an_xcode_licence_not_accepted_is_its_own_item() {
        let raw = Raw {
            developer_dir: "/Applications/Xcode.app/Contents/Developer".into(),
            clang: "You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license' \
                    from within a Terminal window to review and agree to the Xcode and Apple SDKs license.\n"
                .into(),
            ..mini()
        };
        let missing = contract(&raw, vec![], Allow::default()).unwrap_err();
        assert_eq!(missing.len(), 1);
        assert!(missing[0].what.contains("licence"));
        assert!(missing[0].fix.contains("xcodebuild -license accept"));
        assert!(!features(&raw).contains(&"xcode-clt".to_string()));
    }

    /// [D] `pmset -g batt` of a laptop on battery, on mains, and of a desktop.
    #[test]
    fn power_from_pmset() {
        let on_batt =
            "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=123)\t81%; discharging;";
        let plugged = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=123)\t100%; charged;";
        assert!(has_battery(on_batt) && !on_ac(on_batt));
        assert!(has_battery(plugged) && on_ac(plugged));
        assert!(!has_battery(&mini().batt) && on_ac(&mini().batt));
    }

    /// [D] Versions: `15.6.1`, `26`, and what is not one.
    #[test]
    fn versions() {
        assert_eq!(parse_version("15.6.1"), Some((15, 6)));
        assert_eq!(parse_version("26"), Some((26, 0)));
        assert_eq!(parse_version("HEAD-abc"), None);
        assert_eq!(parse_version(""), None);
    }

    /// [D] The live read on the macOS CI host: a whole `Raw`. The CI account is an admin and the VM's disk can sit
    /// under the runner's free-space floor, so only those two items may be missing there.
    #[cfg(all(target_os = "macos", feature = "runner"))]
    #[test]
    fn the_live_read_is_whole() {
        let raw = read(std::path::Path::new("/"));
        assert!(parse_version(&raw.product_version).is_some(), "{raw:?}");
        assert_eq!(raw.arm64, "1");
        assert!(num(&raw.ncpu) > 0 && num(&raw.memsize) > 0 && raw.disk_free > 0);
        assert!(raw.boot_session.len() >= 32, "{raw:?}");
        // the CI account is the host's own, not drgnx-runner: allowed here as `--allow-own-account` would
        let own = Allow {
            own_account: true,
            admin: false,
        };
        match contract(&raw, vec![], own) {
            Ok(_) => {}
            Err(m) => assert!(
                m.iter()
                    .all(|m| m.what.contains("standard") || m.what.contains("GB free")),
                "{m:?}"
            ),
        }
    }
}
