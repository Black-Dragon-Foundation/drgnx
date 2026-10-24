//! Your config files closed by their true paths, the write roots' settings files pinned, and what the reduced tier
//! says. Fixtures live under /tmp/glp-XXXXXX and never reach `~`.

use super::*;
use gleipnir::check::Check;
use gleipnir::{Context, Layers, Net, Rule, Spec, Target, validate};
use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};

struct Fx {
    _dir: tempfile::TempDir,
    b: PathBuf,
}

impl Fx {
    /// `home`, `config` (with `config-link` → `config`), `dot` (a dotfiles folder), `w` and `w2` (write roots),
    /// `outside`, `bin/ratatoskr`.
    fn new() -> Fx {
        let dir = tempfile::Builder::new()
            .prefix("glp-")
            .tempdir_in("/tmp")
            .unwrap();
        let b = fs::canonicalize(dir.path()).unwrap();
        for d in ["home", "config", "dot", "w", "w2", "outside", "bin"] {
            fs::create_dir_all(b.join(d)).unwrap();
        }
        symlink(b.join("config"), b.join("config-link")).unwrap();
        fs::write(b.join("bin/ratatoskr"), "x").unwrap();
        Fx { _dir: dir, b }
    }

    fn p(&self, rel: &str) -> PathBuf {
        self.b.join(rel)
    }

    fn file(&self, rel: &str) {
        let p = self.p(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, "x").unwrap();
    }

    fn link(&self, rel: &str, target: &str) {
        symlink(target, self.p(rel)).unwrap();
    }

    fn ctx(&self, closed: Vec<PathBuf>) -> Context {
        Context {
            home: self.p("home"),
            closed,
            ..Context::default()
        }
    }
}

fn spec(write: Vec<PathBuf>, binds: Vec<Bind>, target: Target) -> Spec {
    Spec {
        read: vec![],
        chdir: write[0].clone(),
        write,
        hide: vec![],
        sockets: vec![],
        binds,
        home: None,
        run: None,
        env: vec![],
        net: Net::Shared,
        tmp: None,
        layers: Layers::for_target(target),
        extra_tcp_ports: vec![],
    }
}

/// Step 5's mutation: without link resolution the stow targets are not closed, and this goes red.
#[test]
fn a_stow_link_target_is_closed() {
    let fx = Fx::new();
    fx.file("dot/settings.el");
    fx.file("config/config.el");
    fx.file("dot/my.el");
    fx.file("dot/sub/x.el");
    // A relative stow link, a dangling one, a self-loop, and a user Lisp file through a link.
    fx.link("config/settings.el", "../dot/settings.el");
    fx.link("config/custom.el", "../dot/not-yet-custom.el");
    fx.link("config/described.el", "described.el");
    fx.link("config/my.el", &fx.p("dot/my.el").to_string_lossy());
    // `..` is collapsed before any lookup, as Emacs does: `lisp/../top.el` is `config/top.el`, whatever `lisp` is.
    fx.link("config/lisp", "../dot/sub");
    // Inside a link's target, `..` is the kernel's: from the true folder (`lnk` is `sub/deeper`, so `lnk/..` is `sub`).
    fs::create_dir(fx.p("dot/sub/deeper")).unwrap();
    fx.link("dot/lnk", "sub/deeper");
    fx.link("dot/up", "lnk/../x.el");
    let files = [
        PathBuf::from("my.el"),
        PathBuf::from("lisp/../top.el"),
        fx.p("dot/up"),
        fx.p("home/lisp/init.el"),
    ];
    let got = closed_config_targets(&fx.p("config-link"), &files);
    let mut want = vec![
        fx.p("dot/settings.el"),
        fx.p("config/config.el"),
        fx.p("dot/not-yet-custom.el"),
        fx.p("config/workspaces"),
        fx.p("dot/my.el"),
        fx.p("config/top.el"),
        fx.p("dot/sub/x.el"),
        fx.p("home/lisp/init.el"),
    ];
    want.sort();
    assert_eq!(got, want);
    // Each is a name the context takes: gleipnir accepts it as a closed entry.
    validate(
        spec(vec![fx.p("w")], vec![], Target::LinuxBwrap),
        &fx.ctx(got),
        Target::LinuxBwrap,
    )
    .expect("the targets are true names");
}

/// The kernel's limit: 40 links are followed, a 41st is a loop.
#[test]
fn forty_links_are_followed_and_no_more() {
    let fx = Fx::new();
    fx.file("end");
    for n in [40, 41] {
        let d = fx.p(&format!("chain{n}"));
        fs::create_dir(&d).unwrap();
        for i in 1..n {
            symlink(d.join((i + 1).to_string()), d.join(i.to_string())).unwrap();
        }
        symlink(fx.p("end"), d.join(n.to_string())).unwrap();
        let got = followed(&d.join("1"), &mut 0);
        assert_eq!(got, (n == 40).then(|| fx.p("end")), "{n} links");
    }
    assert_eq!(followed(Path::new("relative/x"), &mut 0), None);
    assert_eq!(lexical(Path::new("/a/./b/../c")), PathBuf::from("/a/c"));
}

#[test]
fn a_write_root_holding_a_target_is_refused() {
    let fx = Fx::new();
    fx.file("dot/settings.el");
    fx.link("config/settings.el", "../dot/settings.el");
    let ctx = fx.ctx(closed_config_targets(&fx.p("config"), &[]));
    for target in [Target::LinuxBwrap, Target::LinuxReduced, Target::Macos] {
        let r = validate(spec(vec![fx.p("dot")], vec![], target), &ctx, target).unwrap_err();
        assert_eq!(r.rule, Rule::ExposesUser, "{target:?}: {}", r.message);
        assert!(r.message.contains("dot/settings.el"), "{}", r.message);
    }
    validate(
        spec(vec![fx.p("w")], vec![], Target::LinuxBwrap),
        &ctx,
        Target::LinuxBwrap,
    )
    .expect("a folder that holds none of them passes");
}

#[test]
fn the_user_lisp_files_come_from_settings_el() {
    let fx = Fx::new();
    let text = r#"(drgnx-settings :version 1
  (:mode emacs-lisp-mode (drgnx-user-lisp-files ("decoy.el")))
  (drgnx-user-lisp-files '(("~/lisp/init.el" :on nil) "rel.el" "" ("~bob/x.el") "~" "/abs/y.el"
                           ("dotted.el" . x) 7 (8))))"#;
    let settings = fx.p("config/settings.el");
    fs::write(&settings, text).unwrap();
    fs::set_permissions(&settings, fs::Permissions::from_mode(0o600)).unwrap();
    let home = fx.p("home");
    assert_eq!(
        read_user_lisp_files(&fx.p("config"), &home),
        [
            home.join("lisp/init.el"),
            fx.p("config/rel.el"),
            home.clone(),
            PathBuf::from("/abs/y.el"),
        ]
    );
    // None set, a value that is no list, no file: none.
    for text in [
        "(drgnx-settings :version 1)",
        "(drgnx-settings :version 1 (drgnx-user-lisp-files nil))",
    ] {
        fs::write(&settings, text).unwrap();
        assert_eq!(
            read_user_lisp_files(&fx.p("config"), &home),
            [] as [PathBuf; 0]
        );
    }
    assert!(read_user_lisp_files(&fx.p("nope"), &home).is_empty());
}

#[test]
fn pins_only_existing_files() {
    let fx = Fx::new();
    fx.file("w/.dir-locals.el");
    fs::create_dir(fx.p("w/.drgnx")).unwrap();
    fx.file("w/target.el");
    fx.file("outside/x.el");
    // In w2: one link into a write root (pinned at its target), one out of them (not writable: not pinned).
    fx.link(
        "w2/.dir-locals-2.el",
        &fx.p("w/target.el").to_string_lossy(),
    );
    fx.link("w2/.dir-locals.el", &fx.p("outside/x.el").to_string_lossy());
    fx.link("w2/.drgnx", "dangling");
    let roots = [fx.p("w"), fx.p("w2"), fx.p("w")];
    let ro = |p: PathBuf| Bind {
        mode: Mode::Ro,
        source: p.clone(),
        dest: p,
    };
    assert_eq!(
        settings_pins(&roots),
        [
            ro(fx.p("w/.dir-locals.el")),
            ro(fx.p("w/.drgnx")),
            ro(fx.p("w/target.el")),
        ]
    );
    assert!(settings_pins(&[fx.p("outside")]).is_empty());
}

#[cfg(target_os = "linux")]
#[test]
fn the_bwrap_argv_has_the_ro_binds() {
    let fx = Fx::new();
    fx.file("w/.dir-locals.el");
    fs::create_dir(fx.p("w/.drgnx")).unwrap();
    let roots = vec![fx.p("w")];
    let s = spec(roots.clone(), settings_pins(&roots), Target::LinuxBwrap);
    let valid = validate(s, &fx.ctx(vec![]), Target::LinuxBwrap).expect("valid");
    let helper = crate::sandbox::helper_at(&fx.p("bin/ratatoskr"));
    let opened = gleipnir::backend::linux::bwrap::open_sources(&valid, &helper).expect("opened");
    let (argv, _fds) = gleipnir::bwrap::argv(&valid, opened, &["/bin/true".into()]);
    let argv: Vec<String> = argv.into_iter().map(|a| a.into_string().unwrap()).collect();
    let at = |flag: &str, dest: &Path| {
        argv.windows(3)
            .position(|x| x[0] == flag && x[2] == dest.to_str().unwrap())
            .unwrap_or_else(|| panic!("{flag} … {dest:?} in {argv:?}"))
    };
    let root = at("--bind-fd", &fx.p("w"));
    // Each pin after its root, so it covers it.
    assert!(at("--ro-bind-fd", &fx.p("w/.dir-locals.el")) > root);
    assert!(at("--ro-bind-fd", &fx.p("w/.drgnx")) > root);
    assert!(
        !argv.iter().any(|a| a.ends_with(".dir-locals-2.el")),
        "{argv:?}"
    );
}

#[test]
fn the_seatbelt_profile_denies_case_insensitively() {
    let fx = Fx::new();
    fx.file("w/.dir-locals.el");
    let roots = vec![fx.p("w")];
    let s = spec(roots.clone(), settings_pins(&roots), Target::Macos);
    let valid = validate(s, &fx.ctx(vec![]), Target::Macos).expect("valid");
    let profile = gleipnir::sbpl::profile(&valid, &gleipnir::sbpl::MacContext::default()).unwrap();
    let pin = fx.p("w/.dir-locals.el");
    let deny = format!(
        "(deny file-write*\n  (subpath {})\n  (regex ",
        gleipnir::sbpl::quote(pin.to_str().unwrap()).unwrap()
    );
    let at = profile
        .find(&deny)
        .unwrap_or_else(|| panic!("{deny} in {profile}"));
    // The regex after it takes every case of the name (`s` also as U+017F, as APFS folds it).
    let regex = &profile[at + deny.len()..];
    let regex = &regex[..regex.find('\n').unwrap_or(regex.len())];
    assert!(
        regex.contains(r"\\.[Dd][Ii][Rr]-[Ll][Oo][Cc][Aa][Ll](s|S|ſ)\\.[Ee][Ll]"),
        "{regex}"
    );
    // After the write root's allow: SBPL's last match decides.
    let allow = profile.find("(allow file-write*").expect("an allow");
    assert!(at > allow, "{profile}");
}

#[test]
fn reduced_tier_says_it_cannot_pin() {
    let check = |backend| Check {
        backend,
        ok: true,
        ..Check::failed(String::new(), None)
    };
    for b in [BackendKind::Bwrap, BackendKind::Seatbelt, BackendKind::None] {
        assert_eq!(pins_note(b), None, "{b:?}");
        assert!(!crate::sandbox::check_text(&check(b)).contains("cannot pin"));
        assert!(!crate::doctor::sandbox_line(&check(b)).contains("cannot pin"));
        assert!(crate::sandbox::check_json(&check(b))["pins_note"].is_null());
    }
    let c = check(BackendKind::Reduced);
    assert_eq!(pins_note(BackendKind::Reduced), Some(REDUCED_CANNOT_PIN));
    assert!(REDUCED_CANNOT_PIN.contains("the review gate guards them"));
    assert_eq!(
        crate::sandbox::check_text(&c),
        format!("{}\n{REDUCED_CANNOT_PIN}", c.text())
    );
    let line = crate::doctor::sandbox_line(&c);
    assert!(
        line.starts_with("job sandbox backend: reduced works here"),
        "{line}"
    );
    assert!(line.ends_with(&format!("; {REDUCED_CANNOT_PIN}")), "{line}");
    assert_eq!(
        crate::sandbox::check_json(&c)["pins_note"],
        REDUCED_CANNOT_PIN
    );
}
