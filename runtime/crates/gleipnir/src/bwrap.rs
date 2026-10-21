//! The bubblewrap argv (Task 7; docs/develop/gleipnir.md, "The bubblewrap argv"): pure, built on every target, so
//! its goldens run anywhere. Finding bwrap and opening the sources is `backend::linux::bwrap`.
//!
//! Every source of the spec is bound from an fd the caller opened without following a link ([`Opened`]), so a link
//! swapped in after the check cannot redirect a mount (the pattern of CVE-2024-42472). Only root-owned system paths
//! are bound by path. No environment value is ever in the argv: bwrap gets `--clearenv` and no `--setenv`, and the
//! program's environment travels in the inner spec (fd 3).

use crate::spec::{Bind, HELPER_INSIDE, Mode, Net, RESERVED_DESTS, SYSTEM_CLOSED, Spec, ValidSpec};
use crate::validate::{Refusal, Rule};
use eitri::Kind;
use std::ffi::OsString;
use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};

/// The lowest bubblewrap accepted. 0.12.0 fixes CVE-2026-87766 (GHSA-pxhw-h44j-8pfx): a link met through
/// `/oldroot` while bwrap sets up its mounts let it write outside the sandbox.
pub const FLOOR: (u32, u32, u32) = (0, 12, 0);

/// The inner spec inside bwrap: a sealed memfd (Task 8).
pub const SPEC_FD: i32 = 3;
/// The status pipe's write end inside bwrap (Task 8).
pub const STATUS_FD: i32 = 4;
/// The first bind's fd; the binds follow in argv order, and the helper's is the last.
pub const FIRST_BIND_FD: i32 = 5;

/// Root-owned system trees bound read-only by path where they exist (`--ro-bind-try`). `/usr` is always bound.
pub const SYSTEM_READS: &[&str] = &["/etc", "/opt", "/nix", "/gnu", "/var/lib/flatpak"];

/// The top-level directories a merged-/usr host links into `/usr`: a link on the host becomes `--symlink usr/X /X`,
/// anything else `--ro-bind-try /X /X`.
pub const USR_MERGED: &[&str] = &["bin", "lib", "lib64", "sbin"];

/// How the helper (the `ratatoskr` binary) is started inside: `source` is its path outside, bound read-only at
/// [`HELPER_INSIDE`] and run as `HELPER_INSIDE <inner_args> --spec-fd 3 -- <command>`. `relay_args` are what the
/// inner spec's relay runs (`Sandbox::prepare`); the argv does not use them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InnerCommand {
    pub source: PathBuf,
    pub inner_args: Vec<OsString>,
    pub relay_args: Vec<OsString>,
}

/// One source opened without links, and where it is bound. `dev` and `ino` are the identity it was checked under.
#[derive(Debug)]
pub struct Mount {
    pub source: PathBuf,
    pub dest: PathBuf,
    pub mode: Mode,
    pub dev: u64,
    pub ino: u64,
    pub(crate) fd: OwnedFd,
}

/// A `hide` entry and its kind, from an lstat that followed no link: a directory is covered by an empty tmpfs,
/// anything else by `/dev/null`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hidden {
    pub path: PathBuf,
    pub is_dir: bool,
}

/// What the argv needs to know about the host's root: which of [`USR_MERGED`] are links, and the resolver's file
/// when `/etc/resolv.conf` leads under `/run` (which bwrap replaces by an empty tmpfs).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HostLayout {
    pub usr_links: Vec<&'static str>,
    pub resolver: Option<PathBuf>,
}

/// The pinned sources of one spec, in argv order (home, reads, writes, run, binds), the hides, and the helper.
/// Made by `backend::linux::bwrap::open_sources`; consumed by [`argv`], which hands the fds on.
#[derive(Debug)]
pub struct Opened {
    pub(crate) mounts: Vec<Mount>,
    pub(crate) hides: Vec<Hidden>,
    pub(crate) helper: Mount,
    pub(crate) inner_args: Vec<OsString>,
    pub(crate) host: HostLayout,
}

impl Opened {
    /// The spec's mounts, in argv order.
    pub fn mounts(&self) -> &[Mount] {
        &self.mounts
    }

    /// The helper's mount (always read-only, always last).
    pub fn helper(&self) -> &Mount {
        &self.helper
    }
}

/// One source of the spec to open and bind: the key it came from, what it must be, and how it is bound.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))] // used by backend::linux (built on Linux only)
pub(crate) struct Planned<'a> {
    pub(crate) key: String,
    pub(crate) source: &'a Path,
    pub(crate) dest: &'a Path,
    pub(crate) mode: Mode,
    pub(crate) kind: Kind,
}

/// The spec's sources in argv order, each with the mode it is bound with: the home with its own mode (never widened),
/// reads read-only, writes read-write, `run` read-only whatever its mode says, binds with their own modes.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))] // used by backend::linux (built on Linux only)
pub(crate) fn planned(spec: &Spec) -> Vec<Planned<'_>> {
    fn one(key: String, b: &Bind, mode: Mode, kind: Kind) -> Planned<'_> {
        Planned {
            key,
            source: &b.source,
            dest: &b.dest,
            mode,
            kind,
        }
    }
    let mut out = Vec::new();
    if let Some(h) = &spec.home {
        out.push(one("home".into(), h, h.mode, Kind::Dir));
    }
    for (name, list, mode) in [
        ("read", &spec.read, Mode::Ro),
        ("write", &spec.write, Mode::Rw),
    ] {
        for (i, p) in list.iter().enumerate() {
            out.push(Planned {
                key: format!("{name}[{i}]"),
                source: p,
                dest: p,
                mode,
                kind: Kind::Any,
            });
        }
    }
    if let Some(r) = &spec.run {
        out.push(one("run".into(), r, Mode::Ro, Kind::Dir));
    }
    for (i, b) in spec.binds.iter().enumerate() {
        out.push(one(format!("binds[{i}]"), b, b.mode, Kind::Any));
    }
    out
}

/// `bwrap --version`'s output, `"bubblewrap X.Y.Z"` and an optional newline; anything else is `Malformed`.
pub fn parse_version(out: &str) -> Result<(u32, u32, u32), Refusal> {
    let bad = || {
        malformed(format!(
            "bwrap --version printed {out:?}, not \"bubblewrap X.Y.Z\""
        ))
    };
    let line = out.strip_suffix('\n').unwrap_or(out);
    let version = line.strip_prefix("bubblewrap ").ok_or_else(bad)?;
    let mut parts = version.split('.').map(|p| {
        if !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()) {
            p.parse::<u32>().ok()
        } else {
            None
        }
    });
    match (parts.next(), parts.next(), parts.next(), parts.next()) {
        (Some(Some(a)), Some(Some(b)), Some(Some(c)), None) => Ok((a, b, c)),
        _ => Err(bad()),
    }
}

/// `bwrap --version`'s output, accepted only at or above [`FLOOR`]; below it the refusal names the version, 0.12.0
/// and CVE-2026-87766.
pub fn version_at_floor(out: &str) -> Result<(u32, u32, u32), Refusal> {
    let v = parse_version(out)?;
    if v < FLOOR {
        let (a, b, c) = v;
        return Err(malformed(format!(
            "bubblewrap {a}.{b}.{c} is below 0.12.0, the first release with the fix for CVE-2026-87766 (a link \
             followed while bwrap sets up its mounts lets a sandbox write outside it)"
        )));
    }
    Ok(v)
}

/// May the resolver's file (the true name of `/etc/resolv.conf`) be bound back on top of the empty `/run`? Only a
/// file under `/run`, outside every closed system dir (`/run/user`) and every reserved dest.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))] // used by backend::linux (built on Linux only)
pub(crate) fn resolver_bindable(resolved: &Path) -> bool {
    resolved.starts_with("/run")
        && resolved != Path::new("/run")
        && !SYSTEM_CLOSED.iter().any(|d| resolved.starts_with(d))
        && !RESERVED_DESTS.iter().any(|d| resolved.starts_with(d))
}

/// Where each hide is seen inside: its own path (a read, a write or a system tree shows it there), and for every
/// mount whose dest differs from its source and that holds it, the same place under the dest. In order, once each.
fn hide_places(mounts: &[Mount], hides: &[Hidden]) -> Vec<(PathBuf, bool)> {
    let mut out: Vec<(PathBuf, bool)> = Vec::new();
    for h in hides {
        let moved = mounts
            .iter()
            .filter(|m| m.dest != m.source)
            .filter_map(|m| {
                let rest = h.path.strip_prefix(&m.source).ok()?;
                // `join("")` would add a trailing slash.
                Some(if rest.as_os_str().is_empty() {
                    m.dest.clone()
                } else {
                    m.dest.join(rest)
                })
            });
        for place in std::iter::once(h.path.clone()).chain(moved) {
            if !out.iter().any(|(p, _)| *p == place) {
                out.push((place, h.is_dir));
            }
        }
    }
    out
}

/// bwrap's argv (without the program itself) and the fds to pass, each with its number inside. The order is pinned
/// (docs/develop/gleipnir.md, "The bubblewrap argv"); fd 3 (the inner spec) and fd 4 (the status pipe) are the
/// caller's.
pub fn argv(
    spec: &ValidSpec,
    opened: Opened,
    command: &[String],
) -> (Vec<OsString>, Vec<(OwnedFd, i32)>) {
    let s = spec.spec();
    let mut a: Vec<OsString> = Vec::new();
    let mut push = |args: &[&dyn AsRef<std::ffi::OsStr>]| {
        a.extend(args.iter().map(|x| x.as_ref().to_owned()));
    };
    // 1. Namespaces and lifetime; no --setenv ever.
    push(&[&"--unshare-all", &"--unshare-user"]);
    if s.net == Net::Shared {
        push(&[&"--share-net"]);
    }
    push(&[
        &"--disable-userns",
        &"--die-with-parent",
        &"--new-session",
        &"--clearenv",
    ]);
    // 2. The system's reads, by path: root-owned.
    push(&[&"--ro-bind", &"/usr", &"/usr"]);
    for d in SYSTEM_READS {
        push(&[&"--ro-bind-try", d, d]);
    }
    for x in USR_MERGED {
        let top = format!("/{x}");
        if opened.host.usr_links.contains(x) {
            push(&[&"--symlink", &format!("usr/{x}"), &top]);
        } else {
            push(&[&"--ro-bind-try", &top, &top]);
        }
    }
    // 3. Private /dev, /proc, /tmp, /run, /var/tmp.
    push(&[
        &"--dev",
        &"/dev",
        &"--proc",
        &"/proc",
        &"--tmpfs",
        &"/tmp",
        &"--tmpfs",
        &"/run",
        &"--tmpfs",
        &"/var/tmp",
    ]);
    // 4. The resolver's file, back on top of the empty /run.
    if let Some(r) = &opened.host.resolver {
        push(&[&"--ro-bind-try", r, r]);
    }
    // 5–6. The spec's sources by fd, each with its own mode: home, reads, writes, run, binds.
    let hides = hide_places(&opened.mounts, &opened.hides);
    let mut fds = Vec::new();
    let mut next = FIRST_BIND_FD;
    for m in opened.mounts {
        let flag = match m.mode {
            Mode::Ro => "--ro-bind-fd",
            Mode::Rw => "--bind-fd",
        };
        push(&[&flag, &next.to_string(), &m.dest]);
        fds.push((m.fd, next));
        next += 1;
    }
    // 7. Hides: a directory by an empty tmpfs, anything else by /dev/null.
    for (place, is_dir) in &hides {
        if *is_dir {
            push(&[&"--tmpfs", place]);
        } else {
            push(&[&"--ro-bind", &"/dev/null", place]);
        }
    }
    // 8. The helper last, read-only, so that no later mount covers it (review S1).
    push(&[&"--ro-bind-fd", &next.to_string(), &HELPER_INSIDE]);
    fds.push((opened.helper.fd, next));
    // 9. The program: the helper, which applies Landlock and seccomp, then the command.
    push(&[&"--chdir", &s.chdir, &"--", &HELPER_INSIDE]);
    for x in &opened.inner_args {
        push(&[x]);
    }
    push(&[&"--spec-fd", &SPEC_FD.to_string(), &"--"]);
    for x in command {
        push(&[x]);
    }
    (a, fds)
}

fn malformed(message: String) -> Refusal {
    Refusal {
        rule: Rule::Malformed,
        path: None,
        message,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::{Bind, Layers, RelayPort, Target};
    use std::fs::File;

    const CANARY: &str = "glp-canary-5d1e0b7a";

    fn devnull() -> OwnedFd {
        File::open("/dev/null").unwrap().into()
    }

    fn isolated() -> Net {
        Net::Isolated {
            relay: vec![RelayPort {
                port: 3128,
                socket: "/run/drgnx/proxy.sock".into(),
            }],
            mac_tcp_ports: vec![],
        }
    }

    fn bind(mode: Mode, source: &str, dest: &str) -> Bind {
        Bind {
            mode,
            source: source.into(),
            dest: dest.into(),
        }
    }

    /// A spec with every key bwrap binds: a private home, reads, a write, the session dir, a git pin over the task
    /// folder's `.git`, an output dir at another path, and hides in the task folder and in the home.
    fn spec(net: Net) -> Spec {
        Spec {
            read: vec!["/work/docs".into(), "/tools/node".into()],
            write: vec!["/work/task".into()],
            hide: vec![
                "/work/task/.env".into(),
                "/state/home-1/.cache/creds".into(),
            ],
            sockets: vec!["/rt/s/S1/proxy.sock".into()],
            binds: vec![
                bind(Mode::Ro, "/work/task/.git", "/work/task/.git"),
                bind(Mode::Rw, "/state/out-1", "/mnt/out"),
            ],
            home: Some(bind(Mode::Rw, "/state/home-1", "/agent")),
            run: Some(bind(Mode::Ro, "/rt/s/S1", "/run/drgnx")),
            env: vec![
                ("PATH".into(), "/usr/bin".into()),
                ("API_KEY".into(), CANARY.into()),
            ],
            chdir: "/work/task".into(),
            net,
            tmp: None,
            layers: Layers::for_target(Target::LinuxBwrap),
            extra_tcp_ports: vec![],
        }
    }

    /// What `open_sources` would give for `spec`, with `/dev/null` for every fd. Hides ending in `creds` are dirs.
    fn opened_for(spec: &Spec, host: HostLayout) -> Opened {
        let mount = |source: &Path, dest: &Path, mode| Mount {
            source: source.into(),
            dest: dest.into(),
            mode,
            dev: 0,
            ino: 0,
            fd: devnull(),
        };
        Opened {
            mounts: planned(spec)
                .iter()
                .map(|p| mount(p.source, p.dest, p.mode))
                .collect(),
            hides: spec
                .hide
                .iter()
                .map(|p| Hidden {
                    path: p.clone(),
                    is_dir: p.ends_with("creds"),
                })
                .collect(),
            helper: mount(
                Path::new("/opt/drgnx/bin/ratatoskr"),
                Path::new(HELPER_INSIDE),
                Mode::Ro,
            ),
            inner_args: vec!["sandbox-inner".into()],
            host,
        }
    }

    fn merged() -> HostLayout {
        HostLayout {
            usr_links: USR_MERGED.to_vec(),
            resolver: Some("/run/systemd/resolve/stub-resolv.conf".into()),
        }
    }

    /// The argv of `spec` under `host`, as strings, and the fd numbers passed.
    fn run(spec: Spec, host: HostLayout, command: &[&str]) -> (Vec<String>, Vec<i32>) {
        let opened = opened_for(&spec, host);
        let valid = ValidSpec::assume_valid(spec, Target::LinuxBwrap);
        let command: Vec<String> = command.iter().map(|s| s.to_string()).collect();
        let (argv, fds) = argv(&valid, opened, &command);
        let argv = argv.into_iter().map(|a| a.into_string().unwrap()).collect();
        (argv, fds.into_iter().map(|(_, n)| n).collect())
    }

    /// The options part: everything before the first bare `--` (after it come the helper and the command).
    fn options(argv: &[String]) -> &[String] {
        let end = argv.iter().position(|a| a == "--").expect("a bare --");
        &argv[..end]
    }

    /// One line per option and its operands, then the fds passed.
    fn render(argv: &[String], fds: &[i32]) -> String {
        let mut out = String::new();
        for a in argv {
            if a.starts_with("--") && !out.is_empty() {
                out.push('\n');
            } else if !out.is_empty() {
                out.push(' ');
            }
            out.push_str(a);
        }
        let fds: Vec<String> = fds.iter().map(|n| n.to_string()).collect();
        format!("{out}\n\nfds passed: {}\n", fds.join(" "))
    }

    #[test]
    fn argv_golden_shared() {
        let host = HostLayout::default();
        let (argv, fds) = run(spec(Net::Shared), host, &["/usr/bin/agent", "--x"]);
        insta::assert_snapshot!(render(&argv, &fds));
    }

    #[test]
    fn argv_golden_isolated() {
        let (argv, fds) = run(spec(isolated()), merged(), &["/usr/bin/agent", "--x"]);
        insta::assert_snapshot!(render(&argv, &fds));
    }

    const MANDATORY: &[&str] = &[
        "--unshare-all",
        "--unshare-user",
        "--disable-userns",
        "--die-with-parent",
        "--new-session",
        "--clearenv",
    ];

    /// The namespace and lifetime flags lead the argv, each once, whatever the spec; `--share-net` only for a shared
    /// network.
    #[test]
    fn mandatory_flags_always() {
        let mut bare = spec(Net::Shared);
        bare.read.clear();
        bare.write.clear();
        bare.hide.clear();
        bare.binds.clear();
        bare.home = None;
        bare.run = None;
        for (s, shared) in [
            (spec(Net::Shared), true),
            (spec(isolated()), false),
            (bare, true),
        ] {
            let (argv, _) = run(s, merged(), &["/bin/true"]);
            let opts = options(&argv);
            let lead: Vec<&str> = opts[..MANDATORY.len() + usize::from(shared)]
                .iter()
                .map(String::as_str)
                .filter(|a| *a != "--share-net")
                .collect();
            assert_eq!(lead, MANDATORY, "{argv:?}");
            for flag in MANDATORY {
                assert_eq!(opts.iter().filter(|a| a == flag).count(), 1, "{flag}");
            }
            let share = opts.iter().filter(|a| *a == "--share-net").count();
            assert_eq!(share, usize::from(shared), "{argv:?}");
            assert!(!opts.iter().any(|a| a == "--unshare-user-try"));
        }
    }

    #[test]
    fn no_setenv_and_no_env_value_in_argv() {
        for net in [Net::Shared, isolated()] {
            let s = spec(net);
            assert!(
                s.env.iter().any(|(_, v)| v == CANARY),
                "the fixture has the canary"
            );
            let (argv, _) = run(s, merged(), &["/usr/bin/agent"]);
            assert!(!argv.iter().any(|a| a.contains(CANARY)), "{argv:?}");
            assert!(!argv.iter().any(|a| a.contains("API_KEY")), "{argv:?}");
            for flag in ["--setenv", "--unsetenv", "--env"] {
                assert!(!argv.iter().any(|a| a == flag), "{flag} in {argv:?}");
            }
        }
    }

    /// The flags that make a mount, a link or a node in bwrap's new root.
    const MOUNTING: &[&str] = &[
        "--bind",
        "--bind-try",
        "--ro-bind",
        "--ro-bind-try",
        "--dev-bind",
        "--dev-bind-try",
        "--bind-fd",
        "--ro-bind-fd",
        "--tmpfs",
        "--symlink",
        "--dir",
        "--file",
        "--bind-data",
        "--ro-bind-data",
        "--dev",
        "--proc",
        "--mqueue",
        "--overlay",
        "--tmp-overlay",
        "--ro-overlay",
    ];

    /// The helper is bound last, so no later mount can cover it (review S1); a `--bind` in the command is not an
    /// option.
    #[test]
    fn helper_bind_is_last() {
        for net in [Net::Shared, isolated()] {
            let (argv, fds) = run(
                spec(net),
                merged(),
                &["/usr/bin/agent", "--bind", "/", "/x"],
            );
            let opts = options(&argv);
            let at = opts
                .iter()
                .rposition(|a| a == HELPER_INSIDE)
                .expect("the helper is bound");
            assert_eq!(opts[at - 2], "--ro-bind-fd");
            assert_eq!(opts[at - 1], fds.last().unwrap().to_string());
            assert!(
                !opts[at + 1..]
                    .iter()
                    .any(|a| MOUNTING.contains(&a.as_str())),
                "{:?}",
                &opts[at + 1..]
            );
            let rest = &argv[opts.len()..];
            let mut tail = vec!["--", HELPER_INSIDE, "sandbox-inner", "--spec-fd", "3", "--"];
            tail.extend(["/usr/bin/agent", "--bind", "/", "/x"]);
            assert_eq!(rest, tail, "{argv:?}");
            assert_eq!(&opts[opts.len() - 2..], ["--chdir", "/work/task"]);
        }
    }

    /// Each bind keeps its mode, and nothing is widened: a home asked `ro` is bound read-only, and `run` is read-only
    /// even when a spec that skipped validation says `rw` (Task 0's note).
    #[test]
    fn modes_are_honoured() {
        let flag_for = |argv: &[String], dest: &str| {
            let i = argv.iter().position(|a| a == dest).expect(dest);
            argv[i - 2].clone()
        };
        let mut s = spec(Net::Shared);
        s.home.as_mut().unwrap().mode = Mode::Ro;
        s.run.as_mut().unwrap().mode = Mode::Rw;
        let (argv, _) = run(s, merged(), &["/bin/true"]);
        assert_eq!(flag_for(&argv, "/agent"), "--ro-bind-fd");
        assert_eq!(flag_for(&argv, "/run/drgnx"), "--ro-bind-fd");
        assert_eq!(flag_for(&argv, "/work/docs"), "--ro-bind-fd");
        assert_eq!(flag_for(&argv, "/tools/node"), "--ro-bind-fd");
        assert_eq!(flag_for(&argv, "/mnt/out"), "--bind-fd");
        let (argv, _) = run(spec(Net::Shared), merged(), &["/bin/true"]);
        assert_eq!(flag_for(&argv, "/agent"), "--bind-fd");
        let opts = options(&argv);
        // Every bind whose dest is `dest` (`--chdir` is not one).
        let binds_at = |dest: &str| -> Vec<String> {
            opts.windows(3)
                .filter(|w| w[2] == dest && w[0].contains("bind"))
                .map(|w| w[0].clone())
                .collect()
        };
        assert_eq!(binds_at("/work/task"), ["--bind-fd"], "the write");
        assert_eq!(
            binds_at("/work/task/.git"),
            ["--ro-bind-fd"],
            "the pin over the write"
        );
    }

    /// The fds are numbered from 5 in argv order, each passed once, the helper's last.
    #[test]
    fn fds_follow_the_argv_from_5() {
        let s = spec(isolated());
        let want = planned(&s).len() + 1;
        let (argv, fds) = run(s, merged(), &["/bin/true"]);
        let opts = options(&argv);
        let in_argv: Vec<i32> = opts
            .windows(2)
            .filter(|w| w[0] == "--bind-fd" || w[0] == "--ro-bind-fd")
            .map(|w| w[1].parse().unwrap())
            .collect();
        let expected: Vec<i32> = (FIRST_BIND_FD..FIRST_BIND_FD + want as i32).collect();
        assert_eq!(in_argv, expected);
        assert_eq!(fds, expected);
        assert!(!fds.contains(&SPEC_FD) && !fds.contains(&STATUS_FD));
    }

    /// A hide covers the place it is seen at: its own path, and inside a bind whose dest differs from its source
    /// (the home here) the matching path under the dest. A directory gets a tmpfs, a file `/dev/null`.
    #[test]
    fn hides_follow_a_bind_to_its_dest() {
        let (argv, _) = run(spec(Net::Shared), merged(), &["/bin/true"]);
        let opts = options(&argv).join(" ");
        assert!(
            opts.contains("--ro-bind /dev/null /work/task/.env"),
            "{opts}"
        );
        assert!(
            opts.contains("--tmpfs /state/home-1/.cache/creds"),
            "{opts}"
        );
        assert!(opts.contains("--tmpfs /agent/.cache/creds"), "{opts}");
        assert_eq!(opts.matches("/work/task/.env").count(), 1, "{opts}");
        let mut whole = spec(Net::Shared);
        whole.hide = vec!["/state/out-1".into()];
        let (argv, _) = run(whole, merged(), &["/bin/true"]);
        let opts = options(&argv).join(" ");
        assert!(opts.contains("--ro-bind /dev/null /mnt/out "), "{opts}");
        assert!(!opts.contains("/mnt/out/"), "{opts}");
    }

    #[test]
    fn version_floor_table() {
        for out in [
            "bubblewrap 0.11.1\n",
            "bubblewrap 0.11.99",
            "bubblewrap 0.4.0\n",
        ] {
            let r = version_at_floor(out).expect_err(out);
            assert_eq!(r.rule, Rule::Malformed, "{out}");
            assert!(r.message.contains("CVE-2026-87766"), "{}", r.message);
            assert!(r.message.contains("0.12.0"), "{}", r.message);
            let v = out.trim_end().trim_start_matches("bubblewrap ");
            assert!(r.message.contains(v), "{}", r.message);
        }
        assert_eq!(version_at_floor("bubblewrap 0.12.0\n"), Ok((0, 12, 0)));
        assert_eq!(version_at_floor("bubblewrap 0.13.1\n"), Ok((0, 13, 1)));
        assert_eq!(version_at_floor("bubblewrap 1.0.0"), Ok((1, 0, 0)));
        for out in [
            "",
            "\n",
            "bwrap 0.12.0\n",
            "bubblewrap 0.12\n",
            "bubblewrap 0.12.0.1\n",
            "bubblewrap 0.12.0-rc1\n",
            "bubblewrap 0..12\n",
            "bubblewrap +0.12.0\n",
            "bubblewrap 0.12.0\nbubblewrap 0.13.0\n",
            "bubblewrap 0.12.99999999999\n",
            " bubblewrap 0.12.0\n",
            "garbage",
        ] {
            let r = parse_version(out).expect_err(out);
            assert_eq!(r.rule, Rule::Malformed, "{out:?}");
            assert!(version_at_floor(out).is_err(), "{out:?}");
        }
        assert_eq!(parse_version("bubblewrap 0.11.1\n"), Ok((0, 11, 1)));
    }

    #[test]
    fn resolver_bindable_table() {
        for ok in [
            "/run/systemd/resolve/stub-resolv.conf",
            "/run/NetworkManager/resolv.conf",
        ] {
            assert!(resolver_bindable(Path::new(ok)), "{ok}");
        }
        for no in [
            "/run",
            "/etc/resolv.conf",
            "/run/user/1000/resolv.conf",
            "/run/gleipnir/x",
            "/runx/resolv.conf",
        ] {
            assert!(!resolver_bindable(Path::new(no)), "{no}");
        }
    }
}
