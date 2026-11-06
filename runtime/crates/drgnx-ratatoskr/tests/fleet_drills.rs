//! The runner link drills over real SSH to a real `sleipnir serve` in the fake fleet (`#[ignore = "fleet"]`,
//! test/runners/). Each row plays the hub with its real parts: the `OpensshTransport` (one master, three sessions),
//! the link session, the queue on a `runtime.db` of its own. It breaks the link the way the world does (a master told
//! `-O stop`, a connection frozen and then dead, `serve` stopped, the hub gone and back, a changed host key) and
//! proves the outcome from state: the job's attempts in `runtime.db`, the queue's rows, the runner's own log and
//! attempt record, and no key bytes on the runner. Time the hub must sit through (a 3-minute cut, a 5-minute suspend)
//! is the queue's clock moved on: the queue takes its time as a value, and nothing on the runner counts it.
//!
//! `test/runners/drills.sh` runs each row 5 times:
//!
//! ```text
//! cargo test -p drgnx-ratatoskr --features fleet,test-hooks --test fleet_drills --no-run
//! cargo build -p sleipnir --features test-hooks --bin sleipnir --bin drgnx-key   # fleet.sh test shares both
//! fleet.sh up --runners 2 --max-sessions 3
//! DRGNX_FLEET_TEST_BIN=<the test binary> fleet.sh test --test-threads=1 drill::
//! ```
//!
//! Every row is [C]: a real `serve` and the jobs it starts announce their state in frames, files and the hub's copy of
//! the log, and the row waits on that state with `skuld::wait_until_async`; a job that must stay running parks on a
//! FIFO in its container until the row writes to it. Every row asserts what the drills share: no `red`, `crash` or
//! `infra` verdict from the link, the attempt reattached by its nonce with the job's own verdict, the hub's log equal
//! to the runner's byte for byte, and at most 3 sessions on any one connection to the runner.
#![cfg(target_os = "linux")]

use drgnx_ratatoskr::runners::link::{LinkEvent, Session};
use drgnx_ratatoskr::runners::local::{Admission, LocalRunner};
use drgnx_ratatoskr::runners::queue::{
    self as rq, Outcome, Placement, Queue, QueueCfg, RemoteRunner, SendMode, Submit,
};
use drgnx_ratatoskr::runners::ssh_config as generated;
use drgnx_ratatoskr::runners::transport::{Channels, LinkError, OpensshTransport, Transport};
use drgnx_ratatoskr::runners::{Remote, RunnerCfg};
use drgnx_ratatoskr::runtime_db;
use forseti::{Expect, JobSpec, JobTrust, Kind, Lane, Priority, Range, RunnerTrust, Weight};
use runstav::methods::runners::AuditKind;
use secrecy::SecretString;
use serde_json::{Value, json};
use sleipnir::proto::Frame;
use std::hash::{BuildHasher, Hasher};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc::UnboundedReceiver;

/// How long a row waits on any one announced state before it fails: a lost link takes 45 s to be called, a key 60 s.
const WAIT: u64 = 150;

/// The machine the rows' runners report to admission: idle, with room, on mains power (the host's power supplies may
/// show a battery, which a `workstation` runner would refuse jobs on).
const QUIET_MACHINE: &str = r#"{"psi": {"mem_some10": 0.0, "cpu_some10": 0.0, "io_full10": 0.0, "app_mem_some10": null},
"disk_free_gb": 100, "disk_total_gb": 200, "mem_available_mib": 8192, "on_ac": true}"#;

/// A job's log of several 1 MiB chunks, then `parked`, then it waits for the row (a FIFO), then `released`.
const PARK: &str = "head -c 2500000 /dev/zero | tr '\\0' x; echo; echo parked; mkfifo /tmp/gate; \
                    read x < /tmp/gate; echo released";

/// The name of the key the keyed rows give their job.
const KEY: &str = "DRILL_KEY";

/// `st FILE`: a process's `Name`, `PPid` and `Uid` from its status file, into `n`, `pp` and `u`.
const ST: &str = "st() { n= pp= u=; { while read -r k v rest; do case $k in Name:) n=$v;; PPid:) pp=$v;; \
                  Uid:) u=$v;; esac; done < \"$1\"; } 2>/dev/null; }\n";

/// Each `sshd*` process of this user but the one serving this script, and how many processes it started (the
/// sessions open on that connection): one `PID COUNT` line each.
const SESSIONS: &str = "me=$(id -u); self=; p=$$
while [ \"$p\" -gt 1 ]; do st /proc/$p/status; case $n in sshd*) self=$p; break;; esac; p=${pp:-1}; done
L=$(for s in /proc/[0-9]*/status; do st \"$s\"; q=${s#/proc/}; echo \"${q%/status} ${pp:-0} ${u:-x} ${n:-x}\"; done)
printf '%s\\n' \"$L\" | while read -r p pp u n; do
  case $n in sshd*) ;; *) continue;; esac
  [ \"$u\" = \"$me\" ] && [ \"$p\" != \"$self\" ] || continue
  c=$(printf '%s\\n' \"$L\" | while read -r a b rest; do [ \"$b\" = \"$p\" ] && echo x; done | wc -l)
  echo \"$p $c\"
done";

/// The `serve` processes of ROOT and the `sshd*` process of the connection each runs on: one `SERVE SSHD` line each.
const SERVE_PIDS: &str = "for c in /proc/[0-9]*/cmdline; do
  a=$(tr '\\0' ' ' < \"$c\" 2>/dev/null) || continue
  case $a in \"ROOT/bin/test/sleipnir serve --root ROOT \"*) ;; *) continue;; esac
  p=${c#/proc/}; p=${p%/cmdline}; s=$p
  while [ \"$s\" -gt 1 ]; do st /proc/$s/status; case $n in sshd*) echo \"$p $s\"; break;; esac; s=${pp:-1}; done
done";

fn ssh_config() -> String {
    format!("{}/.ssh/config", std::env::var("HOME").unwrap())
}

fn ssh(runner: &str, script: &str) -> std::process::Output {
    Command::new("ssh")
        .args(["-F", &ssh_config(), "-o", "BatchMode=yes", runner])
        .arg(script)
        .output()
        .expect("ssh")
}

/// SCRIPT's stdout on RUNNER, over a connection of its own; panics when it fails.
fn sh_bytes(runner: &str, script: &str) -> Vec<u8> {
    let out = ssh(runner, script);
    assert!(
        out.status.success(),
        "{runner}: {script}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    out.stdout
}

fn sh(runner: &str, script: &str) -> String {
    String::from_utf8_lossy(&sh_bytes(runner, script))
        .trim()
        .to_string()
}

/// The wall clock as the queue takes it: a value, never waited on.
fn now() -> u64 {
    skuld::host_now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

/// A throwaway key value no other row or run shares: `drk-` and 32 hex digits.
fn throwaway() -> String {
    let word = || {
        let mut h = std::collections::hash_map::RandomState::new().build_hasher();
        h.write_u64(now());
        h.finish()
    };
    format!("drk-{:016x}{:016x}", word(), word())
}

/// The row's own home (HOME, which the generated config's `Include ~/.ssh/config` and the rows' own ssh read): the
/// fleet's ssh config with the row's own known hosts first, so a row may change them. The fleet's HOME is back when it
/// is dropped.
struct UserConfig {
    fleet_home: String,
}

impl UserConfig {
    /// A home under DIR whose known hosts are KNOWN_HOSTS, a copy of the fleet's.
    fn new(dir: &Path, known_hosts: &Path) -> UserConfig {
        let fleet_home = std::env::var("HOME").unwrap();
        let home = PathBuf::from(&fleet_home);
        assert!(
            Path::new("/run/.containerenv").exists() && fleet_home.contains("/fleet/"),
            "the drills run only in a fleet's harness container (fleet.sh test)"
        );
        let base = std::fs::read_to_string(home.join(".ssh/config")).unwrap();
        std::fs::copy(home.join(".ssh/known_hosts"), known_hosts).unwrap();
        let ssh = dir.join("home/.ssh");
        std::fs::create_dir_all(&ssh).unwrap();
        let mut text = String::new();
        for h in ["r1", "r2"] {
            text.push_str(&format!(
                "Host {h}\n  UserKnownHostsFile {}\n",
                known_hosts.display()
            ));
        }
        std::fs::write(ssh.join("config"), format!("{text}{base}")).unwrap();
        // SAFETY: the rows run one at a time (--test-threads=1) and set HOME before any task or child reads it
        unsafe { std::env::set_var("HOME", dir.join("home")) };
        UserConfig { fleet_home }
    }
}

impl Drop for UserConfig {
    fn drop(&mut self) {
        // SAFETY: as in `new`: the row's tasks and children are done with HOME by its end
        unsafe { std::env::set_var("HOME", &self.fleet_home) };
    }
}

/// A fresh runner root at ~/NAME on RUNNER: the shared `sleipnir` and `drgnx-key` as bundle `test`, and the quiet
/// machine.
fn root(runner: &str, name: &str) -> String {
    let share =
        std::env::var("DRGNX_FLEET_SHARE").expect("DRGNX_FLEET_SHARE: run through fleet.sh test");
    for b in ["sleipnir", "drgnx-key"] {
        assert!(
            PathBuf::from(&share).join(b).exists(),
            "fleet.sh test puts {b} in the share"
        );
    }
    let home = sh(runner, "echo $HOME");
    let root = format!("{home}/{name}");
    sh(
        runner,
        &format!(
            "rm -rf {root} && mkdir -p {root}/bin/test && cp /fleet/share/sleipnir /fleet/share/drgnx-key \
             {root}/bin/test/ && printf %s '{QUIET_MACHINE}' > {root}/test-machine.json"
        ),
    );
    root
}

/// The fake runner's base image, by digest.
fn image(runner: &str) -> String {
    let d = sh(
        runner,
        "podman image inspect registry.fedoraproject.org/fedora:45 --format '{{.Digest}}'",
    );
    format!("registry.fedoraproject.org/fedora@{d}")
}

/// One of the job's attempts as `runtime.db` keeps it: its number, nonce and state.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Kept {
    attempt: u32,
    nonce: String,
    state: String,
}

/// A hub for one row: the transport, a queue on `runtime.db` in a folder of its own whose one local slot a job holds,
/// and one runner.
struct Drill {
    runner: String,
    root: String,
    prefix: String,
    hub: String,
    profile: &'static str,
    img: String,
    dir: tempfile::TempDir,
    t: Arc<OpensshTransport>,
    q: Arc<Queue>,
    events: UnboundedReceiver<LinkEvent>,
    store: Option<urdr::Store>,
    db: urdr::Handle,
    outcomes: Vec<Outcome>,
    lost: Vec<String>,
    clocks: usize,
    /// How far the queue's clock is ahead of the wall clock: the time the row says has passed.
    jump: u64,
    told: Arc<Mutex<Vec<(String, Value)>>>,
    /// The most sessions seen on one connection to the runner.
    sessions_max: usize,
    _user: UserConfig,
}

impl Drill {
    /// A hub named NAME (its prefix and id) on RUNNER, whose `serve` runs with PROFILE.
    fn new(name: &str, runner: &str, profile: &'static str) -> Drill {
        let dir = tempfile::tempdir().unwrap();
        let user = UserConfig::new(dir.path(), &dir.path().join("known_hosts"));
        let root = root(runner, &format!("dr-{name}"));
        let img = image(runner);
        for d in ["exec", "run", "hub"] {
            std::fs::create_dir_all(dir.path().join(d)).unwrap();
        }
        let (store, db) = runtime_db::open(&dir.path().join("hub")).unwrap();
        let t = Arc::new(OpensshTransport::new(dir.path().join("run")));
        let (q, events) = Self::queue(dir.path(), &format!("hub-{name}"), db.clone());
        let told = Arc::new(Mutex::new(vec![]));
        let to = told.clone();
        q.keys()
            .set_tell(move |e, d| to.lock().unwrap().push((e.to_string(), d)));
        Drill {
            runner: runner.into(),
            root,
            prefix: format!("dr-{name}"),
            hub: format!("hub-{name}"),
            profile,
            img,
            dir,
            t,
            q,
            events,
            store: Some(store),
            db,
            outcomes: vec![],
            lost: vec![],
            clocks: 0,
            jump: 0,
            told,
            sessions_max: 0,
            _user: user,
        }
    }

    fn queue(
        dir: &Path,
        hub: &str,
        db: urdr::Handle,
    ) -> (Arc<Queue>, UnboundedReceiver<LinkEvent>) {
        let (q, events) = Queue::new(QueueCfg {
            hub_id: hub.into(),
            exec_root: dir.join("exec"),
            local: LocalRunner::new(Admission::Fixed(1), dir),
            db: Some(db),
        });
        q.adopt("xbusy", Priority::P1, now());
        (q, events)
    }

    /// The queue's time: the wall clock and what the row moved it on.
    fn now(&self) -> u64 {
        now() + self.jump
    }

    /// How the hub reaches the runner: `serve` on the control session, `cat` holding the bulk ones (the registry's).
    fn cfg(&self) -> RunnerCfg {
        RunnerCfg {
            name: self.runner.clone(),
            host: self.runner.clone(),
            linger: true,
            cloud: None,
            remote: Remote {
                control: vec![
                    format!("{}/bin/test/sleipnir", self.root),
                    "serve".into(),
                    "--root".into(),
                    self.root.clone(),
                    "--prefix".into(),
                    self.prefix.clone(),
                    "--hub-id".into(),
                    self.hub.clone(),
                    "--profile".into(),
                    self.profile.into(),
                ],
                bulk_in: vec!["cat".into()],
                bulk_out: vec!["cat".into()],
            },
        }
    }

    async fn open(&self) -> Result<Channels, LinkError> {
        self.t.open(&self.cfg()).await
    }

    /// The first link: the runner added to the queue, which says `hello`.
    async fn link(&mut self) {
        let channels = self.open().await.expect("the transport opens the runner");
        let s = Session::start(&self.runner, channels, self.q.route(), self.q.link_events());
        self.q.add_runner(
            RemoteRunner {
                name: self.runner.clone(),
                trust: RunnerTrust::Mine,
                accept: forseti::Accept::All,
                grace_s: 600,
                image: Some(self.img.clone()),
            },
            s,
        );
        self.ready().await;
    }

    /// The hub's session ends (as before every new link); returns once the runner's `serve` of it is gone.
    async fn unlink(&mut self) {
        if let Some(s) = self.q.session(&self.runner) {
            s.close().await;
        }
        self.serve_gone().await;
    }

    /// A new link on the runner the queue knows (a redial): it says `hello`, and the runner lists its attempts.
    async fn relink(&mut self) {
        let channels = self
            .open()
            .await
            .expect("the transport opens the runner again");
        let s = Session::start(&self.runner, channels, self.q.route(), self.q.link_events());
        assert!(self.q.set_session(&self.runner, s));
        self.ready().await;
    }

    /// Drains the link's events into the queue at its time and ticks it once.
    fn pump(&mut self) {
        while let Ok(ev) = self.events.try_recv() {
            let ev = match ev {
                // the runner's clock moved with the hub's: the time the row skips passed for both
                LinkEvent::Clock { runner, at } => {
                    self.clocks += 1;
                    LinkEvent::Clock {
                        runner,
                        at: at + self.jump,
                    }
                }
                LinkEvent::Lost { runner, why } => {
                    self.lost.push(why.clone());
                    LinkEvent::Lost { runner, why }
                }
                // a row's job (`x…`, never a health check's canary) refused is offered again at the next tick, every
                // poll here: say why at once instead
                LinkEvent::Frame {
                    frame: Frame::Refuse { r, why, .. },
                    ..
                } if r.job.starts_with('x') => panic!("{}: the runner refused it: {why}", r.job),
                e => e,
            };
            let at = self.now();
            self.outcomes.extend(self.q.on_link(ev, at));
        }
        let at = self.now();
        self.outcomes.extend(self.q.tick(at).outcomes);
    }

    /// Pumps the queue until CHECK (on the queue, its outcomes so far and the losses heard) gives a value.
    async fn drive<T>(
        &mut self,
        what: &str,
        mut check: impl FnMut(&Queue, &[Outcome], &[String]) -> Option<T>,
    ) -> T {
        skuld::wait_until_async(what, WAIT, || {
            self.pump();
            std::future::ready(check(&self.q, &self.outcomes, &self.lost))
        })
        .await
    }

    async fn ready(&mut self) {
        let r = self.runner.clone();
        self.drive(&format!("{r} ready"), |q, _, _| {
            q.runner(&r).filter(|x| x.state == "ready").map(|_| ())
        })
        .await;
    }

    /// Job ID running SCRIPT in the runner's image, restartable, with the keys KEYS.
    fn job(&self, id: &str, script: &str, keys: &[&str]) -> Submit {
        let keys: Vec<String> = keys.iter().map(|k| k.to_string()).collect();
        let spec = JobSpec {
            name: id.into(),
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
            timeout_s: 900,
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
            trust: if keys.is_empty() {
                JobTrust::Private
            } else {
                JobTrust::PrivateKeys
            },
            keys: keys.clone(),
            local_only: false,
            writes: vec![],
        };
        Submit {
            id: id.into(),
            session: Some("s1".into()),
            own: Priority::P3,
            spec,
            place: Placement {
                send: SendMode::All,
                image: Some(self.img.clone()),
                keys,
                ..Placement::default()
            },
            pending: Value::Null,
            inputs: None,
        }
    }

    fn submit(&self, s: Submit) {
        self.q.submit(s, self.now());
    }

    fn hold(&self, value: &str) {
        self.q.take_keys(
            [(KEY.to_string(), SecretString::from(value.to_string()))],
            self.now(),
        );
    }

    /// The hub's copy of job ID's log.
    fn hub_log(&self, id: &str) -> Vec<u8> {
        std::fs::read(self.dir.path().join("exec").join(id).join("log")).unwrap_or_default()
    }

    /// Waits until the hub's copy of ID's log shows its job parked.
    async fn parked(&mut self, id: &str) {
        let path = self.dir.path().join("exec").join(id).join("log");
        self.drive(&format!("{id} parked"), |_, _, _| {
            std::fs::read(&path)
                .ok()
                .filter(|l| l.windows(7).any(|w| w == b"parked\n"))
                .map(|_| ())
        })
        .await;
    }

    /// Lets ID's job go on from its FIFO.
    fn release(&self, id: &str) {
        sh(
            &self.runner,
            &format!(
                "podman exec {}-{id} sh -c 'echo go > /tmp/gate'",
                self.prefix
            ),
        );
    }

    /// The runner's own log of ID's attempt ATTEMPT, read once its result is written and before the hub has it (the
    /// queue's `done` lets the runner remove the folder, and the queue is not pumped meanwhile).
    async fn runner_log(&self, id: &str, attempt: u32) -> Vec<u8> {
        let dir = format!("{}/jobs/{id}.{attempt}", self.root);
        let runner = self.runner.clone();
        let test = format!("test -e {dir}/result.json");
        skuld::wait_until_async(&format!("{id}'s result on the runner"), WAIT, || {
            std::future::ready(ssh(&runner, &test).status.success().then_some(()))
        })
        .await;
        sh_bytes(&self.runner, &format!("cat {dir}/log"))
    }

    /// The runner's own record of ID's attempt ATTEMPT: its nonce.
    fn runner_nonce(&self, id: &str, attempt: u32) -> String {
        let meta: Value = serde_json::from_str(&sh(
            &self.runner,
            &format!("cat {}/jobs/{id}.{attempt}/attempt.json", self.root),
        ))
        .unwrap();
        meta["r"]["nonce"].as_str().unwrap_or_default().to_string()
    }

    /// ID's verdict, once its runner sent it: the attempt and the result.
    async fn done(&mut self, id: &str) -> (u32, Value) {
        let id = id.to_string();
        self.drive(&format!("{id}'s result"), |_, o, _| {
            o.iter().find_map(|o| match o {
                Outcome::Done {
                    id: x,
                    attempt,
                    result,
                    ..
                } if *x == id => Some((*attempt, result.clone())),
                _ => None,
            })
        })
        .await
    }

    /// Job ID's attempts as `runtime.db` holds them now.
    async fn kept(&self, id: &str) -> Vec<Kept> {
        self.q.flush().await;
        kept(&self.db, id).await
    }

    /// Pumps the queue until `runtime.db` says ID has exactly one attempt and it is in STATE.
    async fn kept_as(&mut self, id: &str, state: &str) -> Kept {
        let what = format!("{id}'s one attempt {state} in runtime.db");
        skuld::wait_until_async(&what, WAIT, || {
            self.pump();
            let (q, db, id, state) = (
                self.q.clone(),
                self.db.clone(),
                id.to_string(),
                state.to_string(),
            );
            async move {
                q.flush().await;
                let k = kept(&db, &id).await;
                (k.len() == 1 && k[0].state == state).then(|| k[0].clone())
            }
        })
        .await
    }

    /// The sessions open on each connection to the runner now; the most is kept for the row's end.
    fn sessions(&mut self) -> usize {
        let out = sh(&self.runner, &format!("{ST}{SESSIONS}"));
        let most = out
            .lines()
            .filter_map(|l| l.split_whitespace().nth(1)?.parse::<usize>().ok())
            .max()
            .unwrap_or(0);
        self.sessions_max = self.sessions_max.max(most);
        most
    }

    /// The runner's `serve` processes of this row's root, each with the `sshd` process of its connection.
    fn serve_pids(&self) -> Vec<(u32, u32)> {
        sh(
            &self.runner,
            &format!("{ST}{}", SERVE_PIDS.replace("ROOT", &self.root)),
        )
        .lines()
        .filter_map(|l| {
            let mut w = l.split_whitespace().map(|x| x.parse::<u32>().ok());
            Some((w.next()??, w.next()??))
        })
        .collect()
    }

    /// The one `serve` of this row, and its connection's `sshd`.
    fn the_serve(&self) -> (u32, u32) {
        let p = self.serve_pids();
        assert_eq!(p.len(), 1, "one serve of {}: {p:?}", self.root);
        p[0]
    }

    /// Returns once no `serve` of this row's root runs on the runner.
    async fn serve_gone(&self) {
        skuld::wait_until_async("the old serve gone", WAIT, || {
            std::future::ready(self.serve_pids().is_empty().then_some(()))
        })
        .await;
    }

    /// The folders of the masters the transport made for the runner.
    fn masters(&self) -> Vec<PathBuf> {
        let d = generated::dir(&self.dir.path().join("run"), &self.runner);
        let mut v: Vec<PathBuf> = std::fs::read_dir(d)
            .map(|rd| {
                rd.flatten()
                    .map(|e| e.path())
                    .filter(|p| {
                        p.file_name()
                            .is_some_and(|n| n.to_string_lossy().starts_with(".ssh-connection"))
                    })
                    .collect()
            })
            .unwrap_or_default();
        v.sort();
        v
    }

    /// No file under the runner's root or `/tmp` holds the key's VALUE.
    fn no_key_bytes(&self, value: &str) {
        // a fixed string, so the value is no pattern; grep's status 1 (nothing found) is what the row wants
        let found = sh(
            &self.runner,
            &format!(
                "grep -rlF -- '{value}' {} /tmp 2>/dev/null; true",
                self.root
            ),
        );
        assert_eq!(found, "", "a key's bytes stayed on the runner");
    }

    /// What every drill asserts at its end, for job ID, whose runner's log was THEIRS: one verdict, the job's own
    /// (`Pass`, from attempt 1, the one placed); nothing else ended; the hub's copy of the log equals the runner's byte
    /// for byte; never more than 3 sessions on a connection; and no strike for the runner.
    fn the_jobs_own_verdict(&mut self, id: &str, attempt: u32, result: &Value, theirs: &[u8]) {
        assert_eq!(
            (attempt, &result["verdict"]),
            (1, &json!("Pass")),
            "{result}"
        );
        let ended: Vec<&Outcome> = self
            .outcomes
            .iter()
            .filter(|o| match o {
                Outcome::Done { id: x, .. }
                | Outcome::Lost { id: x }
                | Outcome::Late { id: x, .. } => x == id,
            })
            .collect();
        assert_eq!(ended.len(), 1, "one ending for {id}: {ended:?}");
        let ours = self.hub_log(id);
        let tail =
            |b: &[u8]| String::from_utf8_lossy(&b[b.len().saturating_sub(300)..]).into_owned();
        // the job's own end (podman may add a line of its own after it)
        assert!(
            theirs.windows(9).any(|w| w == b"released\n"),
            "the runner's log holds the job's end: {:?}",
            tail(theirs)
        );
        assert!(
            ours == theirs,
            "the hub's copy ({} bytes, ending {:?}) differs from the runner's ({} bytes, ending {:?})",
            ours.len(),
            tail(&ours),
            theirs.len(),
            tail(theirs)
        );
        self.sessions();
        assert!(
            (1..=3).contains(&self.sessions_max),
            "sessions on one connection: at most {}",
            self.sessions_max
        );
        let r = self.q.runner(&self.runner).unwrap();
        assert_eq!(r.strikes, 0, "{r:?}");
    }

    /// The row's end: the link closed, the master stopped, the store shut.
    async fn end(mut self) {
        self.unlink().await;
        self.t.stop(&self.runner).await;
        if let Some(s) = self.store.take() {
            tokio::task::spawn_blocking(move || s.shutdown())
                .await
                .unwrap();
        }
    }
}

/// Job ID's attempts in the `runtime.db` behind DB.
async fn kept(db: &urdr::Handle, id: &str) -> Vec<Kept> {
    let id = id.to_string();
    db.read(move |c| {
        let mut st = c.prepare(
            "select attempt, nonce, state from rq_attempt where job = ?1 order by attempt",
        )?;
        let rows = st
            .query_map([&id], |r| {
                Ok(Kept {
                    attempt: r.get::<_, i64>(0)? as u32,
                    nonce: r.get::<_, String>(1)?,
                    state: r.get::<_, String>(2)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    })
    .await
    .unwrap()
}

/// How often a key was sent for job ID, by the queue's audit.
fn sent(q: &Queue, id: &str) -> usize {
    q.keys()
        .audit(Some(id), Some(KEY))
        .iter()
        .filter(|a| a.kind == AuditKind::Sent)
        .count()
}

mod drill {
    use super::*;

    /// [C] `-O stop` on the hub's master (a second hub replacing it, or the user): the master stops listening and
    /// its sessions run on, so the link stays up; the hub's next link dials a new master, and the job, running all
    /// along, reattaches by its nonce and ends with its own verdict.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "fleet"]
    async fn o_stop_on_the_master() {
        let mut d = Drill::new("ostop", "r1", "dedicated");
        d.link().await;
        d.submit(d.job("xostop", PARK, &[]));
        d.parked("xostop").await;
        d.sessions();
        let before = d.masters();
        assert_eq!(before.len(), 1, "{before:?}");
        let config = generated::path(&d.dir.path().join("run"), "r1");
        let stop = Command::new("ssh")
            .arg("-F")
            .arg(&config)
            .arg("-o")
            .arg(format!(
                "ControlPath={}",
                before[0].join("master").display()
            ))
            .args(["-O", "stop", "r1"])
            .output()
            .unwrap();
        assert!(stop.status.success(), "-O stop: {stop:?}");
        // the old master's sessions still carry the link: the runner's next ping comes through it
        let target = d.clocks + 1;
        skuld::wait_until_async("a ping after -O stop", WAIT, || {
            d.pump();
            std::future::ready((d.clocks >= target).then_some(()))
        })
        .await;
        assert!(d.lost.is_empty(), "the link was lost: {:?}", d.lost);
        assert_eq!(d.q.runner("r1").unwrap().state, "ready");
        d.sessions();
        // the hub's next link: the stopped master answers no `-O check`, so a new one is dialed
        d.unlink().await;
        d.relink().await;
        let after = d.masters();
        assert_eq!(after.len(), 1, "{after:?}");
        assert_ne!(before, after, "a new master");
        let k = d.kept_as("xostop", "running").await;
        assert_eq!(k.attempt, 1);
        assert_eq!(
            k.nonce,
            d.runner_nonce("xostop", 1),
            "reattached by its nonce"
        );
        d.sessions();
        d.release("xostop");
        let theirs = d.runner_log("xostop", 1).await;
        let (attempt, result) = d.done("xostop").await;
        d.the_jobs_own_verdict("xostop", attempt, &result, &theirs);
        assert!(d.lost.is_empty(), "{:?}", d.lost);
        d.end().await;
    }

    /// [C] The network cut for 3 minutes under a keyed job: the hub's connection to the runner freezes (its `sshd`
    /// stopped), the hub calls the link lost after 45 s without a frame and detaches the attempt, never a verdict; 3
    /// minutes pass on the queue's clock and the grace (600 s, the runner lingers) holds; the dead connection goes and
    /// the hub dials again. The job's helper kept its key through it: the job ends with its own verdict, its key was
    /// sent once, and no file on the runner holds it.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "fleet"]
    async fn network_cut_3_minutes_with_a_keyed_job() {
        let mut d = Drill::new("cut", "r1", "dedicated");
        let v = throwaway();
        d.link().await;
        d.hold(&v);
        let script = format!("test -n \"${KEY}\" && echo keyed; {PARK}");
        d.submit(d.job("xcut", &script, &[KEY]));
        d.parked("xcut").await;
        assert_eq!(sent(&d.q, "xcut"), 1);
        d.sessions();
        let (_, sshd) = d.the_serve();
        sh("r1", &format!("kill -STOP {sshd}"));
        let why = d
            .drive("the link lost", |_, _, lost| lost.first().cloned())
            .await;
        assert!(why.contains("no frame for 45 s"), "{why}");
        // 3 minutes of the cut on the queue's clock
        d.jump += 180;
        d.pump();
        let k = d.kept("xcut").await;
        assert_eq!(k.len(), 1, "{k:?}");
        assert_eq!((k[0].attempt, k[0].state.as_str()), (1, "detached"));
        let row = d.q.row("xcut").unwrap();
        assert_eq!((row.machine.as_deref(), row.attempt), (Some("r1"), Some(1)));
        assert!(d.outcomes.is_empty(), "{:?}", d.outcomes);
        // the cut ends: the frozen connection is dead by now (ssh's keep-alive gave up on it), the hub dials again
        if let Some(s) = d.q.session("r1") {
            s.close().await;
        }
        sh("r1", &format!("kill -KILL {sshd}"));
        d.serve_gone().await;
        d.relink().await;
        let k = d.kept_as("xcut", "running").await;
        assert_eq!(
            k.nonce,
            d.runner_nonce("xcut", 1),
            "reattached by its nonce"
        );
        d.sessions();
        d.release("xcut");
        let theirs = d.runner_log("xcut", 1).await;
        let (attempt, result) = d.done("xcut").await;
        d.the_jobs_own_verdict("xcut", attempt, &result, &theirs);
        assert!(theirs.starts_with(b"keyed\n"), "the job had its key");
        assert_eq!(sent(&d.q, "xcut"), 1, "its key was sent once");
        assert_eq!(d.lost.len(), 1, "{:?}", d.lost);
        d.no_key_bytes(&v);
        d.end().await;
    }

    /// [C] `serve` stopped for 5 minutes (a suspend): the hub calls the link lost after 45 s without a frame; 5
    /// minutes pass on the queue's clock within the grace; `serve` goes on, finds its channel closed and ends; the
    /// hub dials again and the job reattaches.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "fleet"]
    async fn serve_sigstopped_5_minutes() {
        let mut d = Drill::new("suspend", "r1", "dedicated");
        d.link().await;
        d.submit(d.job("xsusp", PARK, &[]));
        d.parked("xsusp").await;
        d.sessions();
        let (serve, _) = d.the_serve();
        sh("r1", &format!("kill -STOP {serve}"));
        let why = d
            .drive("the link lost", |_, _, lost| lost.first().cloned())
            .await;
        assert!(why.contains("no frame for 45 s"), "{why}");
        d.jump += 300;
        d.pump();
        let k = d.kept("xsusp").await;
        assert_eq!(k.len(), 1, "{k:?}");
        assert_eq!((k[0].attempt, k[0].state.as_str()), (1, "detached"));
        assert!(d.outcomes.is_empty(), "{:?}", d.outcomes);
        // the machine wakes: the hub has closed the old link, so `serve` finds its channel ended
        if let Some(s) = d.q.session("r1") {
            s.close().await;
        }
        sh("r1", &format!("kill -CONT {serve}"));
        d.serve_gone().await;
        d.relink().await;
        let k = d.kept_as("xsusp", "running").await;
        assert_eq!(
            k.nonce,
            d.runner_nonce("xsusp", 1),
            "reattached by its nonce"
        );
        d.sessions();
        d.release("xsusp");
        let theirs = d.runner_log("xsusp", 1).await;
        let (attempt, result) = d.done("xsusp").await;
        d.the_jobs_own_verdict("xsusp", attempt, &result, &theirs);
        assert_eq!(d.lost.len(), 1, "{:?}", d.lost);
        d.end().await;
    }

    /// The hub stops (its queue, links and store) with a keyed job running, and starts again: a new transport resumes
    /// the master the old one left, the queue comes back from `runtime.db`, the runner lists the attempt at its
    /// `hello`. With EDITOR, the editor gives the keys back as it connects; without it, the hub asks for them
    /// (`runners/need-keys`) and the job's log and result wait, then come once the keys are given.
    async fn restart(name: &str, editor: bool) {
        let mut d = Drill::new(name, "r1", "dedicated");
        let v = throwaway();
        let id = format!("x{name}");
        d.link().await;
        d.hold(&v);
        let script = format!("test -n \"${KEY}\" && echo keyed; {PARK}");
        d.submit(d.job(&id, &script, &[KEY]));
        d.parked(&id).await;
        assert_eq!(sent(&d.q, &id), 1);
        let k = d.kept(&id).await;
        // open: `offered` stays its word until the next change of state is written
        assert_eq!(k.len(), 1, "{k:?}");
        assert!(
            ["offered", "running"].contains(&k[0].state.as_str()),
            "{k:?}"
        );
        d.sessions();
        // the hub stops: its link ends, its queue goes, its store shuts; the transport leaves the master for the next
        d.unlink().await;
        d.q.flush().await;
        let store = d.store.take().unwrap();
        tokio::task::spawn_blocking(move || store.shutdown())
            .await
            .unwrap();
        let masters = d.masters();
        d.t = Arc::new(OpensshTransport::new(d.dir.path().join("run")));
        // the hub starts again on the same folders
        let (store, db) = runtime_db::open(&d.dir.path().join("hub")).unwrap();
        let (jobs, attempts) = rq::stored(&db).await;
        assert!(
            jobs.iter().any(|j| j.submit.id == id && j.attempt == 1),
            "the job kept: {jobs:?}"
        );
        let (q, events) = Drill::queue(d.dir.path(), &d.hub, db.clone());
        let to = d.told.clone();
        q.keys()
            .set_tell(move |e, data| to.lock().unwrap().push((e.to_string(), data)));
        q.restore(jobs, attempts, d.now());
        (d.q, d.events, d.store, d.db) = (q, events, Some(store), db);
        if editor {
            d.hold(&v);
        }
        d.link().await;
        assert_eq!(d.masters(), masters, "the master the old hub left");
        let k = d.kept_as(&id, "running").await;
        assert_eq!(k.nonce, d.runner_nonce(&id, 1), "reattached by its nonce");
        d.sessions();
        let held = d.hub_log(&id);
        d.release(&id);
        let theirs = d.runner_log(&id, 1).await;
        if !editor {
            // the job's log and result wait for its keys, and the user is asked for them
            let told = d.told.clone();
            d.drive("the hub asks for the keys", |_, _, _| {
                told.lock()
                    .unwrap()
                    .iter()
                    .any(|(e, data)| e == "runners/need-keys" && data == &json!({"names": [KEY]}))
                    .then_some(())
            })
            .await;
            assert!(d.outcomes.is_empty(), "{:?}", d.outcomes);
            assert_eq!(d.hub_log(&id), held, "the log waits for the keys");
            d.hold(&v);
        }
        let (attempt, result) = d.done(&id).await;
        d.the_jobs_own_verdict(&id, attempt, &result, &theirs);
        assert_eq!(sent(&d.q, &id), 0, "no key was sent again");
        assert!(d.lost.is_empty(), "{:?}", d.lost);
        d.no_key_bytes(&v);
        d.end().await;
    }

    /// [C] A dev-hub restart while a keyed job runs, the editor connected: it gives the keys back at once.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "fleet"]
    async fn dev_hub_restart() {
        restart("restart", true).await;
    }

    /// [C] A dev-hub restart while a keyed job runs, with no editor: "needs your keys", and the job's log and verdict
    /// wait for them.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "fleet"]
    async fn dev_hub_restart_without_the_editor() {
        restart("restartne", false).await;
    }

    /// [C] Four jobs at once on one runner (`fleet.sh up --max-sessions 3`, the cap Tailscale SSH sets): they all run
    /// over the one link's three sessions, a round trip rides the control channel with all three taken, and every
    /// job ends with its own verdict.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "fleet"]
    async fn max_sessions_3() {
        let mut d = Drill::new("maxs", "r1", "dedicated");
        d.link().await;
        let ids = ["xmax1", "xmax2", "xmax3", "xmax4"];
        for id in ids {
            d.submit(d.job(id, PARK, &[]));
        }
        for id in ids {
            d.parked(id).await;
        }
        assert_eq!(d.q.runner_jobs("r1"), 4);
        assert_eq!(d.sessions(), 3, "the link's three sessions");
        d.t.round_trip("r1")
            .await
            .expect("a round trip with the three sessions taken");
        let mut theirs = vec![];
        for id in ids {
            d.release(id);
            theirs.push(d.runner_log(id, 1).await);
        }
        for (id, log) in ids.iter().zip(theirs) {
            let (attempt, result) = d.done(id).await;
            d.the_jobs_own_verdict(id, attempt, &result, &log);
        }
        assert!(d.lost.is_empty(), "{:?}", d.lost);
        d.end().await;
    }

    /// [C] The runner's disk falls below its floor during a job (its folder's figures, as a test build reads them):
    /// the job's helper stops it with `infra: disk`, the guard's verdict, never `red`; the link stays up.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "fleet"]
    async fn disk_full_during_a_job() {
        let mut d = Drill::new("disk", "r1", "dedicated");
        d.link().await;
        d.submit(d.job(
            "xdisk",
            "echo parked; while :; do echo grows; sleep 1; done",
            &[],
        ));
        d.parked("xdisk").await;
        let full = QUIET_MACHINE.replace("\"disk_free_gb\": 100", "\"disk_free_gb\": 5");
        sh(
            "r1",
            &format!("printf %s '{full}' > {}/test-machine.json", d.root),
        );
        let (attempt, result) = d.done("xdisk").await;
        assert_eq!(
            (attempt, &result["verdict"]),
            (1, &json!({"Infra": forseti::classify::infra::DISK})),
            "{result}"
        );
        assert!(d.lost.is_empty(), "{:?}", d.lost);
        d.sessions();
        assert!(d.sessions_max <= 3);
        d.end().await;
    }

    /// [C] The runner's memory falls into danger during a job on a `workstation` runner (its folder's figures): its
    /// ladder kills our newest job, `infra: killed`, never `red`; the link stays up.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "fleet"]
    async fn ladder_kill_is_infra_not_red() {
        let mut d = Drill::new("ladder", "r1", "workstation");
        d.link().await;
        d.submit(d.job(
            "xladder",
            "echo parked; mkfifo /tmp/gate; read x < /tmp/gate",
            &[],
        ));
        d.parked("xladder").await;
        let danger =
            QUIET_MACHINE.replace("\"mem_available_mib\": 8192", "\"mem_available_mib\": 512");
        sh(
            "r1",
            &format!("printf %s '{danger}' > {}/test-machine.json", d.root),
        );
        let (attempt, result) = d.done("xladder").await;
        assert_eq!(
            (attempt, &result["verdict"]),
            (1, &json!({"Infra": forseti::classify::infra::KILLED})),
            "{result}"
        );
        assert!(d.lost.is_empty(), "{:?}", d.lost);
        d.sessions();
        assert!(d.sessions_max <= 3);
        d.end().await;
    }

    /// [C] The runner's host key changes while a job runs there: its connection ends (the hub hears the channel end),
    /// and every new dial is refused as a changed host key, never accepted; the attempt stays detached. Once the user
    /// has checked and accepted the key at a terminal, the hub dials again and the job reattaches.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "fleet"]
    async fn host_key_change_needs_login() {
        let mut d = Drill::new("hostkey", "r1", "dedicated");
        d.link().await;
        d.submit(d.job("xhost", PARK, &[]));
        d.parked("xhost").await;
        d.sessions();
        let known = d.dir.path().join("known_hosts");
        let good = std::fs::read_to_string(&known).unwrap();
        let other = d.dir.path().join("other");
        let made = Command::new("ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", ""])
            .arg("-f")
            .arg(&other)
            .status()
            .unwrap();
        assert!(made.success());
        let key = std::fs::read_to_string(other.with_extension("pub")).unwrap();
        let key: Vec<&str> = key.split_whitespace().take(2).collect();
        let changed: String = good
            .lines()
            .map(|l| match l.split_whitespace().next() {
                Some(h) if h.split(',').any(|h| h == "r1") => format!("r1 {}\n", key.join(" ")),
                _ => format!("{l}\n"),
            })
            .collect();
        // the runner's connection ends under the link
        let (_, sshd) = d.the_serve();
        sh("r1", &format!("kill -KILL {sshd}"));
        let why = d
            .drive("the link lost", |_, _, lost| lost.first().cloned())
            .await;
        assert!(why.contains("without bye"), "{why}");
        d.serve_gone().await;
        if let Some(s) = d.q.session("r1") {
            s.close().await;
        }
        // the runner comes back with another host key (here: the hub's known key no longer matches it; this row's own
        // ssh, which shares the known hosts, waits until the key is accepted again)
        std::fs::write(&known, &changed).unwrap();
        match d.open().await {
            Err(LinkError::HostKeyChanged) => {}
            Err(e) => panic!("{e}"),
            Ok(_) => panic!("a changed host key was accepted"),
        }
        assert_eq!(
            std::fs::read_to_string(&known).unwrap(),
            changed,
            "never accepted"
        );
        let k = d.kept("xhost").await;
        assert_eq!((k.len(), k[0].state.as_str()), (1, "detached"), "{k:?}");
        // the user logs in and accepts the runner's key
        std::fs::write(&known, &good).unwrap();
        d.relink().await;
        let k = d.kept_as("xhost", "running").await;
        assert_eq!(
            k.nonce,
            d.runner_nonce("xhost", 1),
            "reattached by its nonce"
        );
        d.release("xhost");
        let theirs = d.runner_log("xhost", 1).await;
        let (attempt, result) = d.done("xhost").await;
        d.the_jobs_own_verdict("xhost", attempt, &result, &theirs);
        assert_eq!(d.lost.len(), 1, "{:?}", d.lost);
        d.end().await;
    }

    /// The wall time of SET jobs (each a few seconds of the shell's own work) over RUNNERS, from the first submit to
    /// the last verdict, read on CLOCK.
    async fn set_wall(
        name: &str,
        runners: &[&str],
        set: usize,
        clock: &dyn Fn() -> std::time::Instant,
    ) -> std::time::Duration {
        let mut d = Drill::new(name, runners[0], "dedicated");
        d.link().await;
        let mut more = vec![];
        for r in &runners[1..] {
            let root = root(r, &format!("dr-{name}"));
            let mut c = d.cfg();
            c.name = r.to_string();
            c.host = r.to_string();
            for w in c.remote.control.iter_mut() {
                *w = w.replace(&d.root, &root);
            }
            let channels = d.t.open(&c).await.expect("the second runner opens");
            let s = Session::start(r, channels, d.q.route(), d.q.link_events());
            d.q.add_runner(
                RemoteRunner {
                    name: r.to_string(),
                    trust: RunnerTrust::Mine,
                    accept: forseti::Accept::All,
                    grace_s: 600,
                    image: Some(d.img.clone()),
                },
                s,
            );
            more.push((r.to_string(), root));
        }
        let names: Vec<String> = runners.iter().map(|r| r.to_string()).collect();
        d.drive("every runner ready", |q, _, _| {
            names
                .iter()
                .all(|n| q.runner(n).is_some_and(|r| r.state == "ready"))
                .then_some(())
        })
        .await;
        let work = "i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done; echo done";
        let start = clock();
        for i in 0..set {
            d.submit(d.job(&format!("xset{i}"), work, &[]));
        }
        d.drive("every verdict", |_, o, _| {
            (o.iter()
                .filter(
                    |o| matches!(o, Outcome::Done { result, .. } if result["verdict"] == "Pass"),
                )
                .count()
                == set)
                .then_some(())
        })
        .await;
        let wall = clock() - start;
        for (r, _) in &more {
            if let Some(s) = d.q.session(r) {
                s.close().await;
            }
            d.t.stop(r).await;
        }
        d.end().await;
        wall
    }

    /// A 40-job set spreads over a fleet of two within 0.6 × the same set's wall on one runner of that fleet, in
    /// the same run (so the bound needs no wall-clock constant).
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "timing: fleet throughput"]
    async fn a_set_spreads_over_two_runners_within_its_bound() {
        let clock = std::time::Instant::now;
        let one = set_wall("set1", &["r1"], 40, &clock).await;
        let two = set_wall("set2", &["r1", "r2"], 40, &clock).await;
        assert!(
            two.as_secs_f64() <= 0.6 * one.as_secs_f64(),
            "two runners took {two:?}, one took {one:?}"
        );
    }
}
