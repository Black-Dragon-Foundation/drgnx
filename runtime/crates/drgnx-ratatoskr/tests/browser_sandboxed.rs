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
