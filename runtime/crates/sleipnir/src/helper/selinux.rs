//! k1: the job's key socket carries the container type on an SELinux host (docs/develop/sleipnir.md, "The key socket
//! on SELinux").  A keyed job runs as `container_t` with its own categories; the stock policy lets `container_t`
//! connect to a `container_t` socket (and the `:Z` mount's categories keep every other job off it), so the helper
//! creates the socket with the context `<its own SELinux user>:system_r:container_t:s0` and the job pins its type
//! (`--security-opt label=type:container_t`).
//!
//! The socket-creation context is per thread and inherited by every thread or child made while it is set, so it is
//! set, used and reset on a throwaway thread of its own, never a pool thread; the reset is read back, and a context
//! left set refuses (the thread, and its context, die with it).  No libselinux: two `/proc` writes.

use super::keys;
use std::fs;
use std::io;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};

/// The calling thread's socket-creation context.
pub const SOCKCREATE: &str = "/proc/thread-self/attr/sockcreate";

/// Whether SELinux is the LSM to label for: `selinux` among the kernel's LSMS (`/sys/kernel/security/lsm`) and
/// selinuxfs mounted (libselinux's own test).  An AppArmor host is neither.
pub fn active(lsm: &str, selinuxfs_mounted: bool) -> bool {
    selinuxfs_mounted && lsm.trim().split(',').any(|m| m.trim() == "selinux")
}

/// This host, as [`active`] reads it.
pub fn host_active() -> bool {
    let lsm = fs::read_to_string("/sys/kernel/security/lsm").unwrap_or_default();
    let mounted = fs::read_to_string("/proc/self/mounts").is_ok_and(|m| {
        m.lines().any(|l| {
            let mut f = l.split_whitespace().skip(1);
            f.next() == Some("/sys/fs/selinux") && f.next() == Some("selinuxfs")
        })
    });
    active(&lsm, mounted)
}

/// The key socket's context from the process's own (`/proc/self/attr/current`, CURRENT): its SELinux user, then
/// `system_r:container_t:s0` (no range).  A context that is not `user:role:type:level` (an AppArmor label) is refused.
pub fn socket_context(current: &[u8]) -> Result<String, String> {
    let text = std::str::from_utf8(current)
        .map_err(|_| "the process's SELinux context is not text".to_string())?
        .trim_end_matches(['\0', '\n']);
    let fields: Vec<&str> = text.split(':').collect();
    let user = fields[0];
    if fields.len() < 4
        || user.is_empty()
        || !user
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.')
    {
        return Err(format!("not an SELinux context: {text:?}"));
    }
    Ok(format!("{user}:system_r:container_t:s0"))
}

/// The key socket's context on this host: none when SELinux is not active.
pub fn job_context() -> Result<Option<String>, String> {
    if !host_active() {
        return Ok(None);
    }
    let current = fs::read("/proc/self/attr/current")
        .map_err(|e| format!("the process's SELinux context: {e}"))?;
    socket_context(&current).map(Some)
}

/// The socket-creation context file, as [`bind_labelled`] uses it (a test stands in its own).
pub(crate) trait Attr: Send + 'static {
    /// Writes CTX (empty: the reset, a zero-length write as `setsockcreatecon(NULL)` makes).
    fn write(&self, ctx: &[u8]) -> io::Result<()>;
    fn read(&self) -> io::Result<Vec<u8>>;
}

/// The file at a path ([`SOCKCREATE`]): resolved on the thread that uses it.
struct AttrFile(PathBuf);

impl Attr for AttrFile {
    fn write(&self, ctx: &[u8]) -> io::Result<()> {
        let f = fs::OpenOptions::new()
            .write(true)
            .truncate(true)
            .open(&self.0)?;
        let n = rustix::io::write(&f, ctx)?;
        if n != ctx.len() {
            return Err(io::Error::other("a short write"));
        }
        Ok(())
    }

    fn read(&self) -> io::Result<Vec<u8>> {
        fs::read(&self.0)
    }
}

/// Binds the socket NAME in DIR ([`keys::bind`]'s way) created with the context CTX: on a fresh thread that writes
/// CTX to ATTR, binds, writes the empty reset, reads ATTR back (anything left: an error, and the socket is removed)
/// and exits.
pub fn bind_labelled(dir: &Path, name: &str, ctx: &str, attr: &Path) -> io::Result<UnixListener> {
    bind_with(dir, name, ctx, AttrFile(attr.to_path_buf()))
}

pub(crate) fn bind_with(
    dir: &Path,
    name: &str,
    ctx: &str,
    attr: impl Attr,
) -> io::Result<UnixListener> {
    let (dir, name, ctx) = (dir.to_path_buf(), name.to_string(), ctx.to_string());
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("sockcreate".into())
        .spawn(move || {
            let r = (|| {
                attr.write(ctx.as_bytes())?;
                let bound = keys::bind(&dir, &name, None);
                let reset = attr.write(b"").and_then(|()| attr.read());
                let l = bound?;
                match reset {
                    Ok(left) if left.iter().all(|b| *b == 0 || *b == b'\n') => Ok(l),
                    Ok(left) => Err(io::Error::other(format!(
                        "the socket-creation context stayed set after the reset: {}",
                        String::from_utf8_lossy(&left).trim_end_matches('\0')
                    ))),
                    Err(e) => Err(io::Error::other(format!(
                        "the socket-creation context was not reset: {e}"
                    ))),
                }
                .inspect_err(|_| {
                    let _ = fs::remove_file(dir.join(&name));
                })
            })();
            let _ = tx.send(r);
        })?;
    rx.recv()
        .map_err(|_| io::Error::other("the labelling thread ended without an answer"))?
}

/// The SELinux label of L's socket (`security.selinux`), for the self-check.
pub fn label_of(l: &UnixListener) -> io::Result<String> {
    let mut buf = [0u8; 256];
    let n = rustix::fs::fgetxattr(l, "security.selinux", &mut buf)?;
    Ok(String::from_utf8_lossy(&buf[..n])
        .trim_end_matches('\0')
        .to_string())
}

/// The create half of k1 on this host (S3): none when SELinux is not active; else a socket bound in DIR with the
/// key socket's context, whose label is read back and must be `container_t`.  Answers the label.
pub fn self_check(dir: &Path) -> Result<Option<String>, String> {
    let Some(ctx) = job_context()? else {
        return Ok(None);
    };
    let name = format!(".k1-check-{}.sock", std::process::id());
    let l = bind_labelled(dir, &name, &ctx, Path::new(SOCKCREATE))
        .map_err(|e| format!("the socket was not labelled: {e}"))?;
    let label = label_of(&l);
    let _ = fs::remove_file(dir.join(&name));
    let label = label.map_err(|e| format!("the socket's label: {e}"))?;
    if label.split(':').nth(2) != Some("container_t") {
        return Err(format!("the socket came out {label}, not container_t"));
    }
    Ok(Some(label))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    use std::thread::ThreadId;

    #[test]
    fn context_from_each_sample() {
        for (current, want) in [
            (
                &b"unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023\0"[..],
                "unconfined_u:system_r:container_t:s0",
            ),
            (
                b"staff_u:staff_r:staff_t:s0-s0:c0.c1023",
                "staff_u:system_r:container_t:s0",
            ),
            (b"user_u:user_r:user_t:s0", "user_u:system_r:container_t:s0"),
        ] {
            assert_eq!(socket_context(current).unwrap(), want);
        }
        assert!(active(
            "lockdown,capability,yama,selinux,bpf,landlock",
            true
        ));
        // selinux listed but selinuxfs not mounted: no
        assert!(!active("capability,selinux", false));
    }

    #[test]
    fn apparmor_strings_dont_activate() {
        for s in ["unconfined", "snap.foo (enforce)"] {
            assert!(socket_context(s.as_bytes()).is_err(), "{s}");
        }
        assert!(!active("lockdown,capability,landlock,yama,apparmor", false));
        assert!(!active("lockdown,capability,landlock,yama,apparmor", true));
    }

    type Writes = Arc<Mutex<Vec<(ThreadId, Vec<u8>)>>>;

    /// A stand-in for the attr file: what was written, on which thread, and whether an empty write is refused or
    /// ignored.
    #[derive(Clone, Default)]
    struct Fake {
        writes: Writes,
        value: Arc<Mutex<Vec<u8>>>,
        refuse_reset: bool,
        ignore_reset: bool,
    }

    impl Attr for Fake {
        fn write(&self, ctx: &[u8]) -> io::Result<()> {
            self.writes
                .lock()
                .unwrap()
                .push((std::thread::current().id(), ctx.to_vec()));
            if ctx.is_empty() {
                if self.refuse_reset {
                    return Err(io::Error::from_raw_os_error(libc::EINVAL));
                }
                if self.ignore_reset {
                    return Ok(());
                }
            }
            *self.value.lock().unwrap() = ctx.to_vec();
            Ok(())
        }

        fn read(&self) -> io::Result<Vec<u8>> {
            Ok(self.value.lock().unwrap().clone())
        }
    }

    #[test]
    fn a_failed_reset_refuses() {
        for fake in [
            Fake {
                refuse_reset: true,
                ..Fake::default()
            },
            Fake {
                ignore_reset: true,
                ..Fake::default()
            },
        ] {
            let d = tempfile::tempdir().unwrap();
            let e = bind_with(d.path(), "key.sock", "u:system_r:container_t:s0", fake).unwrap_err();
            assert!(e.to_string().contains("context"), "{e}");
            // the socket made under the context is gone
            assert!(!d.path().join("key.sock").exists());
        }
    }

    #[test]
    fn the_calling_threads_context_is_untouched() {
        let d = tempfile::tempdir().unwrap();
        let fake = Fake::default();
        let l = bind_with(
            d.path(),
            "key.sock",
            "u:system_r:container_t:s0",
            fake.clone(),
        )
        .unwrap();
        assert!(l.local_addr().is_ok());
        assert!(d.path().join("key.sock").exists());
        let w = fake.writes.lock().unwrap().clone();
        let me = std::thread::current().id();
        // set, then reset, both on the one throwaway thread; nothing on the caller's
        assert_eq!(w.len(), 2, "{:?}", w.len());
        assert_eq!(w[0].1, b"u:system_r:container_t:s0");
        assert!(w[1].1.is_empty());
        assert_eq!(w[0].0, w[1].0);
        assert_ne!(w[0].0, me);
        // the real file path: a temp file stands for each thread's, and the caller's is never written
        let mine = d.path().join("caller-attr");
        fs::write(&mine, b"").unwrap();
        let theirs = d.path().join("thread-attr");
        fs::write(&theirs, b"").unwrap();
        bind_labelled(d.path(), "k2.sock", "u:system_r:container_t:s0", &theirs).unwrap();
        assert!(fs::read(&mine).unwrap().is_empty());
        assert!(fs::read(&theirs).unwrap().is_empty());
    }

    /// [C, VM gate] An SELinux host: a socket bound labelled reads back `container_t`, and the next socket the
    /// caller makes has its own label.
    #[test]
    #[ignore = "selinux"]
    fn after_the_bind_the_next_socket_has_the_helpers_label() {
        let d = tempfile::tempdir().unwrap();
        let label = self_check(d.path()).unwrap().expect("SELinux is active");
        assert!(label.contains(":container_t:"), "{label}");
        let l = keys::bind(d.path(), "plain.sock", None).unwrap();
        let own = label_of(&l).unwrap();
        assert!(!own.contains(":container_t:"), "{own}");
    }
}
