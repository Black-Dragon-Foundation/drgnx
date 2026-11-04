//! Task 10's rows `launch-sandboxed/*`, run for real: the spec `launch::launch_on` builds is prepared by Gleipnir and
//! spawned through draugr, and a shell inside tries what a session must not do.  The sandbox is a hard requirement
//! (a skip would be a pass nobody checked): a host with no usable tier fails these tests with the reason.  So they are
//! the sandbox lane's (`#[ignore]`, run with `-- --ignored` on a host with bwrap and user namespaces: CI's runner
//! job, the desktop), never a container's, which has neither.  Fixtures live under /tmp/glp-XXXXXX; HOME points there.
#![cfg(target_os = "linux")]

use drgnx_ratatoskr::agents::launch::{NetCell, chat_launch, launch_on, scratch_dir, with_stdin};
use drgnx_ratatoskr::agents::lock::{Enforced, LaunchPlan};
use drgnx_ratatoskr::sandbox::{SessionShape, helper_at};
use gleipnir::{Sandbox, Tier};
use runstav::paths::{self, Env};
use std::path::{Path, PathBuf};
use std::time::Duration;

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
            gateway: false,
            trace: None,
        }
    }

    /// Run the plan in `shape` on `tier`; its exit code.  A tier that is not usable here fails the test.
    fn run(&self, tier: Tier, plan: &LaunchPlan, shape: &SessionShape) -> i32 {
        self.run_with(tier, plan, shape, || ())
    }

    /// [`Fx::run`] in the hub's order: nothing has made the session dir before the launch, and `between` runs after the
    /// launch and before the spawn (where `agents/start` binds the session's `mcp.sock`).
    fn run_with(
        &self,
        tier: Tier,
        plan: &LaunchPlan,
        shape: &SessionShape,
        between: impl FnOnce(),
    ) -> i32 {
        let sb = sandbox(tier);
        let env = self.env();
        let launch = launch_on(&env, &sb, plan, shape).unwrap_or_else(|r| panic!("refused: {r}"));
        between();
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
            browser: None,
        }
    }
}

/// The sandbox of `tier` here; a tier that is not usable fails the test.
fn sandbox(tier: Tier) -> Sandbox {
    Sandbox::detect(tier, helper_at(Path::new(RATATOSKR)), None)
        .unwrap_or_else(|r| panic!("the {tier:?} tier is not usable here: {r}"))
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
/// `agents/start`'s order: the launch of a new session id makes its session dir (no MCP session or agent socket has),
/// the hub binds the session's `mcp.sock` in it before the spawn, and the agent inside finds that socket.  A launch
/// that is refused leaves no session dir behind.
#[test]
#[ignore = "needs the real sandbox (bwrap with user namespaces): the sandbox lane"]
fn a_new_sessions_launch_makes_its_dir_and_a_refused_one_leaves_none() {
    let fx = Fx::new();
    let env = fx.env();
    let socket = paths::socket_path(&env);
    let dir = paths::session_dir(&env, &socket, "S1").unwrap();
    assert!(std::fs::symlink_metadata(&dir).is_err());
    let mcp = dir.join(paths::SESSION_MCP_SOCKET);
    let script = format!("[ -S {m} ] || exit 11; exit 0", m = mcp.display());
    let mut bound = None;
    let code = fx.run_with(
        reduced(),
        &fx.plan(&script),
        &fx.shape(NetCell::ProviderOnly),
        || bound = Some(std::os::unix::net::UnixListener::bind(&mcp).unwrap()),
    );
    assert_eq!(code, 0, "the agent did not find mcp.sock");
    drop(bound);

    let gone = paths::session_dir(&env, &socket, "S2").unwrap();
    let mut shape = fx.shape(NetCell::ProviderOnly);
    shape.sid = "S2".into();
    shape.write = vec![fx.p("home")];
    let refused = launch_on(&env, &sandbox(reduced()), &fx.plan("exit 0"), &shape)
        .expect_err("a writable home is refused");
    assert_eq!(refused.rule, gleipnir::Rule::ExposesUser, "{refused}");
    assert!(
        std::fs::symlink_metadata(&gone).is_err(),
        "{} was left",
        gone.display()
    );
}

/// The hub speaks ACP on an agent session's stdin and stdout: what it writes reaches the program inside the sandbox
/// (`launch::with_stdin`; a job's stdin stays `/dev/null`).
#[test]
#[ignore = "needs the real sandbox (bwrap with user namespaces): the sandbox lane"]
fn an_agent_sessions_stdin_reaches_the_program_inside() {
    use tokio::io::AsyncWriteExt;
    let fx = Fx::new();
    let env = fx.env();
    let plan = fx.plan("read -r l || exit 11; [ \"$l\" = ping ] || exit 12; exit 0");
    let launch = launch_on(
        &env,
        &sandbox(reduced()),
        &plan,
        &fx.shape(NetCell::ProviderOnly),
    )
    .unwrap_or_else(|r| panic!("refused: {r}"));
    let launch = with_stdin(launch);
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let code = rt.block_on(async {
        let mut child = draugr::spawn_pinned(launch.spec).await.expect("spawn");
        let mut stdin = child.take_stdin().expect("a pipe on the agent's stdin");
        if let Some(fd) = launch.status {
            gleipnir::read_status(fd, &|| child.stderr_tail(), Duration::from_secs(20))
                .unwrap_or_else(|r| panic!("the sandbox did not start: {r}"));
        }
        stdin.write_all(b"ping\n").await.expect("write");
        drop(stdin);
        let status = child.wait().await.expect("wait").expect("status");
        status.code().unwrap_or(-1)
    });
    assert_eq!(code, 0, "the program did not read the hub's line");
}

/// A Messages API request body the mock LLM's script answers (`msg-1`).
const BODY: &str =
    r#"{"model": "m", "max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]}"#;

/// `ratatoskr-mock llm` (domr's, built beside this binary: `cargo build -p domr`) on the conformance fixture's script,
/// logging to the fixture's `llm.log`: the child, its port and the log.
fn mock_llm(fx: &Fx) -> (std::process::Child, u16, PathBuf) {
    use std::io::BufRead;
    let mock = Path::new(RATATOSKR).with_file_name("ratatoskr-mock");
    assert!(
        mock.is_file(),
        "{} is not built: cargo build -p domr",
        mock.display()
    );
    let script = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../test/conformance/fixtures/llm-messages.json");
    let log = fx.p("llm.log");
    let mut llm = std::process::Command::new(&mock)
        .args(["llm", "--script"])
        .arg(&script)
        .arg("--log")
        .arg(&log)
        .stdout(std::process::Stdio::piped())
        .spawn()
        .expect("ratatoskr-mock llm");
    let mut line = String::new();
    std::io::BufReader::new(llm.stdout.take().unwrap())
        .read_line(&mut line)
        .unwrap();
    let port: u16 = line
        .trim()
        .strip_prefix("MOCK-LLM-PORT ")
        .and_then(|p| p.parse().ok())
        .unwrap_or_else(|| panic!("the mock said {line:?}"));
    (llm, port, log)
}

/// A sandboxed session on a gateway profile reaches the hub's gateway through its relay: a real hub in the fixture's
/// environment opens session S1's MCP session and registers its token on S1's `gateway.sock` (as `agents/start` does
/// for a sandboxed gateway profile), the plan is on the gateway's socket (`LaunchPlan::gateway`), and `curl` inside
/// posts to `$ANTHROPIC_BASE_URL` (the second relay port; loopback is in `NO_PROXY`, so not through the proxy), which
/// the gateway forwards to `ratatoskr-mock llm`.
#[test]
#[ignore = "needs the real sandbox (bwrap with user namespaces): the sandbox lane"]
fn a_gateway_session_reaches_the_hubs_gateway_through_its_relay() {
    use drgnx_ratatoskr::client::Client;
    use serde_json::json;
    let fx = Fx::new();
    let env = fx.env();
    let (mut llm, port, log) = mock_llm(&fx);
    let me = std::process::id();
    // the hub's runtime dir is private, as a user's is
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(fx.p("run"), std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    let mut hub = std::process::Command::new(RATATOSKR)
        .args(["serve", "--foreground", "--parent-pid", &me.to_string()])
        .env_clear()
        .envs([
            ("HOME", fx.p("home")),
            ("XDG_RUNTIME_DIR", fx.p("run")),
            ("TMPDIR", fx.p("t")),
            ("PATH", PathBuf::from("/usr/bin:/bin")),
            ("RATATOSKR_SUPERVISOR", PathBuf::from("none")),
        ])
        .current_dir(fx.p(""))
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::fs::File::create(fx.p("hub.err")).unwrap())
        .spawn()
        .expect("the hub");
    let within = Duration::from_secs(10);
    // a look repeated: the hub says nothing when it is ready; 30 s only bounds a failure
    let mut c = skuld::wait_until(
        "the hub answers a client (its stderr is hub.err)",
        30,
        || Client::user(&env, Duration::from_secs(2)).ok(),
    );
    let provider = json!({"a": {"kind": "anthropic", "url": format!("http://127.0.0.1:{port}"),
                                "caps": ["chat"], "messages": true}});
    c.call(
        "config/settings",
        json!({"overrides": [{"name": "drgnx-ai-providers", "source": "row", "value": provider}]}),
        within,
    )
    .expect("the provider table");
    c.call(
        "mcp/session",
        json!({"agent": "s-0000000a", "sid": "S1", "cwd": fx.p("wt"), "owner": me}),
        within,
    )
    .expect("the session's MCP session");
    let r = c
        .call(
            "gateway/register",
            json!({"chain": [["a", null]], "agent": "s-0000000a", "sid": "S1"}),
            within,
        )
        .expect("the session's registration");
    let token = r["token"].as_str().expect("a token").to_string();
    assert!(
        r["socket"].is_string() && r.get("url").is_none_or(|u| u.is_null()),
        "{r}"
    );

    let mut plan = fx.plan(&format!(
        "out=$(curl -sS -H \"Authorization: Bearer $ANTHROPIC_AUTH_TOKEN\" -H 'content-type: application/json' \
         -d '{BODY}' \"$ANTHROPIC_BASE_URL/v1/messages\") || exit 11; \
         echo \"$out\" | grep -q msg-1 || exit 12; exit 0"
    ));
    plan.gateway = true;
    plan.env = vec![("ANTHROPIC_AUTH_TOKEN".into(), token)];
    let shape = fx.shape(NetCell::ProviderOnly);
    let launch = launch_on(&env, &sandbox(Tier::Full), &plan, &shape)
        .unwrap_or_else(|r| panic!("refused: {r}"));
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let (code, tail) = rt.block_on(async {
        let mut child = draugr::spawn_pinned(launch.spec).await.expect("spawn");
        if let Some(fd) = launch.status {
            gleipnir::read_status(fd, &|| child.stderr_tail(), Duration::from_secs(20))
                .unwrap_or_else(|r| panic!("the sandbox did not start: {r}"));
        }
        let status = child.wait().await.expect("wait").expect("status");
        (status.code().unwrap_or(-1), child.stderr_tail())
    });
    drop(c);
    let _ = hub.kill();
    let _ = hub.wait();
    let _ = llm.kill();
    let _ = llm.wait();
    assert_eq!(code, 0, "the gateway was not reached: {tail}");
    assert!(
        std::fs::read_to_string(&log).is_ok_and(|t| t.contains("\"request\"")),
        "the mock saw no request"
    );
}

/// A sandboxed session reaches its provider through its own proxy: the hub's order (the launch makes the session dir,
/// `agents::net::SessionNet` binds `proxy.sock` in it, then the spawn), and `curl` inside, tunnelling through
/// `HTTPS_PROXY` (the relay port), reaches `ratatoskr-mock llm` under a pinned name.  The mock is domr's
/// `ratatoskr-mock`, built beside this binary (`cargo build -p domr`).
#[test]
#[ignore = "needs the real sandbox (bwrap with user namespaces): the sandbox lane"]
fn a_session_reaches_its_provider_through_the_proxy() {
    use drgnx_ratatoskr::agents::net::SessionNet;
    let fx = Fx::new();
    let env = fx.env();
    let (mut llm, port, log) = mock_llm(&fx);
    let body = BODY;
    let plan = fx.plan(&format!(
        "out=$(curl -sS --proxytunnel -x \"$HTTPS_PROXY\" -H 'content-type: application/json' \
         -d '{body}' http://llm.test:{port}/v1/messages) || exit 11; \
         echo \"$out\" | grep -q msg-1 || exit 12; exit 0"
    ));
    let shape = fx.shape(NetCell::ProviderOnly);
    let launch = launch_on(&env, &sandbox(Tier::Full), &plan, &shape)
        .unwrap_or_else(|r| panic!("refused: {r}"));
    let dir = paths::session_dir(&env, &paths::socket_path(&env), &shape.sid).unwrap();
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap();
    let code = rt.block_on(async {
        let allow = vec![gleipnir::net::host::parse_target(&format!("llm.test:{port}")).unwrap()];
        let pinned = vec![("llm.test".to_string(), std::net::Ipv4Addr::LOCALHOST.into())];
        let net = SessionNet::start(&dir, &shape.sid, allow, pinned, None).expect("the proxy");
        let mut child = draugr::spawn_pinned(launch.spec).await.expect("spawn");
        if let Some(fd) = launch.status {
            gleipnir::read_status(fd, &|| child.stderr_tail(), Duration::from_secs(20))
                .unwrap_or_else(|r| panic!("the sandbox did not start: {r}"));
        }
        let status = child.wait().await.expect("wait").expect("status");
        let tail = child.stderr_tail();
        drop(net);
        (status.code().unwrap_or(-1), tail)
    });
    let _ = llm.kill();
    let _ = llm.wait();
    assert_eq!(code.0, 0, "the provider was not reached: {}", code.1);
    assert!(
        std::fs::read_to_string(&log).is_ok_and(|t| t.contains("\"request\"")),
        "the mock saw no request"
    );
    assert!(std::fs::symlink_metadata(dir.join(paths::SESSION_PROXY_SOCKET)).is_err());
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

/// The folder Claude Code keeps a project's sessions in, under `~/.claude/projects`: its path with every character
/// that is not an ASCII letter or digit made `-`.
fn claude_folder(project: &Path) -> String {
    project
        .to_str()
        .unwrap()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

/// Pattern D (one run, its exit code, then the files on the host), on the full tier and on the reduced one where the
/// kernel has ABI 9.  An agent must never plant what your own, unsandboxed CLI runs or reads later: `settings.json`
/// and its hooks, commands, the shell snapshots its Bash tool sources.  The CLI still refreshes its token in place and
/// keeps its session's transcript, and it never sees another CLI's login.  (The fixture's home lies under `/tmp`, the
/// full tier's private one: a new file in a folder the sandbox shows only as a path may land there, never on the
/// host, so the host's files are what is checked.)
#[test]
#[ignore = "needs the real sandbox (bwrap with user namespaces): the sandbox lane"]
fn the_login_dir_takes_only_the_token_and_the_sessions_state() {
    let fx = Fx::new();
    let c = fx.p("home/.claude");
    for d in ["hooks", "commands", "shell-snapshots"] {
        std::fs::create_dir_all(c.join(d)).unwrap();
    }
    std::fs::write(c.join("settings.json"), "{}").unwrap();
    std::fs::write(c.join("commands/c.md"), "orig").unwrap();
    std::fs::write(c.join(".credentials.json"), "old").unwrap();
    std::fs::write(c.join("shell-snapshots/snapshot-zsh-1.sh"), "orig").unwrap();
    let project = c.join("projects").join(claude_folder(&fx.p("wt")));
    let script = format!(
        "cat {c}/settings.json >/dev/null || exit 10; \
         for f in settings.json commands/c.md; do echo x >> {c}/$f 2>/dev/null && exit 13; done; \
         for f in settings.local.json CLAUDE.md hooks/h.sh shell-snapshots/snapshot-zsh-1.sh; do \
           echo x >> {c}/$f 2>/dev/null; done; \
         mv {c}/settings.json {c}/moved 2>/dev/null && exit 14; mkdir {c}/plugins 2>/dev/null; \
         cat {x}/auth.json 2>/dev/null && exit 16; \
         echo new > {c}/.credentials.json || exit 11; echo t >> {p}/s.jsonl || exit 12; exit 0",
        c = c.display(),
        p = project.display(),
        x = fx.p("home/.codex").display()
    );
    let mut tiers = vec![Tier::Full];
    if reduced() == Tier::Reduced {
        tiers.push(Tier::Reduced);
    }
    for tier in tiers {
        let code = fx.run(tier, &fx.plan(&script), &fx.shape(NetCell::ProviderOnly));
        assert_eq!(code, 0, "{tier:?}");
    }
    for (f, was) in [
        ("settings.json", "{}"),
        ("commands/c.md", "orig"),
        ("shell-snapshots/snapshot-zsh-1.sh", "orig"),
    ] {
        assert_eq!(std::fs::read_to_string(c.join(f)).unwrap(), was, "{f}");
    }
    for f in [
        "settings.local.json",
        "CLAUDE.md",
        "hooks/h.sh",
        "plugins",
        "moved",
    ] {
        assert!(!c.join(f).exists(), "{f} was made");
    }
    assert_eq!(
        std::fs::read_to_string(c.join(".credentials.json")).unwrap(),
        "new\n"
    );
    assert!(project.join("s.jsonl").exists());
}

/// Pattern D (one run, its exit code).  A chat in your project, on the full tier: Claude's folder for that project is
/// the chat's own, bound over yours, so the chat cannot read your transcripts or plant auto memory your own CLI loads,
/// and what it writes there lands in its scratch.
#[test]
#[ignore = "needs the real sandbox (bwrap with user namespaces): the sandbox lane"]
fn a_project_chat_has_a_claude_project_folder_of_its_own() {
    let fx = Fx::new();
    let env = fx.env();
    let project = fx.p("proj");
    std::fs::create_dir_all(&project).unwrap();
    let yours = fx.p("home/.claude/projects").join(claude_folder(&project));
    std::fs::create_dir_all(yours.join("memory")).unwrap();
    std::fs::write(yours.join("you.jsonl"), "yours").unwrap();
    std::fs::write(yours.join("memory/MEMORY.md"), "yours").unwrap();
    let script = format!(
        "cat {y}/you.jsonl 2>/dev/null && exit 11; echo x >> {y}/memory/MEMORY.md 2>/dev/null; \
         echo t > {y}/chat.jsonl || exit 12; exit 0",
        y = yours.display()
    );
    let (plan, shape) = chat_launch(&env, &fx.plan(&script), "C1", &project).unwrap();
    let code = fx.run(Tier::Full, &plan, &shape);
    assert_eq!(code, 0);
    assert_eq!(
        std::fs::read_to_string(yours.join("memory/MEMORY.md")).unwrap(),
        "yours"
    );
    assert!(!yours.join("chat.jsonl").exists());
    assert!(
        scratch_dir(&env, "C1")
            .unwrap()
            .join("claude-project/chat.jsonl")
            .exists()
    );
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
        browser: None,
    };
    // Home lists nothing but the login dir: on the full tier home is the empty folder bwrap makes for that bind, on the
    // reduced tier it cannot be listed at all.
    let script = format!(
        "echo n > note || exit 11; cat {h}/secret.txt 2>/dev/null && exit 12; \
         ls -A {h} 2>/dev/null | grep -qvx .claude && exit 13; exit 0",
        h = fx.p("home").display()
    );
    let code = fx.run(reduced(), &fx.plan(&script), &shape);
    assert_eq!(code, 0);
    assert!(scratch.join("note").exists());
}

/// A chat in a project (the editor's agents panel, review): it starts in the project and reads it, and writes only its
/// scratch dir: no file in the project, not its git folder's hooks or config.
#[test]
#[ignore = "needs the real sandbox (bwrap with user namespaces): the sandbox lane"]
fn a_project_chat_reads_the_project_and_writes_only_its_scratch() {
    let fx = Fx::new();
    let env = fx.env();
    let project = fx.p("proj");
    std::fs::create_dir_all(project.join(".git/hooks")).unwrap();
    std::fs::write(project.join(".git/config"), "[core]\n").unwrap();
    std::fs::write(project.join("README"), "readme").unwrap();
    let scratch = scratch_dir(&env, "C1").unwrap();
    let script = format!(
        "[ \"$(pwd)\" = {p} ] || exit 11; grep -q readme README || exit 12; echo n > {s}/note || exit 13; \
         for f in new .envrc .git/hooks/post-checkout .git/config; do echo x >> {p}/$f 2>/dev/null && exit 14; done; \
         exit 0",
        p = project.display(),
        s = scratch.display()
    );
    let (plan, shape) = chat_launch(&env, &fx.plan(&script), "C1", &project).unwrap();
    let code = fx.run(reduced(), &plan, &shape);
    assert_eq!(code, 0);
    assert!(scratch.join("note").exists());
    assert!(!project.join("new").exists() && !project.join(".envrc").exists());
    assert_eq!(
        std::fs::read_to_string(project.join(".git/config")).unwrap(),
        "[core]\n"
    );

    // a linked worktree of a repository elsewhere (made by git, with HOME in the fixture): `git log` and `git diff`
    // work, and the common git folder cannot be written
    let git = |args: &[&str]| {
        let ok = std::process::Command::new("git")
            .args([
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "-c",
                "init.defaultBranch=main",
            ])
            .args(args)
            .env("HOME", fx.p("home"))
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .status()
            .expect("git")
            .success();
        assert!(ok, "git {args:?}");
    };
    let repo = fx.p("repo");
    let linked = fx.p("lw");
    let (r, l) = (repo.to_str().unwrap(), linked.to_str().unwrap());
    git(&["init", "-q", r]);
    std::fs::write(repo.join("f"), "one\n").unwrap();
    git(&["-C", r, "add", "f"]);
    git(&["-C", r, "commit", "-q", "-m", "first"]);
    git(&["-C", r, "worktree", "add", "-q", l]);
    let common = repo.join(".git");
    let script = format!(
        "git log --oneline -1 | grep -q first || exit 21; git diff --quiet HEAD || exit 22; \
         echo x > {c}/planted 2>/dev/null && exit 23; echo x >> {c}/config 2>/dev/null && exit 24; \
         echo x > {c}/hooks/post-checkout 2>/dev/null && exit 25; exit 0",
        c = common.display()
    );
    let config = std::fs::read_to_string(common.join("config")).unwrap();
    let (plan, shape) = chat_launch(&env, &fx.plan(&script), "C2", &linked).unwrap();
    assert!(shape.read.contains(&common) && !shape.write.iter().any(|w| common.starts_with(w)));
    let code = fx.run(reduced(), &plan, &shape);
    assert_eq!(code, 0);
    assert!(!common.join("planted").exists() && !common.join("hooks/post-checkout").exists());
    assert_eq!(
        std::fs::read_to_string(common.join("config")).unwrap(),
        config
    );
}

/// Pattern D (one run, its exit code), on the full tier and on the reduced one where the kernel has ABI 9.  The
/// session reads only what its CLI loads from the login dir: not the keys of your own Claude Code's daemon and live
/// sessions, not another project's transcript or auto memory, not your prompt history or shell snapshots.  A settings
/// file that is a link into your dotfiles still reads.
#[test]
#[ignore = "needs the real sandbox (bwrap with user namespaces): the sandbox lane"]
fn the_login_dir_shows_only_what_the_cli_loads() {
    let fx = Fx::new();
    let c = fx.p("home/.claude");
    for d in [
        "daemon",
        "sessions",
        "projects/-other/memory",
        "shell-snapshots",
        "commands",
    ] {
        std::fs::create_dir_all(c.join(d)).unwrap();
    }
    for f in [
        "daemon/control.key",
        "sessions/9.key",
        "projects/-other/t.jsonl",
        "projects/-other/memory/MEMORY.md",
        "history.jsonl",
        "shell-snapshots/snapshot-zsh-1.sh",
        "commands/c.md",
    ] {
        std::fs::write(c.join(f), "x").unwrap();
    }
    std::fs::create_dir_all(fx.p("home/dotfiles")).unwrap();
    std::fs::write(fx.p("home/dotfiles/settings.json"), "dotfile").unwrap();
    std::os::unix::fs::symlink(fx.p("home/dotfiles/settings.json"), c.join("settings.json"))
        .unwrap();
    let script = format!(
        "for f in daemon/control.key sessions/9.key projects/-other/t.jsonl projects/-other/memory/MEMORY.md \
           history.jsonl shell-snapshots/snapshot-zsh-1.sh; do cat {c}/$f >/dev/null 2>&1 && exit 13; done; \
         ls -A {c} {c}/projects 2>/dev/null | grep -qx -- '-other\\|daemon\\|history.jsonl' && exit 14; \
         grep -q dotfile {c}/settings.json || exit 11; cat {c}/commands/c.md >/dev/null || exit 12; exit 0",
        c = c.display()
    );
    let mut tiers = vec![Tier::Full];
    if reduced() == Tier::Reduced {
        tiers.push(Tier::Reduced);
    }
    for tier in tiers {
        let code = fx.run(tier, &fx.plan(&script), &fx.shape(NetCell::ProviderOnly));
        assert_eq!(code, 0, "{tier:?}");
    }
}

/// Pattern D (one run, its exit code), full tier.  Codex keeps every session it runs, yours too, in its `sessions`
/// folder: a sandboxed session gets an empty one of its own bound there, so it can neither read nor change yours, and
/// what it records lands in its scratch.
#[test]
#[ignore = "needs the real sandbox (bwrap with user namespaces): the sandbox lane"]
fn a_codex_session_records_into_a_sessions_folder_of_its_own() {
    let fx = Fx::new();
    let env = fx.env();
    let s = fx.p("home/.codex/sessions");
    std::fs::create_dir_all(s.join("2026")).unwrap();
    std::fs::write(s.join("2026/old.jsonl"), "yours").unwrap();
    let script = format!(
        "cat {s}/2026/old.jsonl 2>/dev/null && exit 11; echo x >> {s}/2026/old.jsonl 2>/dev/null; \
         mkdir -p {s}/2026/11 && echo t > {s}/2026/11/new.jsonl || exit 12; exit 0",
        s = s.display()
    );
    let mut plan = fx.plan(&script);
    plan.login_dir = Some(fx.p("home/.codex"));
    let code = fx.run(Tier::Full, &plan, &fx.shape(NetCell::ProviderOnly));
    assert_eq!(code, 0);
    assert_eq!(
        std::fs::read_to_string(s.join("2026/old.jsonl")).unwrap(),
        "yours"
    );
    assert!(!s.join("2026/11").exists());
    assert!(
        scratch_dir(&env, "S1")
            .unwrap()
            .join("login/sessions/2026/11/new.jsonl")
            .exists()
    );
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
        browser: None,
    };
    let code = fx.run(Tier::Full, &plan, &shape);
    assert_eq!(code, 0);
    assert!(wt.join("a").exists());
    assert_eq!(wt.join("mise.toml").metadata().unwrap().len(), 0);
}
