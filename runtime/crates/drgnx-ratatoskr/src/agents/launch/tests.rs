//! Launch specs (unit): the spec each cell and role yields, validated as the hub will.  Fixtures live under
//! /tmp/glp-XXXXXX and never reach `~`; the real runs are `tests/launch_sandboxed.rs`.

use super::*;
use crate::agents::lock::Enforced;
use crate::sandbox::{context_for, session_spec};
use gleipnir::{Mode, Net, Target};
use std::fs;

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
        for d in [
            "home/.claude",
            "home/.codex",
            "home/.ssh",
            "wt/.codex",
            "run",
            "t",
        ] {
            fs::create_dir_all(b.join(d)).unwrap();
        }
        Fx { _dir: dir, b }
    }

    fn p(&self, rel: &str) -> PathBuf {
        self.b.join(rel)
    }

    fn env(&self) -> Env {
        let s = |rel: &str| self.p(rel).to_str().unwrap().to_owned();
        Env::new(
            &[
                ("HOME", &s("home")),
                ("XDG_RUNTIME_DIR", &s("run")),
                ("TMPDIR", &s("t")),
                ("PATH", "/usr/bin:/bin"),
            ],
            1000,
        )
    }

    fn plan(&self, login: &str) -> LaunchPlan {
        LaunchPlan {
            argv: vec!["/bin/true".into()],
            env: vec![("DRGNX_ROLE_HINT".into(), "x".into())],
            session_meta: None,
            protected_ro: vec![self.p("wt/.codex")],
            login_dir: Some(self.p(&format!("home/{login}"))),
            enforced: Enforced::Yes,
        }
    }

    fn shape(&self, net: NetCell) -> SessionShape {
        SessionShape {
            sid: "S1".into(),
            cwd: self.p("wt"),
            write: vec![self.p("wt")],
            read: vec![],
            net,
        }
    }

    /// The spec for `shape`, validated for the reduced tier.
    fn spec(&self, plan: &LaunchPlan, shape: &SessionShape) -> gleipnir::Spec {
        let env = self.env();
        let ctx = context_for(&env, None);
        paths::make_session_dir(&env, &paths::socket_path(&env), &shape.sid).unwrap();
        let scratch = scratch_dir(&env, &shape.sid).unwrap();
        let spec = session_spec(
            &env,
            &ctx,
            plan,
            shape,
            &scratch,
            Tier::Reduced,
            Target::LinuxReduced,
        )
        .unwrap();
        let valid = gleipnir::validate(spec, &ctx, Target::LinuxReduced).unwrap();
        valid.spec().clone()
    }
}

#[test]
fn a_worker_writes_its_worktree_and_its_login_dir_only() {
    let fx = Fx::new();
    let spec = fx.spec(&fx.plan(".claude"), &fx.shape(NetCell::ProviderOnly));
    assert_eq!(spec.write, vec![fx.p("wt"), fx.p("home/.claude")]);
    assert!(spec.home.is_none());
    let all: Vec<&PathBuf> = spec.read.iter().chain(&spec.write).collect();
    for never in ["home", "home/.ssh", "home/.codex"] {
        assert!(!all.contains(&&fx.p(never)), "{never} is bound");
    }
    assert_eq!(spec.chdir, fx.p("wt"));
}

#[test]
fn protected_paths_are_bound_read_only() {
    let fx = Fx::new();
    let spec = fx.spec(&fx.plan(".codex"), &fx.shape(NetCell::ProviderOnly));
    let pin = spec.binds.iter().find(|b| b.source == fx.p("wt/.codex"));
    assert_eq!(pin.map(|b| b.mode), Some(Mode::Ro), "{:?}", spec.binds);
    assert!(spec.binds.iter().all(|b| b.mode == Mode::Ro));
}

#[test]
fn the_login_dir_is_the_plans_own_alone() {
    let fx = Fx::new();
    let claude = fx.spec(&fx.plan(".claude"), &fx.shape(NetCell::ProviderOnly));
    let codex = fx.spec(&fx.plan(".codex"), &fx.shape(NetCell::ProviderOnly));
    assert!(claude.write.contains(&fx.p("home/.claude")));
    assert!(!claude.write.contains(&fx.p("home/.codex")));
    assert!(codex.write.contains(&fx.p("home/.codex")));
    assert!(!codex.write.contains(&fx.p("home/.claude")));
}

#[test]
fn provider_cells_go_through_the_relay_and_open_shares() {
    let fx = Fx::new();
    for cell in [NetCell::ProviderOnly, NetCell::ProviderAndPackages] {
        let spec = fx.spec(&fx.plan(".claude"), &fx.shape(cell));
        let Net::Isolated { relay, .. } = &spec.net else {
            panic!("{cell:?} is not isolated: {:?}", spec.net);
        };
        assert_eq!(relay.len(), 1);
        let proxy = format!("http://127.0.0.1:{}", relay[0].port);
        assert!(spec.env.contains(&("HTTPS_PROXY".into(), proxy)));
        assert!(spec.sockets.contains(&relay[0].socket));
    }
    let open = fx.spec(&fx.plan(".claude"), &fx.shape(NetCell::Open));
    assert_eq!(open.net, Net::Shared);
    assert!(open.env.iter().all(|(k, _)| k != "HTTPS_PROXY"));
}

#[test]
fn the_session_dir_is_read_only_and_holds_the_hub_socket() {
    let fx = Fx::new();
    let spec = fx.spec(&fx.plan(".claude"), &fx.shape(NetCell::ProviderOnly));
    let run = spec.run.expect("a session dir");
    assert_eq!(run.mode, Mode::Ro);
    assert!(spec.sockets.contains(&run.source.join("hub.sock")));
    // The lock's env comes last, after the base.
    assert_eq!(spec.env.last().unwrap().0, "DRGNX_ROLE_HINT");
}

#[test]
fn a_plain_chat_works_in_a_scratch_dir_with_no_home() {
    let fx = Fx::new();
    let env = fx.env();
    let scratch = scratch_dir(&env, "C1").unwrap();
    assert!(scratch.starts_with(fx.p("t")));
    let shape = SessionShape {
        sid: "C1".into(),
        cwd: scratch.clone(),
        write: vec![scratch.clone()],
        read: vec![],
        net: NetCell::ProviderOnly,
    };
    let spec = fx.spec(&fx.plan(".claude"), &shape);
    assert_eq!(spec.chdir, scratch);
    assert_eq!(spec.write, vec![scratch, fx.p("home/.claude")]);
    assert!(spec.read.iter().all(|p| p != &fx.p("home")));
    assert!(matches!(spec.net, Net::Isolated { .. }));
}

#[test]
fn a_chat_is_not_a_worker_and_a_bad_session_id_is_refused() {
    let fx = Fx::new();
    let req = SandboxReq {
        sid: "S1".into(),
        worktree: fx.p("wt"),
        read: vec![],
        net: NetCell::ProviderOnly,
        role: Role::Chat,
    };
    assert!(spawn(&fx.plan(".claude"), &req).is_err());
    assert!(scratch_dir(&fx.env(), "../x").is_err());
}
