//! What the web proxies must treat as the host itself, kept live by the hub (docs/develop/hub.md, "The web proxy"):
//! - the host's own addresses ([`HostAddrsWatch`]): every interface's, read with `getifaddrs` every 5 s; the web
//!   policy treats each as loopback, reachable only as `host.drgnx.internal`;
//! - the hub's own TCP endpoints on the host's loopback ([`NeverSetWatch`]): the gateway's port, every other listener
//!   the hub registers, and an Emacs TCP server's port, read from its server file every 30 s.  No grant opens these.
//!
//! Every session's web proxy reads the same two sets at each request ([`Nevers`]), so a change reaches them all at
//! once.

use gleipnir::net::policy::{HostAddrs, NeverSet};
use std::collections::BTreeSet;
use std::io::{self, BufRead};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

/// How often the interfaces are read again.
pub const HOST_ADDRS_EVERY: Duration = Duration::from_secs(5);
/// How often the Emacs server files are read again.
pub const EMACS_EVERY: Duration = Duration::from_secs(30);

/// The two sets every web proxy shares, and what keeps them live.
#[derive(Clone, Default)]
pub struct Nevers {
    pub host_addrs: HostAddrsWatch,
    pub never: NeverSetWatch,
}

impl Nevers {
    /// The hub's watches, from now until the hub stops: the interfaces, and the Emacs server files in DIRS (see
    /// [`emacs_server_dirs`]).  Call it inside a tokio runtime.
    pub fn start(&self, dirs: Vec<PathBuf>) {
        self.never.set_server_dirs(dirs);
        crate::clock::spawn("browser:host-addrs", self.host_addrs.clone().run());
        crate::clock::spawn("browser:nevers", self.never.clone().run());
    }
}

fn read<T>(l: &RwLock<T>) -> std::sync::RwLockReadGuard<'_, T> {
    l.read().unwrap_or_else(|e| e.into_inner())
}

fn write<T>(l: &RwLock<T>) -> std::sync::RwLockWriteGuard<'_, T> {
    l.write().unwrap_or_else(|e| e.into_inner())
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The host's own addresses, as the web policy reads them.
#[derive(Clone, Default)]
pub struct HostAddrsWatch {
    addrs: Arc<RwLock<HostAddrs>>,
}

impl HostAddrsWatch {
    /// The set the proxies read (`gleipnir::net::proxy::WebState::new`).
    pub fn shared(&self) -> Arc<RwLock<HostAddrs>> {
        self.addrs.clone()
    }

    /// Reads the interfaces once into the shared set; a failure keeps the last set (and is logged).
    pub fn refresh(&self) {
        match interface_addrs() {
            Ok(a) => {
                if *read(&self.addrs) != a {
                    *write(&self.addrs) = a;
                }
            }
            Err(e) => tracing::warn!("cannot read the host's interface addresses: {e}"),
        }
    }

    /// [`Self::refresh`] every [`HOST_ADDRS_EVERY`], for good.
    pub async fn run(self) {
        loop {
            self.refresh();
            crate::clock::sleep(HOST_ADDRS_EVERY).await;
        }
    }
}

/// Every address of every interface (`getifaddrs`), up or not, loopback included.
pub fn interface_addrs() -> io::Result<HostAddrs> {
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: getifaddrs fills HEAD with a list that freeifaddrs frees below; nothing of it outlives that.
    if unsafe { libc::getifaddrs(&mut head) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let mut out = BTreeSet::new();
    let mut p = head;
    while !p.is_null() {
        // SAFETY: P is a node of the list getifaddrs made, alive until freeifaddrs.
        let ifa = unsafe { &*p };
        if !ifa.ifa_addr.is_null() {
            // SAFETY: ifa_addr points at a sockaddr; its family says which sockaddr it is.
            let family = i32::from(unsafe { (*ifa.ifa_addr).sa_family });
            if family == libc::AF_INET {
                // SAFETY: an AF_INET address is a sockaddr_in.
                let sin = unsafe { &*ifa.ifa_addr.cast::<libc::sockaddr_in>() };
                out.insert(IpAddr::V4(Ipv4Addr::from(u32::from_be(
                    sin.sin_addr.s_addr,
                ))));
            } else if family == libc::AF_INET6 {
                // SAFETY: an AF_INET6 address is a sockaddr_in6.
                let sin6 = unsafe { &*ifa.ifa_addr.cast::<libc::sockaddr_in6>() };
                out.insert(IpAddr::V6(Ipv6Addr::from(sin6.sin6_addr.s6_addr)));
            }
        }
        p = ifa.ifa_next;
    }
    // SAFETY: HEAD came from getifaddrs and is freed once.
    unsafe { libc::freeifaddrs(head) };
    Ok(HostAddrs(out))
}

/// The hub's own TCP endpoints on the host's loopback.
#[derive(Clone, Default)]
pub struct NeverSetWatch {
    never: Arc<RwLock<NeverSet>>,
    /// The ports of the hub's own loopback listeners (the gateway's among them), as their code registered them.
    held: Arc<Mutex<BTreeSet<u16>>>,
    /// The Emacs TCP servers' ports, as last read.
    emacs: Arc<Mutex<BTreeSet<u16>>>,
    /// Where the Emacs server files are.
    dirs: Arc<Mutex<Vec<PathBuf>>>,
    /// On a Mac, podman machine's control ports (its SSH port and its hypervisor's REST port), as last read (B4).
    machine: Arc<Mutex<BTreeSet<u16>>>,
}

impl NeverSetWatch {
    /// The set the proxies read (`gleipnir::net::proxy::WebState::new`).
    pub fn shared(&self) -> Arc<RwLock<NeverSet>> {
        self.never.clone()
    }

    /// A loopback listener of the hub's on PORT, from now on (the code that binds it registers it).
    pub fn hold(&self, port: u16) {
        lock(&self.held).insert(port);
        self.publish();
    }

    /// The listener on PORT is closed.
    pub fn release(&self, port: u16) {
        lock(&self.held).remove(&port);
        self.publish();
    }

    /// The directories [`Self::read_emacs`] reads.
    pub fn set_server_dirs(&self, dirs: Vec<PathBuf>) {
        *lock(&self.dirs) = dirs;
    }

    /// Reads the Emacs server files again: the port of each that names a TCP server.
    pub fn read_emacs(&self) {
        let dirs = lock(&self.dirs).clone();
        let ports: BTreeSet<u16> = dirs.iter().flat_map(|d| emacs_ports(d)).collect();
        *lock(&self.emacs) = ports;
        self.publish();
    }

    /// Podman machine's control ports are PORTS from now on, replacing the last ones (a restart that moved a port
    /// releases the old one).
    pub fn set_machine_ports(&self, ports: impl IntoIterator<Item = u16>) {
        *lock(&self.machine) = ports.into_iter().collect();
        self.publish();
    }

    /// On a Mac, reads podman machine's control ports again ([`machine_ports`] over `podman machine inspect` and the
    /// machine's config file); a failed read keeps the last ports.  Elsewhere nothing.
    pub fn read_machine(&self) {
        #[cfg(target_os = "macos")]
        if let Ok(ports) = read_machine_ports() {
            self.set_machine_ports(ports);
        }
    }

    fn publish(&self) {
        let loopback_ports: BTreeSet<u16> = lock(&self.held)
            .iter()
            .chain(lock(&self.emacs).iter())
            .chain(lock(&self.machine).iter())
            .copied()
            .collect();
        let mut never = write(&self.never);
        if never.loopback_ports != loopback_ports {
            never.loopback_ports = loopback_ports;
        }
    }

    /// [`Self::read_emacs`] (and on a Mac [`Self::read_machine`]) every [`EMACS_EVERY`], for good.
    pub async fn run(self) {
        loop {
            self.read_emacs();
            self.read_machine();
            crate::clock::sleep(EMACS_EVERY).await;
        }
    }
}

/// Podman machine's control ports on the Mac's loopback (B4; S0 Step 8): the SSH port (`SSHConfig.Port` in INSPECT,
/// one machine's `podman machine inspect` entry, else `SSH.Port` in CONFIG) and the hypervisor's REST port, only in
/// the machine's config file CONFIG (`AppleHypervisor.Vfkit.Endpoint` for applehv, `LibKrunHypervisor.KRun.Endpoint`
/// for libkrun: `http://localhost:<port>`).
pub fn machine_ports(
    inspect: &serde_json::Value,
    config: Option<&serde_json::Value>,
) -> Result<Vec<u16>, String> {
    let port = |v: &serde_json::Value| v.as_u64().and_then(|p| u16::try_from(p).ok());
    let ssh = port(&inspect["SSHConfig"]["Port"])
        .or_else(|| config.and_then(|c| port(&c["SSH"]["Port"])))
        .ok_or("podman machine inspect names no SSH port")?;
    let mut out = vec![ssh];
    if let Some(c) = config {
        for e in [
            &c["AppleHypervisor"]["Vfkit"]["Endpoint"],
            &c["LibKrunHypervisor"]["KRun"]["Endpoint"],
        ] {
            if let Some(p) = e
                .as_str()
                .and_then(|u| u.rsplit(':').next())
                .and_then(|p| p.trim_end_matches('/').parse::<u16>().ok())
            {
                out.push(p);
            }
        }
    }
    out.sort_unstable();
    out.dedup();
    Ok(out)
}

/// `podman machine inspect` of the default machine and its config file (`<ConfigDir.Path>/<Name>.json`), read now.
#[cfg(target_os = "macos")]
fn read_machine_ports() -> Result<Vec<u16>, String> {
    let out = std::process::Command::new("podman")
        .args(["machine", "inspect"])
        .stdin(std::process::Stdio::null())
        .output()
        .map_err(|e| format!("podman machine inspect: {e}"))?;
    let all: serde_json::Value =
        serde_json::from_slice(&out.stdout).map_err(|e| format!("podman machine inspect: {e}"))?;
    let m = all.get(0).unwrap_or(&all);
    let config = m["ConfigDir"]["Path"]
        .as_str()
        .zip(m["Name"].as_str())
        .and_then(|(d, n)| std::fs::read(Path::new(d).join(format!("{n}.json"))).ok())
        .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok());
    machine_ports(m, config.as_ref())
}

/// Where Emacs keeps the files of its TCP servers (`server-auth-dir`) under HOME, the hub's HOME: Emacs's default
/// `~/.emacs.d/server/`, and `~/.config/emacs/server/` (XDG_CONFIG_HOME's when set), where it is when the init
/// directory is there.  No drgnx setting names another directory.
pub fn emacs_server_dirs(home: &Path, xdg_config_home: Option<&Path>) -> Vec<PathBuf> {
    let config = xdg_config_home.map_or_else(|| home.join(".config"), Path::to_path_buf);
    vec![
        home.join(".emacs.d").join("server"),
        config.join("emacs").join("server"),
    ]
}

/// The ports the server files in DIR name.  A TCP server's file starts `HOST:PORT PID` on its first line; the line
/// after holds its key, which is never read.  Sockets, directories and other files are passed over.
fn emacs_ports(dir: &Path) -> Vec<u16> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        .filter_map(|e| server_file_port(&e.path()))
        .collect()
}

/// The port on the first line of the server file at PATH (at most 256 bytes of it are read).
fn server_file_port(path: &Path) -> Option<u16> {
    use std::io::Read;
    let f = std::fs::File::open(path).ok()?;
    let mut line = String::new();
    io::BufReader::new(f.take(256)).read_line(&mut line).ok()?;
    let line = line.strip_suffix('\n')?;
    let (addr, pid) = line.split_once(' ')?;
    pid.parse::<u32>().ok()?;
    let (_, port) = addr.rsplit_once(':')?;
    port.parse::<u16>().ok().filter(|p| *p != 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn machine_ports_reads_ssh_and_rest() {
        let inspect = serde_json::json!({"Name": "podman-machine-default", "SSHConfig": {"Port": 53211},
            "ConfigDir": {"Path": "/machine/applehv"}});
        let applehv = serde_json::json!({"SSH": {"Port": 53211},
            "AppleHypervisor": {"Vfkit": {"Endpoint": "http://localhost:61234"}}});
        assert_eq!(
            machine_ports(&inspect, Some(&applehv)).unwrap(),
            [53211, 61234]
        );
        let libkrun = serde_json::json!({"SSH": {"Port": 53211},
            "LibKrunHypervisor": {"KRun": {"Endpoint": "http://localhost:61999"}}});
        assert_eq!(
            machine_ports(&inspect, Some(&libkrun)).unwrap(),
            [53211, 61999]
        );
        // no inspect port: the config's; no file: the SSH port alone; neither: refused
        assert_eq!(
            machine_ports(&serde_json::json!({}), Some(&applehv)).unwrap(),
            [53211, 61234]
        );
        assert_eq!(machine_ports(&inspect, None).unwrap(), [53211]);
        assert!(machine_ports(&serde_json::json!({}), None).is_err());
    }

    #[test]
    fn a_restart_swaps_the_held_ports() {
        let w = NeverSetWatch::default();
        w.hold(4100);
        w.set_machine_ports([53211, 61234]);
        let ports = |w: &NeverSetWatch| w.shared().read().unwrap().loopback_ports.clone();
        assert_eq!(ports(&w), BTreeSet::from([4100, 53211, 61234]));
        // the machine restarted with a new SSH port: the new pair is held, the old SSH port released
        w.set_machine_ports([53999, 61234]);
        assert_eq!(ports(&w), BTreeSet::from([4100, 53999, 61234]));
    }

    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "a Mac with podman machine"]
    fn the_machines_ports_are_held() {
        let w = NeverSetWatch::default();
        w.read_machine();
        let held = w.shared().read().unwrap().loopback_ports.clone();
        assert!(held.len() >= 2, "{held:?}");
    }
    use gleipnir::net::host::parse_target;
    use gleipnir::net::policy::{Judgement, PrivateGrant, PrivateTarget, RefuseWhy, WebCtx, judge};

    #[test]
    fn gateway_and_emacs_ports_are_never() {
        let home = tempfile::tempdir().unwrap();
        let dirs = emacs_server_dirs(home.path(), None);
        std::fs::create_dir_all(&dirs[0]).unwrap();
        std::fs::create_dir_all(&dirs[1]).unwrap();
        // a TCP server's file (its key on the second line), one in the XDG place, and files that are not servers'
        std::fs::write(dirs[0].join("server"), "127.0.0.1:43123 4242\nSECRET-KEY").unwrap();
        std::fs::write(dirs[1].join("work"), "127.0.0.1:43124 77\nk").unwrap();
        std::fs::write(dirs[0].join("notes"), "no port here\n").unwrap();
        std::fs::write(dirs[0].join("half"), "127.0.0.1:43125").unwrap();
        std::fs::create_dir(dirs[0].join("sub")).unwrap();
        let w = NeverSetWatch::default();
        w.set_server_dirs(dirs.clone());
        w.hold(4100);
        w.read_emacs();
        let shared = w.shared();
        assert_eq!(
            read(&shared).loopback_ports,
            BTreeSet::from([4100, 43123, 43124])
        );
        // under a grant for the reserved name on that port, the web policy still refuses it
        let ctx_judge = |port: u16| {
            let t = parse_target(&format!("host.drgnx.internal:{port}")).unwrap();
            let grants = vec![PrivateGrant {
                target: PrivateTarget::HostPort(t.clone()),
                expires: None,
            }];
            let never = read(&shared).clone();
            let ctx = WebCtx {
                web: true,
                deny_hosts: &[],
                grants: &grants,
                now: 0.0,
                host_addrs: &HostAddrs::default(),
                never: &never,
            };
            judge(&t, &[], &ctx)
        };
        for port in [4100, 43123, 43124] {
            assert_eq!(
                ctx_judge(port),
                Judgement::Refuse(RefuseWhy::Never),
                "{port}"
            );
        }
        assert!(matches!(ctx_judge(5173), Judgement::Connect(_)));
        // the server ends and the gateway's listener closes: its ports are free to grant again
        std::fs::remove_file(dirs[0].join("server")).unwrap();
        w.release(4100);
        w.read_emacs();
        assert_eq!(read(&shared).loopback_ports, BTreeSet::from([43124]));
    }

    #[test]
    fn host_addrs_include_every_interface() {
        let a = interface_addrs().unwrap();
        assert!(a.0.contains(&IpAddr::V4(Ipv4Addr::LOCALHOST)), "{:?}", a.0);
        // every IPv6 address the kernel lists (/proc/net/if_inet6: 32 hex digits first on each line)
        if let Ok(text) = std::fs::read_to_string("/proc/net/if_inet6") {
            for line in text.lines() {
                let hex = &line[..32];
                let v6 = Ipv6Addr::from(u128::from_str_radix(hex, 16).unwrap());
                assert!(a.0.contains(&IpAddr::V6(v6)), "{v6} not in {:?}", a.0);
            }
        }
        // and the watch publishes them
        let w = HostAddrsWatch::default();
        w.refresh();
        assert_eq!(*read(&w.shared()), a);
    }
}
