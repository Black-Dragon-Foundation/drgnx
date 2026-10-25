//! Task 10's rows `launch-sandboxed/*`, run for real: the spec `launch::launch_on` builds is prepared by Gleipnir and
//! spawned through draugr, and a shell inside tries what a session must not do.  The sandbox is a hard requirement
//! (a skip would be a pass nobody checked): a host with no usable tier fails these tests with the reason.  So they are
//! the sandbox lane's (`#[ignore]`, run with `-- --ignored` on a host with bwrap and user namespaces: CI's runner
//! job, the desktop), never a container's, which has neither.  Fixtures live under /tmp/glp-XXXXXX; HOME points there.
#![cfg(target_os = "linux")]

use drgnx_ratatoskr::agents::launch::{NetCell, launch_on, scratch_dir};
use drgnx_ratatoskr::agents::lock::{Enforced, LaunchPlan};
use drgnx_ratatoskr::sandbox::{SessionShape, helper_at};
use gleipnir::{Sandbox, Tier};
use runstav::paths::{self, Env};
use std::path::{Path, PathBuf};

const RATATOSKR: &str = env!("CARGO_BIN_EXE_ratatoskr");

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
        let b = std::fs::canonicalize(dir.path()).unwrap();
        for d in [
            "home/.claude",
            "home/.codex",
            "wt/.codex",
            "outside",
            "run",
            "t",
        ] {
            std::fs::create_dir_all(b.join(d)).unwrap();
        }
        std::fs::write(b.join("home/.codex/auth.json"), "codex-token").unwrap();
        std::fs::write(b.join("home/secret.txt"), "home-file").unwrap();
        std::fs::write(b.join("wt/.codex/config.toml"), "orig").unwrap();
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
            rustix::process::geteuid().as_raw(),
        )
    }

    fn plan(&self, script: &str) -> LaunchPlan {
        LaunchPlan {
            argv: vec!["/bin/bash".into(), "-c".into(), script.into()],
            env: vec![],
            session_meta: None,
            protected_ro: vec![self.p("wt/.codex")],
            login_dir: Some(self.p("home/.claude")),
            enforced: Enforced::Yes,
        }
    }

    /// Run the plan in `shape` on `tier`; its exit code.  A tier that is not usable here fails the test.
    fn run(&self, tier: Tier, plan: &LaunchPlan, shape: &SessionShape) -> i32 {
        let sb = Sandbox::detect(tier, helper_at(Path::new(RATATOSKR)), None)
            .unwrap_or_else(|r| panic!("the {tier:?} tier is not usable here: {r}"));
        let env = self.env();
        paths::make_session_dir(&env, &paths::socket_path(&env), &shape.sid).unwrap();
        let launch = launch_on(&env, &sb, plan, shape).unwrap_or_else(|r| panic!("refused: {r}"));
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let mut child = draugr::spawn_pinned(launch.spec).await.expect("spawn");
            let deadline = std::time::Duration::from_secs(20);
            if let Some(fd) = launch.status {
                gleipnir::read_status(fd, &|| child.stderr_tail(), deadline)
                    .unwrap_or_else(|r| panic!("the sandbox did not start: {r}"));
            }
            let status = child.wait().await.expect("wait").expect("status");
            status.code().unwrap_or(-1)
        })
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
}

/// The reduced tier where the kernel has Landlock ABI 9, else the full tier: the row's check runs under a real
/// sandbox either way (no CI runner's kernel has ABI 9 yet; the escape suite's reduced rows list that).
fn reduced() -> Tier {
    let abi = gleipnir::landlock::kernel_abi();
    if abi >= 9 {
        Tier::Reduced
    } else {
        eprintln!(
            "the kernel's Landlock ABI is {abi}, below the reduced tier's 9: this row runs on the full tier"
        );
        Tier::Full
    }
}
#[test]
#[ignore = "needs the real sandbox (bwrap with user namespaces): the sandbox lane"]
fn worker_writes_only_its_worktree() {
    let fx = Fx::new();
    let script = format!(
        "echo a > {w}/a || exit 11; echo b > {o}/b 2>/dev/null && exit 12; exit 0",
        w = fx.p("wt").display(),
        o = fx.p("outside").display()
    );
    let code = fx.run(
        reduced(),
        &fx.plan(&script),
        &fx.shape(NetCell::ProviderOnly),
    );
    assert_eq!(code, 0);
    assert!(fx.p("wt/a").exists());
    assert!(!fx.p("outside/b").exists());
}

/// Bwrap's read-only bind is what pins a path inside a writable root; the reduced tier cannot
/// (`sandbox_settings::REDUCED_CANNOT_PIN`), so this row needs the full tier.
#[test]
#[ignore = "needs the real sandbox (bwrap with user namespaces): the sandbox lane"]
fn codex_config_is_read_only() {
    let fx = Fx::new();
    let script = format!(
        "echo x > {c} 2>/dev/null && exit 12; exit 0",
        c = fx.p("wt/.codex/config.toml").display()
    );
    let code = fx.run(
        Tier::Full,
        &fx.plan(&script),
        &fx.shape(NetCell::ProviderOnly),
    );
    assert_eq!(code, 0);
    assert_eq!(
        std::fs::read_to_string(fx.p("wt/.codex/config.toml")).unwrap(),
        "orig"
    );
}

#[test]
#[ignore = "needs the real sandbox (bwrap with user namespaces): the sandbox lane"]
fn network_is_provider_only_under_balanced() {
    let fx = Fx::new();
    let other = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let script = format!(
        "(exec 4<>/dev/tcp/127.0.0.1/{}) 2>/dev/null && exit 12; exit 0",
        other.local_addr().unwrap().port()
    );
    let code = fx.run(
        reduced(),
        &fx.plan(&script),
        &fx.shape(NetCell::ProviderOnly),
    );
    assert_eq!(code, 0, "a live listener outside was reachable");
}

#[test]
#[ignore = "needs the real sandbox (bwrap with user namespaces): the sandbox lane"]
fn the_login_token_dir_is_bound_for_its_own_cli_only() {
    let fx = Fx::new();
    let script = format!(
        "echo t > {c}/token || exit 11; cat {x}/auth.json 2>/dev/null && exit 12; exit 0",
        c = fx.p("home/.claude").display(),
        x = fx.p("home/.codex").display()
    );
    let code = fx.run(
        reduced(),
        &fx.plan(&script),
        &fx.shape(NetCell::ProviderOnly),
    );
    assert_eq!(code, 0);
    assert!(fx.p("home/.claude/token").exists());
}

#[test]
#[ignore = "needs the real sandbox (bwrap with user namespaces): the sandbox lane"]
fn plain_chat_cannot_read_home() {
    let fx = Fx::new();
    let env = fx.env();
    let scratch = scratch_dir(&env, "C1").unwrap();
    let shape = SessionShape {
        sid: "C1".into(),
        cwd: scratch.clone(),
        write: vec![scratch.clone()],
        read: vec![],
        net: NetCell::ProviderOnly,
    };
    let script = format!(
        "echo n > note || exit 11; cat {h}/secret.txt 2>/dev/null && exit 12; ls {h} >/dev/null 2>&1 && exit 13; exit 0",
        h = fx.p("home").display()
    );
    let code = fx.run(reduced(), &fx.plan(&script), &shape);
    assert_eq!(code, 0);
    assert!(scratch.join("note").exists());
}

/// B3 + B4 on the shipped layout: the worktree sits under `<state>/hub/runs` (inside Gleipnir's closed folders) and
/// the lock's real, relative `PROTECTED_RO` list is pinned inside it, `.envrc` and `mise.toml` included, though none
/// exists yet.  Pinning needs bwrap's read-only bind, so the full tier.
#[test]
#[ignore = "needs the real sandbox (bwrap with user namespaces): the sandbox lane"]
fn a_worker_under_the_hub_run_root_cannot_write_the_protected_files() {
    use drgnx_ratatoskr::agents::lock::PROTECTED_RO;
    let fx = Fx::new();
    let env = fx.env();
    let wt = paths::state_dir(&env).join("hub/runs/w1");
    std::fs::create_dir_all(wt.join(".git")).unwrap();
    let mut plan = fx.plan(&format!(
        "echo a > {w}/a || exit 11; for f in .envrc mise.toml .claude/settings.json .git/hooks/post-merge; do \
         echo x > {w}/$f 2>/dev/null && exit 12; done; exit 0",
        w = wt.display()
    ));
    plan.protected_ro = PROTECTED_RO.iter().map(PathBuf::from).collect();
    let shape = SessionShape {
        sid: "S1".into(),
        cwd: wt.clone(),
        write: vec![wt.clone()],
        read: vec![],
        net: NetCell::ProviderOnly,
    };
    let code = fx.run(Tier::Full, &plan, &shape);
    assert_eq!(code, 0);
    assert!(wt.join("a").exists());
    assert_eq!(wt.join("mise.toml").metadata().unwrap().len(), 0);
}
