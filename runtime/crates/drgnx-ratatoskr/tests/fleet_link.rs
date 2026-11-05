//! The transport's fleet rows (`#[ignore = "fleet"]`): the hub's `OpensshTransport` reaches a fake runner over real
//! SSH (test/runners/). They run only in a fleet's harness container, never on a developer's machine: each row
//! writes the harness's own `~/.ssh/config` (ssh reads `~` from the password database, not `$HOME`), and refuses to
//! start anywhere else.
//!
//! ```text
//! cargo test -p drgnx-ratatoskr --test fleet_link --no-run
//! L=$PWD/test/runners/link
//! DRGNX_FLEET_RUNNER_OPTS="-v $L/sshd-agent-forwarding.conf:/etc/ssh/sshd_config.d/05-link.conf:ro" \
//!   fleet.sh up --runners 1 --max-sessions 3
//! DRGNX_FLEET_TEST_BIN=<binary> fleet.sh test --test-threads=1 --skip needs_login_from_a_forcecommand_banner
//! fleet.sh down
//! DRGNX_FLEET_RUNNER_OPTS="-v $L/sshd-tailscale-check.conf:/etc/ssh/sshd_config.d/05-link.conf:ro" \
//!   fleet.sh up --runners 1
//! DRGNX_FLEET_TEST_BIN=<binary> fleet.sh test --exact transport::needs_login_from_a_forcecommand_banner
//! ```

use drgnx_ratatoskr::runners::ssh_config as generated;
use drgnx_ratatoskr::runners::transport::{
    LinkError, Login, OpensshTransport, Transport, effective,
};
use drgnx_ratatoskr::runners::{Remote, RunnerCfg};
use std::ffi::{CStr, OsStr};
use std::io::{BufRead, Read};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWriteExt, BufReader};

/// Every read waits at most this long: it only bounds a failure.
const READ_BOUND: Duration = Duration::from_secs(90);

/// The harness's own home, from the password database: what ssh expands `~` to.
fn passwd_home() -> PathBuf {
    // SAFETY: the rows run one at a time; the entry is copied out before anything else reads the database
    unsafe {
        let pw = libc::getpwuid(libc::getuid());
        assert!(!pw.is_null(), "no password entry");
        PathBuf::from(OsStr::from_bytes(CStr::from_ptr((*pw).pw_dir).to_bytes()))
    }
}

/// One row's setup: the user's ssh config (EXTRA first, then the fleet's hosts) and a runtime dir of its own.
struct Harness {
    user_config: PathBuf,
    tmp: tempfile::TempDir,
}

impl Harness {
    fn new(extra: &str) -> Harness {
        let home = PathBuf::from(std::env::var("HOME").unwrap());
        assert!(
            Path::new("/run/.containerenv").exists() && home.to_string_lossy().contains("/fleet/"),
            "the fleet rows run only in a fleet's harness container (fleet.sh test)"
        );
        let pw = passwd_home();
        assert_eq!(pw, Path::new("/root"), "the harness runs as its own root");
        let base = std::fs::read_to_string(home.join(".ssh/config")).unwrap();
        let ssh = pw.join(".ssh");
        std::fs::create_dir_all(&ssh).unwrap();
        let user_config = ssh.join("config");
        std::fs::write(&user_config, format!("{extra}\n{base}")).unwrap();
        Harness {
            user_config,
            tmp: tempfile::tempdir().unwrap(),
        }
    }

    fn runtime(&self) -> &Path {
        self.tmp.path()
    }

    /// The user's own ssh to r1 with the same user config and none of the hub's options.
    fn plain_ssh(&self, args: &[&str]) -> Command {
        let mut c = Command::new("ssh");
        c.arg("-F").arg(&self.user_config).arg("r1").args(args);
        c.stdin(Stdio::null());
        c
    }

    /// The master folders the transport made in r1's folder.
    fn masters(&self) -> Vec<String> {
        let mut v: Vec<String> = std::fs::read_dir(generated::dir(self.runtime(), "r1"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n.starts_with(".ssh-connection"))
            .collect();
        v.sort();
        v
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.user_config);
    }
}

fn argv(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| w.to_string()).collect()
}

fn runner(control: &[&str], bulk_in: &[&str], bulk_out: &[&str]) -> RunnerCfg {
    RunnerCfg {
        name: "r1".into(),
        host: "r1".into(),
        linger: true,
        cloud: None,
        remote: Remote {
            control: argv(control),
            bulk_in: argv(bulk_in),
            bulk_out: argv(bulk_out),
        },
    }
}

const READY_CAT: [&str; 3] = ["sh", "-c", "echo ready; exec cat"];

/// The next line on R, without its newline.
async fn line<R: AsyncBufRead + Unpin>(r: &mut R) -> String {
    let mut s = String::new();
    let n = tokio::time::timeout(READ_BOUND, r.read_line(&mut s))
        .await
        .expect("a line within the bound")
        .unwrap();
    assert!(n > 0, "the session ended");
    s.trim_end_matches('\n').to_string()
}

mod ssh_config {
    use super::*;

    // [C] a real ssh into a fake runner whose sshd allows forwarding; the remote command reports its environment
    #[tokio::test]
    #[ignore = "fleet"]
    async fn no_ssh_auth_sock_on_a_runner_that_allows_forwarding() {
        let h = Harness::new("Host r1\n  ForwardAgent yes\n");
        let sock = h.runtime().join("agent.sock");
        let mut agent = Command::new("ssh-agent")
            .arg("-D")
            .arg("-a")
            .arg(&sock)
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        skuld::wait_until("the agent's socket", 30, || sock.exists().then_some(()));

        // the user's own ssh with the same config forwards it: the runner and the config both allow forwarding
        let out = h
            .plain_ssh(&["echo sock=${SSH_AUTH_SOCK:-}"])
            .env("SSH_AUTH_SOCK", &sock)
            .output()
            .unwrap();
        let said = String::from_utf8_lossy(&out.stdout);
        assert!(
            said.starts_with("sock=/"),
            "the control forwards: {said:?} {out:?}"
        );

        // the hub's master, with the same agent in its environment, forwards nothing
        // SAFETY: the fleet rows run with --test-threads=1, and nothing else reads the environment meanwhile
        unsafe { std::env::set_var("SSH_AUTH_SOCK", &sock) };
        let t = OpensshTransport::new(h.runtime());
        let r = runner(
            &["sh", "-c", "echo sock=${SSH_AUTH_SOCK:-}"],
            &["cat"],
            &["cat"],
        );
        let mut ch = t.open(&r).await.unwrap();
        let mut rx = BufReader::new(&mut ch.control.rx);
        assert_eq!(line(&mut rx).await, "sock=");
        let eff = effective(&generated::path(h.runtime(), "r1"), "r1")
            .await
            .unwrap();
        assert!(!eff.forward_agent, "{eff:?}");
        drop(rx);
        drop(ch);
        t.stop("r1").await;
        unsafe { std::env::remove_var("SSH_AUTH_SOCK") };
        agent.kill().unwrap();
        agent.wait().unwrap();
    }

    // [C] a real ssh; the user's config names a remote command, a terminal and a local command
    #[tokio::test]
    #[ignore = "fleet"]
    async fn a_remote_command_in_the_users_config_is_overridden() {
        let marker = tempfile::tempdir().unwrap();
        let ran = marker.path().join("local-command-ran");
        let h = Harness::new(&format!(
            "Host r1\n  RemoteCommand echo hijacked\n  RequestTTY force\n  PermitLocalCommand yes\n  \
             LocalCommand touch {}\n",
            ran.display()
        ));
        // the user's own ssh runs their command, on a terminal, and their local command
        let out = h.plain_ssh(&[]).output().unwrap();
        assert!(
            String::from_utf8_lossy(&out.stdout).contains("hijacked"),
            "the control runs the user's command: {out:?}"
        );
        assert!(ran.exists(), "the control runs the user's local command");
        std::fs::remove_file(&ran).unwrap();

        let t = OpensshTransport::new(h.runtime());
        let r = runner(
            &[
                "sh",
                "-c",
                "if [ -t 0 ] || [ -t 1 ]; then echo tty; else echo notty; fi; echo ours",
            ],
            &["cat"],
            &["cat"],
        );
        let mut ch = t.open(&r).await.unwrap();
        let mut rx = BufReader::new(&mut ch.control.rx);
        assert_eq!(line(&mut rx).await, "notty");
        assert_eq!(line(&mut rx).await, "ours");
        // a local command runs while the master connects, long before its sessions answer
        assert!(!ran.exists(), "the hub's master never runs a local command");
        drop(rx);
        drop(ch);
        t.stop("r1").await;
    }

    // [C] a real ssh; the user's config forwards a local port to the runner's sshd
    #[tokio::test]
    #[ignore = "fleet"]
    async fn local_forwards_in_the_users_config_never_open() {
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let h = Harness::new(&format!(
            "Host r1\n  LocalForward 127.0.0.1:{port} 127.0.0.1:22\n"
        ));
        // the user's own ssh opens the forward before its session starts
        let mut plain = h.plain_ssh(&["echo ready; exec cat"]);
        let mut child = plain
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut out = std::io::BufReader::new(child.stdout.take().unwrap());
        let mut s = String::new();
        out.read_line(&mut s).unwrap();
        assert_eq!(s, "ready\n");
        let mut banner = [0u8; 4];
        std::net::TcpStream::connect(("127.0.0.1", port))
            .expect("the control's forward listens")
            .read_exact(&mut banner)
            .unwrap();
        assert_eq!(&banner, b"SSH-");
        drop(child.stdin.take());
        child.wait().unwrap();

        let t = OpensshTransport::new(h.runtime());
        let mut ch = t
            .open(&runner(&READY_CAT, &["cat"], &["cat"]))
            .await
            .unwrap();
        let mut rx = BufReader::new(&mut ch.control.rx);
        assert_eq!(line(&mut rx).await, "ready");
        let e = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap_err();
        assert_eq!(e.kind(), std::io::ErrorKind::ConnectionRefused, "{e}");
        let eff = effective(&generated::path(h.runtime(), "r1"), "r1")
            .await
            .unwrap();
        assert!(eff.forwards.is_empty(), "{eff:?}");
        drop(rx);
        drop(ch);
        t.stop("r1").await;
    }
}

mod transport {
    use super::*;
    use std::sync::Arc;

    // [C] a real master; a session on it is used across the replacement
    #[tokio::test]
    #[ignore = "fleet"]
    async fn never_sends_o_exit() {
        let h = Harness::new("");
        let t = OpensshTransport::new(h.runtime());
        let mut ch = t
            .open(&runner(&READY_CAT, &["cat"], &["cat"]))
            .await
            .unwrap();
        let tx = &mut ch.control.tx;
        let mut rx = BufReader::new(&mut ch.control.rx);
        assert_eq!(line(&mut rx).await, "ready");
        let before = h.masters();
        assert_eq!(before.len(), 1, "{before:?}");

        t.replace_master("r1").await.unwrap();
        let after = h.masters();
        assert_eq!(
            after.len(),
            1,
            "the old master's folder went, a new one came: {after:?}"
        );
        assert_ne!(before, after);
        // the old master only stopped listening: its session still answers
        tx.write_all(b"still here\n").await.unwrap();
        tx.flush().await.unwrap();
        assert_eq!(line(&mut rx).await, "still here");

        drop(rx);
        drop(ch);
        t.round_trip("r1").await.expect("the new master answers");
        t.stop("r1").await;
    }

    // [C] a real runner whose sshd allows 3 sessions per connection (fleet.sh up --max-sessions 3)
    #[tokio::test]
    #[ignore = "fleet"]
    async fn at_most_3_sessions() {
        let h = Harness::new("");
        let t = Arc::new(OpensshTransport::new(h.runtime()));
        let r = runner(&READY_CAT, &READY_CAT, &READY_CAT);
        let mut ch = t.open(&r).await.unwrap();
        let tx = &mut ch.control.tx;
        let mut rx = BufReader::new(&mut ch.control.rx);
        let mut rx2 = BufReader::new(&mut ch.bulk_in.rx);
        let mut rx3 = BufReader::new(&mut ch.bulk_out.rx);
        assert_eq!(line(&mut rx).await, "ready");
        assert_eq!(line(&mut rx2).await, "ready");
        assert_eq!(line(&mut rx3).await, "ready");
        assert!(
            matches!(t.open(&r).await, Err(LinkError::Refused(_))),
            "a second open while the three are open"
        );
        // with all three open, the round trip rides the control channel: a fourth session would be refused by sshd.
        // Lines go back and forth on it until the round trip has seen one; each is a real trip to the runner.
        let t2 = t.clone();
        let rt = tokio::spawn(async move { t2.round_trip("r1").await });
        let mut n = 0u32;
        while !rt.is_finished() {
            n += 1;
            assert!(
                n < 1000,
                "the round trip never saw the control channel's bytes"
            );
            tx.write_all(format!("p{n}\n").as_bytes()).await.unwrap();
            tx.flush().await.unwrap();
            assert_eq!(line(&mut rx).await, format!("p{n}"));
        }
        rt.await
            .unwrap()
            .expect("a round trip with three sessions open");
        drop((rx, rx2, rx3));
        drop(ch);
        t.stop("r1").await;
    }

    // [C] a real runner that answers every session with Tailscale's banner (sshd-tailscale-check.conf)
    #[tokio::test]
    #[ignore = "fleet"]
    async fn needs_login_from_a_forcecommand_banner() {
        let h = Harness::new("");
        let t = OpensshTransport::new(h.runtime());
        let want = LinkError::NeedsLogin(Login::TailscaleCheck {
            url: Some("https://login.example.invalid/a/0123abcd".into()),
        });
        match t.open(&runner(&["cat"], &["cat"], &["cat"])).await {
            Err(e) => assert_eq!(e, want),
            Ok(_) => panic!("opened past the banner"),
        }
        assert_eq!(t.round_trip("r1").await, Err(want));
        t.stop("r1").await;
    }

    /// The pid of the sshd process that serves this session's connection: the first `sshd*` above the shell.
    const SSHD_PID: &str = "p=$$; while [ \"$p\" -gt 1 ]; do \
                            case $(cat /proc/$p/comm) in sshd*) echo $p; exec cat;; esac; \
                            q=1; while read -r k v; do [ \"$k\" = PPid: ] && q=$v; done < /proc/$p/status; \
                            p=$q; done; echo none";

    // [C] a real master whose link is cut by stopping the runner's sshd for its connection (the harness has no
    // podman to disconnect a network with); the stop is confirmed over a connection of its own
    #[tokio::test]
    #[ignore = "fleet"]
    async fn a_dead_link_fails_the_round_trip_though_o_check_passes() {
        let h = Harness::new("");
        let t = OpensshTransport::new(h.runtime());
        let mut ch = t
            .open(&runner(&["cat"], &["cat"], &["sh", "-c", SSHD_PID]))
            .await
            .unwrap();
        let mut rx = BufReader::new(&mut ch.bulk_out.rx);
        let pid = line(&mut rx).await;
        assert!(pid.parse::<u32>().is_ok(), "the session's sshd: {pid}");
        let stop = h.plain_ssh(&["kill", "-STOP", &pid]).status().unwrap();
        assert!(stop.success(), "the runner's sshd for the master stopped");

        t.check_master("r1")
            .await
            .expect("-O check asks only the local socket, and passes");
        drop(rx);
        drop(ch);
        assert_eq!(t.round_trip("r1").await, Err(LinkError::Lost));

        let cont = h.plain_ssh(&["kill", "-CONT", &pid]).status().unwrap();
        assert!(cont.success());
        t.stop("r1").await;
    }
}
