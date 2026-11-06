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
    }
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
