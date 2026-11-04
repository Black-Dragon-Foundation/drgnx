//! The agent browser under a real sandbox: a session spec with `browser`, prepared by Gleipnir and spawned through
//! draugr, so the inner helper forks `ratatoskr browser-host` under the browser layer, with the stand-in Chromium
//! (`tests/data/fake-chromium.sh`) as its program. The sandbox lane's (`#[ignore]`): bwrap, user namespaces and
//! Landlock ABI 9, which no container has. Fixtures live under /tmp/glp-XXXXXX; HOME points there.
#![cfg(target_os = "linux")]

use drgnx_ratatoskr::agents::launch::{NetCell, scratch_dir};
use drgnx_ratatoskr::agents::lock::{Enforced, LaunchPlan};
use drgnx_ratatoskr::sandbox::{self, SessionShape, helper_at};
use gleipnir::{BROWSER_DIR_FULL, Net, RelayPort, Sandbox, SpecBrowser, Tier};
use heimdall::codec::{Frame, FrameDecoder, KIND_CDP, KIND_CONTROL};
use runstav::paths::Env;
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const RATATOSKR: &str = env!("CARGO_BIN_EXE_ratatoskr");

fn data_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data")
}

/// The hub's side of the socketpair: frames out, frames in (the others kept for later).
struct Hub {
    s: UnixStream,
    dec: FrameDecoder,
    backlog: Vec<Frame>,
}

impl Hub {
    fn send(&mut self, kind: u8, payload: &str) {
        self.s
            .write_all(&Frame::encode(kind, payload.as_bytes()))
            .unwrap();
    }

    fn wait(&mut self, what: &str, within: Duration, want: impl Fn(&Frame) -> bool) -> Frame {
        let end = Instant::now() + within;
        let mut buf = [0u8; 65536];
        loop {
            if let Some(i) = self.backlog.iter().position(&want) {
                return self.backlog.remove(i);
            }
            let left = end.saturating_duration_since(Instant::now());
            assert!(
                !left.is_zero(),
                "no {what} within {within:?}; got {:?}",
                self.backlog
            );
            self.s.set_read_timeout(Some(left)).unwrap();
            match self.s.read(&mut buf) {
                Ok(0) => panic!("the host closed before {what}; got {:?}", self.backlog),
                Ok(n) => self.backlog.extend(self.dec.push(&buf[..n]).unwrap()),
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(e) => panic!("{e}"),
            }
        }
    }

    fn event(&mut self, ev: &str) -> Value {
        let f = self.wait(ev, Duration::from_secs(10), |f| {
            f.kind == KIND_CONTROL
                && serde_json::from_slice::<Value>(&f.payload).is_ok_and(|v| v["ev"] == ev)
        });
        serde_json::from_slice(&f.payload).unwrap()
    }
}

/// The browser host starts under its layer: its own check passes there (it refuses to run otherwise), Chromium
/// starts with its pipe, a CDP message gets its reply, its stderr comes out as an event, and a stop ends it.
#[test]
#[ignore = "needs bwrap, user namespaces and Landlock ABI 9 (the VM)"]
fn the_host_starts_under_its_layer() {
    let abi = gleipnir::landlock::kernel_abi();
    assert!(
        abi >= 9,
        "the kernel's Landlock ABI is {abi}: the browser needs 9"
    );
    let dir = tempfile::Builder::new()
        .prefix("glp-")
        .tempdir_in("/tmp")
        .unwrap();
    let b = std::fs::canonicalize(dir.path()).unwrap();
    for d in ["home", "wt", "run", "t"] {
        std::fs::create_dir_all(b.join(d)).unwrap();
    }
    let s = |rel: &str| b.join(rel).to_str().unwrap().to_owned();
    let env = Env::new(
        &[
            ("HOME", &s("home")),
            ("XDG_RUNTIME_DIR", &s("run")),
            ("TMPDIR", &s("t")),
            ("PATH", "/usr/bin:/bin"),
        ],
        rustix::process::geteuid().as_raw(),
    );
    let plan = LaunchPlan {
        argv: vec!["/bin/bash".into(), "-c".into(), "sleep 60".into()],
        env: vec![],
        session_meta: None,
        protected_ro: vec![],
        login_dir: None,
        enforced: Enforced::Yes,
        gateway: false,
    };
    let data = data_dir();
    let shape = SessionShape {
        sid: "S1".into(),
        cwd: b.join("wt"),
        write: vec![b.join("wt")],
        read: vec![data.clone()],
        net: NetCell::ProviderOnly,
        browser: None,
    };
    let sb = Sandbox::detect(Tier::Full, helper_at(Path::new(RATATOSKR)), None)
        .unwrap_or_else(|r| panic!("the full tier is not usable here: {r}"));
    let target = sb.target().unwrap();
    let ctx = sandbox::context(&env);
    let scratch = scratch_dir(&env, "S1").unwrap();
    let built = sandbox::session_spec(&env, &ctx, &plan, &shape, &scratch, sb.tier(), target)
        .unwrap_or_else(|r| panic!("refused: {r}"));
    let mut spec = built.spec;
    if let Net::Isolated { relay, .. } = &mut spec.net {
        let socket = relay[0].socket.with_file_name("web.sock");
        relay.push(RelayPort { port: 3130, socket });
    }
    spec.browser = Some(SpecBrowser {
        program: data.join("fake-chromium.sh"),
        own_dir: BROWSER_DIR_FULL.into(),
        web_port: 3130,
        local_ports: vec![],
        extra_read: vec![data],
        host_args: vec!["--full".into(), "--max-message".into(), "1048576".into()],
    });
    let valid = gleipnir::validate(spec, &ctx, target).unwrap_or_else(|r| panic!("refused: {r}"));
    let (hub, end) = UnixStream::pair().unwrap();
    let command = vec![
        built.program.to_string_lossy().into_owned(),
        "-c".into(),
        "sleep 60".into(),
    ];
    let prepared = sb
        .prepare(
            valid,
            command,
            Some(end.into()),
            #[cfg(feature = "test-hooks")]
            gleipnir::TestHooks::default(),
        )
        .unwrap_or_else(|r| panic!("refused: {r}"));
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let mut child = draugr::spawn_pinned(sandbox::to_draugr(prepared.invocation))
            .await
            .expect("spawn");
        let status = prepared.status.expect("a status pipe");
        let layers = gleipnir::inner::read_status_for(
            status,
            &|| child.stderr_tail(),
            Duration::from_secs(20),
            prepared.browser,
        )
        .unwrap_or_else(|r| panic!("the sandbox did not start: {r}\n{}", child.stderr_tail()));
        assert!(layers.browser, "{layers:?}");
        let talk = tokio::task::spawn_blocking(move || {
            let mut hub = Hub {
                s: hub,
                dec: FrameDecoder::new((1 << 20) + 64),
                backlog: vec![],
            };
            hub.send(KIND_CONTROL, &json!({"op": "start"}).to_string());
            let started = hub.event("started");
            assert!(started["pid"].as_i64().is_some_and(|p| p > 0), "{started}");
            hub.send(KIND_CDP, r#"{"id":1,"method":"Browser.getVersion"}"#);
            let reply = hub.wait("the reply", Duration::from_secs(10), |f| f.kind == KIND_CDP);
            let reply: Value = serde_json::from_slice(&reply.payload).unwrap();
            assert_eq!(reply["id"], 1, "{reply}");
            assert_eq!(hub.event("stderr")["line"], "fake-chromium: up");
            hub.send(
                KIND_CONTROL,
                &json!({"op": "stop", "why": "idle"}).to_string(),
            );
            hub.event("exited")
        });
        let exited = talk.await;
        // SAFETY: the sandbox's own process group, which draugr made.
        unsafe { libc::kill(-child.id(), libc::SIGKILL) };
        let _ = child.wait().await;
        let exited = exited.unwrap_or_else(|e| panic!("{e}\n{}", child.stderr_tail()));
        assert!(
            exited["code"].is_number() || exited["signal"].is_number(),
            "{exited}"
        );
    });
}

/// A worker session's launch with the browser, as the hub makes it (`launch_on` with a `BrowserShape`: the relays,
/// the socketpair, `Spec.browser`), the stand-in Chromium as its program; the agent runs `bash -c AGENT` in `wt`.
/// With PROBE, `gleipnir-probe` (built next to ratatoskr) is copied to `bin/` beside `wt`, which the agent reads, so it
/// can serve a dev server as `../bin/gleipnir-probe serve-http …`.
struct Launched {
    _dir: tempfile::TempDir,
    b: PathBuf,
    launch: drgnx_ratatoskr::agents::launch::Launch,
}

fn launch_with_browser(agent: &str) -> Launched {
    launch_with(agent, false)
}

fn launch_with(agent: &str, probe: bool) -> Launched {
    let abi = gleipnir::landlock::kernel_abi();
    assert!(
        abi >= 9,
        "the kernel's Landlock ABI is {abi}: the browser needs 9"
    );
    let dir = tempfile::Builder::new()
        .prefix("glp-")
        .tempdir_in("/tmp")
        .unwrap();
    let b = std::fs::canonicalize(dir.path()).unwrap();
    for d in ["home", "wt", "run", "t"] {
        std::fs::create_dir_all(b.join(d)).unwrap();
    }
    let s = |rel: &str| b.join(rel).to_str().unwrap().to_owned();
    let env = Env::new(
        &[
            ("HOME", &s("home")),
            ("XDG_RUNTIME_DIR", &s("run")),
            ("TMPDIR", &s("t")),
            ("PATH", "/usr/bin:/bin"),
        ],
        rustix::process::geteuid().as_raw(),
    );
    let plan = LaunchPlan {
        argv: vec!["/bin/bash".into(), "-c".into(), agent.into()],
        env: vec![],
        session_meta: None,
        protected_ro: vec![],
        login_dir: None,
        enforced: Enforced::Yes,
        gateway: false,
    };
    let data = data_dir();
    let mut read = vec![data.clone()];
    if probe {
        let built = Path::new(RATATOSKR).with_file_name("gleipnir-probe");
        assert!(
            built.exists(),
            "build gleipnir-probe first: {}",
            built.display()
        );
        std::fs::create_dir_all(b.join("bin")).unwrap();
        std::fs::copy(&built, b.join("bin/gleipnir-probe")).unwrap();
        read.push(b.join("bin"));
    }
    let shape = SessionShape {
        sid: "S1".into(),
        cwd: b.join("wt"),
        write: vec![b.join("wt")],
        read,
        net: NetCell::ProviderOnly,
        browser: Some(sandbox::BrowserShape {
            program: data.join("fake-chromium.sh"),
            kind: drgnx_ratatoskr::browser::resolve::Kind::Full,
            web_port: sandbox::WEB_PORT,
            cdp_port: sandbox::CDP_PORT,
            local_ports: vec![3000],
            max_message: 1 << 20,
            secret: drgnx_ratatoskr::browser::Secret::new().unwrap(),
        }),
    };
    let sb = Sandbox::detect(Tier::Full, helper_at(Path::new(RATATOSKR)), None)
        .unwrap_or_else(|r| panic!("the full tier is not usable here: {r}"));
    let launch = drgnx_ratatoskr::agents::launch::launch_on(&env, &sb, &plan, &shape)
        .unwrap_or_else(|r| panic!("refused: {r}"));
    assert!(launch.browser.is_some(), "the hub's end of the socketpair");
    Launched {
        _dir: dir,
        b,
        launch,
    }
}

/// The processes under PID (its descendants, PID included) whose command line names the stand-in Chromium.
fn chromiums_under(pid: i32) -> Vec<i32> {
    procs_under(pid, "fake-chromium")
}

/// The processes under PID (PID included) whose command line holds NAME ("" for every one), zombies left out.
fn procs_under(pid: i32, name: &str) -> Vec<i32> {
    let mut parent = std::collections::HashMap::new();
    let mut named = Vec::new();
    for e in std::fs::read_dir("/proc").unwrap().flatten() {
        let Some(p) = e.file_name().to_str().and_then(|n| n.parse::<i32>().ok()) else {
            continue;
        };
        let Ok(stat) = std::fs::read_to_string(format!("/proc/{p}/stat")) else {
            continue;
        };
        // the field after the command's closing parenthesis: state, then the parent's pid
        let ppid = stat
            .rsplit_once(')')
            .and_then(|(_, rest)| rest.split_whitespace().nth(1))
            .and_then(|x| x.parse::<i32>().ok())
            .unwrap_or(0);
        parent.insert(p, ppid);
        let zombie = stat
            .rsplit_once(')')
            .and_then(|(_, rest)| rest.split_whitespace().next())
            == Some("Z");
        if !zombie
            && std::fs::read(format!("/proc/{p}/cmdline"))
                .is_ok_and(|c| String::from_utf8_lossy(&c).contains(name))
        {
            named.push(p);
        }
    }
    named
        .into_iter()
        .filter(|&p| {
            let mut cur = p;
            for _ in 0..64 {
                if cur == pid {
                    return true;
                }
                match parent.get(&cur) {
                    Some(&pp) if pp > 0 => cur = pp,
                    _ => return false,
                }
            }
            false
        })
        .collect()
}

/// Until F holds, within WITHIN (a failure guard: it ends as soon as F holds).
fn until(what: &str, within: Duration, f: impl Fn() -> bool) {
    let end = Instant::now() + within;
    while !f() {
        assert!(Instant::now() < end, "{what}: not within {within:?}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Review Focus 1: the hub ends while the session's browser runs. Its end of the socketpair goes with it; the browser
/// host sees EOF, stops Chromium and exits, so no Chromium is left; the agent itself runs on.
#[test]
#[ignore = "needs bwrap, user namespaces and Landlock ABI 9 (the VM)"]
fn a_hub_restart_leaves_no_chromium() {
    let mut l = launch_with_browser("sleep 60");
    let hub_end = l.launch.browser.take().unwrap();
    let status = l.launch.status.take().expect("a status pipe");
    let spec = std::mem::replace(
        &mut l.launch.spec,
        draugr::Spec {
            program: PathBuf::new(),
            args: vec![],
            env: vec![],
            cwd: None,
            stdin_null: true,
            pass_fds: vec![],
            new_session: false,
        },
    );
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let mut child = draugr::spawn_pinned(spec).await.expect("spawn");
        gleipnir::inner::read_status_for(
            status,
            &|| child.stderr_tail(),
            Duration::from_secs(20),
            true,
        )
        .unwrap_or_else(|r| panic!("the sandbox did not start: {r}\n{}", child.stderr_tail()));
        let pid = child.id();
        let mut hub = Hub {
            s: hub_end,
            dec: FrameDecoder::new((1 << 20) + 64),
            backlog: vec![],
        };
        hub.send(KIND_CONTROL, &json!({"op": "start"}).to_string());
        let started = hub.event("started");
        assert!(started["pid"].as_i64().is_some_and(|p| p > 0), "{started}");
        assert!(!chromiums_under(pid).is_empty(), "the stand-in runs");
        // the hub goes: its end of the socketpair closes with it
        drop(hub);
        until("no Chromium left", Duration::from_secs(15), || {
            chromiums_under(pid).is_empty()
        });
        // the agent is not the browser's: it runs on until its session ends
        assert!(
            std::fs::metadata(format!("/proc/{pid}")).is_ok(),
            "the sandbox ended with the browser"
        );
        // SAFETY: the sandbox's own process group, which draugr made.
        unsafe { libc::kill(-pid, libc::SIGKILL) };
        let _ = child.wait().await;
    });
    drop(l);
}

/// No CDP port listens inside the session but the relay's 9222: with the browser started, the netns's TCP listeners
/// are the three relays' (3128 provider, 9222 CDP, 3130 web) and nothing else.
#[test]
#[ignore = "needs bwrap, user namespaces and Landlock ABI 9 (the VM)"]
fn there_is_no_listening_cdp_port_inside() {
    let mut l = launch_with_browser(
        "while [ ! -e go ]; do sleep 0.05; done; cat /proc/net/tcp /proc/net/tcp6 > tcp.tmp; mv tcp.tmp tcp; sleep 60",
    );
    let wt = l.b.join("wt");
    let hub_end = l.launch.browser.take().unwrap();
    let status = l.launch.status.take().expect("a status pipe");
    let spec = std::mem::replace(
        &mut l.launch.spec,
        draugr::Spec {
            program: PathBuf::new(),
            args: vec![],
            env: vec![],
            cwd: None,
            stdin_null: true,
            pass_fds: vec![],
            new_session: false,
        },
    );
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let mut child = draugr::spawn_pinned(spec).await.expect("spawn");
        gleipnir::inner::read_status_for(
            status,
            &|| child.stderr_tail(),
            Duration::from_secs(20),
            true,
        )
        .unwrap_or_else(|r| panic!("the sandbox did not start: {r}\n{}", child.stderr_tail()));
        let mut hub = Hub {
            s: hub_end,
            dec: FrameDecoder::new((1 << 20) + 64),
            backlog: vec![],
        };
        hub.send(KIND_CONTROL, &json!({"op": "start"}).to_string());
        hub.event("started");
        std::fs::write(wt.join("go"), "").unwrap();
        until(
            "the agent's look at its listeners",
            Duration::from_secs(10),
            || wt.join("tcp").exists(),
        );
        let text = std::fs::read_to_string(wt.join("tcp")).unwrap();
        let mut listening: Vec<u16> = text
            .lines()
            .filter_map(|line| {
                let f: Vec<&str> = line.split_whitespace().collect();
                // sl local_address rem_address st …: state 0A is LISTEN
                (f.len() > 3 && f[3] == "0A")
                    .then(|| f[1].rsplit_once(':'))
                    .flatten()
                    .and_then(|(_, port)| u16::from_str_radix(port, 16).ok())
            })
            .collect();
        listening.sort_unstable();
        listening.dedup();
        assert_eq!(listening, [3128, 3130, 9222], "{text}");
        // SAFETY: the sandbox's own process group, which draugr made.
        unsafe { libc::kill(-child.id(), libc::SIGKILL) };
        let _ = child.wait().await;
    });
}

/// The doctor's check, for real: a hub in a fixture environment runs `browser/check` with the stand-in that returns a
/// fixed PNG as the browser. The throwaway session starts under the real sandbox, the hub connects to its own broker,
/// opens the page and takes the screenshot; the result is kept in `<state>/hub/browser-check.json`.
#[test]
#[ignore = "needs bwrap, user namespaces and Landlock ABI 9 (the VM)"]
fn the_check_takes_a_screenshot() {
    use drgnx_ratatoskr::client::Client;
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::Builder::new()
        .prefix("glp-")
        .tempdir_in("/tmp")
        .unwrap();
    let b = std::fs::canonicalize(dir.path()).unwrap();
    for d in ["home", "run", "t"] {
        std::fs::create_dir_all(b.join(d)).unwrap();
    }
    std::fs::set_permissions(b.join("run"), std::fs::Permissions::from_mode(0o700)).unwrap();
    let env = Env::new(
        &[
            ("HOME", b.join("home").to_str().unwrap()),
            ("XDG_RUNTIME_DIR", b.join("run").to_str().unwrap()),
            ("TMPDIR", b.join("t").to_str().unwrap()),
            ("PATH", "/usr/bin:/bin"),
        ],
        rustix::process::geteuid().as_raw(),
    );
    let me = std::process::id();
    let mut hub = std::process::Command::new(RATATOSKR)
        .args(["serve", "--foreground", "--parent-pid", &me.to_string()])
        .env_clear()
        .envs([
            ("HOME", b.join("home")),
            ("XDG_RUNTIME_DIR", b.join("run")),
            ("TMPDIR", b.join("t")),
            ("PATH", PathBuf::from("/usr/bin:/bin")),
            ("RATATOSKR_SUPERVISOR", PathBuf::from("none")),
        ])
        .current_dir(&b)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::fs::File::create(b.join("hub.err")).unwrap())
        .spawn()
        .expect("the hub");
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut c = loop {
        match Client::user(&env, Duration::from_secs(2)) {
            Ok(c) => break c,
            Err(e) if Instant::now() > deadline => panic!(
                "no hub: {e}: {}",
                std::fs::read_to_string(b.join("hub.err")).unwrap_or_default()
            ),
            Err(_) => std::thread::sleep(Duration::from_millis(100)),
        }
    };
    let program = data_dir().join("fake-chromium-png.sh");
    c.call(
        "config/settings",
        json!({"overrides": [{"name": "drgnx-agents-browser-program", "source": "row",
                              "value": program.to_str().unwrap()}]}),
        Duration::from_secs(10),
    )
    .expect("the browser program setting");
    let r = c.call("browser/check", json!({}), Duration::from_secs(60));
    let kept =
        std::fs::read_to_string(runstav::paths::state_dir(&env).join("hub/browser-check.json"));
    drop(c);
    let _ = hub.kill();
    let _ = hub.wait();
    let r = r.unwrap_or_else(|e| {
        panic!(
            "browser/check: {e}: {}",
            std::fs::read_to_string(b.join("hub.err")).unwrap_or_default()
        )
    });
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["screenshot_bytes"], 70, "{r}");
    assert_eq!(r["sys_missed"], false, "{r}");
    assert!(r["start_ms"].as_u64().is_some_and(|ms| ms > 0), "{r}");
    assert_eq!(
        serde_json::from_str::<Value>(&kept.expect("the result is kept")).unwrap(),
        r
    );
}

/// L's launch spawned, its status read (it must say the browser host is ready), the host's end in a `Hub` and the
/// browser started.
async fn spawn_and_start(l: &mut Launched) -> (draugr::Child, Hub) {
    let hub_end = l.launch.browser.take().unwrap();
    let status = l.launch.status.take().expect("a status pipe");
    let spec = std::mem::replace(
        &mut l.launch.spec,
        draugr::Spec {
            program: PathBuf::new(),
            args: vec![],
            env: vec![],
            cwd: None,
            stdin_null: true,
            pass_fds: vec![],
            new_session: false,
        },
    );
    let child = draugr::spawn_pinned(spec).await.expect("spawn");
    gleipnir::inner::read_status_for(
        status,
        &|| child.stderr_tail(),
        Duration::from_secs(20),
        true,
    )
    .unwrap_or_else(|r| panic!("the sandbox did not start: {r}\n{}", child.stderr_tail()));
    let mut hub = Hub {
        s: hub_end,
        dec: FrameDecoder::new((1 << 20) + 64),
        backlog: vec![],
    };
    hub.send(KIND_CONTROL, &json!({"op": "start"}).to_string());
    let started = hub.event("started");
    assert!(started["pid"].as_i64().is_some_and(|p| p > 0), "{started}");
    (child, hub)
}

/// The agent's dev server on a local port (3000), started inside the sandbox (`gleipnir-probe serve-http`), is what
/// the agent's browser reaches: `Page.navigate` to `http://127.0.0.1:3000/` goes straight to it on the session's own
/// loopback, through the browser layer's local ports, and the page's body comes back over CDP.
#[test]
#[ignore = "needs bwrap, user namespaces, Landlock ABI 9 and gleipnir-probe next to ratatoskr (the VM)"]
fn a_browser_session_starts_and_reaches_its_dev_server() {
    let mut l = launch_with(
        "../bin/gleipnir-probe serve-http 3000 1 dev-ok > served.tmp; mv served.tmp served; sleep 60",
        true,
    );
    let wt = l.b.join("wt");
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let (mut child, mut hub) = spawn_and_start(&mut l).await;
        let nav = tokio::task::spawn_blocking(move || {
            hub.send(
                KIND_CDP,
                r#"{"id":7,"method":"Page.navigate","params":{"url":"http://127.0.0.1:3000/app"}}"#,
            );
            let reply = hub.wait("the navigation", Duration::from_secs(20), |f| {
                f.kind == KIND_CDP
                    && serde_json::from_slice::<Value>(&f.payload).is_ok_and(|v| v["id"] == 7)
            });
            serde_json::from_slice::<Value>(&reply.payload).unwrap()
        })
        .await;
        let reply = nav.unwrap_or_else(|e| panic!("{e}\n{}", child.stderr_tail()));
        assert_eq!(reply["result"]["status"], 200, "{reply}");
        assert_eq!(reply["result"]["body"], "dev-ok", "{reply}");
        // the dev server says it served that one request
        until("the dev server's report", Duration::from_secs(10), || {
            wt.join("served").exists()
        });
        let served = std::fs::read_to_string(wt.join("served")).unwrap();
        assert!(
            served.contains("\"result\":\"reached\"") && served.contains("served 1"),
            "{served}"
        );
        // SAFETY: the sandbox's own process group, which draugr made.
        unsafe { libc::kill(-child.id(), libc::SIGKILL) };
        let _ = child.wait().await;
    });
}

/// The session ends (its agent exits) while its browser runs: nothing of it is left. No process of the sandbox runs
/// (the agent, its relays, the browser host, Chromium), no stand-in Chromium runs anywhere, and the hub's end of the
/// socketpair reads EOF. (The session dir and the scratch dir are the hub's: a session can be resumed, so they stay
/// until it is closed.)
#[test]
#[ignore = "needs bwrap, user namespaces and Landlock ABI 9 (the VM)"]
fn everything_is_gone_after_the_session() {
    let mut l = launch_with_browser("while [ ! -e go ]; do sleep 0.05; done; exit 0");
    let wt = l.b.join("wt");
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let (mut child, hub) = spawn_and_start(&mut l).await;
        let pid = child.id();
        assert!(!chromiums_under(pid).is_empty(), "the stand-in runs");
        let ran = procs_under(pid, "");
        assert!(
            ran.len() >= 3,
            "the sandbox, the browser host, Chromium: {ran:?}"
        );
        // the agent ends: so does its session
        std::fs::write(wt.join("go"), "").unwrap();
        let status = tokio::time::timeout(Duration::from_secs(20), child.wait())
            .await
            .unwrap_or_else(|_| {
                panic!("the agent's exit ended no sandbox\n{}", child.stderr_tail())
            });
        assert!(status.is_ok(), "{status:?}");
        until(
            "no process of the session left",
            Duration::from_secs(10),
            || {
                ran.iter().all(
                    |p| match std::fs::read_to_string(format!("/proc/{p}/stat")) {
                        Err(_) => true,
                        Ok(s) => {
                            s.rsplit_once(')')
                                .and_then(|(_, rest)| rest.split_whitespace().next())
                                == Some("Z")
                        }
                    },
                )
            },
        );
        assert!(chromiums_under(1).is_empty(), "a stand-in Chromium is left");
        let mut s = hub.s;
        s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut b = [0u8; 4096];
        loop {
            match s.read(&mut b) {
                Ok(0) => break,
                Ok(_) => continue,
                Err(e) => panic!("the hub's end did not read EOF: {e}"),
            }
        }
    });
}
