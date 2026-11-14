//! The wizard's backend: TEI (a podman Quadlet) and Ollama start only on a confirmed request (`search/server-*`).
//!
//! test-pattern: pure (D) for the plan, the unit file and the commands: the tools (`podman`, `systemctl`, `ollama`,
//! `launchctl`, `nvidia-ctk`) are recording stubs that answer at once, and the host (container, systemd session, CDI,
//! PATH) is a value the test builds; no clock, no process. `hub_never_calls_start` is a handshake (C): the hub's own
//! runner records the commands it was asked to run (test-hooks: it runs none) and the test acts when the hub answers.

mod support;

use drgnx_ratatoskr::search::servers::{self, Host, Refused, Run};
use runstav::methods::search::ServerKind;
use std::cell::RefCell;
use std::path::PathBuf;

/// Records every command; fails the ones named in FAIL.
#[derive(Default)]
struct Rec {
    calls: RefCell<Vec<String>>,
    fail: Vec<&'static str>,
}

impl Run for Rec {
    fn run(&self, prog: &str, args: &[String]) -> Result<(), String> {
        let line = std::iter::once(prog)
            .chain(args.iter().map(String::as_str))
            .collect::<Vec<_>>()
            .join(" ");
        self.calls.borrow_mut().push(line.clone());
        if self.fail.iter().any(|f| line.starts_with(f)) {
            return Err(format!("{line} failed"));
        }
        Ok(())
    }
}

/// A Linux host with everything TEI needs, config under DIR.
fn linux(dir: &std::path::Path) -> Host {
    Host {
        config_home: dir.to_path_buf(),
        macos: false,
        uid: 1000,
        in_container: false,
        systemd_user: true,
        podman: true,
        cdi_nvidia: false,
        gpu_compute: None,
        ollama: None,
        ollama_running: false,
    }
}

/// Pattern D. The plan shows what would run, and runs and writes nothing.
#[test]
fn plan_lists_commands_without_running_any() {
    let dir = tempfile::tempdir().unwrap();
    let host = linux(dir.path());
    let plan = servers::plan(&host, ServerKind::Tei);
    assert!(plan.available, "{:?}", plan.why);
    assert_eq!(
        plan.commands,
        [
            "systemctl --user daemon-reload",
            "systemctl --user start drgnx-tei.service"
        ]
    );
    assert_eq!(plan.model, "Qwen/Qwen3-Embedding-0.6B");
    assert_eq!(plan.memory_cap, "4g");
    assert!(!plan.gpu);
    let unit = dir.path().join("containers/systemd/drgnx-tei.container");
    assert_eq!(plan.unit_path.as_deref(), unit.to_str());
    assert!(!unit.exists(), "a plan writes nothing");
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
}

/// Pattern D. Without `confirm` nothing is written and nothing runs.
#[test]
fn start_refused_without_confirm() {
    let dir = tempfile::tempdir().unwrap();
    let host = linux(dir.path());
    let rec = Rec::default();
    let r = servers::start(&host, &rec, ServerKind::Tei, false);
    assert!(matches!(r, Err(Refused::Confirm)), "{r:?}");
    assert!(rec.calls.borrow().is_empty());
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
}

/// Pattern D. The unit caps the container's memory and publishes on loopback only; the reload comes before the start.
#[test]
fn tei_unit_has_memory_cap_and_loopback() {
    let dir = tempfile::tempdir().unwrap();
    let host = linux(dir.path());
    let rec = Rec::default();
    servers::start(&host, &rec, ServerKind::Tei, true).unwrap();
    let unit =
        std::fs::read_to_string(dir.path().join("containers/systemd/drgnx-tei.container")).unwrap();
    assert!(unit.contains("PodmanArgs=--memory=4g"), "{unit}");
    assert!(unit.contains("PublishPort=127.0.0.1:8087:80"), "{unit}");
    assert!(
        unit.lines()
            .filter(|l| l.starts_with("PublishPort="))
            .all(|l| l.starts_with("PublishPort=127.0.0.1:")),
        "{unit}"
    );
    assert!(unit.contains("Volume=drgnx-tei-cache:/data"), "{unit}");
    assert!(unit.contains("Qwen/Qwen3-Embedding-0.6B"), "{unit}");
    assert!(
        unit.contains("Image=ghcr.io/huggingface/text-embeddings-inference:cpu-1.9"),
        "{unit}"
    );
    assert!(
        !unit.contains("[Install]"),
        "it must not start at login: {unit}"
    );
    assert_eq!(
        *rec.calls.borrow(),
        [
            "systemctl --user daemon-reload",
            "systemctl --user start drgnx-tei.service"
        ]
    );
}

/// Pattern D. With the NVIDIA CDI device present the image is the card's tag, the device is passed and the host-side
/// cap is 2 GiB.
#[test]
fn gpu_tag_when_cdi_present() {
    let dir = tempfile::tempdir().unwrap();
    let mut host = linux(dir.path());
    host.cdi_nvidia = true;
    host.gpu_compute = Some("8.6".into());
    let plan = servers::plan(&host, ServerKind::Tei);
    assert!(plan.gpu);
    assert_eq!(plan.memory_cap, "2g");
    assert_eq!(
        plan.image.as_deref(),
        Some("ghcr.io/huggingface/text-embeddings-inference:86-1.9")
    );
    let rec = Rec::default();
    servers::start(&host, &rec, ServerKind::Tei, true).unwrap();
    let unit =
        std::fs::read_to_string(dir.path().join("containers/systemd/drgnx-tei.container")).unwrap();
    assert!(unit.contains("AddDevice=nvidia.com/gpu=all"), "{unit}");
    assert!(unit.contains("PodmanArgs=--memory=2g"), "{unit}");
    // a card with no matching tag stays on the CPU image
    host.gpu_compute = Some("5.2".into());
    let plan = servers::plan(&host, ServerKind::Tei);
    assert!(!plan.gpu);
    assert!(plan.image.unwrap().ends_with(":cpu-1.9"));
}

/// Pattern D. Inside a container, or with no systemd user session, or no podman, TEI is unavailable and says why.
#[test]
fn no_systemd_session_unavailable_with_reason() {
    let dir = tempfile::tempdir().unwrap();
    let mut host = linux(dir.path());
    host.systemd_user = false;
    let plan = servers::plan(&host, ServerKind::Tei);
    assert!(!plan.available);
    assert!(plan.why.as_deref().unwrap().contains("systemd"), "{plan:?}");
    let rec = Rec::default();
    let r = servers::start(&host, &rec, ServerKind::Tei, true);
    assert!(matches!(r, Err(Refused::Unavailable(_))), "{r:?}");
    assert!(rec.calls.borrow().is_empty());

    host.systemd_user = true;
    host.in_container = true;
    let plan = servers::plan(&host, ServerKind::Tei);
    assert!(!plan.available);
    assert!(
        plan.why.as_deref().unwrap().contains("container"),
        "{plan:?}"
    );

    host.in_container = false;
    host.podman = false;
    let plan = servers::plan(&host, ServerKind::Tei);
    assert!(!plan.available);
    assert!(plan.why.as_deref().unwrap().contains("podman"), "{plan:?}");

    host.podman = true;
    host.macos = true;
    let plan = servers::plan(&host, ServerKind::Tei);
    assert!(!plan.available, "TEI is Linux only");
}

/// Pattern D. Without `ollama` on the PATH it is not offered, and a start is refused.
#[test]
fn ollama_absent_not_offered() {
    let dir = tempfile::tempdir().unwrap();
    let host = linux(dir.path());
    let plan = servers::plan(&host, ServerKind::Ollama);
    assert!(!plan.available);
    assert!(plan.why.as_deref().unwrap().contains("ollama"), "{plan:?}");
    assert!(plan.commands.is_empty());
    let rec = Rec::default();
    let r = servers::start(&host, &rec, ServerKind::Ollama, true);
    assert!(matches!(r, Err(Refused::Unavailable(_))), "{r:?}");
    assert!(rec.calls.borrow().is_empty());
}

/// Pattern D. A start answers the entry for the settings' provider table; Ollama's own service starts only when it is
/// not running.
#[test]
fn start_answers_the_provider_entry() {
    let dir = tempfile::tempdir().unwrap();
    let host = linux(dir.path());
    let rec = Rec::default();
    let a = servers::start(&host, &rec, ServerKind::Tei, true).unwrap();
    assert!(a.started);
    assert_eq!(a.unit, "drgnx-tei.service");
    assert_eq!(a.provider.id, "tei");
    assert_eq!(a.provider.kind, "tei");
    assert_eq!(a.provider.base, "http://127.0.0.1:8087");
    assert_eq!(a.provider.auth, "none");
    assert_eq!(a.provider.caps, ["embed"]);

    let mut host = linux(dir.path());
    host.ollama = Some(PathBuf::from("/usr/bin/ollama"));
    let rec = Rec::default();
    let a = servers::start(&host, &rec, ServerKind::Ollama, true).unwrap();
    assert_eq!(a.provider.kind, "ollama");
    assert_eq!(a.provider.base, "http://127.0.0.1:11434");
    assert_eq!(a.provider.caps, ["embed"]);
    assert_eq!(
        *rec.calls.borrow(),
        [
            "systemctl --user start ollama.service",
            "/usr/bin/ollama pull qwen3-embedding:0.6b"
        ]
    );

    host.ollama_running = true;
    let rec = Rec::default();
    servers::start(&host, &rec, ServerKind::Ollama, true).unwrap();
    assert_eq!(
        *rec.calls.borrow(),
        ["/usr/bin/ollama pull qwen3-embedding:0.6b"]
    );

    host.macos = true;
    host.ollama_running = false;
    let rec = Rec::default();
    servers::start(&host, &rec, ServerKind::Ollama, true).unwrap();
    assert_eq!(
        *rec.calls.borrow(),
        [
            "launchctl start com.ollama.ollama",
            "/usr/bin/ollama pull qwen3-embedding:0.6b"
        ]
    );
}

/// Pattern D. A failing command is an error naming it, and a stop runs the matching stop.
#[test]
fn failed_command_and_stop() {
    let dir = tempfile::tempdir().unwrap();
    let host = linux(dir.path());
    let rec = Rec {
        fail: vec!["systemctl --user start"],
        ..Rec::default()
    };
    let r = servers::start(&host, &rec, ServerKind::Tei, true);
    assert!(
        matches!(r, Err(Refused::Failed(ref m)) if m.contains("start")),
        "{r:?}"
    );

    let rec = Rec::default();
    assert!(servers::stop(&host, &rec, ServerKind::Tei).unwrap());
    assert_eq!(
        *rec.calls.borrow(),
        ["systemctl --user stop drgnx-tei.service"]
    );
}

/// Pattern C. The hub's idle paths (the other `search/*` methods, a project's tiers) never reach a start; the hub's
/// runner records what it is asked to run (test-hooks: it runs nothing), so the record is the call counter. A start
/// without `confirm` is refused before the runner.
#[cfg(feature = "test-hooks")]
#[test]
fn hub_never_calls_start() {
    use serde_json::json;
    use support::{Client, Hub, Root};
    let root = Root::new();
    let mut hub = Hub::start(&root, 1);
    let socket = root.socket();
    hub.wait_ready(&socket);
    let mut c = Client::open(&socket);
    c.hello(&socket);
    let proj = root.dir.path().join("h/proj");
    std::fs::create_dir_all(&proj).unwrap();
    std::fs::write(proj.join("a.el"), "(defun a-b () 1)\n").unwrap();
    for args in [
        &["init", "-q"][..],
        &["add", "-A"],
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@example.invalid",
            "commit",
            "-q",
            "-m",
            "one",
        ],
    ] {
        let st = std::process::Command::new("git")
            .arg("-C")
            .arg(&proj)
            .args(args)
            .status()
            .unwrap();
        assert!(st.success(), "git {args:?}");
    }
    let ok = |c: &mut Client, id: u64, m: &str, p: serde_json::Value| {
        c.send(json!({"id": id, "method": m, "params": p}));
        c.answer(id).0
    };
    for (i, (m, p)) in [
        ("search/embedders", json!({})),
        ("search/typing", json!({})),
        ("search/index", json!({"root": proj, "now": true})),
        ("search/status", json!({"root": proj})),
        ("search/query", json!({"root": proj, "text": "a-b"})),
        ("search/server-plan", json!({"kind": "tei"})),
    ]
    .into_iter()
    .enumerate()
    {
        let a = ok(&mut c, i as u64 + 1, m, p);
        assert!(a.get("error").is_none(), "{m}: {a}");
    }
    let a = ok(
        &mut c,
        20,
        "search/server-start",
        json!({"kind": "tei", "confirm": false}),
    );
    assert!(a.get("error").is_some(), "start without confirm: {a}");
    let log = root.dir.path().join("s/drgnx/servers-test.log");
    assert!(
        !log.exists(),
        "the hub ran or planned a command: {:?}",
        std::fs::read_to_string(&log)
    );
}
