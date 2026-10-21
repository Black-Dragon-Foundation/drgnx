//! The fixture: a HOME, a runtime dir and a data dir under `/tmp/glp-XXXXXX/`, random canaries, listeners that
//! record connections (Task 14).
//!
//! Nothing here reaches the real home, the user's sockets, D-Bus or a display: the environment the harness builds
//! points every variable into the fixture. Each row gets fixtures of its own (one for the control run, one for the
//! sandboxed run), so a probe that moves or creates things in one cannot disturb the other.
//!
//! Layout under the root (the paths rows write with placeholders):
//!
//! | | |
//! |---|---|
//! | `home/` (`${HOME}`) | `.ssh/id_canary`, `other-repo/secret`, `canary-dir/canary.txt` (`${CANARY_DIR}`) |
//! | `run/` (`${RUNTIME}`) | `drgnx/hub-0000.sock`, `emacs/server`, `bus`, `ssh-agent.sock`; `drgnx/s/S1` is `${RUN}`, holding `proxy.sock` and `gateway.sock` |
//! | `data/` (`${DATA}`) | `work.db` |
//! | `tasks/t1`, `tasks/t2` | `${TASK}`, `${TASK2}` (`t2/canary`) |
//! | `w/` | `${W}`, an empty work dir; `t/` is `${TMP}` |
//! | `bin/` | a copy of the probe, bound read-only into the sandbox |

use gleipnir::net::host::parse_target;
use gleipnir::net::proxy::{self, Listener, ProxyConfig, ProxyEvent, SystemResolver};
use std::collections::HashMap;
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

/// 24 random hex digits from the kernel.
pub fn random_hex() -> String {
    use std::io::Read;
    let mut b = [0u8; 12];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut b))
        .expect("/dev/urandom");
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// A secret that must never appear in any output.
#[derive(Debug, Clone)]
pub struct Canary {
    pub name: &'static str,
    pub text: String,
}

/// The addresses of the listeners.
#[derive(Debug, Clone)]
pub struct Addrs {
    pub tcp_lo: SocketAddr,
    pub tcp_nl: Option<SocketAddr>,
    pub udp_lo: SocketAddr,
    pub udp_nl: Option<SocketAddr>,
    pub upstream: SocketAddr,
    pub proxy_tcp: SocketAddr,
    pub abstract_name: String,
}

pub struct Fixture {
    pub root: PathBuf,
    pub canaries: Vec<Canary>,
    pub addrs: Addrs,
    counts: HashMap<&'static str, Arc<AtomicUsize>>,
    events: Arc<Mutex<Vec<String>>>,
    rt: Option<tokio::runtime::Runtime>,
    _proxy: proxy::ProxyHandle,
    pub sleep: Option<Child>,
    /// Directories made as root (`/var/lib/glp-XXXXXX`), removed with `sudo -n` when they are not ours.
    pub root_dirs: Vec<PathBuf>,
    users_shared: Option<PathBuf>,
}

fn write(path: &Path, text: &str) -> io::Result<()> {
    if let Some(p) = path.parent() {
        std::fs::create_dir_all(p)?;
    }
    std::fs::write(path, text)
}

impl Fixture {
    pub fn new() -> io::Result<Fixture> {
        let dir = tempfile::Builder::new().prefix("glp-").tempdir_in("/tmp")?;
        let root = dir.keep().canonicalize()?;
        let p = |rel: &str| root.join(rel);
        let mut canaries = Vec::new();
        let mut canary = |name: &'static str| -> String {
            let text = format!("glp-canary-{}", random_hex());
            canaries.push(Canary {
                name,
                text: text.clone(),
            });
            text
        };
        write(&p("home/.ssh/id_canary"), &canary("ssh-key"))?;
        write(&p("home/other-repo/secret"), &canary("other-repo"))?;
        write(&p("home/canary-dir/canary.txt"), &canary("canary-dir"))?;
        write(&p("data/work.db"), &canary("work-db"))?;
        write(&p("tasks/t2/canary"), &canary("task2"))?;
        for d in [
            "tasks/t1",
            "w",
            "t",
            "bin",
            "config",
            "run/drgnx/s/S1",
            "run/emacs",
        ] {
            std::fs::create_dir_all(p(d))?;
        }
        // The API key in the environment the sandbox runs from (`Fixture::env`); a canary like the files.
        canary("api-key");
        let users_shared = if cfg!(target_os = "macos") {
            let d = tempfile::Builder::new()
                .prefix("glp-")
                .tempdir_in("/Users/Shared")?
                .keep();
            write(&d.join("canary"), &canary("users-shared"))?;
            Some(d)
        } else {
            None
        };

        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()?;
        let mut counts: HashMap<&'static str, Arc<AtomicUsize>> = HashMap::new();
        let events = Arc::new(Mutex::new(Vec::new()));
        let abstract_name = format!("glp-{}", random_hex());
        let (addrs, handle) = {
            let _g = rt.enter();
            let mut count = |name: &'static str| {
                let c = Arc::new(AtomicUsize::new(0));
                counts.insert(name, c.clone());
                c
            };
            for (name, rel) in [
                ("hub", "run/drgnx/hub-0000.sock"),
                ("emacs", "run/emacs/server"),
                ("bus", "run/bus"),
                ("ssh-agent", "run/ssh-agent.sock"),
                ("gateway", "run/drgnx/s/S1/gateway.sock"),
            ] {
                serve_unix(tokio::net::UnixListener::bind(p(rel))?, count(name));
            }
            serve_unix(abstract_listener(&abstract_name)?, count("abstract"));
            let tcp_lo = serve_tcp(bind_tcp(Ipv4Addr::LOCALHOST.into())?, count("tcp-lo"));
            let upstream = serve_tcp(bind_tcp(Ipv4Addr::LOCALHOST.into())?, count("upstream"));
            let udp_lo = serve_udp(bind_udp(Ipv4Addr::LOCALHOST.into())?, count("udp-lo"));
            let nl = non_loopback();
            let tcp_nl = nl
                .and_then(|ip| bind_tcp(ip).ok())
                .map(|l| serve_tcp(l, count("tcp-nl")));
            let udp_nl = nl
                .and_then(|ip| bind_udp(ip).ok())
                .map(|s| serve_udp(s, count("udp-nl")));

            let (tx, mut rx) = tokio::sync::mpsc::channel(256);
            let cfg = ProxyConfig {
                allow: vec![
                    parse_target(&format!("upstream.test:{}", upstream.port())).expect("target"),
                ],
                pinned: vec![("upstream.test".into(), IpAddr::V4(Ipv4Addr::LOCALHOST))],
                ..ProxyConfig::default()
            };
            let handle = proxy::start(cfg, Arc::new(SystemResolver), tx);
            handle.listen(
                Listener::Unix(tokio::net::UnixListener::bind(p(
                    "run/drgnx/s/S1/proxy.sock",
                ))?),
                1,
            );
            let ptcp = bind_tcp(Ipv4Addr::LOCALHOST.into())?;
            let proxy_tcp = ptcp.local_addr()?;
            handle.listen(Listener::Tcp(tokio::net::TcpListener::from_std(ptcp)?), 2);
            let sink = events.clone();
            tokio::spawn(async move {
                while let Some(e) = rx.recv().await {
                    sink.lock().unwrap().push(match e {
                        ProxyEvent::Denied { target, .. } => format!("Denied {target}"),
                        ProxyEvent::Refused { target, why, .. } => {
                            format!("Refused {why:?} {target}")
                        }
                    });
                }
            });
            (
                Addrs {
                    tcp_lo,
                    tcp_nl,
                    udp_lo,
                    udp_nl,
                    upstream,
                    proxy_tcp,
                    abstract_name,
                },
                handle,
            )
        };
        Ok(Fixture {
            root,
            canaries,
            addrs,
            counts,
            events,
            rt: Some(rt),
            _proxy: handle,
            sleep: None,
            root_dirs: Vec::new(),
            users_shared,
        })
    }

    pub fn path(&self, rel: &str) -> PathBuf {
        self.root.join(rel)
    }

    /// The text of the canary named `name`.
    pub fn canary(&self, name: &str) -> &str {
        &self
            .canaries
            .iter()
            .find(|c| c.name == name)
            .expect("canary")
            .text
    }

    /// The environment `ratatoskr` and a direct (control) probe run under: everything points into the fixture, and
    /// the names a sandbox must not pass on are all set, so a probe that finds none inside proves something.
    /// `HTTPS_PROXY` is the proxy's TCP listener (for the control run of `http-connect`; the sandbox gets its own
    /// from the spec).
    pub fn env(&self, path: &str) -> Vec<(String, String)> {
        let s = |p: PathBuf| p.to_string_lossy().into_owned();
        vec![
            ("HOME".into(), s(self.path("home"))),
            ("XDG_RUNTIME_DIR".into(), s(self.path("run"))),
            ("DRGNX_DATA_DIR".into(), s(self.path("data"))),
            ("DRGNX_CONFIG_DIR".into(), s(self.path("config"))),
            ("SSH_AUTH_SOCK".into(), s(self.path("run/ssh-agent.sock"))),
            (
                "DBUS_SESSION_BUS_ADDRESS".into(),
                format!("unix:path={}", self.path("run/bus").display()),
            ),
            ("DISPLAY".into(), ":99".into()),
            ("WAYLAND_DISPLAY".into(), "wayland-glp".into()),
            (
                "OPENROUTER_API_KEY".into(),
                self.canary("api-key").to_string(),
            ),
            ("PATH".into(), path.into()),
            (
                "HTTPS_PROXY".into(),
                format!("http://{}", self.addrs.proxy_tcp),
            ),
        ]
    }

    /// How many connections (or datagrams) the named listener has seen.
    pub fn seen(&self, listener: &str) -> usize {
        self.counts
            .get(listener)
            .map_or(0, |c| c.load(Ordering::SeqCst))
    }

    /// The proxy's events so far, sorted.
    pub fn proxy_events(&self) -> Vec<String> {
        // Events are sent before the client is answered, so they are in by the time the probe has its answer; a
        // short wait covers the channel hop.
        std::thread::sleep(std::time::Duration::from_millis(100));
        let mut e = self.events.lock().unwrap().clone();
        e.sort();
        e
    }

    /// `${NAME}` for the closed list (`row::PLACEHOLDERS`).
    pub fn value(&self, name: &str) -> Result<String, String> {
        let s = |p: PathBuf| p.to_string_lossy().into_owned();
        let a = &self.addrs;
        Ok(match name {
            "HOME" => s(self.path("home")),
            "RUNTIME" => s(self.path("run")),
            "RUN" => s(self.path("run/drgnx/s/S1")),
            "TASK" => s(self.path("tasks/t1")),
            "TASK2" => s(self.path("tasks/t2")),
            "W" => s(self.path("w")),
            "DATA" => s(self.path("data")),
            "CANARY_DIR" => s(self.path("home/canary-dir")),
            "FIXTURE" => s(self.root.clone()),
            "TMP" => s(self.path("t")),
            "USERS_SHARED" => self
                .users_shared
                .as_ref()
                .map(|d| s(d.clone()))
                .ok_or("${USERS_SHARED} exists only on macOS")?,
            "ABSTRACT" => format!("@{}", a.abstract_name),
            "TCP_LO" => a.tcp_lo.to_string(),
            "UDP_LO" => a.udp_lo.to_string(),
            "TCP_NL" => a
                .tcp_nl
                .ok_or("no non-loopback address for ${TCP_NL}")?
                .to_string(),
            "UDP_NL" => a
                .udp_nl
                .ok_or("no non-loopback address for ${UDP_NL}")?
                .to_string(),
            "UPSTREAM" => format!("upstream.test:{}", a.upstream.port()),
            "PROXY_TCP" => a.proxy_tcp.to_string(),
            "HARNESS_PID" => std::process::id().to_string(),
            "SLEEP_PID" => self
                .sleep
                .as_ref()
                .map(|c| c.id().to_string())
                .ok_or("${SLEEP_PID} needs the start-sleep setup step")?,
            "MARKER" => s(self.path("marker")),
            "GIT" => s(draugr::git::git_program()
                .map_err(|e| format!("${{GIT}}: no trusted git here: {e}"))?
                .path),
            "FAKE_BWRAP" => s(self
                .root_dirs
                .first()
                .map(|d| d.join("bwrap"))
                .ok_or("${FAKE_BWRAP} needs the fake-bwrap setup step")?),
            other => return Err(format!("undefined placeholder ${{{other}}}")),
        })
    }

    /// `s` with every placeholder filled.
    pub fn expand(&self, s: &str) -> Result<String, String> {
        let mut out = String::new();
        let mut rest = s;
        while let Some(i) = rest.find("${") {
            out.push_str(&rest[..i]);
            let after = &rest[i + 2..];
            let j = after
                .find('}')
                .ok_or_else(|| format!("unclosed placeholder in {s:?}"))?;
            out.push_str(&self.value(&after[..j])?);
            rest = &after[j + 1..];
        }
        out.push_str(rest);
        Ok(out)
    }

    /// Starts the `sleep` that `${SLEEP_PID}` names.
    pub fn start_sleep(&mut self) -> io::Result<()> {
        if self.sleep.is_none() {
            self.sleep = Some(
                Command::new("sleep")
                    .arg("300")
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()?,
            );
        }
        Ok(())
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(mut c) = self.sleep.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        if let Some(rt) = self.rt.take() {
            rt.shutdown_background();
        }
        for d in &self.root_dirs {
            let _ = if rustix::process::geteuid().is_root() {
                std::fs::remove_dir_all(d)
            } else {
                Command::new("sudo")
                    .args(["-n", "rm", "-r", "--"])
                    .arg(d)
                    .stderr(Stdio::null())
                    .status()
                    .map(|_| ())
            };
        }
        let _ = std::fs::remove_dir_all(&self.root);
        if let Some(d) = &self.users_shared {
            let _ = std::fs::remove_dir_all(d);
        }
    }
}

/// The first non-loopback IPv4 address the host would use to reach the outside (no packet is sent).
fn non_loopback() -> Option<IpAddr> {
    let s = UdpSocket::bind("0.0.0.0:0").ok()?;
    s.connect("192.0.2.1:9").ok()?;
    let ip = s.local_addr().ok()?.ip();
    (!ip.is_loopback() && !ip.is_unspecified()).then_some(ip)
}

fn bind_tcp(ip: IpAddr) -> io::Result<std::net::TcpListener> {
    let l = std::net::TcpListener::bind((ip, 0))?;
    l.set_nonblocking(true)?;
    Ok(l)
}

fn bind_udp(ip: IpAddr) -> io::Result<std::net::UdpSocket> {
    let s = std::net::UdpSocket::bind((ip, 0))?;
    s.set_nonblocking(true)?;
    Ok(s)
}

#[cfg(target_os = "linux")]
fn abstract_listener(name: &str) -> io::Result<tokio::net::UnixListener> {
    use std::os::linux::net::SocketAddrExt;
    let addr = std::os::unix::net::SocketAddr::from_abstract_name(name)?;
    let l = std::os::unix::net::UnixListener::bind_addr(&addr)?;
    l.set_nonblocking(true)?;
    tokio::net::UnixListener::from_std(l)
}

/// No abstract sockets off Linux: a listener on a path nobody is told about keeps the name valid.
#[cfg(not(target_os = "linux"))]
fn abstract_listener(name: &str) -> io::Result<tokio::net::UnixListener> {
    tokio::net::UnixListener::bind(std::env::temp_dir().join(format!("{name}.sock")))
}

/// Accept, count, then echo until the peer closes.
fn serve_unix(l: tokio::net::UnixListener, count: Arc<AtomicUsize>) {
    tokio::spawn(async move {
        while let Ok((s, _)) = l.accept().await {
            count.fetch_add(1, Ordering::SeqCst);
            tokio::spawn(echo(s));
        }
    });
}

fn serve_tcp(l: std::net::TcpListener, count: Arc<AtomicUsize>) -> SocketAddr {
    let addr = l.local_addr().expect("local addr");
    let l = tokio::net::TcpListener::from_std(l).expect("tokio listener");
    tokio::spawn(async move {
        while let Ok((s, _)) = l.accept().await {
            count.fetch_add(1, Ordering::SeqCst);
            tokio::spawn(echo(s));
        }
    });
    addr
}

fn serve_udp(s: std::net::UdpSocket, count: Arc<AtomicUsize>) -> SocketAddr {
    let addr = s.local_addr().expect("local addr");
    let s = tokio::net::UdpSocket::from_std(s).expect("tokio socket");
    tokio::spawn(async move {
        let mut buf = [0u8; 512];
        while let Ok((n, from)) = s.recv_from(&mut buf).await {
            count.fetch_add(1, Ordering::SeqCst);
            let _ = s.send_to(&buf[..n], from).await;
        }
    });
    addr
}

async fn echo<S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Send + 'static>(s: S) {
    let (mut r, mut w) = tokio::io::split(s);
    let _ = tokio::io::copy(&mut r, &mut w).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canaries_are_random_and_never_under_the_real_home() {
        let a = Fixture::new().unwrap();
        let b = Fixture::new().unwrap();
        assert_eq!(a.canaries.len(), b.canaries.len());
        for (x, y) in a.canaries.iter().zip(&b.canaries) {
            assert_ne!(x.text, y.text, "{} is the same in two fixtures", x.name);
            assert!(
                x.text.len() >= "glp-canary-".len() + 24,
                "{} is too short to be random",
                x.name
            );
        }
        assert_ne!(a.root, b.root);
        assert!(
            a.root.to_string_lossy().starts_with("/tmp/glp-"),
            "{}",
            a.root.display()
        );
        let real = std::env::var_os("HOME").map(PathBuf::from);
        for f in [&a, &b] {
            if let Some(h) = &real
                && !h.starts_with("/tmp")
            {
                assert!(!f.root.starts_with(h));
                assert!(
                    !f.env("/usr/bin")
                        .iter()
                        .any(|(_, v)| v.starts_with(&*h.to_string_lossy()))
                );
            }
            // The canary files hold exactly the canary text.
            assert_eq!(
                std::fs::read_to_string(f.path("home/.ssh/id_canary")).unwrap(),
                f.canary("ssh-key")
            );
        }
        let root = a.root.clone();
        drop(a);
        assert!(!root.exists(), "the fixture removes itself");
    }

    #[test]
    fn placeholders_expand_and_unknown_ones_fail() {
        let f = Fixture::new().unwrap();
        let home = f.expand("${HOME}/.ssh").unwrap();
        assert_eq!(home, format!("{}/home/.ssh", f.root.display()));
        assert!(f.expand("${NOPE}").is_err());
        assert!(f.expand("${SLEEP_PID}").is_err());
        assert!(f.expand("${FAKE_BWRAP}").is_err());
        for p in crate::row::PLACEHOLDERS {
            // Each is either filled or says why not; none is "undefined".
            if let Err(e) = f.value(p) {
                assert!(!e.starts_with("undefined"), "{p}: {e}");
            }
        }
    }

    #[test]
    fn listeners_count_connections() {
        let f = Fixture::new().unwrap();
        assert_eq!(f.seen("hub"), 0);
        std::os::unix::net::UnixStream::connect(f.path("run/drgnx/hub-0000.sock")).unwrap();
        std::net::TcpStream::connect(f.addrs.tcp_lo).unwrap();
        for _ in 0..50 {
            if f.seen("hub") == 1 && f.seen("tcp-lo") == 1 {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert_eq!((f.seen("hub"), f.seen("tcp-lo"), f.seen("bus")), (1, 1, 0));
    }
}
