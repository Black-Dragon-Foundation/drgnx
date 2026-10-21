//! `Sandbox` over its backends (Task 13). Fixtures live under /tmp/glp-XXXXXX. No real bwrap runs here (review S15:
//! the container has none that works); the rows `any/works` and `reduced-*` (Tasks 14, 15) run the invocations.

use super::*;
use crate::bwrap::{SPEC_FD, STATUS_FD};
use crate::inner::InnerSpec;
use crate::spec::{Bind, HELPER_INSIDE, Layers, Mode, Net, RelayPort, Spec};
use std::fs;
use std::io::Read;
use std::path::Path;

/// `w` (written), `r` (read), `t` (the reduced tier's tmp), `rt/s/S1` (the session dir, with `proxy.sock`),
/// `bin/ratatoskr` (the helper) and `w/.env` (a file to hide).
struct Fx {
    _dir: tempfile::TempDir,
    b: PathBuf,
}

impl Fx {
    fn new() -> Fx {
        let dir = tempfile::Builder::new()
            .prefix("glp-")
            .tempdir_in("/tmp")
            .unwrap();
        let b = fs::canonicalize(dir.path()).unwrap();
        for d in ["w", "r", "t", "rt/s/S1", "bin", "elsewhere"] {
            fs::create_dir_all(b.join(d)).unwrap();
        }
        for f in [
            "rt/s/S1/proxy.sock",
            "bin/ratatoskr",
            "w/.env",
            "elsewhere/x",
        ] {
            fs::write(b.join(f), "x").unwrap();
        }
        Fx { _dir: dir, b }
    }

    fn p(&self, rel: &str) -> PathBuf {
        self.b.join(rel)
    }

    fn helper(&self) -> InnerCommand {
        InnerCommand {
            source: self.p("bin/ratatoskr"),
            inner_args: vec!["sandbox-inner".into()],
            relay_args: vec!["relay".into()],
        }
    }

    /// A spec for `target`, isolated with one relay port.
    fn spec(&self, target: Target) -> ValidSpec {
        let full = target == Target::LinuxBwrap;
        let run_dest = if full {
            PathBuf::from("/run/drgnx")
        } else {
            self.p("rt/s/S1")
        };
        let spec = Spec {
            read: vec![self.p("r")],
            write: vec![self.p("w")],
            hide: vec![],
            sockets: vec![self.p("rt/s/S1/proxy.sock")],
            binds: vec![],
            home: None,
            run: Some(Bind {
                mode: Mode::Ro,
                source: self.p("rt/s/S1"),
                dest: run_dest.clone(),
            }),
            env: vec![("PATH".into(), "/usr/bin".into())],
            chdir: self.p("w"),
            net: Net::Isolated {
                relay: vec![RelayPort {
                    port: 3128,
                    socket: run_dest.join("proxy.sock"),
                }],
                mac_tcp_ports: vec![],
            },
            tmp: (!full).then(|| self.p("t")),
            layers: Layers::for_target(target),
            extra_tcp_ports: vec![],
        };
        ValidSpec::assume_valid(spec, target)
    }

    fn sandbox(&self, kind: BackendKind) -> Sandbox {
        let program = (kind == BackendKind::Bwrap)
            .then(|| eitri::trusted_program(&[Path::new("/usr/bin/env")]).unwrap());
        Sandbox {
            kind,
            tier: if kind == BackendKind::Reduced {
                Tier::Reduced
            } else {
                Tier::Full
            },
            helper: self.helper(),
            program,
            mac: MacContext::default(),
        }
    }
}

fn prep(sb: &Sandbox, spec: ValidSpec, cmd: &[&str]) -> Result<Prepared, Refusal> {
    let cmd = cmd.iter().map(|s| s.to_string()).collect();
    #[cfg(feature = "test-hooks")]
    return sb.prepare(spec, cmd, TestHooks::default());
    #[cfg(not(feature = "test-hooks"))]
    sb.prepare(spec, cmd)
}

fn targets(inv: &Invocation) -> Vec<i32> {
    inv.fds.iter().map(|(_, t)| *t).collect()
}

fn fd_at(inv: &Invocation, target: i32) -> &OwnedFd {
    &inv.fds.iter().find(|(_, t)| *t == target).unwrap().0
}

fn inner_spec(inv: &Invocation) -> InnerSpec {
    let mut s = String::new();
    fs::File::from(fd_at(inv, SPEC_FD).try_clone().unwrap())
        .read_to_string(&mut s)
        .unwrap();
    serde_json::from_str(&s).unwrap()
}

fn strings(args: &[OsString]) -> Vec<String> {
    args.iter()
        .map(|a| a.to_str().unwrap().to_owned())
        .collect()
}

/// The status pipe: what fd 4 writes, `status` reads.
fn status_connected(p: &Prepared) {
    rustix::io::write(fd_at(&p.invocation, STATUS_FD), b"x").unwrap();
    let mut b = [0u8; 1];
    assert_eq!(
        rustix::io::read(p.status.as_ref().unwrap(), &mut b).unwrap(),
        1
    );
}

#[test]
fn none_refuses() {
    let fx = Fx::new();
    let sb = fx.sandbox(BackendKind::None);
    assert_eq!(sb.target(), None);
    for t in [Target::LinuxBwrap, Target::LinuxReduced] {
        let r = prep(&sb, fx.spec(t), &["/bin/true"]).unwrap_err();
        assert_eq!(r.rule, Rule::Setup, "{}", r.message);
        assert!(r.message.contains("no sandbox backend"), "{}", r.message);
    }
}

#[test]
fn bwrap_invocation_has_spec_status_and_binds_at_3_4_5() {
    let fx = Fx::new();
    let sb = fx.sandbox(BackendKind::Bwrap);
    let p = prep(
        &sb,
        fx.spec(Target::LinuxBwrap),
        &["/bin/sh", "-c", "exit 0"],
    )
    .unwrap();
    let inv = &p.invocation;
    assert_eq!(inv.program, PathBuf::from("/usr/bin/env"), "bwrap's path");
    assert!(inv.env.is_empty() && inv.cwd.is_none() && !inv.new_session);
    // 3 = the spec, 4 = the status pipe, then the binds from 5 in argv order: read, write, run, the helper.
    assert_eq!(targets(inv), [3, 4, 5, 6, 7, 8]);
    let args = strings(&inv.args);
    let helper_at = args
        .windows(3)
        .position(|w| w[0] == "--ro-bind-fd" && w[2] == HELPER_INSIDE)
        .expect("the helper is bound");
    assert_eq!(args[helper_at + 1], "8", "the helper's fd is the last");
    let tail: Vec<&str> = args[args.len() - 9..args.len() - 1]
        .iter()
        .map(String::as_str)
        .collect();
    assert_eq!(
        tail,
        [
            "--",
            HELPER_INSIDE,
            "sandbox-inner",
            "--spec-fd",
            "3",
            "--",
            "/bin/sh",
            "-c"
        ]
    );
    assert_eq!(args.last().unwrap(), "exit 0");
    assert!(!args.iter().any(|a| a.contains("PATH=")), "no env in argv");
    // The inner spec: the full tier's plan, the spec's env, the relay run as the helper inside.
    let inner = inner_spec(inv);
    assert_eq!(inner.landlock.tier, Tier::Full);
    assert!(!inner.new_session);
    assert_eq!(inner.env, vec![("PATH".to_owned(), "/usr/bin".to_owned())]);
    assert_eq!(
        inner.relay.unwrap().argv,
        [
            HELPER_INSIDE,
            "relay",
            "--ready-fd",
            "3",
            "3128=/run/drgnx/proxy.sock"
        ]
    );
    status_connected(&p);
    assert!(p.layers.is_none());
}

#[test]
fn reduced_invocation_runs_the_helper_directly() {
    let fx = Fx::new();
    let sb = fx.sandbox(BackendKind::Reduced);
    let p = prep(
        &sb,
        fx.spec(Target::LinuxReduced),
        &["/bin/sh", "-c", "exit 0"],
    )
    .unwrap();
    let inv = &p.invocation;
    assert_eq!(inv.program, fx.p("bin/ratatoskr"));
    assert_eq!(
        strings(&inv.args),
        [
            "sandbox-inner",
            "--spec-fd",
            "3",
            "--",
            "/bin/sh",
            "-c",
            "exit 0"
        ]
    );
    assert_eq!(targets(inv), [3, 4]);
    assert!(inv.env.is_empty() && inv.cwd.is_none());
    assert!(inv.new_session, "spawned with setsid (GL-T8-1)");
    let inner = inner_spec(inv);
    assert_eq!(inner.landlock.tier, Tier::Reduced);
    assert!(inner.new_session);
    let relay = inner.relay.unwrap().argv;
    assert_eq!(relay[0], fx.p("bin/ratatoskr").to_str().unwrap());
    status_connected(&p);
}

#[test]
fn full_never_falls_back_to_reduced() {
    let fx = Fx::new();
    // A bwrap that is not there, and one only root does not own (or under the world-writable /tmp).
    let fake = fx.p("bin/bwrap");
    fs::write(&fake, "#!/bin/sh\necho bubblewrap 0.12.0\n").unwrap();
    for bwrap in [fx.p("bin/no-bwrap"), fake] {
        let r = Sandbox::detect(Tier::Full, fx.helper(), Some(bwrap.clone())).unwrap_err();
        assert_eq!(r.rule, Rule::Malformed, "{bwrap:?}: {}", r.message);
        assert!(r.message.contains("bubblewrap"), "{}", r.message);
    }
    // Without the override: bwrap if this host has a good one, else a refusal; never the reduced tier.
    match Sandbox::detect(Tier::Full, fx.helper(), None) {
        Ok(sb) => assert_eq!(sb.kind(), BackendKind::Bwrap),
        Err(r) => assert_eq!(r.rule, Rule::Malformed, "{}", r.message),
    }
    let sb = Sandbox::detect(Tier::Reduced, fx.helper(), None).unwrap();
    assert_eq!(
        (sb.kind(), sb.target()),
        (BackendKind::Reduced, Some(Target::LinuxReduced))
    );
    let relative = InnerCommand {
        source: "ratatoskr".into(),
        ..fx.helper()
    };
    assert_eq!(
        Sandbox::detect(Tier::Reduced, relative, None)
            .unwrap_err()
            .rule,
        Rule::Malformed
    );
}

/// The status pipe's write end exists once, in the invocation: when the invocation is gone (moved into a spawn
/// that drops it), the read end sees EOF, never a hang (review S6).
#[test]
fn status_write_end_moves_into_the_spawn() {
    let fx = Fx::new();
    for (kind, target) in [
        (BackendKind::Bwrap, Target::LinuxBwrap),
        (BackendKind::Reduced, Target::LinuxReduced),
    ] {
        let p = prep(&fx.sandbox(kind), fx.spec(target), &["/bin/true"]).unwrap();
        let Prepared {
            invocation, status, ..
        } = p;
        let status = status.unwrap();
        drop(invocation);
        rustix::fs::fcntl_setfl(&status, rustix::fs::OFlags::NONBLOCK).unwrap();
        let mut b = [0u8; 1];
        assert_eq!(
            rustix::io::read(&status, &mut b),
            Ok(0),
            "{kind:?}: a copy of the write end is still open"
        );
    }
}

#[test]
fn a_spec_for_another_target_or_no_command_is_refused() {
    let fx = Fx::new();
    let r = prep(
        &fx.sandbox(BackendKind::Reduced),
        fx.spec(Target::LinuxBwrap),
        &["/bin/true"],
    )
    .unwrap_err();
    assert_eq!(r.rule, Rule::Malformed, "{}", r.message);
    let r = prep(
        &fx.sandbox(BackendKind::Bwrap),
        fx.spec(Target::LinuxReduced),
        &["/bin/true"],
    )
    .unwrap_err();
    assert_eq!(r.rule, Rule::Malformed, "{}", r.message);
    for cmd in [&[][..], &[""]] {
        let r = prep(
            &fx.sandbox(BackendKind::Reduced),
            fx.spec(Target::LinuxReduced),
            cmd,
        )
        .unwrap_err();
        assert_eq!(r.rule, Rule::Malformed, "{cmd:?}");
    }
}

/// Without a mount namespace nothing can be put over a file the reduced tier's Landlock grants: such a hide is
/// refused, not silently left readable. A hide outside every granted root is unreachable anyway, and passes.
#[test]
fn reduced_cannot_hide_inside_a_granted_root() {
    let fx = Fx::new();
    let sb = fx.sandbox(BackendKind::Reduced);
    let with_hide = |h: PathBuf| {
        let mut s = fx.spec(Target::LinuxReduced).spec().clone();
        s.hide = vec![h];
        ValidSpec::assume_valid(s, Target::LinuxReduced)
    };
    let r = prep(&sb, with_hide(fx.p("w/.env")), &["/bin/true"]).unwrap_err();
    assert_eq!(r.rule, Rule::Malformed, "{}", r.message);
    assert!(r.message.contains("cannot be hidden"), "{}", r.message);
    assert_eq!(r.path, Some(fx.p("w/.env")));
    prep(&sb, with_hide(fx.p("elsewhere/x")), &["/bin/true"]).expect("unreachable anyway");
    // The full tier hides it with a mount.
    let mut s = fx.spec(Target::LinuxBwrap).spec().clone();
    s.hide = vec![fx.p("w/.env")];
    let spec = ValidSpec::assume_valid(s, Target::LinuxBwrap);
    let p = prep(&fx.sandbox(BackendKind::Bwrap), spec, &["/bin/true"]).unwrap();
    let args = strings(&p.invocation.args);
    assert!(
        args.windows(3)
            .any(|w| w == ["--ro-bind", "/dev/null", fx.p("w/.env").to_str().unwrap()])
    );
}

/// Task 9's hand-off: Seatbelt's run maps to an invocation with no fds and no status line, and its layers are known
/// at once.
#[test]
fn seatbelt_run_maps_to_an_invocation() {
    let run = macos::Run {
        program: "/usr/bin/sandbox-exec".into(),
        args: ["-f", "/s/profile.sb", "/bin/sh"]
            .map(OsString::from)
            .to_vec(),
        env: vec![("PATH".into(), "/usr/bin".into())],
        cwd: "/w".into(),
        profile_file: Some("/s/profile.sb".into()),
    };
    let p = seatbelt_prepared(run.clone());
    assert_eq!(p.invocation.program, run.program);
    assert_eq!(p.invocation.args, run.args);
    assert_eq!(p.invocation.env, run.env);
    assert_eq!(p.invocation.cwd, Some(run.cwd));
    assert!(p.invocation.fds.is_empty() && !p.invocation.new_session);
    assert!(p.status.is_none());
    let l = p.layers.unwrap();
    assert!(l.seatbelt && !l.seccomp && l.landlock_abi == 0);
}

/// GL-T8-3: the reduced tier's relay ports are free host ports, distinct within a session and from every port bound
/// now; the full tier keeps its own (its network namespace is the session's).
#[test]
fn relay_ports_per_tier() {
    assert_eq!(
        relay_ports(Tier::Full, &[3128, 3129]).unwrap(),
        [3128, 3129]
    );
    let busy = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let busy = busy.local_addr().unwrap().port();
    let ports = relay_ports(Tier::Reduced, &[3128, 3129]).unwrap();
    assert_eq!(ports.len(), 2);
    assert_ne!(ports[0], ports[1]);
    assert!(!ports.contains(&busy) && !ports.contains(&0));
    for p in ports {
        std::net::TcpListener::bind(("127.0.0.1", p)).expect("free again for the relay");
    }
    assert!(relay_ports(Tier::Reduced, &[]).unwrap().is_empty());
}

#[cfg(feature = "test-hooks")]
#[test]
fn test_hooks_reach_the_inner_spec() {
    let fx = Fx::new();
    let hooks = TestHooks {
        landlock_omit: vec![fx.p("w")],
        abi_cap: Some(8),
    };
    for (kind, target) in [
        (BackendKind::Bwrap, Target::LinuxBwrap),
        (BackendKind::Reduced, Target::LinuxReduced),
    ] {
        let p = fx
            .sandbox(kind)
            .prepare(fx.spec(target), vec!["/bin/true".into()], hooks.clone())
            .unwrap();
        let inner = inner_spec(&p.invocation);
        assert_eq!(inner.landlock_omit, hooks.landlock_omit, "{kind:?}");
        assert_eq!(inner.abi_cap, Some(8), "{kind:?}");
    }
}
