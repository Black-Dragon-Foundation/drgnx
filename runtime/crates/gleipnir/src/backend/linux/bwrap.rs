//! The full tier: bwrap ≥ 0.12.0 from a root-owned path, its version floor, the sources opened and passed by fd
//! (Task 7; docs/develop/gleipnir.md, "The bubblewrap argv"). The argv itself is the pure [`crate::bwrap`].

use crate::bwrap::{
    Hidden, HostLayout, InnerCommand, Mount, Opened, USR_MERGED, planned, resolver_bindable,
    version_at_floor,
};
use crate::spec::{HELPER_INSIDE, Mode, Target, ValidSpec};
use crate::validate::{Refusal, Rule};
use eitri::{FsError, Kind, TrustedProgram, open_path, trusted_program};
use std::fs;
use std::io::{self, Read};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Where bwrap is looked for, in order. `PATH` is never consulted (review S12).
pub const CANDIDATES: &[&str] = &["/usr/bin/bwrap", "/bin/bwrap", "/usr/local/bin/bwrap"];

/// How long `bwrap --version` may take.
pub const VERSION_DEADLINE: Duration = Duration::from_secs(2);

/// bwrap from [`CANDIDATES`]: the first root-owned one, at or above [`crate::bwrap::FLOOR`].
pub fn find() -> Result<(TrustedProgram, (u32, u32, u32)), Refusal> {
    let candidates: Vec<&Path> = CANDIDATES.iter().map(Path::new).collect();
    find_in(&candidates)
}

/// The bwrap the check reports: the first root-owned candidate (or `only`) and the version it prints, whatever the
/// version is (the floor is [`find`]'s to enforce). `None` when none is root-owned or its version is unreadable.
pub fn probe(only: Option<&Path>) -> Option<(std::path::PathBuf, (u32, u32, u32))> {
    let all: Vec<&Path> = match only {
        Some(p) => vec![p],
        None => CANDIDATES.iter().map(Path::new).collect(),
    };
    let prog = trusted_program(&all).ok()?;
    let out = version_output(&prog.path, VERSION_DEADLINE).ok()?;
    let version = crate::bwrap::parse_version(&out).ok()?;
    Some((prog.path, version))
}

/// The first of `candidates` that only root can change (`eitri::trusted_program`), run with `--version` within
/// [`VERSION_DEADLINE`] and accepted only at or above the floor.
pub fn find_in(candidates: &[&Path]) -> Result<(TrustedProgram, (u32, u32, u32)), Refusal> {
    find_with(candidates, VERSION_DEADLINE)
}

fn find_with(
    candidates: &[&Path],
    deadline: Duration,
) -> Result<(TrustedProgram, (u32, u32, u32)), Refusal> {
    let names: Vec<String> = candidates.iter().map(|c| c.display().to_string()).collect();
    let prog = trusted_program(candidates).map_err(|e| {
        malformed(format!(
            "no bubblewrap only root can change among {}: {e}",
            names.join(", ")
        ))
    })?;
    let out = version_output(&prog.path, deadline)?;
    let version = version_at_floor(&out)?;
    Ok((prog, version))
}

/// What `PROGRAM --version` prints, run with an empty environment and no stdin. Past `deadline` it is killed and
/// refused; a failing exit or output that is not UTF-8 is refused too.
fn version_output(program: &Path, deadline: Duration) -> Result<String, Refusal> {
    let what = format!("{} --version", program.display());
    let failed = |why: String| malformed(format!("{what}: {why}"));
    let mut child = Command::new(program)
        .arg("--version")
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| failed(format!("cannot run it ({e})")))?;
    let start = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if start.elapsed() < deadline => std::thread::sleep(Duration::from_millis(10)),
            waited => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(failed(match waited {
                    Err(e) => format!("cannot wait for it ({e})"),
                    _ => format!("no answer within {} ms", deadline.as_millis()),
                }));
            }
        }
    };
    if !status.success() {
        return Err(failed(format!("exited with {status}")));
    }
    // It has exited: read what it left in the pipe without blocking (a child of its own may still hold the pipe).
    let mut stdout = child.stdout.take().expect("piped");
    rustix::fs::fcntl_setfl(&stdout, rustix::fs::OFlags::NONBLOCK)
        .map_err(|e| failed(format!("cannot read its output ({e})")))?;
    let mut buf = Vec::new();
    match (&mut stdout).take(4096).read_to_end(&mut buf) {
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
        Err(e) => return Err(failed(format!("cannot read its output ({e})"))),
    }
    String::from_utf8(buf).map_err(|_| failed("its output is not UTF-8".into()))
}

/// Opens every source of `spec` (home, reads, writes, run, binds) and the helper with `eitri::open_path`, which
/// follows no link, checks each one's kind, and lstats each `hide` entry the same way. Only a spec validated for
/// `Target::LinuxBwrap` is accepted.
pub fn open_sources(spec: &ValidSpec, helper: &InnerCommand) -> Result<Opened, Refusal> {
    if spec.target() != Target::LinuxBwrap {
        return Err(malformed(format!(
            "a spec validated for {:?} cannot run under bwrap",
            spec.target()
        )));
    }
    let s = spec.spec();
    let mounts = planned(s)
        .into_iter()
        .map(|p| pin(&p.key, p.source, p.kind, p.mode, p.dest))
        .collect::<Result<Vec<_>, _>>()?;
    let hides = s
        .hide
        .iter()
        .enumerate()
        .map(|(i, p)| {
            let pinned =
                open_path(p, Kind::Any).map_err(|e| refused(&format!("hide[{i}]"), p, e))?;
            Ok(Hidden {
                path: p.clone(),
                is_dir: pinned.is_dir,
            })
        })
        .collect::<Result<Vec<_>, Refusal>>()?;
    let helper_mount = pin(
        "helper",
        &helper.source,
        Kind::File,
        Mode::Ro,
        Path::new(HELPER_INSIDE),
    )?;
    Ok(Opened {
        mounts,
        hides,
        helper: helper_mount,
        inner_args: helper.inner_args.clone(),
        host: host_layout(),
    })
}

/// Opens `source` following no link, as `kind`, to be bound at `dest` with `mode`.
fn pin(key: &str, source: &Path, kind: Kind, mode: Mode, dest: &Path) -> Result<Mount, Refusal> {
    let p = open_path(source, kind).map_err(|e| refused(key, source, e))?;
    Ok(Mount {
        source: source.to_path_buf(),
        dest: dest.to_path_buf(),
        mode,
        dev: p.dev,
        ino: p.ino,
        fd: p.fd,
    })
}

/// A source that could not be opened: a link is `NotCanonical` (rule 1, met after validation), a missing one
/// `Missing`, a kind mismatch or anything else `Malformed`.
fn refused(key: &str, path: &Path, e: FsError) -> Refusal {
    let rule = match &e {
        FsError::Link { .. } => Rule::NotCanonical,
        FsError::Io(io) if io.kind() == io::ErrorKind::NotFound => Rule::Missing,
        _ => Rule::Malformed,
    };
    Refusal {
        rule,
        path: Some(path.to_path_buf()),
        message: format!("{key}: {} cannot be bound: {e}", path.display()),
    }
}

/// Which of the host's `/bin`, `/lib`, `/lib64`, `/sbin` are links, and the resolver's file when bindable.
pub fn host_layout() -> HostLayout {
    let usr_links = USR_MERGED
        .iter()
        .copied()
        .filter(|x| fs::symlink_metadata(format!("/{x}")).is_ok_and(|m| m.file_type().is_symlink()))
        .collect();
    let resolver = fs::canonicalize("/etc/resolv.conf")
        .ok()
        .filter(|r| resolver_bindable(r) && fs::metadata(r).is_ok_and(|m| m.is_file()));
    HostLayout {
        usr_links,
        resolver,
    }
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
    use crate::bwrap::{SYSTEM_READS, USR_MERGED, argv};
    use crate::spec::{Bind, HELPER_INSIDE, Layers, Mode, Net, Spec, Target};
    use crate::validate::{Context, Rule, validate};
    use std::fs;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    use std::path::PathBuf;

    fn is_root() -> bool {
        rustix::process::geteuid().is_root()
    }

    /// A tree under /tmp/glp-XXXXXX: `home/u` (the user's home) with `proj` (the task folder: `.env`, `cache/`) and
    /// `tools`; `state` (closed) with `J1` (this job's, open) holding `home-1` and `out`; `rt/s/S1` (the session
    /// dir); `bin/ratatoskr` (the helper).
    struct Fx {
        _dir: tempfile::TempDir,
        b: PathBuf,
    }

    impl Fx {
        fn new() -> Fx {
            let dir = tempfile::Builder::new().prefix("glp-").tempdir().unwrap();
            let b = fs::canonicalize(dir.path()).unwrap();
            for d in [
                "home/u/proj/cache",
                "home/u/tools",
                "state/J1/home-1",
                "state/J1/out",
                "rt/s/S1",
                "bin",
                "canary",
            ] {
                fs::create_dir_all(b.join(d)).unwrap();
            }
            for f in ["home/u/proj/.env", "rt/s/S1/proxy.sock", "bin/ratatoskr"] {
                fs::write(b.join(f), "x").unwrap();
            }
            Fx { _dir: dir, b }
        }

        fn p(&self, rel: &str) -> PathBuf {
            self.b.join(rel)
        }

        fn ctx(&self) -> Context {
            Context {
                home: self.p("home/u"),
                closed: vec![self.p("state"), self.p("rt")],
                open_inside_closed: vec![self.p("state/J1")],
                run_parents: vec![self.p("rt/s")],
                program_dirs: vec!["/usr/bin".into()],
                ..Context::default()
            }
        }

        fn spec(&self) -> Spec {
            Spec {
                read: vec![self.p("home/u/tools")],
                write: vec![self.p("home/u/proj")],
                hide: vec![self.p("home/u/proj/.env"), self.p("home/u/proj/cache")],
                sockets: vec![self.p("rt/s/S1/proxy.sock")],
                binds: vec![Bind {
                    mode: Mode::Rw,
                    source: self.p("state/J1/out"),
                    dest: "/mnt/out".into(),
                }],
                home: Some(Bind {
                    mode: Mode::Rw,
                    source: self.p("state/J1/home-1"),
                    dest: "/home/agent".into(),
                }),
                run: Some(Bind {
                    mode: Mode::Ro,
                    source: self.p("rt/s/S1"),
                    dest: "/run/drgnx".into(),
                }),
                env: vec![("PATH".into(), "/usr/bin".into())],
                chdir: self.p("home/u/proj"),
                net: Net::Shared,
                tmp: None,
                layers: Layers::for_target(Target::LinuxBwrap),
                extra_tcp_ports: vec![],
            }
        }

        fn helper(&self) -> InnerCommand {
            InnerCommand {
                source: self.p("bin/ratatoskr"),
                inner_args: vec!["sandbox-inner".into()],
                relay_args: vec![],
            }
        }

        fn valid(&self) -> ValidSpec {
            validate(self.spec(), &self.ctx(), Target::LinuxBwrap).expect("the fixture validates")
        }
    }

    fn strings(argv: &[std::ffi::OsString]) -> Vec<String> {
        argv.iter()
            .map(|a| a.to_str().unwrap().to_owned())
            .collect()
    }

    fn options(argv: &[String]) -> &[String] {
        &argv[..argv.iter().position(|a| a == "--").unwrap()]
    }

    fn id(p: &Path) -> (u64, u64) {
        let m = fs::symlink_metadata(p).unwrap();
        (m.dev(), m.ino())
    }

    fn fd_id(fd: &std::os::fd::OwnedFd) -> (u64, u64) {
        let st = rustix::fs::fstat(fd).unwrap();
        (st.st_dev, st.st_ino)
    }

    /// No source of the spec is bound by its path: after a path bind comes only a root-owned system path, after an
    /// fd bind a number, and each source is one fd, opened once. A link swapped in after the open does not change
    /// what that fd is (review focus 3).
    #[test]
    fn sources_are_opened_once_and_passed_by_fd() {
        let fx = Fx::new();
        let valid = fx.valid();
        let opened = open_sources(&valid, &fx.helper()).expect("opens");
        let want = [
            ("home/u/tools", "read"),
            ("home/u/proj", "write"),
            ("state/J1/out", "bind"),
            ("state/J1/home-1", "home"),
            ("rt/s/S1", "run"),
        ];
        assert_eq!(opened.mounts().len(), want.len());
        for (rel, what) in want {
            let m = opened
                .mounts()
                .iter()
                .find(|m| m.source == fx.p(rel))
                .unwrap_or_else(|| panic!("{what} is opened"));
            assert_eq!((m.dev, m.ino), id(&fx.p(rel)), "{what}");
            assert_eq!(fd_id(&m.fd), id(&fx.p(rel)), "{what}: the fd is the source");
        }
        assert_eq!(fd_id(&opened.helper().fd), id(&fx.p("bin/ratatoskr")));

        // The write is swapped for a link to the canary after the open: the fd still holds the original.
        let task = fx.p("home/u/proj");
        let before = id(&task);
        fs::rename(&task, fx.p("home/u/proj.old")).unwrap();
        std::os::unix::fs::symlink(fx.p("canary"), &task).unwrap();
        let w = opened.mounts().iter().find(|m| m.source == task).unwrap();
        assert_eq!(fd_id(&w.fd), before);
        assert_ne!(fd_id(&w.fd), id(&fx.p("canary")));

        let n = opened.mounts().len() + 1;
        let (argv, fds) = argv(&valid, opened, &["/bin/true".into()]);
        let argv = strings(&argv);
        let opts = options(&argv);
        let mut allowed: Vec<String> = SYSTEM_READS.iter().map(|s| s.to_string()).collect();
        allowed.extend(USR_MERGED.iter().map(|x| format!("/{x}")));
        allowed.extend(["/usr".into(), "/dev/null".into()]);
        allowed.extend(
            host_layout()
                .resolver
                .map(|r| r.to_str().unwrap().to_owned()),
        );
        let mut numbers = Vec::new();
        for (i, a) in opts.iter().enumerate() {
            match a.as_str() {
                "--bind" | "--ro-bind" | "--bind-try" | "--ro-bind-try" | "--dev-bind"
                | "--dev-bind-try" => {
                    assert!(allowed.contains(&opts[i + 1]), "{a} {}", opts[i + 1]);
                }
                "--bind-fd" | "--ro-bind-fd" => numbers.push(opts[i + 1].parse::<i32>().unwrap()),
                _ => {}
            }
        }
        let mut passed: Vec<i32> = fds.iter().map(|(_, n)| *n).collect();
        assert_eq!(numbers, passed, "each fd bind has its fd");
        passed.dedup();
        assert_eq!(passed.len(), n, "one fd per source and the helper");
        // The fixture's paths appear only as places inside (a write, a read or a hide is seen at its own path).
        let base = fx.b.to_str().unwrap();
        for (i, a) in opts.iter().enumerate().filter(|(_, a)| a.starts_with(base)) {
            let flag = opts[i - 1].as_str();
            let ok = matches!(flag, "--tmpfs" | "--chdir")
                || (opts[i - 2] == "--ro-bind" && opts[i - 1] == "/dev/null")
                || matches!(opts[i - 2].as_str(), "--bind-fd" | "--ro-bind-fd");
            assert!(ok, "{a} after {flag}");
        }
    }

    /// A link swapped in between validation and the open is refused, never followed.
    #[test]
    fn a_link_swapped_in_before_the_open_is_refused() {
        let fx = Fx::new();
        let valid = fx.valid();
        let task = fx.p("home/u/proj");
        fs::rename(&task, fx.p("home/u/proj.old")).unwrap();
        std::os::unix::fs::symlink(fx.p("canary"), &task).unwrap();
        let r = open_sources(&valid, &fx.helper()).expect_err("a link");
        assert_eq!(r.rule, Rule::NotCanonical, "{}", r.message);
        assert!(r.message.contains("write[0]"), "{}", r.message);
    }

    /// Task 2 refuses the home, a parent of it and the user's runtime dir in every source key; asserted again here,
    /// and no fd of a valid spec is the home, `/` or `/run/user`.
    #[test]
    fn never_binds_run_user_or_home() {
        let fx = Fx::new();
        let home = fx.p("home/u");
        for bad in [home.clone(), fx.p("home"), PathBuf::from("/run/user")] {
            let mut s = fx.spec();
            s.read.push(bad.clone());
            let r = validate(s, &fx.ctx(), Target::LinuxBwrap).expect_err("refused");
            assert!(
                matches!(r.rule, Rule::ExposesUser | Rule::Closed),
                "{bad:?}: {r:?}"
            );
        }
        let opened = open_sources(&fx.valid(), &fx.helper()).unwrap();
        let mut never = vec![id(&home), id(Path::new("/"))];
        if Path::new("/run/user").exists() {
            never.push(id(Path::new("/run/user")));
        }
        for m in opened.mounts().iter().chain([opened.helper()]) {
            assert!(!never.contains(&fd_id(&m.fd)), "{:?}", m.source);
        }
        let (argv, _) = argv(&fx.valid(), opened, &["/bin/true".into()]);
        let argv = strings(&argv);
        let opts = options(&argv);
        // Sources bound by path: none is the home, above it, or the user's runtime dir.
        for w in opts.windows(2) {
            if matches!(
                w[0].as_str(),
                "--bind"
                    | "--ro-bind"
                    | "--bind-try"
                    | "--ro-bind-try"
                    | "--dev-bind"
                    | "--dev-bind-try"
            ) {
                let src = Path::new(&w[1]);
                assert!(!home.starts_with(src), "{src:?} is the home or above it");
                assert!(!src.starts_with("/run/user"), "{src:?}");
                assert!(!Path::new("/run/user").starts_with(src), "{src:?}");
            }
        }
    }

    /// A hide's kind comes from an lstat that follows no link: a directory → `--tmpfs`, a file → `/dev/null`, and a
    /// link swapped in after validation is refused.
    #[test]
    fn hide_kind_by_lstat() {
        let fx = Fx::new();
        let valid = fx.valid();
        let (argv, _) = argv(&valid, open_sources(&valid, &fx.helper()).unwrap(), &[]);
        let opts = options(&strings(&argv)).join(" ");
        let env = fx.p("home/u/proj/.env");
        let cache = fx.p("home/u/proj/cache");
        assert!(
            opts.contains(&format!("--ro-bind /dev/null {}", env.display())),
            "{opts}"
        );
        assert!(
            opts.contains(&format!("--tmpfs {}", cache.display())),
            "{opts}"
        );
        fs::remove_dir(&cache).unwrap();
        std::os::unix::fs::symlink(fx.p("canary"), &cache).unwrap();
        let r = open_sources(&valid, &fx.helper()).expect_err("a link");
        assert_eq!(r.rule, Rule::NotCanonical, "{}", r.message);
        assert!(r.message.contains("hide[1]"), "{}", r.message);
    }

    /// The home and run must be directories and the helper a regular file; a mismatch is `Malformed`. A spec for
    /// another target is refused.
    #[test]
    fn kinds_are_checked() {
        let fx = Fx::new();
        let mut s = fx.spec();
        s.home.as_mut().unwrap().source = fx.p("home/u/proj/.env");
        let r = open_sources(
            &ValidSpec::assume_valid(s, Target::LinuxBwrap),
            &fx.helper(),
        )
        .expect_err("home is a file");
        assert_eq!(r.rule, Rule::Malformed, "{}", r.message);
        let mut h = fx.helper();
        h.source = fx.p("bin");
        let r = open_sources(&fx.valid(), &h).expect_err("the helper is a dir");
        assert_eq!(r.rule, Rule::Malformed, "{}", r.message);
        let reduced = ValidSpec::assume_valid(fx.spec(), Target::LinuxReduced);
        let r = open_sources(&reduced, &fx.helper()).expect_err("not a bwrap spec");
        assert_eq!(r.rule, Rule::Malformed, "{}", r.message);
        let mut gone = fx.spec();
        gone.write = vec![fx.p("home/u/nothing")];
        let r = open_sources(
            &ValidSpec::assume_valid(gone, Target::LinuxBwrap),
            &fx.helper(),
        )
        .expect_err("missing");
        assert_eq!(r.rule, Rule::Missing, "{}", r.message);
    }

    /// A fake bwrap that would leave a marker if run; owned by a user, so it is never run.
    fn fake(dir: &Path, name: &str, body: &str) -> PathBuf {
        let d = dir.join(name);
        fs::create_dir(&d).unwrap();
        let p = d.join("bwrap");
        fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
        p
    }

    #[test]
    fn find_refuses_a_user_owned_bwrap() {
        // As root, under root-owned /var/lib so only the file's owner is wrong; otherwise a temp dir of the user's.
        let base = if is_root() { "/var/lib" } else { "/tmp" };
        let dir = tempfile::Builder::new()
            .prefix("glp-")
            .tempdir_in(base)
            .unwrap();
        let marker = dir.path().join("ran");
        let p = fake(
            dir.path(),
            "u",
            &format!(
                "/usr/bin/touch {}; echo bubblewrap 0.12.0",
                marker.display()
            ),
        );
        if is_root() {
            std::os::unix::fs::chown(&p, Some(65534), Some(65534)).unwrap();
        }
        let r = find_in(&[p.as_path()]).expect_err("user-owned");
        assert_eq!(r.rule, Rule::Malformed, "{}", r.message);
        assert!(r.message.contains(p.to_str().unwrap()), "{}", r.message);
        if is_root() {
            assert!(r.message.contains("not owned by root"), "{}", r.message);
        }
        assert!(!marker.exists(), "the untrusted bwrap was run");
    }

    /// Root-owned fake bwraps (needs uid 0, as in the container): the floor, garbage output and a hang are each
    /// refused; 0.12.0 is accepted with its path.
    #[test]
    fn find_applies_the_floor_and_the_deadline() {
        if !is_root() {
            eprintln!("skipped: needs uid 0 for root-owned fixtures");
            return;
        }
        let dir = tempfile::Builder::new()
            .prefix("glp-")
            .tempdir_in("/var/lib")
            .unwrap();
        let old = fake(dir.path(), "old", "echo bubblewrap 0.11.1");
        let new = fake(dir.path(), "new", "echo bubblewrap 0.12.0");
        let junk = fake(dir.path(), "junk", "echo bwrap version 12");
        let fails = fake(dir.path(), "fails", "echo bubblewrap 0.12.0; exit 1");
        let hang = fake(dir.path(), "hang", "exec /usr/bin/sleep 30");

        let r = find_in(&[old.as_path()]).expect_err("below the floor");
        assert!(r.message.contains("CVE-2026-87766"), "{}", r.message);
        let (prog, v) = find_in(&[Path::new("/nonexistent/bwrap"), new.as_path()]).unwrap();
        assert_eq!((prog.path, v), (new.clone(), (0, 12, 0)));
        assert_eq!(
            find_in(&[junk.as_path()]).unwrap_err().rule,
            Rule::Malformed
        );
        assert_eq!(
            find_in(&[fails.as_path()]).unwrap_err().rule,
            Rule::Malformed
        );
        let t = std::time::Instant::now();
        let r = find_with(&[hang.as_path()], Duration::from_millis(300)).expect_err("hangs");
        assert!(t.elapsed() < Duration::from_secs(5), "{:?}", t.elapsed());
        assert!(r.message.contains("--version"), "{}", r.message);
    }

    /// The layout is the host's: a merged-/usr dir is listed exactly when it is a link, and the resolver's file only
    /// when `/etc/resolv.conf` leads to a bindable file under `/run`.
    #[test]
    fn host_layout_reads_the_host() {
        let layout = host_layout();
        for x in USR_MERGED {
            let link =
                fs::symlink_metadata(format!("/{x}")).is_ok_and(|m| m.file_type().is_symlink());
            assert_eq!(layout.usr_links.contains(x), link, "/{x}");
        }
        match &layout.resolver {
            Some(r) => {
                assert_eq!(fs::canonicalize("/etc/resolv.conf").unwrap(), *r);
                assert!(
                    r.starts_with("/run/") && !r.starts_with("/run/user"),
                    "{r:?}"
                );
                assert!(fs::metadata(r).unwrap().is_file(), "{r:?}");
            }
            None => {
                let real = fs::canonicalize("/etc/resolv.conf").ok();
                assert!(
                    real.as_deref()
                        .is_none_or(|r| !(r.starts_with("/run/")
                            && fs::metadata(r).is_ok_and(|m| m.is_file()))),
                    "{real:?} should have been bound"
                );
            }
        }
    }

    /// The helper's bind: read-only at `HELPER_INSIDE`, whatever else the spec holds.
    #[test]
    fn helper_is_bound_read_only_inside() {
        let fx = Fx::new();
        let opened = open_sources(&fx.valid(), &fx.helper()).unwrap();
        assert_eq!(opened.helper().mode, Mode::Ro);
        assert_eq!(opened.helper().dest, Path::new(HELPER_INSIDE));
    }
}
