//! Fleet rows for `sleipnir serve`: the hub's side, over real SSH to a real `serve` in a fake runner (`test/runners/`).
//! They run in the fleet's harness, never on a developer's machine:
//!
//! ```text
//! cargo test -p sleipnir --features test-hooks --test fleet_serve --no-run
//! fleet.sh up --runners 2 --no-linger-on 2
//! DRGNX_FLEET_TEST_BIN=<the test binary> fleet.sh test --test-threads=1 serve::
//! ```
//!
//! `fleet.sh test` copies the `sleipnir` binary into the fleet's share; each row installs it into its own runner
//! root as a bundle and runs `serve` from there. Runner 1 lingers, runner 2 doesn't. Every row is [C]: a real child
//! (`serve`, and the jobs it starts) announces its state in frames or files, and the test waits on that state; a job
//! that must stay running parks on a FIFO in its container until the test writes to it.
#![cfg(target_os = "linux")]

use forseti::{Expect, JobSpec, JobTrust, Kind, Lane, Priority, Range, Weight};
use sleipnir::proto::{AttemptInfo, AttemptState, Frame, FrameReader, FrameWriter, JobRef, Nonce};
use std::collections::BTreeMap;
use std::io::BufReader;
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};

/// The bundle name of the binary under test.
const BUNDLE: &str = "test";
/// How long a row waits on any one announced state before it fails.
const WAIT: u64 = 120;

fn ssh_config() -> String {
    format!("{}/.ssh/config", std::env::var("HOME").unwrap())
}

fn ssh(runner: &str) -> Command {
    let mut c = Command::new("ssh");
    c.args(["-F", &ssh_config(), "-o", "BatchMode=yes", runner]);
    c
}

/// Runs SCRIPT on RUNNER as `runner`; its stdout, and whether it succeeded.
fn sh_status(runner: &str, script: &str) -> (bool, Vec<u8>) {
    let out = ssh(runner).arg(script).output().expect("ssh");
    if !out.status.success() {
        eprintln!(
            "{runner}: {script}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    (out.status.success(), out.stdout)
}

/// Runs SCRIPT on RUNNER; its stdout, trimmed. Panics when it fails.
fn sh(runner: &str, script: &str) -> String {
    let (ok, out) = sh_status(runner, script);
    assert!(ok, "{runner}: {script}");
    String::from_utf8_lossy(&out).trim().to_string()
}

/// The machine `serve` admits on in these rows: a fake runner's `/proc/pressure`, `/proc/meminfo` and disk are its
/// host's, so a busy or nearly full host would refuse a row's offer. The test build reads these figures instead
/// (`probe::TEST_MACHINE`), under the profile's limits as they are.
const QUIET_MACHINE: &str = r#"{"psi": {"mem_some10": 0.0, "cpu_some10": 0.0, "io_full10": 0.0, "app_mem_some10": null},
"disk_free_gb": 100, "disk_total_gb": 200, "mem_available_mib": 8192}"#;

/// A fresh runner root at ~/NAME on RUNNER with the binary under test installed as each of BUNDLES, and the quiet
/// machine's figures; its path.
fn root(runner: &str, name: &str, bundles: &[&str]) -> String {
    let share =
        std::env::var("DRGNX_FLEET_SHARE").expect("DRGNX_FLEET_SHARE: run through fleet.sh test");
    assert!(
        PathBuf::from(&share).join("sleipnir").exists(),
        "fleet.sh test puts sleipnir in the share"
    );
    let home = sh(runner, "echo $HOME");
    let root = format!("{home}/{name}");
    let mut script = format!("rm -rf {root} && mkdir -p {root}/bin");
    for b in bundles {
        script += &format!(
            " && mkdir {root}/bin/{b} && cp /fleet/share/sleipnir {root}/bin/{b}/sleipnir"
        );
    }
    script += &format!(" && printf %s '{QUIET_MACHINE}' > {root}/test-machine.json");
    sh(runner, &script);
    root
}

/// The fake runner's base image, by digest, as an allow-list holds it.
fn image(runner: &str) -> String {
    let d = sh(
        runner,
        "podman image inspect registry.fedoraproject.org/fedora:45 --format '{{.Digest}}'",
    );
    format!("registry.fedoraproject.org/fedora@{d}")
}

fn jr(job: &str, n: u8) -> JobRef {
    JobRef {
        job: job.into(),
        attempt: 1,
        nonce: Nonce([n; 16]),
    }
}

fn spec(script: &str) -> JobSpec {
    JobSpec {
        os: Default::default(),
        name: "fleet".into(),
        kind: Kind::Test,
        weight: Weight::Light,
        suite: None,
        tree: PathBuf::from("/src/p"),
        cwd: PathBuf::from("."),
        command: vec!["sh".into(), "-c".into(), script.into()],
        select: None,
        needs: vec![],
        inputs_extra: vec![],
        inputs_outside: vec![],
        features: vec![],
        cores: Range { min: 1, max: 1 },
        mem_mib: Range { min: 64, max: 256 },
        disk_gib: 0,
        timeout_s: 600,
        restartable: true,
        writes_tree: false,
        priority: None,
        for_user: None,
        gate: None,
        expect: Expect::default(),
        outputs: vec![],
        state: vec![],
        on: None,
        lane: Lane::Work,
        fresh: false,
        stop_on_red: false,
        project: "p".into(),
        trust: JobTrust::Private,
        keys: vec![],
        local_only: false,
        writes: vec![],
    }
}

/// A job that prints `started`, parks until the test writes to its FIFO ([`release`]), prints `released` and ends.
const PARKED: &str = "echo started; mkfifo /tmp/gate; read x < /tmp/gate; echo released";

/// Lets job ID's parked container (prefix PREFIX) go on.
fn release(runner: &str, prefix: &str, id: &str) {
    sh(
        runner,
        &format!("podman exec {prefix}-{id} sh -c 'echo go > /tmp/gate'"),
    );
}

/// One control channel: `ssh RUNNER <root>/bin/<bundle>/sleipnir serve …`, its frames read on a thread.
struct Link {
    child: Child,
    w: Arc<Mutex<Option<FrameWriter<ChildStdin>>>>,
    rx: Receiver<Frame>,
    /// Every log byte received, per job, by offset.
    logs: BTreeMap<String, Vec<(u64, Vec<u8>)>>,
    hub: String,
}

impl Link {
    fn open(runner: &str, root: &str, bundle: &str, hub: &str, prefix: &str) -> Link {
        let mut child = ssh(runner)
            .arg(format!(
                "{root}/bin/{bundle}/sleipnir serve --root {root} --prefix {prefix} --hub-id {hub} --profile dedicated"
            ))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .expect("ssh");
        let out = child.stdout.take().unwrap();
        let w = Arc::new(Mutex::new(Some(FrameWriter::new(
            child.stdin.take().unwrap(),
        ))));
        let (tx, rx) = mpsc::channel();
        let pong = w.clone();
        std::thread::spawn(move || {
            let mut r = FrameReader::new(BufReader::new(out));
            while let Ok(Some(f)) = r.read() {
                // the hub answers the runner's ping, as the link does, so an idle row's link stays up
                if let Frame::Ping { at } = f
                    && let Some(w) = pong.lock().unwrap().as_mut()
                {
                    let _ = w.write(&Frame::Pong { at });
                }
                if tx.send(f).is_err() {
                    break;
                }
            }
        });
        Link {
            child,
            w,
            rx,
            logs: BTreeMap::new(),
            hub: hub.into(),
        }
    }

    fn send(&mut self, f: &Frame) {
        self.w
            .lock()
            .unwrap()
            .as_mut()
            .expect("the channel is open")
            .write(f)
            .unwrap();
    }

    /// The first frame PICK takes, within the wait; the log bytes of every frame before it are kept. A channel that
    /// ends first fails the row at once.
    fn next<T>(&mut self, what: &str, mut pick: impl FnMut(&Frame) -> Option<T>) -> T {
        let (rx, logs) = (&self.rx, &mut self.logs);
        skuld::wait_until(what, WAIT, || {
            loop {
                let f = match rx.try_recv() {
                    Ok(f) => f,
                    Err(mpsc::TryRecvError::Empty) => return None,
                    Err(mpsc::TryRecvError::Disconnected) => {
                        panic!("the channel ended while waiting for {what}")
                    }
                };
                keep_log(logs, &f);
                if let Some(v) = pick(&f) {
                    return Some(v);
                }
            }
        })
    }

    /// The log of JOB as received: the bytes in order, each frame starting where the last ended.
    fn log(&self, job: &str) -> Vec<u8> {
        let mut out = vec![];
        for (offset, bytes) in self.logs.get(job).map(Vec::as_slice).unwrap_or(&[]) {
            assert_eq!(*offset, out.len() as u64, "log frames out of order");
            out.extend_from_slice(bytes);
        }
        out
    }

    /// `hello`, and the runner's answer: linger, its attempts, its bundle.
    fn hello(&mut self) -> (bool, Vec<AttemptInfo>, String) {
        let hub = self.hub.clone();
        self.send(&Frame::Hello {
            version: sleipnir::proto::PROTO_VERSION,
            hub_id: hub,
        });
        self.next("hello-ok", |f| match f {
            Frame::HelloOk {
                linger,
                attempts,
                bundle,
                ..
            } => Some((*linger, attempts.clone(), bundle.clone())),
            _ => None,
        })
    }

    /// Offers R running SCRIPT in IMAGE, then starts it once admitted; returns at `started`.
    fn run(&mut self, r: &JobRef, image: &str, script: &str) {
        self.offer(r, script);
        self.start(r, image);
    }

    /// Offers R running SCRIPT; returns once it is admitted. (Admission counts the gap since the last start, so a
    /// row that starts two jobs at once admits both first.)
    fn offer(&mut self, r: &JobRef, script: &str) {
        self.send(&Frame::Offer {
            r: r.clone(),
            spec: Box::new(spec(script)),
            priority: Priority::P3,
            input_key: String::new(),
            grant_hint: None,
            expected: None,
        });
        let admitted = self.next("admit or refuse", |f| match f {
            Frame::Admit { r: a, .. } if a == r => Some(Ok(())),
            Frame::Refuse { r: a, why, .. } if a == r => Some(Err(why.clone())),
            _ => None,
        });
        assert_eq!(admitted, Ok(()), "{r:?}");
    }

    /// Starts the admitted R in IMAGE; returns at `started`.
    fn start(&mut self, r: &JobRef, image: &str) {
        self.send(&Frame::Start {
            r: r.clone(),
            image: Some(image.into()),
            env: vec![],
            net_hosts: vec![],
            pins: vec![],
            parser: "exit".into(),
        });
        self.next("started", |f| match f {
            Frame::Started { r: a, .. } if a == r => Some(()),
            Frame::Finished { r: a, result } if a == r => {
                panic!("{r:?} finished instead of starting: {result}")
            }
            _ => None,
        });
    }

    /// R's `finished` result.
    fn finished(&mut self, r: &JobRef) -> serde_json::Value {
        self.next("finished", |f| match f {
            Frame::Finished { r: a, result } if a == r => Some(result.clone()),
            _ => None,
        })
    }

    /// Waits until JOB's log, as received, shows TEXT.
    fn log_until(&mut self, job: &str, text: &str) {
        let what = format!("{job}'s log to show {text:?}");
        while !String::from_utf8_lossy(&self.log(job)).contains(text) {
            self.next(&what, |f| match f {
                Frame::Log { r, .. } if r.job == job => Some(()),
                _ => None,
            });
        }
    }

    /// `bye`, its answer, and the process's end.
    fn bye(mut self) {
        self.send(&Frame::Bye { why: "test".into() });
        self.next("bye", |f| matches!(f, Frame::Bye { .. }).then_some(()));
        self.wait_exit();
    }

    /// The local end of the channel closes (EOF for `serve`); the process ends.
    fn close(mut self) {
        drop(self.w.lock().unwrap().take());
        self.wait_exit();
    }

    fn wait_exit(&mut self) {
        let child = &mut self.child;
        skuld::wait_until("serve to exit", WAIT, || child.try_wait().unwrap());
    }
}

impl Drop for Link {
    /// The channel is cut: ssh killed, so `serve` gets an EOF without `bye`.
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Keeps a `log` frame's bytes in LOGS, by job and offset.
fn keep_log(logs: &mut BTreeMap<String, Vec<(u64, Vec<u8>)>>, f: &Frame) {
    if let Frame::Log { r, offset, bytes } = f {
        logs.entry(r.job.clone())
            .or_default()
            .push((*offset, bytes.clone()));
    }
}

fn verdict(result: &serde_json::Value) -> &str {
    result["verdict"].as_str().unwrap_or("?")
}

mod serve {
    use super::*;

    /// [C] After the channel is cut while a job runs, a new `serve` lists the attempt at `hello` (job, attempt, nonce,
    /// running, its log offset), and attaching streams its log and its result.
    #[test]
    #[ignore = "fleet"]
    fn hello_lists_running_attempts_after_a_reconnect() {
        let (r1, prefix) = ("r1", "fsrc");
        let root = root(r1, "fs-reconnect", &[BUNDLE]);
        let img = image(r1);
        let mut a = Link::open(r1, &root, BUNDLE, "hubrc", prefix);
        let (_, attempts, _) = a.hello();
        assert!(attempts.is_empty(), "{attempts:?}");
        let r = jr("j1", 1);
        a.run(&r, &img, PARKED);
        a.log_until("j1", "started\n");
        drop(a);
        let mut b = Link::open(r1, &root, BUNDLE, "hubrc", prefix);
        let (_, attempts, _) = b.hello();
        assert_eq!(attempts.len(), 1, "{attempts:?}");
        assert_eq!(
            (&attempts[0].r, attempts[0].state),
            (&r, AttemptState::Running)
        );
        assert!(attempts[0].log_offset >= "started\n".len() as u64);
        release(r1, prefix, "j1");
        b.send(&Frame::Attach {
            r: r.clone(),
            log_offset: 0,
        });
        let result = b.finished(&r);
        assert_eq!(verdict(&result), "Pass", "{result}");
        let log = String::from_utf8_lossy(&b.log("j1")).into_owned();
        assert!(
            log.contains("started\n") && log.contains("released\n"),
            "{log}"
        );
        b.send(&Frame::Done { r });
        b.bye();
    }

    /// [C] `serve` ends at `bye` and at an EOF; afterwards nothing of ours is enabled or running, and nothing was
    /// written outside the runner root but podman's own storage.
    #[test]
    #[ignore = "fleet"]
    fn exits_at_eof_and_leaves_no_unit_enabled() {
        let (r1, prefix) = ("r1", "fseof");
        let root = root(r1, "fs-eof", &[BUNDLE]);
        let img = image(r1);
        let enabled = "systemctl --user list-unit-files --state=enabled --no-legend --plain";
        let before = sh(r1, enabled);
        sh(r1, "touch /tmp/fs-eof-marker");
        let mut a = Link::open(r1, &root, BUNDLE, "hubeof", prefix);
        a.hello();
        let r = jr("e1", 2);
        a.run(&r, &img, "echo hi");
        let result = a.finished(&r);
        assert_eq!(verdict(&result), "Pass", "{result}");
        a.send(&Frame::Done { r });
        a.bye();
        let mut b = Link::open(r1, &root, BUNDLE, "hubeof", prefix);
        b.hello();
        b.close();
        assert_eq!(sh(r1, enabled), before, "a unit was enabled");
        assert_eq!(
            sh(
                r1,
                &format!("systemctl --user list-units --all --no-legend --plain '{prefix}-*'")
            ),
            "",
            "a unit of ours is still loaded"
        );
        assert_eq!(
            sh(
                r1,
                &format!("podman ps -a --filter name=^{prefix}- --format '{{{{.Names}}}}'")
            ),
            "",
            "a container of ours is left"
        );
        let outside = sh(
            r1,
            &format!(
                "find $HOME -newer /tmp/fs-eof-marker -not -path '{root}' -not -path '{root}/*' \
             -not -path \"$HOME/.local/share/containers*\" -not -path \"$HOME/.cache*\" -not -path \"$HOME\" \
             -not -path \"$HOME/.local\" -not -path \"$HOME/.local/share\""
            ),
        );
        assert_eq!(outside, "", "written outside the runner root");
        let reserved = sh(
            r1,
            "ls $XDG_RUNTIME_DIR/forseti/reservations 2>/dev/null | grep '^drgnx-hubeof\\.' || true",
        );
        assert_eq!(reserved, "", "a reservation is left");
    }

    /// [C] Two hubs share one runner root and prefix. Neither removes the other's containers or job folders; each
    /// removes its own ended ones; each lists only its own attempts; a running job of one holds its reservation while
    /// the other admits.
    #[test]
    #[ignore = "fleet"]
    fn two_hubs_on_one_runner_never_clean_each_other() {
        let (r1, prefix) = ("r1", "fstw");
        let root = root(r1, "fs-two", &[BUNDLE]);
        let img = image(r1);
        let exists = |what: &str| sh_status(r1, what).0;
        let ctr = |name: &str| format!("podman container exists {prefix}-{name}");
        let mut a = Link::open(r1, &root, BUNDLE, "hubA", prefix);
        a.hello();
        let (a1, a2) = (jr("a1", 3), jr("a2", 4));
        a.offer(&a1, PARKED);
        a.offer(&a2, "echo a2");
        a.start(&a1, &img);
        a.log_until("a1", "started\n");
        a.start(&a2, &img);
        assert_eq!(verdict(&a.finished(&a2)), "Pass");
        // A's a2 is finished, not collected, and old; and an ended container of each hub, with the shared prefix
        sh(
            r1,
            &format!("touch -d '2 days ago' {root}/jobs/a2.1/attempt.json"),
        );
        sh(
            r1,
            &format!(
                "podman create -q --name {prefix}-za --label drgnx.runner=hubA {img} true >/dev/null && \
             podman create -q --name {prefix}-zb --label drgnx.runner=hubB {img} true >/dev/null"
            ),
        );
        assert!(
            exists("test -e $XDG_RUNTIME_DIR/forseti/reservations/drgnx-hubA.a1-1.json"),
            "A's running job holds no reservation"
        );

        let mut b = Link::open(r1, &root, BUNDLE, "hubB", prefix);
        let (_, attempts, _) = b.hello();
        assert!(attempts.is_empty(), "B lists A's attempts: {attempts:?}");
        let b1 = jr("b1", 5);
        b.run(&b1, &img, "echo b1");
        assert_eq!(verdict(&b.finished(&b1)), "Pass");
        b.send(&Frame::Done { r: b1 });
        // frames are handled in order: the pong comes after `done`'s cleanup
        b.send(&Frame::Ping { at: 777 });
        b.next("the pong after B's cleanup", |f| {
            matches!(f, Frame::Pong { at: 777 }).then_some(())
        });
        b.bye();
        // B cleaned its own and nothing of A's
        assert!(!exists(&ctr("zb")), "B's ended container stayed");
        assert!(
            !exists(&format!("test -e {root}/jobs/b1.1")),
            "B's collected folder stayed"
        );
        assert!(exists(&ctr("za")), "B removed A's ended container");
        assert!(exists(&ctr("a1")), "B removed A's running container");
        assert!(exists(&format!("test -e {root}/jobs/a1.1")));
        assert!(
            exists(&format!("test -e {root}/jobs/a2.1")),
            "B removed A's old folder"
        );

        // A's job ends: A cleans its own
        release(r1, prefix, "a1");
        assert_eq!(verdict(&a.finished(&a1)), "Pass");
        a.next("ready after A's cleanup", |f| {
            matches!(f, Frame::Ready { .. }).then_some(())
        });
        assert!(!exists(&ctr("za")), "A's ended container stayed");
        assert!(
            !exists(&format!("test -e {root}/jobs/a2.1")),
            "A's old folder stayed"
        );
        assert!(
            exists(&format!("test -e {root}/jobs/a1.1")),
            "A's uncollected folder went"
        );
        a.send(&Frame::Done { r: a1 });
        a.bye();
    }

    /// [C] A new hub's `serve` (another bundle) keeps the old bundle while an attempt the old one started still runs
    /// from it, reattaches that attempt by its nonce, and drops the old bundle once nothing runs from it.
    #[test]
    #[ignore = "fleet"]
    fn an_update_keeps_the_old_bundle_while_its_jobs_run() {
        let (r1, prefix) = ("r1", "fsup");
        let root = root(r1, "fs-update", &["old", BUNDLE]);
        // the hub copied the new bundle after the old one
        sh(r1, &format!("touch -d '1 hour ago' {root}/bin/old"));
        let img = image(r1);
        let mut old = Link::open(r1, &root, "old", "hubup", prefix);
        let (_, _, bundle) = old.hello();
        assert_eq!(bundle, "old");
        let r = jr("u1", 6);
        old.run(&r, &img, PARKED);
        old.log_until("u1", "started\n");
        drop(old);
        let mut new = Link::open(r1, &root, BUNDLE, "hubup", prefix);
        let (_, attempts, bundle) = new.hello();
        assert_eq!(bundle, BUNDLE);
        assert_eq!(
            attempts.iter().map(|a| (&a.r, a.state)).collect::<Vec<_>>(),
            vec![(&r, AttemptState::Running)]
        );
        assert!(
            sh_status(r1, &format!("test -x {root}/bin/old/sleipnir")).0,
            "the old bundle went while its job ran"
        );
        release(r1, prefix, "u1");
        new.send(&Frame::Attach {
            r: r.clone(),
            log_offset: 0,
        });
        assert_eq!(verdict(&new.finished(&r)), "Pass");
        new.next("ready after the cleanup", |f| {
            matches!(f, Frame::Ready { .. }).then_some(())
        });
        assert!(
            !sh_status(r1, &format!("test -e {root}/bin/old")).0,
            "the old bundle stayed with nothing running from it"
        );
        new.send(&Frame::Done { r });
        new.bye();
    }

    /// [C] The log comes from the attempt's file by offset: the channel is cut after the first part, the job writes the
    /// rest with no link, and a new channel attached at an earlier offset sends exactly the bytes from there to the end,
    /// so the stream equals the file.
    #[test]
    #[ignore = "fleet"]
    fn logs_come_from_the_file_by_offset() {
        let (r1, prefix) = ("r1", "fslg");
        let root = root(r1, "fs-log", &[BUNDLE]);
        let img = image(r1);
        let mut a = Link::open(r1, &root, BUNDLE, "hublg", prefix);
        a.hello();
        let r = jr("l1", 7);
        a.run(
            &r,
            &img,
            "seq 1 30000; mkfifo /tmp/gate; read x < /tmp/gate; seq 30001 60000",
        );
        a.log_until("l1", "\n30000\n");
        let first = a.log("l1");
        drop(a);
        release(r1, prefix, "l1");
        skuld::wait_until("l1's result.json", WAIT, || {
            sh_status(r1, &format!("test -e {root}/jobs/l1.1/result.json"))
                .0
                .then_some(())
        });
        let keep = first.len() as u64 - 100;
        let mut b = Link::open(r1, &root, BUNDLE, "hublg", prefix);
        let (_, attempts, _) = b.hello();
        assert_eq!(attempts.len(), 1);
        assert_eq!(attempts[0].state, AttemptState::Finished);
        b.send(&Frame::Attach {
            r: r.clone(),
            log_offset: keep,
        });
        assert_eq!(verdict(&b.finished(&r)), "Pass");
        let rest = b.logs.get("l1").cloned().unwrap_or_default();
        assert_eq!(
            rest.first().map(|(o, _)| *o),
            Some(keep),
            "the stream starts at the hub's offset"
        );
        let mut stream = first[..keep as usize].to_vec();
        for (offset, bytes) in &rest {
            assert_eq!(
                *offset,
                stream.len() as u64,
                "a gap or an overlap in the stream"
            );
            stream.extend_from_slice(bytes);
        }
        let file = sh_status(r1, &format!("cat {root}/jobs/l1.1/log")).1;
        assert_eq!(stream.len(), file.len());
        assert!(stream == file, "the stream differs from the file");
        assert!(String::from_utf8_lossy(&file).contains("\n60000\n"));
        b.send(&Frame::Done { r });
        b.bye();
    }

    /// [C] Linger is read again at every `hello`: runner 2 starts without it and says so twice; once linger is turned on
    /// there, the next `hello` says it is on.
    #[test]
    #[ignore = "fleet"]
    fn no_linger_is_reported_at_every_hello() {
        let r2 = "r2";
        let root = root(r2, "fs-linger", &[BUNDLE]);
        let mut a = Link::open(r2, &root, BUNDLE, "hubln", "fsln");
        assert!(!a.hello().0, "linger reported on a runner without it");
        assert!(!a.hello().0, "linger reported on the second hello");
        let share = std::env::var("DRGNX_FLEET_SHARE").unwrap();
        std::fs::write(PathBuf::from(share).join("enable-linger"), b"").unwrap();
        skuld::wait_until("linger on runner 2", WAIT, || {
            (sh(r2, "loginctl show-user $(id -u) --property=Linger --value") == "yes").then_some(())
        });
        assert!(a.hello().0, "linger turned on, not reported");
        a.bye();
    }
}
