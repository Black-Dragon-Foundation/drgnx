//! Each sandboxed debug session's block of loopback ports (spec §21). On macOS, Seatbelt lets a session's adapter
//! and program use only the ports named in its profile (`mac_loopback_ports`), so each session gets a fixed block:
//! the adapter's port, the program's, and one per child process. Blocks sit below macOS's ephemeral range, so the
//! system never hands one out for an outgoing connection.
//!
//! A block is claimed machine-wide: an exclusive `flock` on its file in [`LOCK_DIR`] (sticky and open to every
//! account, so two hubs, a test hub or another user's, never hand out the same block), held for the session's life
//! and gone with the process. The lock belongs to the open file, which a child forked by any of the hub's threads
//! shares until it execs (the descriptor is close-on-exec): so the block's drop unlocks it (`LOCK_UN` frees it for
//! every copy) before closing, and a block is free the moment its session lets it go. A `fcntl` record lock would not
//! pass to children, but it is the process's, so one hub's two claims of a file would both hold it. Under the lock each port is bound once on 127.0.0.1, ::1 and 0.0.0.0 and let go: a
//! block locked elsewhere or with a port another process holds is passed over (the macOS runner's spike found 47610
//! taken now and then), and when every block is taken the session is refused, naming the range.
//!
//! The probe and the adapter's own bind are apart, so before the hub connects to a block port (or starts a program
//! that will) it checks that every listener there is the session's ([`owned`]): a stranger's ends the session.

use std::collections::BTreeSet;
use std::fs::File;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, TcpListener};
use std::ops::Range;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// The first port of macOS's ephemeral range: blocks stay below it.
pub const MAC_EPHEMERAL: u16 = 49152;
/// The ports blocks are cut from.
pub const RANGE: Range<u16> = 47000..49000;
/// Ports per block: the adapter, the program and up to six children.
pub const LEN: u16 = 8;
/// Where blocks are locked, for every hub on the machine.
#[cfg(target_os = "macos")]
pub const LOCK_DIR: &str = "/private/tmp/drgnx-debug-ports";
/// Where blocks are locked, for every hub on the machine.
#[cfg(not(target_os = "macos"))]
pub const LOCK_DIR: &str = "/tmp/drgnx-debug-ports";

/// The blocks in use, by first port.
type Taken = Arc<Mutex<BTreeSet<u16>>>;

/// The hub's blocks.
#[derive(Debug)]
pub struct Blocks {
    range: Range<u16>,
    len: u16,
    taken: Taken,
    /// Whether a port is free ([`free`]; the tests' own, as other tests' outgoing connections take real ports).
    probe: fn(u16) -> bool,
    /// [`LOCK_DIR`], or a test's.
    dir: PathBuf,
}

/// One session's block; its ports go back when it is dropped.
#[derive(Debug)]
pub struct Block {
    first: u16,
    len: u16,
    taken: Taken,
    /// The block's lock file, locked; dropping the block unlocks it (see its `Drop`).
    lock: File,
}

/// The hub's one table of blocks (every session's, the machine-wide locks under it).
pub fn machine() -> &'static Blocks {
    static BLOCKS: std::sync::OnceLock<Blocks> = std::sync::OnceLock::new();
    BLOCKS.get_or_init(Blocks::default)
}

impl Default for Blocks {
    fn default() -> Blocks {
        Blocks::new(RANGE, LEN)
    }
}

/// DIR, made shared and sticky when missing: every account may add a lock file and none may delete another's (or a
/// held lock could be deleted and its name locked again). An existing one that is not a sticky directory is refused.
fn lock_dir(dir: &Path) -> Result<(), String> {
    match std::fs::create_dir(dir) {
        Ok(()) => std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o1777))
            .map_err(|e| format!("{}: {e}", dir.display()))?,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(format!("{}: {e}", dir.display())),
    }
    let m = std::fs::symlink_metadata(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    if !m.is_dir() || m.permissions().mode() & 0o1000 == 0 {
        return Err(format!(
            "{} is not a sticky shared directory: debug port blocks cannot be locked there",
            dir.display()
        ));
    }
    Ok(())
}

/// PATH (created open to every account, never through a link), locked exclusively without waiting; none when another
/// process holds it or the file is not ours to open (another account's, made private: that block is passed over).
fn lock(path: &Path) -> Option<File> {
    let f = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o666)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .ok()?;
    // the umask narrowed the mode: widen it (only ours can be changed, and only ours needs it)
    let _ = f.set_permissions(std::fs::Permissions::from_mode(0o666));
    // SAFETY: flock(2) on a descriptor this function owns.
    (unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0).then_some(f)
}

/// Whether PORT is free on every loopback and the wildcard address (an address this machine lacks, ::1 without
/// IPv6, does not count against it).
pub fn free(port: u16) -> bool {
    let addrs = [
        SocketAddr::from((Ipv4Addr::LOCALHOST, port)),
        SocketAddr::from((Ipv6Addr::LOCALHOST, port)),
        SocketAddr::from((Ipv4Addr::UNSPECIFIED, port)),
    ];
    addrs.iter().all(|a| match TcpListener::bind(a) {
        Ok(_) => true,
        Err(e) => e.kind() == std::io::ErrorKind::AddrNotAvailable,
    })
}

impl Blocks {
    /// Blocks of LEN ports cut from RANGE.
    pub fn new(range: Range<u16>, len: u16) -> Blocks {
        Blocks::with(range, len, free, Path::new(LOCK_DIR))
    }

    /// Blocks whose ports PROBE says are free, locked in DIR.
    pub fn with(range: Range<u16>, len: u16, probe: fn(u16) -> bool, dir: &Path) -> Blocks {
        Blocks {
            range,
            len,
            taken: Arc::default(),
            probe,
            dir: dir.to_path_buf(),
        }
    }

    pub fn range(&self) -> Range<u16> {
        self.range.clone()
    }

    pub fn size(&self) -> u16 {
        self.len
    }

    /// The first block no session holds whose ports are all free; an error naming the range when there is none.
    pub fn claim(&self) -> Result<Block, String> {
        lock_dir(&self.dir)?;
        let mut taken = self.taken.lock().unwrap_or_else(|e| e.into_inner());
        let mut first = self.range.start;
        while first.saturating_add(self.len) <= self.range.end {
            if !taken.contains(&first)
                && let Some(lock) = lock(&self.dir.join(format!("block-{first}")))
                && (first..first + self.len).all(self.probe)
            {
                taken.insert(first);
                return Ok(Block {
                    first,
                    len: self.len,
                    taken: self.taken.clone(),
                    lock,
                });
            }
            first += self.len;
        }
        Err(format!(
            "no free block of {} debug ports in {}-{}: other sessions or programs hold them",
            self.len,
            self.range.start,
            self.range.end - 1
        ))
    }
}

impl Block {
    /// Its ports, in order.
    pub fn ports(&self) -> Vec<u16> {
        (self.first..self.first + self.len).collect()
    }
}

impl Drop for Block {
    fn drop(&mut self) {
        // SAFETY: flock(2) on the descriptor this block owns. Unlocking (not only closing) lets go even while a
        // forked child that has not exec'd yet holds a copy of the descriptor.
        unsafe { libc::flock(self.lock.as_raw_fd(), libc::LOCK_UN) };
        self.taken
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&self.first);
    }
}

/// Whether the listeners on PORT (127.0.0.1, ::1 or any address) are the session's: none yet (`Ok(false)`), every one
/// of them in one of the process GROUPS (`Ok(true)`), or one that is not (an error naming the port, and the process
/// when it can be seen). macOS: `lsof`, which sees this account's processes only (another account's listener makes the
/// adapter's own bind fail instead). Linux: `/proc/net/tcp*` and each listener's socket among this account's
/// processes' descriptors.
pub fn owned(port: u16, groups: &[i32]) -> Result<bool, String> {
    let pids = listener_pids(port)?;
    if pids.is_empty() {
        return Ok(false);
    }
    for pid in pids {
        let ours = pid.is_some_and(|pid| {
            // SAFETY: getpgid(2) reads a process's group; an error (it is gone) is -1, never a group of ours.
            let g = unsafe { libc::getpgid(pid) };
            g > 0 && groups.contains(&g)
        });
        if !ours {
            return Err(match pid {
                Some(pid) => format!(
                    "port {port} is held by process {pid}, not the session's adapter or program: the session ends"
                ),
                None => format!(
                    "port {port} is held by a process that is not the session's adapter or program: the session ends"
                ),
            });
        }
    }
    Ok(true)
}

/// How long a port check's `lsof` may take: past it the process is killed and the check fails, so a session's start
/// (which waits on the check, [`super::blocked::wait_owned`]) keeps its own deadline.
pub const LSOF_WITHIN: std::time::Duration = std::time::Duration::from_secs(5);

/// CMD's output (stdin closed), or an error once it has run WITHIN without exiting (it is killed then).
pub fn output_within(
    mut cmd: std::process::Command,
    within: std::time::Duration,
) -> Result<std::process::Output, String> {
    use std::io::Read;
    use std::process::Stdio;
    let name = cmd.get_program().to_string_lossy().into_owned();
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("{name}: {e}"))?;
    // read both pipes as it runs: a full pipe would stop it before it exits
    let drain = |p: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut buf = Vec::new();
            if let Some(mut p) = p {
                let _ = p.read_to_end(&mut buf);
            }
            buf
        })
    };
    let out = drain(
        child
            .stdout
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    );
    let err = drain(
        child
            .stderr
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    );
    let start = crate::clock::real_now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) if start.elapsed() < within => {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!(
                    "{name} did not answer within {} ms (killed)",
                    within.as_millis()
                ));
            }
            Err(e) => return Err(format!("{name}: {e}")),
        }
    };
    Ok(std::process::Output {
        status,
        stdout: out.join().unwrap_or_default(),
        stderr: err.join().unwrap_or_default(),
    })
}

/// The process of each listener on PORT; `None` where it cannot be seen.
#[cfg(target_os = "macos")]
fn listener_pids(port: u16) -> Result<Vec<Option<i32>>, String> {
    let mut cmd = std::process::Command::new("/usr/sbin/lsof");
    // -b -w: no kernel call that can block (a stat of a hung mount); the deadline covers the rest
    cmd.args([
        "-b",
        "-w",
        "-nP",
        "-a",
        &format!("-iTCP:{port}"),
        "-sTCP:LISTEN",
        "-Fp",
    ]);
    let out = output_within(cmd, LSOF_WITHIN)?;
    // exit 1 with no output: nothing listens
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| l.strip_prefix('p'))
        .map(|p| p.parse().ok())
        .collect())
}

/// The process of each listener on PORT; `None` where it cannot be seen.
#[cfg(not(target_os = "macos"))]
fn listener_pids(port: u16) -> Result<Vec<Option<i32>>, String> {
    let mut inodes = vec![];
    for f in ["/proc/net/tcp", "/proc/net/tcp6"] {
        let Ok(t) = std::fs::read_to_string(f) else {
            continue;
        };
        for line in t.lines().skip(1) {
            let c: Vec<&str> = line.split_whitespace().collect();
            // columns: sl local remote st … inode (the tenth); st 0A is LISTEN
            let local = c
                .get(1)
                .and_then(|a| a.rsplit(':').next())
                .and_then(|p| u16::from_str_radix(p, 16).ok());
            if c.get(3) == Some(&"0A")
                && local == Some(port)
                && let Some(i) = c.get(9)
            {
                inodes.push(format!("socket:[{i}]"));
            }
        }
    }
    if inodes.is_empty() {
        return Ok(vec![]);
    }
    let mut found: Vec<Option<i32>> = vec![None; inodes.len()];
    let procs = std::fs::read_dir("/proc").map_err(|e| format!("/proc: {e}"))?;
    for p in procs.flatten() {
        let Some(pid) = p.file_name().to_str().and_then(|n| n.parse::<i32>().ok()) else {
            continue;
        };
        let Ok(fds) = std::fs::read_dir(p.path().join("fd")) else {
            continue;
        };
        for fd in fds.flatten() {
            if let Ok(l) = std::fs::read_link(fd.path())
                && let Some(i) = inodes.iter().position(|s| l.as_os_str() == s.as_str())
            {
                found[i] = Some(pid);
            }
        }
    }
    Ok(found)
}
