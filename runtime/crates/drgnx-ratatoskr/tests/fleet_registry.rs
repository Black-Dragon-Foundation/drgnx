//! The runner registry's rows over real SSH to a fake runner (`#[ignore = "fleet"]`, test/runners/): a host becomes a
//! runner (probe, contract, bundle, image, bench, link), the refusals, and a removal that leaves nothing of ours. They
//! run in a fleet's harness only:
//!
//! ```text
//! cargo test -p drgnx-ratatoskr --features fleet --test fleet_registry --no-run
//! cargo build -p sleipnir --features test-hooks        # the bundle each row copies (fleet.sh test shares it)
//! fleet.sh up --runners 1
//! DRGNX_FLEET_TEST_BIN=<the test binary> fleet.sh test --test-threads=1
//! ```
//!
//! Every row is [C]: a real `sleipnir serve` over the user's real ssh, and the rows wait with `skuld::wait_until_async`
//! on the state the hub announces (the queue's runner row), never on time.
#![cfg(target_os = "linux")]

use drgnx_ratatoskr::runners::link::LinkEvent;
use drgnx_ratatoskr::runners::local::{Admission, LocalRunner};
use drgnx_ratatoskr::runners::queue::{Queue, QueueCfg};
use drgnx_ratatoskr::runners::registry::{Cfg, MemStore, RegError, Registry, Store};
use drgnx_ratatoskr::runners::transport::OpensshTransport;
use runstav::methods::runners::AddParams;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use tokio::sync::mpsc::UnboundedReceiver;

/// How long a row waits on any one announced state before it fails.
const WAIT: u64 = 180;

fn ssh_config() -> String {
    format!("{}/.ssh/config", std::env::var("HOME").unwrap())
}

/// SCRIPT's stdout on RUNNER; panics when it fails.
fn sh(runner: &str, script: &str) -> String {
    let out = Command::new("ssh")
        .args(["-F", &ssh_config(), "-o", "BatchMode=yes", runner])
        .arg(script)
        .output()
        .expect("ssh");
    assert!(
        out.status.success(),
        "{runner}: {script}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// Whether SCRIPT succeeds on RUNNER.
fn ok(runner: &str, script: &str) -> bool {
    Command::new("ssh")
        .args(["-F", &ssh_config(), "-o", "BatchMode=yes", runner])
        .arg(script)
        .status()
        .expect("ssh")
        .success()
}

/// The fake runner's base image, by digest.
fn image(runner: &str) -> String {
    let d = sh(
        runner,
        "podman image inspect registry.fedoraproject.org/fedora:45 --format '{{.Digest}}'",
    );
    format!("registry.fedoraproject.org/fedora@{d}")
}

struct Hub {
    reg: Registry,
    queue: Arc<Queue>,
    events: UnboundedReceiver<LinkEvent>,
    store: Arc<MemStore>,
    _dir: tempfile::TempDir,
}

/// A registry over the real transport, a queue and records in memory; its bundle folder holds the shared `sleipnir`
/// (a `test-hooks` build) for this machine's architecture. HUB_BOOT is the boot id the hub says is its machine's.
fn hub(hub_boot: &str, images: Vec<String>) -> Hub {
    let share =
        std::env::var("DRGNX_FLEET_SHARE").expect("DRGNX_FLEET_SHARE: run through fleet.sh test");
    let dir = tempfile::tempdir().unwrap();
    let bundles: PathBuf = dir.path().join("bundles").join(std::env::consts::ARCH);
    std::fs::create_dir_all(&bundles).unwrap();
    std::fs::copy(Path::new(&share).join("sleipnir"), bundles.join("sleipnir"))
        .expect("fleet.sh test puts sleipnir in the share");
    let (queue, events) = Queue::new(QueueCfg {
        hub_id: "hub".into(),
        exec_root: dir.path().to_path_buf(),
        local: LocalRunner::new(Admission::Fixed(1), dir.path()),
        db: None,
    });
    let run = dir.path().join("run");
    std::fs::create_dir_all(&run).unwrap();
    let store = Arc::new(MemStore::default());
    let reg = Registry::new(Cfg {
        transport: Arc::new(OpensshTransport::new(&run)),
        store: store.clone(),
        queue: queue.clone(),
        hub_id: "hub".into(),
        hub_boot_id: hub_boot.into(),
        runtime_dir: run,
        bundles: dir.path().join("bundles"),
        images: Arc::new(move || images.clone()),
    });
    Hub {
        reg,
        queue,
        events,
        store,
        _dir: dir,
    }
}

fn now() -> u64 {
    skuld::host_now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

/// `runners/add`'s params for RUNNER's host, its folder ROOT.
fn add_params(name: &str, root: &str) -> AddParams {
    serde_json::from_value(json!({"host": "r1", "trust": "mine", "name": name, "root": root}))
        .unwrap()
}

/// The runner's home folder.
fn home() -> String {
    sh("r1", "echo $HOME")
}

mod registry {
    use super::*;

    /// [C] `add` takes a host through probe and the contract, copies the bundle for its architecture, pulls the image by
    /// digest, benches it, records it and links it: the queue's row says `ready` once its `hello-ok` came. (Warming the
    /// caches needs a project's jobs, which come with the hub's sync.)
    #[tokio::test]
    #[ignore = "fleet"]
    async fn add_completes_probe_copy_pull_bench() {
        let img = image("r1");
        let root = format!("{}/reg-add", home());
        let mut h = hub("not-this-machine", vec![img.clone()]);
        let added = h.reg.add(add_params("rone", &root)).await.expect("add");
        assert_eq!(added.name, "rone");
        assert_eq!(added.arch, std::env::consts::ARCH);
        assert!(added.cores > 0 && added.mem_mib > 0, "{added:?}");
        assert!(added.linger, "the fake runner's user lingers: {added:?}");
        assert!(added.speed.is_some_and(|s| s > 0.0), "benched: {added:?}");
        // the bundle is on the runner, in a folder named by its hash, and the image is there
        assert!(ok("r1", &format!("test -x {root}/bin/*/sleipnir")));
        assert!(ok("r1", &format!("podman image exists {img}")));
        // and tagged under the runner's prefix, so a `podman image prune` (an image pulled by digest alone is
        // dangling) never takes it from under the runner
        let digest = img.rsplit("@sha256:").next().unwrap();
        let tag = format!("localhost/drgnx-runner:{}", &digest[..12]);
        assert!(
            ok("r1", &format!("podman image exists {tag}")),
            "{tag} is not among r1's images:\n{}",
            sh(
                "r1",
                "podman images --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Digest}}'"
            )
        );
        assert_eq!(
            sh(
                "r1",
                &format!("podman image inspect --format '{{{{.Digest}}}}' {tag}")
            ),
            format!("sha256:{digest}")
        );
        assert_eq!(h.store.list().await.unwrap().len(), 1);
        // linked: the queue's row is `ready` once hello-ok has been taken in
        let q = h.queue.clone();
        let events = &mut h.events;
        skuld::wait_until_async("the runner ready in the queue", WAIT, || {
            while let Ok(ev) = events.try_recv() {
                q.on_link(ev, now());
            }
            std::future::ready(q.runner("rone").filter(|r| r.state == "ready"))
        })
        .await;
        h.reg.remove("rone").await.expect("remove");
        // `remove` takes our tag back; the image stays while another tag (here the fleet's base) holds it
        assert!(
            !ok("r1", &format!("podman image exists {tag}")),
            "our tag is gone"
        );
        assert!(ok("r1", &format!("podman image exists {img}")));
    }

    /// [C] A host that lacks something of the contract is refused with every missing item and its fix, and nothing is
    /// recorded or linked. The fake runner's podman is put on the cgroupfs manager (its user's own containers.conf),
    /// so it can't cap a container.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn add_refuses_a_host_missing_the_contract_with_the_list() {
        let conf = "~/.config/containers/containers.conf";
        sh(
            "r1",
            &format!(
                "mkdir -p ~/.config/containers && printf '[engine]\\ncgroup_manager = \"cgroupfs\"\\n' > {conf}"
            ),
        );
        let root = format!("{}/reg-refuse", home());
        let h = hub("not-this-machine", vec![]);
        let refused = h.reg.add(add_params("rone", &root)).await;
        sh("r1", &format!("rm -f {conf}"));
        let Err(RegError::Refused(text)) = refused else {
            panic!("expected a refusal, got {refused:?}");
        };
        assert!(text.contains("runner contract"), "{text}");
        assert!(text.contains("cgroup"), "the missing item: {text}");
        assert!(text.contains("fix:"), "its fix: {text}");
        assert!(h.store.list().await.unwrap().is_empty());
        assert!(!h.queue.has_runner("rone"));
    }

    /// [C] Adding the hub's own machine (its boot id is the runner's) is refused, and nothing is recorded or linked.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn add_refuses_the_hubs_own_machine() {
        let boot = sh("r1", "cat /proc/sys/kernel/random/boot_id");
        let root = format!("{}/reg-own", home());
        let h = hub(&boot, vec![]);
        let refused = h.reg.add(add_params("rone", &root)).await;
        let Err(RegError::Refused(text)) = refused else {
            panic!("expected a refusal, got {refused:?}");
        };
        assert_eq!(
            text,
            "this is the hub's own machine; it already runs jobs as `local`"
        );
        assert!(h.store.list().await.unwrap().is_empty());
        assert!(!h.queue.has_runner("rone"));
    }

    /// [C] `remove` stops our units and containers on the runner and deletes its folder; a container that isn't ours
    /// stays.
    #[tokio::test]
    #[ignore = "fleet"]
    async fn remove_leaves_nothing_of_ours() {
        let img = image("r1");
        let root = format!("{}/reg-remove", home());
        let h = hub("not-this-machine", vec![]);
        h.reg.add(add_params("rone", &root)).await.expect("add");
        // something of ours (our prefix, our label, our unit) is running, and something that isn't
        sh(
            "r1",
            &format!(
                "podman run -d --pull=never --name drgnx-leftover --label drgnx.runner=hub {img} sleep 600 >/dev/null 2>&1 </dev/null; \
                 podman run -d --pull=never --name keep-other {img} sleep 600 >/dev/null 2>&1 </dev/null; \
                 systemd-run --user --quiet --unit drgnx-leftover-unit sleep 600 >/dev/null 2>&1 </dev/null"
            ),
        );
        assert!(ok(
            "r1",
            "systemctl --user is-active --quiet drgnx-leftover-unit"
        ));
        h.reg.remove("rone").await.expect("remove");
        assert!(!ok("r1", &format!("test -e {root}")), "the folder is gone");
        assert_eq!(
            sh(
                "r1",
                "podman ps -a --filter label=drgnx.runner=hub --format '{{.Names}}'"
            ),
            ""
        );
        assert_eq!(
            sh(
                "r1",
                "systemctl --user list-units --all --plain --no-legend 'drgnx-leftover*'"
            ),
            ""
        );
        assert_eq!(
            sh(
                "r1",
                "podman ps -a --filter name=keep-other --format '{{.Names}}'"
            ),
            "keep-other",
            "what isn't ours stays"
        );
        assert!(h.store.list().await.unwrap().is_empty());
        assert!(!h.queue.has_runner("rone"));
        sh("r1", "podman rm -f keep-other >/dev/null");
    }
}
