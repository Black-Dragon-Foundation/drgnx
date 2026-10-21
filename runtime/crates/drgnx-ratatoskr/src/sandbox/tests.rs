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
        PathBuf::from("/tmp/emacs1000"),
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
    for name in ENV_DENY {
        assert!(ctx.env_deny.contains(&name.to_string()));
    }
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
/// Gleipnir takes as a run source; the backend's directory is never one, nor can any other source reach it, and a
/// session dir holds no `backend.sock`.
#[test]
fn an_agent_session_dir_never_reaches_the_backend_socket() {
    let fx = Fx::new();
    let env = fx.env();
    let ctx = context_for(&env, Some(&fx.p("bin/ratatoskr")));
    let socket = paths::socket_path(&env);
    let session = paths::make_session_dir(&env, &socket, "0123456789ab").unwrap();
    fs::write(session.join(paths::SESSION_HUB_SOCKET), "").unwrap();
    let backend = paths::backend_socket_path(&env, &socket).unwrap();
    let backend_dir = backend.parent().unwrap().to_path_buf();
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
    // the backend's dir is no run source, nor readable, nor a socket's place
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
