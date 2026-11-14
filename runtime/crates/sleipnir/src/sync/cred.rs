//! The origin's credential on a runner (docs/develop/sleipnir.md, "Sync"): a read-only token or deploy key the user
//! named for the project, held only in memory and served to one fetch.
//!
//! - A token (HTTPS) is served on a socket in `<root>/run/` (mode 0700) for the fetch's life. Git asks for it through
//!   `sleipnir credential-helper SOCKET get`, which reads it from the socket and prints it to git's pipe.
//! - A deploy key (SSH) is added on stdin to a per-fetch `ssh-agent` (with a 600 s lifetime besides), which is killed
//!   after the fetch.

use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::thread::JoinHandle;

use secrecy::{ExposeSecret, SecretString};

use super::{Result, refused};

/// The origin's credential. It has no `Debug`, `Clone` or `Serialize`.
pub enum OriginCred {
    /// A token git sends as the HTTPS password.
    Https(SecretString),
    /// An OpenSSH private key.
    SshKey(SecretString),
}

/// A credential being served to one fetch: the `-c` options and environment git needs. Dropping it ends the
/// serving (the socket's thread stops, the agent is killed) and removes the socket.
pub(crate) struct Served {
    pub args: Vec<String>,
    pub env: Vec<(&'static str, PathBuf)>,
    end: End,
}

enum End {
    Socket {
        sock: PathBuf,
        stop: Arc<AtomicBool>,
        thread: Option<JoinHandle<()>>,
    },
    Agent {
        sock: PathBuf,
        pid: String,
    },
}

static NEXT: AtomicU64 = AtomicU64::new(0);

/// `p` single-quoted for the shell git runs a helper or `core.sshCommand` with.
fn quoted(p: &Path) -> Result<String> {
    match p.to_str() {
        Some(s) if !s.contains(['\'', '\n']) => Ok(format!("'{s}'")),
        _ => Err(refused(
            p.as_os_str().as_bytes(),
            "a path git's shell can't quote",
        )),
    }
}

/// Starts serving `cred` under the runner folder `root`; `helper` is the `sleipnir` binary git runs.
pub(crate) fn serve(root: &Path, cred: &OriginCred, helper: &Path) -> Result<Served> {
    let dir = root.join("run");
    fs::create_dir_all(&dir)?;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    let pid = std::process::id();
    match cred {
        OriginCred::Https(token) => {
            if token.expose_secret().contains(['\n', '\0']) {
                return Err(refused(b"the origin token", "a newline or NUL in it"));
            }
            let sock = dir.join(format!("cred-{pid}-{n}.sock"));
            let arg = format!(
                "credential.helper=!{} credential-helper {}",
                quoted(helper)?,
                quoted(&sock)?
            );
            remove_if_there(&sock)?;
            let l = UnixListener::bind(&sock)?;
            fs::set_permissions(&sock, fs::Permissions::from_mode(0o600))?;
            let stop = Arc::new(AtomicBool::new(false));
            let token = SecretString::from(token.expose_secret().to_owned());
            let st = stop.clone();
            let thread = std::thread::spawn(move || {
                for s in l.incoming() {
                    if st.load(Ordering::SeqCst) {
                        break;
                    }
                    if let Ok(mut s) = s {
                        let _ = s.write_all(token.expose_secret().as_bytes());
                    }
                }
            });
            Ok(Served {
                args: vec!["-c".into(), arg],
                env: vec![],
                end: End::Socket {
                    sock,
                    stop,
                    thread: Some(thread),
                },
            })
        }
        OriginCred::SshKey(key) => {
            let sock = dir.join(format!("agent-{pid}-{n}.sock"));
            let ssh = format!(
                "core.sshCommand=ssh -o IdentityAgent={} -o BatchMode=yes",
                quoted(&sock)?
            );
            remove_if_there(&sock)?;
            // ssh-agent forks once its socket listens, and its parent prints the agent's pid and exits: that exit
            // is the handshake
            let out = Command::new("ssh-agent")
                .args(["-s", "-t", "600", "-a"])
                .arg(&sock)
                .stdin(Stdio::null())
                .output()?;
            let text = String::from_utf8_lossy(&out.stdout);
            let agent = text
                .split("SSH_AGENT_PID=")
                .nth(1)
                .and_then(|r| r.split(';').next())
                .filter(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()));
            let Some(agent) = agent.filter(|_| out.status.success()) else {
                return Err(io::Error::other(format!(
                    "ssh-agent: {}",
                    String::from_utf8_lossy(&out.stderr).trim()
                ))
                .into());
            };
            // from here a failure kills the agent: the drop
            let served = Served {
                args: vec!["-c".into(), ssh],
                env: vec![("SSH_AUTH_SOCK", sock.clone())],
                end: End::Agent {
                    sock: sock.clone(),
                    pid: agent.to_string(),
                },
            };
            let mut add = Command::new("ssh-add")
                .args(["-q", "-"])
                .env("SSH_AUTH_SOCK", &sock)
                .env("SSH_ASKPASS_REQUIRE", "never")
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::piped())
                .spawn()?;
            {
                let mut pipe = add.stdin.take().expect("piped");
                let k = key.expose_secret();
                pipe.write_all(k.as_bytes())?;
                if !k.ends_with('\n') {
                    pipe.write_all(b"\n")?;
                }
            }
            let out = add.wait_with_output()?;
            if !out.status.success() {
                return Err(io::Error::other(format!(
                    "ssh-add: {}",
                    String::from_utf8_lossy(&out.stderr).trim()
                ))
                .into());
            }
            Ok(served)
        }
    }
}

impl Drop for Served {
    fn drop(&mut self) {
        match &mut self.end {
            End::Socket { sock, stop, thread } => {
                stop.store(true, Ordering::SeqCst);
                // wakes the accept, which then sees the stop
                let _ = UnixStream::connect(&*sock);
                if let Some(t) = thread.take() {
                    let _ = t.join();
                }
                let _ = fs::remove_file(&*sock);
            }
            End::Agent { sock, pid } => {
                let _ = Command::new("ssh-agent")
                    .arg("-k")
                    .env("SSH_AGENT_PID", &*pid)
                    .env("SSH_AUTH_SOCK", &*sock)
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status();
                let _ = fs::remove_file(&*sock);
            }
        }
    }
}

fn remove_if_there(p: &Path) -> io::Result<()> {
    match fs::remove_file(p) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

/// `sleipnir credential-helper SOCKET OP`: for `get`, the token from SOCKET as git's password; any other operation
/// (`store`, `erase`) does nothing. Git's request on stdin is read whole first.
pub fn helper(sock: &Path, op: &str) -> io::Result<()> {
    io::copy(&mut io::stdin().lock(), &mut io::sink())?;
    if op != "get" {
        return Ok(());
    }
    let mut token = Vec::new();
    UnixStream::connect(sock)?.read_to_end(&mut token)?;
    let mut msg = b"username=x-access-token\npassword=".to_vec();
    msg.extend_from_slice(&token);
    msg.push(b'\n');
    token.fill(0);
    std::hint::black_box(&token);
    let mut out = io::stdout().lock();
    let r = out.write_all(&msg).and_then(|()| out.flush());
    msg.fill(0);
    std::hint::black_box(&msg);
    r
}
