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

    /// The spec for `shape`, validated for the reduced tier, in `launch_on`'s order: nothing has made the session dir
    /// before the spec is built.
    fn spec(&self, plan: &LaunchPlan, shape: &SessionShape) -> gleipnir::Spec {
        let env = self.env();
        let ctx = context_for(&env, None);
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
        .unwrap()
        .spec;
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

/// `agents/start` and the probe build the spec of a session id nothing has used yet: no MCP session and no agent
/// socket has made `s/SID`, and Gleipnir requires `run`'s source to exist.  The spec makes it, private; the sockets it
/// names need not exist yet (the hub binds `mcp.sock` after, and nothing inside needs one at start).
#[test]
fn the_spec_makes_the_session_dir_it_binds() {
    use std::os::unix::fs::PermissionsExt;
    let fx = Fx::new();
    let env = fx.env();
    let dir = paths::session_dir(&env, &paths::socket_path(&env), "S1").unwrap();
    assert!(fs::symlink_metadata(&dir).is_err(), "made too early");
    let spec = fx.spec(&fx.plan(".claude"), &fx.shape(NetCell::ProviderOnly));
    assert_eq!(spec.run.map(|r| r.source), Some(dir.clone()));
    let mode = fs::metadata(&dir).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o700, "{mode:o}");
    assert!(spec.sockets.iter().all(|s| !s.exists()));
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
    assert!(spawn(&fx.env(), &fx.plan(".claude"), &req).is_err());
    assert!(scratch_dir(&fx.env(), "../x").is_err());
}

/// The editor's agents panel and review start a chat with the project as its cwd (with the trailing slash of
/// `default-directory`): the project is the cwd and read-only, the scratch dir the only writable path beside the login
/// dir, the network provider-only, and nothing is made in the project.
#[test]
fn a_chat_in_a_project_reads_it_and_writes_only_its_scratch() {
    use crate::agents::lock::PROTECTED_RO;
    let fx = Fx::new();
    let env = fx.env();
    let project = fx.p("proj");
    fs::create_dir_all(project.join(".git/hooks")).unwrap();
    fs::write(project.join(".git/config"), "[core]\n").unwrap();
    let mut plan = fx.plan(".claude");
    plan.protected_ro = PROTECTED_RO.iter().map(PathBuf::from).collect();
    let given = PathBuf::from(format!("{}/", project.display()));
    let (plan, shape) = chat_launch(&env, &plan, "C1", &given).unwrap();
    let spec = fx.spec(&plan, &shape);
    let scratch = scratch_path(&env, "C1");
    assert_eq!(spec.chdir, project);
    assert!(spec.read.contains(&project), "{:?}", spec.read);
    assert_eq!(spec.write, vec![scratch, fx.p("home/.claude")]);
    for w in &spec.write {
        assert!(
            !w.starts_with(&project) && !project.starts_with(w),
            "{} is writable",
            w.display()
        );
    }
    assert!(
        spec.binds
            .iter()
            .all(|b| b.mode == Mode::Ro && !b.source.starts_with(&project)),
        "{:?}",
        spec.binds
    );
    assert!(matches!(spec.net, Net::Isolated { .. }));
    assert!(spec.env.iter().any(|(k, _)| k == "HTTPS_PROXY"));
    for rel in PROTECTED_RO {
        if !rel.starts_with(".git") {
            assert!(!project.join(rel).exists(), "{rel} was made in the project");
        }
    }
    // a plain checkout's git folder is inside the project: nothing more is bound
    assert_eq!(
        spec.read
            .iter()
            .filter(|r| !r.starts_with(&project))
            .count(),
        0,
        "{:?}",
        spec.read
    );
    // a linked worktree of a repository elsewhere: its common git folder (which holds its own) is read-only, and
    // nowhere in the write set or the binds
    let common = fx.p("repo/.git");
    let own = common.join("worktrees/lw");
    for d in ["objects", "refs/heads", "hooks"] {
        fs::create_dir_all(common.join(d)).unwrap();
    }
    fs::create_dir_all(&own).unwrap();
    fs::write(own.join("commondir"), "../..\n").unwrap();
    let linked = fx.p("lw");
    fs::create_dir_all(&linked).unwrap();
    fs::write(linked.join(".git"), format!("gitdir: {}\n", own.display())).unwrap();
    let (plan, shape) = chat_launch(&env, &fx.plan(".claude"), "C2", &linked).unwrap();
    let spec = fx.spec(&plan, &shape);
    assert_eq!(spec.chdir, linked);
    assert_eq!(spec.read, vec![linked.clone(), common.clone()]);
    assert_eq!(
        spec.write,
        vec![scratch_path(&env, "C2"), fx.p("home/.claude")]
    );
    for w in &spec.write {
        assert!(
            !w.starts_with(fx.p("repo")) && !common.starts_with(w),
            "{} is writable",
            w.display()
        );
    }
    assert!(
        spec.binds
            .iter()
            .all(|b| !b.source.starts_with(fx.p("repo")))
    );
    // a `.git` file whose folder does not resolve is refused
    fs::write(linked.join(".git"), "gitdir: /nowhere/at/all\n").unwrap();
    let refused = chat_launch(&env, &fx.plan(".claude"), "C2", &linked).unwrap_err();
    assert_eq!(refused.path, Some(linked.join(".git")), "{refused}");
    // a project that is not a folder is refused, and a chat still never takes the worktree launch
    assert!(chat_launch(&env, &fx.plan(".claude"), "C1", &fx.p("missing")).is_err());
    assert_eq!(
        kind(Role::Chat, &project, &scratch_path(&env, "C1")),
        Kind::Chat
    );
}

/// B3: the lock's real list is relative; it is pinned inside the worktree, missing entries included.
#[test]
fn the_real_protected_list_is_pinned_in_the_worktree() {
    use crate::agents::lock::PROTECTED_RO;
    let fx = Fx::new();
    fs::create_dir_all(fx.p("wt/.git")).unwrap();
    let mut plan = fx.plan(".claude");
    plan.protected_ro = PROTECTED_RO.iter().map(PathBuf::from).collect();
    let spec = fx.spec(&plan, &fx.shape(NetCell::ProviderOnly));
    for rel in PROTECTED_RO {
        let want = fx.p("wt").join(rel);
        let pin = spec.binds.iter().find(|b| b.source == want);
        assert_eq!(
            pin.map(|b| b.mode),
            Some(Mode::Ro),
            "{rel}: {:?}",
            spec.binds
        );
        assert!(want.exists(), "{rel} is made so it can be pinned");
    }
    assert!(fx.p("wt/.envrc").is_file() && fx.p("wt/.claude").is_dir());
}

/// B3: a linked worktree has `.git` as a file, so `.git/hooks` has no place to be pinned; the rest still are.
#[test]
fn a_linked_worktrees_missing_hooks_dir_is_left_out() {
    use crate::agents::lock::PROTECTED_RO;
    let fx = Fx::new();
    fs::write(fx.p("wt/.git"), "gitdir: /elsewhere").unwrap();
    let mut plan = fx.plan(".claude");
    plan.protected_ro = PROTECTED_RO.iter().map(PathBuf::from).collect();
    let spec = fx.spec(&plan, &fx.shape(NetCell::ProviderOnly));
    assert!(spec.binds.iter().all(|b| !b.source.ends_with(".git/hooks")));
    assert!(spec.binds.iter().any(|b| b.source == fx.p("wt/.envrc")));
}

/// B4: a worktree under `<state>/hub/runs` (inside closed folders) is refused by validation unless the context opens
/// the run root; the context opens that root and nothing else of the state folder.
#[test]
fn a_worktree_under_the_hub_run_root_launches_with_only_the_run_root_opened() {
    let fx = Fx::new();
    let env = fx.env();
    let state = paths::state_dir(&env);
    let wt = state.join("hub/runs/w1");
    fs::create_dir_all(&wt).unwrap();
    let shape = SessionShape {
        sid: "S1".into(),
        cwd: wt.clone(),
        write: vec![wt.clone()],
        read: vec![],
        net: NetCell::ProviderOnly,
    };
    let plan = fx.plan(".claude");
    let scratch = scratch_dir(&env, &shape.sid).unwrap();
    let build = |ctx: &gleipnir::Context| {
        let spec = session_spec(
            &env,
            ctx,
            &plan,
            &shape,
            &scratch,
            Tier::Reduced,
            Target::LinuxReduced,
        )
        .unwrap()
        .spec;
        gleipnir::validate(spec, ctx, Target::LinuxReduced)
    };
    let ctx = context_for(&env, None);
    assert_eq!(
        ctx.open_inside_closed,
        vec![fs::canonicalize(state.join("hub")).unwrap().join("runs")]
    );
    build(&ctx).expect("the shipped layout validates");
    let mut shut = ctx.clone();
    shut.open_inside_closed.clear();
    let refused =
        build(&shut).expect_err("the closed folder refuses the tree when nothing is opened");
    assert_eq!(refused.rule, gleipnir::Rule::Closed, "{refused}");
    // a folder elsewhere in the state folder is not opened by it
    let mut other = shape.clone();
    other.write = vec![state.join("hub")];
    other.cwd = state.join("hub");
    assert!(
        session_spec(
            &env,
            &ctx,
            &plan,
            &other,
            &scratch,
            Tier::Reduced,
            Target::LinuxReduced
        )
        .and_then(|s| gleipnir::validate(s.spec, &ctx, Target::LinuxReduced))
        .is_err()
    );
}

/// The shipped layout: a plan run's or manager worker's tree is a snapshot, `.git` a copy of the run's store inside
/// the tree under `<state>/hub/runs`.  The hooks and config in it (and a submodule's) are pinned read-only; the
/// source repository's `.git` is nowhere in the spec, readable or writable.
#[test]
fn a_snapshot_workers_git_folder_is_its_own_and_the_source_repo_is_not_given() {
    use crate::agents::lock::PROTECTED_RO;
    let fx = Fx::new();
    let env = fx.env();
    let source = fx.p("repo/.git");
    fs::create_dir_all(source.join("refs/heads")).unwrap();
    let wt = paths::state_dir(&env).join("hub/runs/w1");
    for d in ["objects", "refs/heads", "hooks", "modules/sub/hooks"] {
        fs::create_dir_all(wt.join(".git").join(d)).unwrap();
    }
    fs::write(wt.join(".git/config"), "[core]\n").unwrap();
    fs::write(wt.join(".git/modules/sub/config"), "[core]\n").unwrap();
    let mut plan = fx.plan(".claude");
    plan.protected_ro = PROTECTED_RO.iter().map(PathBuf::from).collect();
    let req = SandboxReq {
        sid: "S1".into(),
        worktree: wt.clone(),
        read: vec![],
        net: NetCell::ProviderOnly,
        role: Role::Worker,
    };
    let (plan, shape) = worktree_launch(&plan, &req);
    let spec = fx.spec(&plan, &shape);
    assert_eq!(spec.write[0], wt);
    for pinned in [
        ".git/hooks",
        ".git/config",
        ".git/modules/sub/hooks",
        ".git/modules/sub/config",
    ] {
        let pin = spec.binds.iter().find(|b| b.source == wt.join(pinned));
        assert_eq!(
            pin.map(|b| b.mode),
            Some(Mode::Ro),
            "{pinned}: {:?}",
            spec.binds
        );
    }
    assert!(
        spec.binds
            .iter()
            .all(|b| b.source != wt.join(".git/objects"))
    );
    let named = spec
        .read
        .iter()
        .chain(&spec.write)
        .chain(spec.binds.iter().map(|b| &b.source));
    for p in named {
        assert!(
            !p.starts_with(fx.p("repo")),
            "{} names the source repository",
            p.display()
        );
    }
    // the same for a linked worktree of the source (a session the user started in one): its common folder is the
    // user's repository, so nothing of it is opened or pinned
    fs::create_dir_all(source.join("worktrees/w2")).unwrap();
    fs::write(source.join("worktrees/w2/commondir"), "../..\n").unwrap();
    let linked = paths::state_dir(&env).join("hub/runs/w2");
    fs::create_dir_all(&linked).unwrap();
    fs::write(
        linked.join(".git"),
        format!("gitdir: {}\n", source.join("worktrees/w2").display()),
    )
    .unwrap();
    let req = SandboxReq {
        worktree: linked.clone(),
        ..req
    };
    let (plan, shape) = worktree_launch(&fx.plan(".claude"), &req);
    assert_eq!(shape.write, vec![linked]);
    assert!(
        plan.protected_ro
            .iter()
            .all(|p| !p.starts_with(fx.p("repo")))
    );
    // the stubs the hub made for the lock's files go with the session, unless the agent filled them
    assert!(wt.join(".envrc").is_file() && wt.join("mise.toml").is_file());
    fs::write(wt.join("mise.toml"), "[tools]\n").unwrap();
    crate::sandbox::remove_stubs(&scratch_path(&env, "S1"), &wt);
    assert!(!wt.join(".envrc").exists(), "an empty stub is removed");
    assert!(wt.join("mise.toml").exists(), "a file with content stays");
}

/// A home with the usual toolchain layouts: `~/.local/bin/claude` a link into Claude's versioned install, a mise
/// install with an npm credential beside it, mise's shims (links to the mise binary), and cargo's bin dir with the
/// credentials file next to it (not in it).  ENV's `PATH` is `path`, its entries relative to the fixture.
struct Tools {
    fx: Fx,
}

impl Tools {
    fn new() -> Tools {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let fx = Fx::new();
        let file = |rel: &str, mode: u32| {
            let p = fx.p(rel);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(&p, "x").unwrap();
            fs::set_permissions(&p, fs::Permissions::from_mode(mode)).unwrap();
            p
        };
        let link = |rel: &str, to: &Path| {
            let p = fx.p(rel);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            symlink(to, p).unwrap();
        };
        let claude = file("home/.local/share/claude/versions/2.1.0/claude", 0o755);
        link("home/.local/bin/claude", &claude);
        let mise = file("home/.local/bin/mise", 0o755);
        file("home/.local/share/mise/installs/node/22.1/bin/node", 0o755);
        file("home/.local/share/mise/installs/node/22.1/etc/npmrc", 0o600);
        link("home/.local/share/mise/shims/node", &mise);
        file("home/.cargo/bin/cargo", 0o755);
        file("home/.cargo/credentials.toml", 0o600);
        file("home/.cache/agent/run", 0o755);
        Tools { fx }
    }

    fn env(&self, path: &[&str]) -> Env {
        let s = |rel: &str| self.fx.p(rel).to_str().unwrap().to_owned();
        let mut dirs: Vec<String> = path
            .iter()
            .map(|d| if d.starts_with('/') { d.to_string() } else { s(d) })
            .collect();
        dirs.extend(["/usr/bin".to_string(), "/bin".to_string()]);
        Env::new(
            &[
                ("HOME", &s("home")),
                ("XDG_RUNTIME_DIR", &s("run")),
                ("TMPDIR", &s("t")),
                ("PATH", &dirs.join(":")),
            ],
            1000,
        )
    }

    /// The session spec for a worker running ARGV under ENV, built and validated for TIER.
    fn spec(
        &self,
        env: &Env,
        argv: &[&str],
        tier: Tier,
    ) -> Result<crate::sandbox::SessionSpec, gleipnir::Refusal> {
        let target = match tier {
            Tier::Full => Target::LinuxBwrap,
            Tier::Reduced => Target::LinuxReduced,
        };
        let ctx = context_for(env, None);
        let mut plan = self.fx.plan(".claude");
        plan.argv = argv.iter().map(Into::into).collect();
        let shape = self.fx.shape(NetCell::ProviderOnly);
        let scratch = scratch_dir(env, &shape.sid).unwrap();
        let built = session_spec(env, &ctx, &plan, &shape, &scratch, tier, target)?;
        let valid = gleipnir::validate(built.spec, &ctx, target)?;
        Ok(crate::sandbox::SessionSpec {
            spec: valid.spec().clone(),
            program: built.program,
        })
    }
}

const TOOL_PATH: [&str; 4] = [
    "home/.local/bin",
    "home/.local/share/mise/shims",
    "home/.local/share/mise/installs/node/22.1/bin",
    "home/.cargo/bin",
];

/// The toolchain roots of PATH are read-only: the bin dirs and install roots (Claude's versions behind its link, the
/// mise install), never a tool home or the shims folder; the credential file inside a root is hidden, and the one
/// beside cargo's bin dir is not in any root.  The program is its PATH hit, which the sandbox shows.
#[test]
fn the_toolchain_roots_are_read_only_and_their_credentials_hidden() {
    let t = Tools::new();
    let p = |rel: &str| t.fx.p(rel);
    let built = t
        .spec(&t.env(&TOOL_PATH), &["claude", "--acp"], Tier::Full)
        .unwrap_or_else(|r| panic!("refused: {r}"));
    let spec = &built.spec;
    for root in [
        "home/.local/bin",
        "home/.local/share/claude/versions",
        "home/.local/share/mise/installs/node/22.1",
        "home/.cargo/bin",
    ] {
        assert!(spec.read.contains(&p(root)), "{root}: {:?}", spec.read);
    }
    for never in [
        "home",
        "home/.local",
        "home/.local/share",
        "home/.local/share/mise",
        "home/.local/share/mise/shims",
        "home/.cargo",
    ] {
        assert!(!spec.read.contains(&p(never)), "{never} is bound");
    }
    assert!(spec.write.iter().all(|w| !w.starts_with(p("home/.local"))));
    assert_eq!(
        spec.hide,
        vec![p("home/.local/share/mise/installs/node/22.1/etc/npmrc")]
    );
    assert!(
        spec.read
            .iter()
            .all(|r| !p("home/.cargo/credentials.toml").starts_with(r))
    );
    assert_eq!(built.program, p("home/.local/bin/claude"));
}

/// The reduced tier cannot hide a file inside a root it grants, so a root that holds a credential file is left out
/// rather than shown with it.
#[test]
fn the_reduced_tier_leaves_out_a_root_with_a_credential_file() {
    let t = Tools::new();
    let p = |rel: &str| t.fx.p(rel);
    let spec = t
        .spec(&t.env(&TOOL_PATH), &["claude"], Tier::Reduced)
        .unwrap_or_else(|r| panic!("refused: {r}"))
        .spec;
    assert!(spec.hide.is_empty(), "{:?}", spec.hide);
    assert!(!spec.read.contains(&p("home/.local/share/mise/installs/node/22.1")));
    assert!(spec.read.contains(&p("home/.local/share/claude/versions")));
    assert!(spec.read.contains(&p("home/.cargo/bin")));
}

/// A program the sandbox would not show is refused before anything starts, and the refusal names its path: a mise
/// shim (it runs mise, whose folder of shims is not bound), a program in a cache folder, one not on PATH, and a
/// relative path.  A program on PATH outside the home is the system's; one under a bound root is fine by full path.
#[test]
fn a_program_the_sandbox_does_not_show_is_refused_by_its_path() {
    let t = Tools::new();
    let p = |rel: &str| t.fx.p(rel);
    let shims_first = t.env(&[
        "home/.local/share/mise/shims",
        "home/.local/share/mise/installs/node/22.1/bin",
    ]);
    let r = t.spec(&shims_first, &["node"], Tier::Full).unwrap_err();
    assert_eq!(r.rule, gleipnir::Rule::Setup, "{r}");
    assert_eq!(r.path, Some(p("home/.local/share/mise/shims/node")), "{r}");
    assert!(r.message.contains("shim"), "{r}");
    let env = t.env(&TOOL_PATH);
    let cache = p("home/.cache/agent/run");
    let r = t
        .spec(&env, &[cache.to_str().unwrap()], Tier::Full)
        .unwrap_err();
    assert_eq!(r.path, Some(cache), "{r}");
    let r = t.spec(&env, &["no-such-agent"], Tier::Full).unwrap_err();
    assert!(r.message.contains("not found on PATH"), "{r}");
    let r = t.spec(&env, &["./claude"], Tier::Full).unwrap_err();
    assert!(r.message.contains("absolute"), "{r}");
    // a link by its full path leads to its install too; a system program is the system's
    let full = p("home/.local/bin/claude");
    let ok = t
        .spec(&env, &[full.to_str().unwrap()], Tier::Full)
        .unwrap_or_else(|r| panic!("refused: {r}"));
    assert_eq!(ok.program, full);
    assert_eq!(
        t.spec(&env, &["sh"], Tier::Full).unwrap().program,
        sandbox::true_name(Path::new("/usr/bin")).unwrap().join("sh")
    );
}

/// The launch's sandbox is the one whose check passes (the doctor's check, not bwrap's presence): the full tier, else
/// the reduced tier, else a refusal that says the full tier's reason and fix (a container's bwrap that cannot run).
#[test]
fn the_launch_takes_the_tier_whose_check_passes() {
    use gleipnir::check::Check;
    let ok = || Check {
        ok: true,
        reason: None,
        fix: None,
        ..Check::failed(String::new(), None)
    };
    let container = || {
        Check::failed(
            "inside a container: bubblewrap needs user namespaces the container does not give".into(),
            Some("run it on the host".into()),
        )
    };
    let block = |f: &dyn Fn(Tier) -> Check| {
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(pick(|t| std::future::ready(f(t))))
    };
    assert_eq!(block(&|_| ok()), Ok(Tier::Full));
    assert_eq!(
        block(&|t| if t == Tier::Full { container() } else { ok() }),
        Ok(Tier::Reduced)
    );
    let refused = block(&|t| {
        if t == Tier::Full {
            container()
        } else {
            Check::failed("Landlock is off".into(), None)
        }
    })
    .unwrap_err();
    assert_eq!(refused.rule, gleipnir::Rule::Setup);
    assert!(
        refused.message.contains("inside a container") && refused.message.contains("run it on the host"),
        "{refused}"
    );
}
