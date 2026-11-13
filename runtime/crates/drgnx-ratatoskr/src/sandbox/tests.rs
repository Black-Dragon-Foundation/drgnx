//! The context Ratatoskr gives Gleipnir, the helper and the spawn mapping. Fixtures live under /tmp/glp-XXXXXX and
//! never reach `~`: the `Env` is a fixture's.

use super::*;
use gleipnir::{Bind, Layers, Mode, Net, Rule, Spec, Target, validate};
use std::fs;

struct Fx {
    _dir: tempfile::TempDir,
    b: PathBuf,
}

impl Fx {
    /// `home` (with `proj`, `.local/share` through a link `data-link` → `real-data`), `run` (a runtime dir), `t`
    /// (TMPDIR), `src` (DRGNX_DIR), `realbin` with a link `linkbin` to it (on PATH), `agent.sock`, `bin/ratatoskr`.
    fn new() -> Fx {
        let dir = tempfile::Builder::new()
            .prefix("glp-")
            .tempdir_in("/tmp")
            .unwrap();
        let b = fs::canonicalize(dir.path()).unwrap();
        for d in [
            "home/proj",
            "run",
            "t",
            "src",
            "realbin",
            "real-data",
            "bin",
        ] {
            fs::create_dir_all(b.join(d)).unwrap();
        }
        std::os::unix::fs::symlink(b.join("realbin"), b.join("linkbin")).unwrap();
        std::os::unix::fs::symlink(b.join("real-data"), b.join("data-link")).unwrap();
        for f in ["agent.sock", "bin/ratatoskr"] {
            fs::write(b.join(f), "x").unwrap();
        }
        Fx { _dir: dir, b }
    }

    fn p(&self, rel: &str) -> PathBuf {
        self.b.join(rel)
    }

    fn s(&self, rel: &str) -> String {
        self.p(rel).to_str().unwrap().to_owned()
    }

    fn env(&self) -> Env {
        let path = format!(
            "/usr/bin:relative/bin:{}:{}",
            self.s("linkbin"),
            self.s("nope/bin")
        );
        let bus = format!(
            "unix:path={}/bus%2cx,guid=1;unix:abstract=/tmp/dbus-x;unix:runtime=yes",
            self.s("run")
        );
        Env::new(
            &[
                ("HOME", &self.s("home")),
                ("XDG_RUNTIME_DIR", &self.s("run")),
                ("XDG_DATA_HOME", &self.s("data-link")),
                ("TMPDIR", &self.s("t")),
                ("DRGNX_DIR", &self.s("src")),
                ("SSH_AUTH_SOCK", &self.s("agent.sock")),
                ("DBUS_SESSION_BUS_ADDRESS", &bus),
                ("PATH", &path),
            ],
            1000,
        )
    }
}

#[test]
fn context_closes_data_state_config_and_sockets() {
    let fx = Fx::new();
    let ctx = context_for(&fx.env(), Some(&fx.p("bin/ratatoskr")));
    assert_eq!(ctx.home, fx.p("home"));
    for want in [
        fx.p("real-data/drgnx"), // XDG_DATA_HOME through a link: its true name
        fx.p("home/.config/drgnx"),
        fx.p("home/.local/state/drgnx"),
        fx.p("home/.local/state/drgnx/hub"),
        fx.p("run/drgnx"),
        fx.p("t/drgnx-hub-1000"),
        fx.p("t/emacs1000"),
        // the true name: on macOS /tmp is a link to /private/tmp, and the context closes true names
        std::fs::canonicalize("/tmp").unwrap().join("emacs1000"),
        fx.p("run/emacs"),
        fx.p("src"),
        fx.p("bin"),
    ] {
        assert!(
            ctx.closed.contains(&want),
            "{want:?} not in {:#?}",
            ctx.closed
        );
    }
    assert!(
        !ctx.closed.contains(&fx.p("data-link/drgnx")),
        "never the link"
    );
    assert_eq!(
        ctx.run_parents,
        vec![fx.p("run/drgnx/s"), fx.p("t/drgnx-hub-1000/s")]
    );
    let mut sockets = vec![fx.p("agent.sock"), fx.p("run/bus,x"), fx.p("run/bus")];
    sockets.sort();
    assert_eq!(ctx.user_sockets, sockets);
    // Absolute entries only, each by its true name (a missing one keeps its own).
    let mut dirs = vec![
        fs::canonicalize("/usr/bin").unwrap(),
        fx.p("realbin"),
        fx.p("nope/bin"),
    ];
    dirs.sort();
    assert_eq!(ctx.program_dirs, dirs);
    // Written out, not taken from the constant, so a dropped entry is caught (gate review M3); the secret's name too.
    let mut deny = ctx.env_deny.clone();
    deny.sort();
    assert_eq!(
        deny,
        [
            "DRGNX_AGENT",
            "DRGNX_CONFIG_DIR",
            "DRGNX_DATA_DIR",
            "DRGNX_HUB_PARENT_PID",
            "DRGNX_HUB_SERVE_SECRET",
            "DRGNX_HUB_SERVE_SOCKET",
        ]
    );
    // Gleipnir accepts the context, and it refuses what it closes.
    let spec = |write: PathBuf| Spec {
        read: vec![],
        write: vec![write.clone()],
        hide: vec![],
        sockets: vec![],
        binds: vec![],
        home: None,
        run: None,
        env: vec![],
        chdir: write,
        net: Net::Shared,
        tmp: None,
        layers: Layers::for_target(Target::LinuxBwrap),
        extra_tcp_ports: vec![],
        trace: Default::default(),
        browser: None,
    };
    validate(spec(fx.p("home/proj")), &ctx, Target::LinuxBwrap).expect("a task folder passes");
    for closed in [fx.p("real-data/drgnx/x"), fx.p("src"), fx.p("run/drgnx/s")] {
        fs::create_dir_all(&closed).unwrap();
        let r = validate(spec(closed.clone()), &ctx, Target::LinuxBwrap).unwrap_err();
        assert!(
            matches!(r.rule, Rule::Closed | Rule::ExposesUser | Rule::SessionDir),
            "{closed:?}: {r:?}"
        );
    }
    let r = validate(spec(fx.p("realbin")), &ctx, Target::LinuxBwrap).unwrap_err();
    assert_eq!(r.rule, Rule::ProgramDir, "{}", r.message);
}

/// The hub counts a chat's git reads by `trusted-folders.eld` (`agents::trust`): the file lives in the state dir, which
/// is closed, so no spec of an agent or a job can write it, nor read it, nor bind its folder.
#[test]
fn an_agent_cannot_write_the_trusted_folders_file() {
    let fx = Fx::new();
    let ctx = context_for(&fx.env(), Some(&fx.p("bin/ratatoskr")));
    let file = fx.p("home/.local/state/drgnx/trusted-folders.eld");
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(&file, "(:version 2 :folders ())\n").unwrap();
    let spec = |write: PathBuf, chdir: PathBuf| Spec {
        read: vec![],
        write: vec![write],
        hide: vec![],
        sockets: vec![],
        binds: vec![],
        home: None,
        run: None,
        env: vec![],
        chdir,
        net: Net::Shared,
        tmp: None,
        layers: Layers::for_target(Target::LinuxBwrap),
        extra_tcp_ports: vec![],
        trace: Default::default(),
        browser: None,
    };
    for write in [file.clone(), file.parent().unwrap().to_path_buf()] {
        let r = validate(
            spec(write.clone(), fx.p("home/proj")),
            &ctx,
            Target::LinuxBwrap,
        )
        .unwrap_err();
        assert!(
            matches!(r.rule, Rule::Closed | Rule::ExposesUser),
            "{write:?}: {r:?}"
        );
    }
}

/// Review M10: what an agent session is given is its session dir (`s/SID`, from `paths::make_session_dir`), which
/// Gleipnir takes as a run source; another directory beside the hub's socket (an older hub's `hub-HASH.d/`, say) is
/// never one, nor can any other source reach it.
#[test]
fn an_agent_session_dir_reaches_nothing_else_beside_the_socket() {
    let fx = Fx::new();
    let env = fx.env();
    let ctx = context_for(&env, Some(&fx.p("bin/ratatoskr")));
    let socket = paths::socket_path(&env);
    let session = paths::make_session_dir(&env, &socket, "0123456789ab").unwrap();
    fs::write(session.join(paths::SESSION_HUB_SOCKET), "").unwrap();
    let stem = socket.file_stem().unwrap().to_string_lossy().into_owned();
    let backend_dir = socket.parent().unwrap().join(format!("{stem}.d"));
    let backend = backend_dir.join("backend.sock");
    paths::private_dir(&backend_dir).unwrap();
    fs::write(&backend, "").unwrap();
    assert!(!session.join("backend.sock").exists());
    assert!(!backend.starts_with(&session) && !session.starts_with(&backend_dir));
    let spec = |run: Option<Bind>, read: Vec<PathBuf>, sockets: Vec<PathBuf>| Spec {
        read,
        write: vec![fx.p("home/proj")],
        hide: vec![],
        sockets,
        binds: vec![],
        home: None,
        run,
        env: vec![],
        chdir: fx.p("home/proj"),
        net: Net::Shared,
        tmp: None,
        layers: Layers::for_target(Target::LinuxBwrap),
        extra_tcp_ports: vec![],
        trace: Default::default(),
        browser: None,
    };
    let run = |source: &Path| {
        Some(Bind {
            mode: Mode::Ro,
            source: source.to_path_buf(),
            dest: "/run/drgnx".into(),
        })
    };
    // the session dir is a run source, its hub.sock a socket inside it
    validate(
        spec(
            run(&session),
            vec![],
            vec![session.join(paths::SESSION_HUB_SOCKET)],
        ),
        &ctx,
        Target::LinuxBwrap,
    )
    .expect("a session dir passes");
    // the other dir is no run source, nor readable, nor a socket's place
    for (what, s) in [
        ("run", spec(run(&backend_dir), vec![], vec![])),
        ("read", spec(None, vec![backend_dir.clone()], vec![])),
        ("read socket", spec(None, vec![backend.clone()], vec![])),
        ("socket", spec(run(&session), vec![], vec![backend.clone()])),
        // s/ whole would hold every session's sockets
        (
            "run s/",
            spec(run(session.parent().unwrap()), vec![], vec![]),
        ),
    ] {
        let r = validate(s, &ctx, Target::LinuxBwrap).unwrap_err();
        assert!(
            matches!(r.rule, Rule::Closed | Rule::SessionDir | Rule::ExposesUser),
            "{what}: {r:?}"
        );
    }
}

/// Review M12: the helper's own dir is closed, so no spec can write over the binary bwrap runs as the helper.
#[test]
fn helper_dir_is_closed() {
    let fx = Fx::new();
    let ctx = context_for(&fx.env(), Some(&fx.p("bin/ratatoskr")));
    assert!(ctx.closed.contains(&fx.p("bin")));
    let spec = Spec {
        read: vec![],
        write: vec![],
        hide: vec![],
        sockets: vec![],
        binds: vec![Bind {
            mode: Mode::Rw,
            source: fx.p("bin"),
            dest: "/mnt/bin".into(),
        }],
        home: None,
        run: None,
        env: vec![],
        chdir: "/".into(),
        net: Net::Shared,
        tmp: None,
        layers: Layers::for_target(Target::LinuxBwrap),
        extra_tcp_ports: vec![],
        trace: Default::default(),
        browser: None,
    };
    let r = validate(spec, &ctx, Target::LinuxBwrap).unwrap_err();
    assert_eq!(r.rule, Rule::ExposesUser, "{}", r.message);
    // The process's own binary, through the real lookup.
    let own = crate::idle::resolve_exe().unwrap();
    let dir = fs::canonicalize(own.parent().unwrap()).unwrap();
    assert!(context(&fx.env()).closed.contains(&dir));
    let h = helper().unwrap();
    assert_eq!(h.source, own);
    assert_eq!(h.inner_args, ["sandbox-inner"]);
    assert_eq!(h.relay_args, ["relay"]);
}

#[test]
fn true_names_resolve_links_and_keep_missing_tails() {
    let fx = Fx::new();
    assert_eq!(true_name(&fx.p("linkbin")), Some(fx.p("realbin")));
    assert_eq!(true_name(&fx.p("linkbin/a/../b")), Some(fx.p("realbin/b")));
    assert_eq!(
        true_name(Path::new(&format!("{}//./t/", fx.s("home")))),
        Some(fx.p("home/t"))
    );
    assert_eq!(true_name(Path::new("relative")), None);
    std::os::unix::fs::symlink(fx.p("gone"), fx.p("dangling")).unwrap();
    assert_eq!(true_name(&fx.p("dangling")), None);
    assert_eq!(unescape("a%2cb%zz%2"), b"a,b%zz%2");
}

#[test]
fn to_draugr_maps_every_field() {
    let (r, w) = std::io::pipe().unwrap();
    let inv = Invocation {
        program: "/p".into(),
        args: vec!["a".into()],
        env: vec![("K".into(), "V".into())],
        cwd: Some("/c".into()),
        fds: vec![(w.into(), 4), (r.into(), 3)],
        new_session: true,
    };
    let s = to_draugr(inv);
    assert_eq!(s.program, PathBuf::from("/p"));
    assert_eq!(s.args, ["a"]);
    assert_eq!(s.env, [(OsString::from("K"), OsString::from("V"))]);
    assert_eq!(s.cwd, Some(PathBuf::from("/c")));
    assert!(s.stdin_null && s.new_session);
    let targets: Vec<i32> = s.pass_fds.iter().map(|p| p.target).collect();
    assert_eq!(targets, [4, 3]);
}

/// A browser shape for the fixture's stand-in program (outside `/usr` and `/opt`), local ports 3000 and 5173.
fn browser(fx: &Fx) -> BrowserShape {
    let program = fx.p("chrome/headless_shell");
    fs::create_dir_all(program.parent().unwrap()).unwrap();
    fs::write(&program, "#!/bin/sh\n").unwrap();
    let found = crate::browser::resolve::Found {
        path: program,
        kind: crate::browser::resolve::Kind::HeadlessShell,
        version: None,
        source: crate::browser::resolve::Source::Setting,
    };
    browser_for(
        norn::matrix::Verdict::Allow,
        Some(gleipnir::BackendKind::Bwrap),
        9,
        Ok(found),
        vec![3000, 5173],
        1 << 20,
        crate::browser::Secret([0x5a; 32]),
    )
    .unwrap()
    .unwrap()
}

fn browser_plan(env: Vec<(String, String)>) -> crate::agents::lock::LaunchPlan {
    crate::agents::lock::LaunchPlan {
        argv: vec!["/bin/sh".into()],
        env,
        session_meta: None,
        protected_ro: vec![],
        login_dir: None,
        enforced: crate::agents::lock::Enforced::Yes,
        gateway: false,
        trace: None,
        ro_files: Vec::new(),
        gateway_url_env: Vec::new(),
    }
}

// [D] pure: the lock's files (`LaunchPlan::ro_files`). One in the session's own folder, which the agent reads and never
// writes on every target, is written there; one elsewhere (Codex's `/etc/codex`) is bound read-only at its path from a
// copy in the session's scratch on the full tier, and the launch is refused on any other.
#[test]
fn lock_files_are_written_bound_or_refused() {
    let fx = Fx::new();
    fs::create_dir_all(fx.p("wt")).unwrap();
    let env = fx.env();
    let ctx = context_for(&env, None);
    let run = paths::session_dir(&env, &paths::socket_path(&env), "S2").unwrap();
    let shape = SessionShape {
        sid: "S2".into(),
        cwd: fx.p("wt"),
        write: vec![fx.p("wt")],
        read: vec![],
        net: crate::agents::launch::NetCell::ProviderOnly,
        sockets: vec![],
        browser: None,
    };
    let mut plan = browser_plan(vec![]);
    let etc = PathBuf::from("/etc/codex/requirements.toml");
    plan.ro_files = vec![
        (run.join("lock/policy.toml"), b"a = 1\n".to_vec()),
        (etc.clone(), b"b = 2\n".to_vec()),
    ];
    let scratch = crate::agents::launch::scratch_dir(&env, "S2").unwrap();
    let built = session_spec(
        &env,
        &ctx,
        &plan,
        &shape,
        &scratch,
        Tier::Full,
        Target::LinuxBwrap,
    )
    .unwrap_or_else(|r| panic!("refused: {r}"));
    assert_eq!(
        fs::read_to_string(run.join("lock/policy.toml")).unwrap(),
        "a = 1\n"
    );
    let bind = built
        .spec
        .binds
        .iter()
        .find(|b| b.dest == etc)
        .expect("bound at its path");
    assert_eq!(bind.mode, Mode::Ro);
    assert!(bind.source.starts_with(&scratch), "{bind:?}");
    assert_eq!(fs::read_to_string(&bind.source).unwrap(), "b = 2\n");
    let refused = session_spec(
        &env,
        &ctx,
        &plan,
        &shape,
        &scratch,
        Tier::Reduced,
        Target::LinuxReduced,
    )
    .unwrap_err();
    assert!(
        refused.message.contains("/etc/codex/requirements.toml"),
        "{refused}"
    );
}

// [D] pure: a keyed job's key socket (`exec::keys`, in the session's folder) is a socket the program may connect to, by
// its path alone; on macOS Seatbelt allows connecting to that path (`path-literal`), never to the folder it is in, and
// `drgnx-key` is read as the file it is
#[test]
fn a_keyed_jobs_key_socket_is_allowed_by_its_path_alone() {
    let fx = Fx::new();
    fs::create_dir_all(fx.p("wt")).unwrap();
    let bin = fx.p("hub/drgnx-key");
    fs::create_dir_all(bin.parent().unwrap()).unwrap();
    fs::write(&bin, "x").unwrap();
    let env = fx.env();
    let ctx = context_for(&env, None);
    let run = paths::session_dir(&env, &paths::socket_path(&env), "S4").unwrap();
    let key = run.join("k-x1.sock");
    let shape = SessionShape {
        sid: "S4".into(),
        cwd: fx.p("wt"),
        write: vec![fx.p("wt")],
        read: vec![bin.clone()],
        net: crate::agents::launch::NetCell::ProviderOnly,
        sockets: vec![key.clone()],
        browser: None,
    };
    let plan = browser_plan(vec![]);
    let scratch = crate::agents::launch::scratch_dir(&env, "S4").unwrap();
    for target in [Target::LinuxBwrap, Target::Macos] {
        let built = session_spec(&env, &ctx, &plan, &shape, &scratch, Tier::Full, target)
            .unwrap_or_else(|r| panic!("{target:?} refused: {r}"));
        assert!(
            built.spec.sockets.contains(&key),
            "{:?}",
            built.spec.sockets
        );
        assert!(built.spec.read.contains(&bin), "{:?}", built.spec.read);
        if target == Target::Macos {
            let valid =
                validate(built.spec, &ctx, target).unwrap_or_else(|r| panic!("refused: {r}"));
            let profile =
                gleipnir::sbpl::profile(&valid, &gleipnir::sbpl::MacContext::default()).unwrap();
            let q = |p: &std::path::Path| gleipnir::sbpl::quote(p.to_str().unwrap()).unwrap();
            let allow = format!(
                "(allow network-outbound (remote unix-socket (path-literal {})))",
                q(&key)
            );
            assert!(profile.contains(&allow), "{allow} in {profile}");
            let folder = format!("(remote unix-socket (subpath {})))", q(&run));
            assert!(!profile.contains(&folder), "{folder} in {profile}");
        }
    }
}

// Kimi Code's and DeepSeek Harness's hub-owned homes (`<state>/agents/kimi-code`, `<state>/agents/dsh`) lie in the closed
// state dir and are the sessions' own: exactly those two are open, a sibling stays closed, and the lock's
// `config.toml` in the home is only the read-only copy bound over an empty file (P3-LOCK-ROWS-FULL-TIER-1).
#[test]
fn the_hub_owned_cli_homes_are_open_inside_the_closed_state_dir_and_nothing_beside_them() {
    let fx = Fx::new();
    fs::create_dir_all(fx.p("wt")).unwrap();
    let env = fx.env();
    let ctx = context_for(&env, None);
    let agents = fx.p("home/.local/state/drgnx/agents");
    for home in ["kimi-code", "dsh"] {
        assert!(
            ctx.open_inside_closed.contains(&agents.join(home)),
            "{home}: {:?}",
            ctx.open_inside_closed
        );
    }
    assert!(
        !ctx.open_inside_closed.contains(&agents),
        "never the folder above"
    );
    assert!(
        !ctx.open_inside_closed.contains(&agents.join("other")),
        "{:?}",
        ctx.open_inside_closed
    );
    let spec = |read: PathBuf| Spec {
        read: vec![read],
        write: vec![fx.p("wt")],
        hide: vec![],
        sockets: vec![],
        binds: vec![],
        home: None,
        run: None,
        env: vec![],
        chdir: fx.p("wt"),
        net: Net::Shared,
        tmp: None,
        layers: Layers::for_target(Target::LinuxBwrap),
        extra_tcp_ports: vec![],
        trace: Default::default(),
        browser: None,
    };
    // strictly inside an open entry, never the entry itself
    for ok in ["kimi-code/sessions", "dsh/profiles"] {
        let p = agents.join(ok);
        fs::create_dir_all(&p).unwrap();
        validate(spec(p.clone()), &ctx, Target::LinuxBwrap)
            .unwrap_or_else(|r| panic!("{ok} refused: {r}"));
    }
    let other = agents.join("other");
    fs::create_dir_all(&other).unwrap();
    let r = validate(spec(other), &ctx, Target::LinuxBwrap).unwrap_err();
    assert_eq!(r.rule, Rule::Closed, "{}", r.message);
}

#[test]
fn the_locks_config_toml_in_a_hub_home_stays_read_only_inside_the_session() {
    let fx = Fx::new();
    fs::create_dir_all(fx.p("wt")).unwrap();
    let env = fx.env();
    let ctx = context_for(&env, None);
    let home = fx.p("home/.local/state/drgnx/agents/kimi-code");
    let config = home.join("config.toml");
    let mut plan = browser_plan(vec![]);
    plan.login_dir = Some(home.clone());
    plan.ro_files = vec![(config.clone(), b"default_yolo = false\n".to_vec())];
    plan.make_home().unwrap();
    let shape = SessionShape {
        sid: "S5".into(),
        cwd: fx.p("wt"),
        write: vec![fx.p("wt")],
        read: vec![],
        net: crate::agents::launch::NetCell::ProviderOnly,
        sockets: vec![],
        browser: None,
    };
    let scratch = crate::agents::launch::scratch_dir(&env, "S5").unwrap();
    let built = session_spec(
        &env,
        &ctx,
        &plan,
        &shape,
        &scratch,
        Tier::Full,
        Target::LinuxBwrap,
    )
    .unwrap_or_else(|r| panic!("refused: {r}"));
    let bind = built
        .spec
        .binds
        .iter()
        .find(|b| b.dest == config)
        .expect("bound at its path");
    assert_eq!(bind.mode, Mode::Ro);
    assert_eq!(
        fs::read_to_string(&bind.source).unwrap(),
        "default_yolo = false\n"
    );
    // no write grant covers it, and the home's own state folders are the only writes there
    assert!(
        built.spec.write.iter().all(|w| !config.starts_with(w)),
        "{:?}",
        built.spec.write
    );
    assert!(
        built.spec.write.contains(&home.join("sessions")),
        "{:?}",
        built.spec.write
    );
    // the spec as built validates (it was refused as "inside a closed directory")
    validate(built.spec, &ctx, Target::LinuxBwrap).unwrap_or_else(|r| panic!("refused: {r}"));
}

#[test]
fn browser_spec_shape() {
    let fx = Fx::new();
    fs::create_dir_all(fx.p("wt")).unwrap();
    let env = fx.env();
    let ctx = context_for(&env, None);
    let b = browser(&fx);
    let secret = b.secret.hex();
    // the shape never shows its secret
    assert!(!format!("{b:?}").contains(&secret));
    let shape = SessionShape {
        sid: "S1".into(),
        cwd: fx.p("wt"),
        write: vec![fx.p("wt")],
        read: vec![],
        net: crate::agents::launch::NetCell::ProviderOnly,
        sockets: vec![],
        browser: Some(b),
    };
    // an editor's endpoint and a display are dropped
    let plan = browser_plan(vec![
        ("DRGNX_BROWSER_CDP".into(), "ws://elsewhere".into()),
        ("WAYLAND_DISPLAY".into(), "wayland-0".into()),
        ("DISPLAY".into(), ":0".into()),
        ("SOCK".into(), "/run/user/1000/x".into()),
        ("KEPT".into(), "1".into()),
    ]);
    let scratch = crate::agents::launch::scratch_dir(&env, "S1").unwrap();
    let built = session_spec(
        &env,
        &ctx,
        &plan,
        &shape,
        &scratch,
        Tier::Full,
        Target::LinuxBwrap,
    )
    .unwrap();
    let spec = validate(built.spec, &ctx, Target::LinuxBwrap)
        .unwrap_or_else(|r| panic!("refused: {r}"))
        .spec()
        .clone();
    let run = paths::session_dir(&env, &paths::socket_path(&env), "S1").unwrap();
    let Net::Isolated { relay, .. } = &spec.net else {
        panic!("{:?}", spec.net)
    };
    let relays: Vec<(u16, PathBuf)> = relay.iter().map(|r| (r.port, r.socket.clone())).collect();
    assert_eq!(
        relays,
        [
            (3128, run.join("proxy.sock")),
            (9222, run.join("cdp.sock")),
            (3130, run.join("web.sock"))
        ]
    );
    assert_eq!(spec.extra_tcp_ports, [3000, 5173]);
    assert!(spec.read.contains(&fx.p("chrome")), "{:?}", spec.read);
    let url = format!("ws://127.0.0.1:9222/devtools/browser/{secret}");
    let get = |k: &str| {
        spec.env
            .iter()
            .filter(|(n, _)| n == k)
            .map(|(_, v)| v.clone())
            .collect::<Vec<_>>()
    };
    assert_eq!(
        get("PLAYWRIGHT_MCP_CDP_ENDPOINT"),
        std::slice::from_ref(&url)
    );
    assert_eq!(get("DRGNX_BROWSER_CDP"), [url]);
    assert_eq!(get("KEPT"), ["1"]);
    for gone in ["WAYLAND_DISPLAY", "DISPLAY", "XDG_RUNTIME_DIR", "SOCK"] {
        assert!(get(gone).is_empty(), "{gone} is in {:?}", spec.env);
    }
    assert!(spec.env.iter().all(|(_, v)| !v.contains("/run/user")));
    let sb = spec.browser.as_ref().expect("Spec.browser");
    assert_eq!(sb.program, fx.p("chrome/headless_shell"));
    assert_eq!(sb.own_dir, PathBuf::from(gleipnir::BROWSER_DIR_FULL));
    assert_eq!(sb.web_port, 3130);
    assert_eq!(sb.local_ports, [3000, 5173]);
    assert!(sb.extra_read.contains(&fx.p("chrome")));
    assert_eq!(
        sb.host_args,
        ["--headless-shell", "--max-message", "1048576"]
    );
    // the secret is in the environment only
    assert!(sb.host_args.iter().all(|a| !a.contains(&secret)));
    assert!(!format!("{:?}", spec.read).contains(&secret));
    // and the data dir's browsers are open for a download's program
    assert!(
        ctx.open_inside_closed
            .contains(&true_name(&paths::data_dir(&env).join("browsers")).unwrap()),
        "{:?}",
        ctx.open_inside_closed
    );
}

#[test]
fn no_browser_without_abi9_or_bwrap_or_program() {
    use crate::browser::resolve::{Found, Kind, NotFound, Source};
    use norn::matrix::Verdict;
    let found = || {
        Ok(Found {
            path: "/usr/bin/chromium".into(),
            kind: Kind::Full,
            version: None,
            source: Source::System,
        })
    };
    let secret = || crate::browser::Secret([1; 32]);
    let ask =
        |cell, backend, abi, found| browser_for(cell, backend, abi, found, vec![], 64, secret());
    // Never: no browser and no reason to say
    assert_eq!(
        ask(Verdict::Never, None, 0, found()).map(|s| s.is_none()),
        Ok(true)
    );
    // Allow and Ask: one, on the full tier with ABI 9 and a program
    for cell in [Verdict::Allow, Verdict::Ask] {
        let s = ask(cell, Some(gleipnir::BackendKind::Bwrap), 9, found())
            .unwrap()
            .unwrap();
        assert_eq!((s.web_port, s.cdp_port, s.kind), (3130, 9222, Kind::Full));
    }
    let why = |backend, abi, found| ask(Verdict::Allow, backend, abi, found).unwrap_err();
    let tier = why(Some(gleipnir::BackendKind::Reduced), 10, found());
    assert_eq!(tier.kind, "tier");
    assert!(tier.fix.contains("bubblewrap"), "{tier:?}");
    assert_eq!(why(None, 10, found()).kind, "tier");
    let old = why(Some(gleipnir::BackendKind::Bwrap), 8, found());
    assert_eq!(old.kind, "landlock");
    assert!(old.why.contains('8') && old.why.contains('9'), "{old:?}");
    let none = why(
        Some(gleipnir::BackendKind::Bwrap),
        9,
        Err(NotFound {
            fix: "run drgnx browser install".into(),
        }),
    );
    assert_eq!(none.kind, "program");
    assert_eq!(none.fix, "run drgnx browser install");
}

/// [D]a one-shot run in a session's tree (a commit) removes the placeholders it made to pin the absent protected
/// files, and only those: the session's own stubs, made at its launch, stay listed and in place for its sandbox.
#[test]
fn a_one_shot_run_removes_only_the_stubs_it_made() {
    let fx = Fx::new();
    let (scratch, wt) = (fx.p("scratch"), fx.p("wt"));
    fs::create_dir_all(&scratch).unwrap();
    fs::create_dir_all(&wt).unwrap();
    // the session's launch pinned `.envrc`
    fs::write(wt.join(".envrc"), "").unwrap();
    fs::write(
        stubs_file(&scratch),
        format!("{}\n", wt.join(".envrc").display()),
    )
    .unwrap();
    let mark = stubs_mark(&scratch);
    // the one-shot run pinned `mise.toml` and `.claude`
    let (_, made) = pin_protected(
        &wt,
        &[
            PathBuf::from(".envrc"),
            PathBuf::from("mise.toml"),
            PathBuf::from(".claude"),
        ],
    )
    .unwrap();
    assert_eq!(made, [wt.join("mise.toml"), wt.join(".claude")]);
    let mut list = fs::read_to_string(stubs_file(&scratch)).unwrap();
    for p in &made {
        list.push_str(&format!("{}\n", p.display()));
    }
    fs::write(stubs_file(&scratch), list).unwrap();
    remove_stubs_since(&scratch, &wt, mark);
    assert!(!wt.join("mise.toml").exists() && !wt.join(".claude").exists());
    assert!(wt.join(".envrc").is_file(), "the session's own stub stays");
    assert_eq!(
        fs::read_to_string(stubs_file(&scratch)).unwrap(),
        format!("{}\n", wt.join(".envrc").display())
    );
    // the session's end removes its own as before
    remove_stubs(&scratch, &wt);
    assert!(!wt.join(".envrc").exists());
}

/// A job's sandbox notes the protected paths missing before its launch, and its end removes the stubs the launch
/// made for them: the tree is as the job found it, so its key is too.  A file that was there stays, and so does a
/// noted one written meanwhile.
#[test]
fn a_job_removes_the_stubs_its_launch_made() {
    let fx = Fx::new();
    let wt = fx.p("wt");
    fs::create_dir_all(&wt).unwrap();
    fs::write(wt.join(".envrc"), "export A=1\n").unwrap();
    let protected: Vec<PathBuf> = [".envrc", "mise.toml", ".claude", ".codex"]
        .iter()
        .map(|p| wt.join(p))
        .collect();
    let list = fx.p("stubs");
    note_missing(&list, &wt, &protected).unwrap();
    let (_, made) = pin_protected(&wt, &protected).unwrap();
    assert_eq!(
        made,
        [wt.join("mise.toml"), wt.join(".claude"), wt.join(".codex")]
    );
    fs::write(wt.join(".codex").join("x"), "").unwrap();
    remove_made(&list);
    assert!(!wt.join("mise.toml").exists() && !wt.join(".claude").exists());
    assert!(
        wt.join(".codex").join("x").exists(),
        "a folder written meanwhile stays"
    );
    assert_eq!(
        fs::read_to_string(wt.join(".envrc")).unwrap(),
        "export A=1\n"
    );
    assert!(!list.exists());
    // nothing missing: no list
    note_missing(&list, &wt, &protected[..1]).unwrap();
    assert!(!list.exists());
}

// GL-T12-4: `run_probe` reads the helper's status line without holding the runtime's thread. On a runtime of one
// thread, a task that wakes only when the child signals (after the read has begun) writes the line the read waits
// for. With the read on the thread itself the task never runs and the read times out.
#[tokio::test(flavor = "current_thread")]
async fn run_probe_reads_the_status_without_holding_the_runtime_thread() {
    use std::io::Write;
    use std::os::fd::OwnedFd;
    let (status_r, mut status_w) = std::io::pipe().unwrap();
    let (go_r, go_w) = std::io::pipe().unwrap();
    let prepared = gleipnir::backend::Prepared {
        invocation: gleipnir::backend::Invocation {
            program: "/bin/sh".into(),
            args: vec!["-c".into(), "sleep 0.3; echo go >&5; exec sleep 30".into()],
            env: vec![("PATH".into(), "/usr/bin:/bin".into())],
            cwd: None,
            fds: vec![(OwnedFd::from(go_w), 5)],
            new_session: false,
        },
        status: Some(OwnedFd::from(status_r)),
        layers: None,
        browser: false,
    };
    let task = tokio::spawn(async move {
        let go =
            tokio::net::unix::pipe::Receiver::from_file(std::fs::File::from(OwnedFd::from(go_r)))
                .unwrap();
        go.readable().await.unwrap();
        status_w
            .write_all(b"{\"ok\":false,\"error\":\"from the task\"}\n")
            .unwrap();
        status_w
    });
    let ran = run_probe(prepared, Duration::from_millis(2500)).await;
    let _w = task.await.unwrap();
    let why = ran.layers.expect_err("the line says ok false").message;
    assert!(why.contains("from the task"), "{why}");
}

// GL-T15-4: a refused start's `exit` in the result file is the helper's setup failure, whichever of the helper and
// the group's kill came first (it was 125 or 143 by race).
#[cfg(feature = "test-hooks")]
#[test]
fn a_refused_starts_exit_is_always_the_setup_failure() {
    use super::run::refused_start_exit;
    assert_eq!(
        refused_start_exit(Some(143)),
        Some(gleipnir::inner::EXIT_SETUP)
    );
    assert_eq!(
        refused_start_exit(Some(125)),
        Some(gleipnir::inner::EXIT_SETUP)
    );
    assert_eq!(
        refused_start_exit(Some(0)),
        Some(gleipnir::inner::EXIT_SETUP)
    );
    assert_eq!(refused_start_exit(None), None);
}
