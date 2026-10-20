//! Where a hub's files are (design 3.1): the same rule as Lisp's `drgnx-paths-dir 'data` and `drgnx-hub-socket`
//! (`core/drgnx-paths.el`, `core/drgnx-hub-client.el`), oddities of Emacs's `expand-file-name` kept.  The shared
//! fixture `test/fixtures/hub-socket-cases.json` pins Lisp, the conformance harness and this module.  A relative env
//! value is out of scope (a DEFERRED row).

use rustix::fs::{FileType, Mode, OFlags};
use sha1::{Digest, Sha1};
use std::collections::BTreeMap;
use std::fmt;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};

/// The longest socket path used (bytes): `sun_path` holds 104 on macOS, with its NUL.
pub const MAX_SOCKET_PATH: usize = 103;

/// The environment a hub sees (only the variables the rule reads matter) and the uid it runs as.
#[derive(Clone, Debug, Default)]
pub struct Env {
    pub vars: BTreeMap<String, String>,
    pub uid: u32,
}

impl Env {
    pub fn new(vars: &[(&str, &str)], uid: u32) -> Env {
        Env {
            vars: vars
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            uid,
        }
    }

    /// This process's own environment and effective uid.
    pub fn process() -> Env {
        Env {
            vars: std::env::vars_os()
                .map(|(k, v)| {
                    (
                        k.to_string_lossy().into_owned(),
                        v.to_string_lossy().into_owned(),
                    )
                })
                .collect(),
            uid: rustix::process::geteuid().as_raw(),
        }
    }

    fn get(&self, name: &str) -> Option<&str> {
        self.vars.get(name).map(String::as_str)
    }

    /// `drgnx-paths-env-dir`: the value when it begins with "/", else nothing (unset, empty, relative and "~/..."
    /// all mean the default).
    fn abs(&self, name: &str) -> Option<&str> {
        self.get(name).filter(|v| v.starts_with('/'))
    }
}

/// A path that cannot be used.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PathError {
    /// Over [`MAX_SOCKET_PATH`] bytes even under `<tmp>`.
    TooLong(PathBuf),
}

impl fmt::Display for PathError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            PathError::TooLong(p) => write!(
                f,
                "the socket path {} is over {MAX_SOCKET_PATH} bytes (set TMPDIR to a shorter directory)",
                p.display()
            ),
        }
    }
}

impl std::error::Error for PathError {}

/// `expand-file-name` of an absolute name, as Emacs's C code canonicalises it (fileio.c): "/./" and "/x/../" go,
/// repeated "/" collapse except a leading "//", three or more leading "/" become one, and ".." at the root
/// stays when something follows it ("/../b") and goes when it is last ("/.." is kept, "/../.." is "/").
fn normalize(name: &str) -> String {
    let mut nm = name.as_bytes();
    if nm.starts_with(b"///") {
        while nm.starts_with(b"//") {
            nm = &nm[1..];
        }
    }
    let at = |i: usize| nm.get(i).copied().unwrap_or(0);
    let mut out: Vec<u8> = Vec::with_capacity(nm.len());
    let mut p = 0;
    while p < nm.len() {
        if nm[p] != b'/' {
            out.push(nm[p]);
            p += 1;
        } else if at(p + 1) == b'.' && (at(p + 2) == b'/' || p + 2 >= nm.len()) {
            // "/." : the whole name "/." keeps its "/", otherwise the "/." goes
            if out.is_empty() && p + 2 >= nm.len() {
                out.push(b'/');
            }
            p += 2;
        } else if at(p + 1) == b'.'
            && at(p + 2) == b'.'
            && !out.is_empty()
            && (at(p + 3) == b'/' || p + 3 >= nm.len())
        {
            // "/..": drop the last component, and its "/"
            while let Some(c) = out.pop() {
                if c == b'/' {
                    break;
                }
            }
            // keep an initial "/" only when this is the whole name
            if out.is_empty() && p + 3 >= nm.len() {
                out.push(b'/');
            }
            p += 3;
        } else if p > 0 && at(p + 1) == b'/' {
            p += 1; // collapse repeated "/" (a leading "//" stays: p == 0 copies the first)
        } else {
            out.push(b'/');
            p += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn as_directory(s: &str) -> String {
    if s.ends_with('/') {
        s.to_string()
    } else {
        format!("{s}/")
    }
}

/// `(expand-file-name NAME DIR)` for a relative NAME and an absolute DIR (not itself canonicalised first, as in Emacs).
fn expand_in(name: &str, dir: &str) -> String {
    normalize(&format!("{}{}", as_directory(dir), name))
}

/// `(expand-file-name "~/REST")` with the home from HOME.
fn in_home(env: &Env, rest: &str) -> String {
    expand_in(rest, env.get("HOME").unwrap_or("/"))
}

/// `(drgnx-paths-dir KIND)` for the kinds a hub needs: `own` is drgnx's variable, `xdg` the XDG one, `base` under "~".
fn dir(env: &Env, own: Option<&str>, xdg: &str, base: &str) -> String {
    let d = match own.and_then(|o| env.abs(o)) {
        Some(v) => normalize(v),
        None => match env.abs(xdg) {
            Some(x) => expand_in("drgnx", x),
            None => expand_in("drgnx", &in_home(env, base)),
        },
    };
    as_directory(&d)
}

/// `(drgnx-data-dir)`: a name ending in "/".
pub fn data_dir(env: &Env) -> PathBuf {
    PathBuf::from(dir(
        env,
        Some("DRGNX_DATA_DIR"),
        "XDG_DATA_HOME",
        ".local/share",
    ))
}

fn state_dir(env: &Env) -> String {
    dir(env, None, "XDG_STATE_HOME", ".local/state")
}

/// `<tmp>`, Emacs's `temporary-file-directory` on Linux and macOS: the first of TMPDIR, TMP, TEMP that is set, else
/// /tmp (a relative one is out of scope).
fn temporary_file_directory(env: &Env) -> String {
    let t = ["TMPDIR", "TMP", "TEMP"]
        .iter()
        .find_map(|n| env.get(n))
        .unwrap_or("/tmp");
    if t.is_empty() {
        "./".to_string()
    } else if t.starts_with('/') {
        as_directory(&normalize(t))
    } else {
        as_directory(t)
    }
}

/// `<tmp>/drgnx-hub-UID/`: where a socket goes whose usual path is too long.
fn private_tmp(env: &Env) -> String {
    expand_in(
        &format!("drgnx-hub-{}", env.uid),
        &temporary_file_directory(env),
    )
}

/// `(drgnx-hub-socket)`: `$XDG_RUNTIME_DIR/drgnx/hub-HASH.sock` when that is a directory, else
/// `<state>/hub/hub-HASH.sock`; over 103 bytes, `<tmp>/drgnx-hub-UID/hub-HASH.sock`.  HASH is sha1 of the data dir
/// (with its trailing "/") cut to 8 hex.
pub fn socket_path(env: &Env) -> PathBuf {
    let data = data_dir(env);
    let hex: String = Sha1::digest(data.as_os_str().as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let name = format!("hub-{}.sock", &hex[..8]);
    let path = match env
        .abs("XDG_RUNTIME_DIR")
        .filter(|r| std::fs::metadata(r).is_ok_and(|m| m.is_dir()))
    {
        Some(run) => expand_in(&name, &expand_in("drgnx", run)),
        None => expand_in(&name, &expand_in("hub", &state_dir(env))),
    };
    if path.len() <= MAX_SOCKET_PATH {
        return PathBuf::from(path);
    }
    PathBuf::from(expand_in(&name, &private_tmp(env)))
}

/// `hub-HASH.cap` beside SOCKET.
pub fn cap_path(socket: &Path) -> PathBuf {
    socket.with_extension("cap")
}

/// `hub-HASH.sock.lock` beside SOCKET.
pub fn lock_path(socket: &Path) -> PathBuf {
    let mut p = socket.as_os_str().to_owned();
    p.push(".lock");
    PathBuf::from(p)
}

/// The Lisp backend's private socket: `<socket dir>/hub-HASH.d/backend.sock` (per data dir, so two data dirs sharing
/// one runtime dir never collide); over 103 bytes `<tmp>/drgnx-hub-UID/hub-HASH.d/backend.sock`; over 103 bytes
/// there too, [`PathError::TooLong`].  `env` gives `<tmp>` and the uid.
pub fn backend_socket_path(env: &Env, socket: &Path) -> Result<PathBuf, PathError> {
    let stem = socket.file_stem().unwrap_or_default().to_string_lossy();
    let rest = format!("{stem}.d/backend.sock");
    let beside = socket.parent().unwrap_or(Path::new("/")).join(&rest);
    if beside.as_os_str().len() <= MAX_SOCKET_PATH {
        return Ok(beside);
    }
    let under_tmp = PathBuf::from(expand_in(&rest, &private_tmp(env)));
    if under_tmp.as_os_str().len() <= MAX_SOCKET_PATH {
        return Ok(under_tmp);
    }
    Err(PathError::TooLong(under_tmp))
}

/// Make DIR a private directory of this user's: made (with its missing parents) mode 0700 from the start when it is
/// not there; then refused unless it is a directory, not a link (one would be followed to wherever it points, and
/// that chmodded) and owned by this uid; then chmodded 0700 through the descriptor that was checked.  The Lisp hub's
/// `drgnx-hub--private-dir`.
pub fn private_dir(dir: &Path) -> io::Result<()> {
    match std::fs::symlink_metadata(dir) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)?,
        Err(e) => return Err(e),
        Ok(_) => {}
    }
    let not_private = |why: &str| {
        io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} {why}", dir.display()),
        )
    };
    // O_NOFOLLOW: a link in the last component fails (ELOOP) instead of being followed
    let fd = rustix::fs::open(
        dir,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|e| not_private(&format!("is not a directory of its own (a link?): {e}")))?;
    let st = rustix::fs::fstat(&fd)?;
    if FileType::from_raw_mode(st.st_mode as _) != FileType::Directory {
        return Err(not_private("is not a directory"));
    }
    if st.st_uid != rustix::process::geteuid().as_raw() {
        return Err(not_private("belongs to another user"));
    }
    rustix::fs::fchmod(&fd, Mode::from_raw_mode(0o700))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn socket_cases_fixture() {
        let file = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../test/fixtures/hub-socket-cases.json"
        );
        let cases: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(file).expect("the fixture file"))
                .expect("the fixture's JSON");
        let cases = cases.as_array().expect("an array");
        assert!(cases.len() >= 13, "the fixture needs at least 13 cases");
        for c in cases {
            let vars: Vec<(&str, &str)> = c["env"]
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, v)| (k.as_str(), v.as_str().unwrap()))
                .collect();
            let env = Env::new(&vars, 4242);
            assert_eq!(
                data_dir(&env).to_str().unwrap(),
                c["data_dir"].as_str().unwrap(),
                "data_dir of {}",
                c["env"]
            );
            let want = c["socket"].as_str().unwrap().replace("$UID", "4242");
            assert_eq!(
                socket_path(&env).to_str().unwrap(),
                want,
                "socket of {}",
                c["env"]
            );
        }
    }

    #[test]
    fn the_cap_and_the_lock_are_beside_the_socket() {
        let s = Path::new("/r/drgnx/hub-546b5fa5.sock");
        assert_eq!(cap_path(s), Path::new("/r/drgnx/hub-546b5fa5.cap"));
        assert_eq!(lock_path(s), Path::new("/r/drgnx/hub-546b5fa5.sock.lock"));
    }

    #[test]
    fn backend_socket_is_per_data_dir_and_within_103_bytes() {
        let a = Env::new(
            &[
                ("HOME", "/hm/u"),
                ("XDG_RUNTIME_DIR", "/tmp"),
                ("DRGNX_DATA_DIR", "/srv/a"),
            ],
            4242,
        );
        let b = Env::new(
            &[
                ("HOME", "/hm/u"),
                ("XDG_RUNTIME_DIR", "/tmp"),
                ("DRGNX_DATA_DIR", "/srv/b"),
            ],
            4242,
        );
        let (sa, sb) = (socket_path(&a), socket_path(&b));
        assert_eq!(sa.parent(), sb.parent(), "one runtime dir");
        let (ba, bb) = (
            backend_socket_path(&a, &sa).unwrap(),
            backend_socket_path(&b, &sb).unwrap(),
        );
        assert_ne!(ba, bb);
        let stem = sa.file_stem().unwrap().to_str().unwrap();
        assert_eq!(
            ba,
            Path::new("/tmp/drgnx").join(format!("{stem}.d/backend.sock"))
        );
        // a main socket of 100 bytes: the backend's would be over 103, so it goes under <tmp>
        let dir = format!("/{}", "s".repeat(100 - "/hub-546b5fa5.sock".len() - 1));
        let main = PathBuf::from(format!("{dir}/hub-546b5fa5.sock"));
        assert_eq!(main.as_os_str().len(), 100);
        let t = Env::new(&[("HOME", "/hm/u"), ("TMPDIR", "/var/tmp")], 4242);
        assert_eq!(
            backend_socket_path(&t, &main).unwrap(),
            Path::new("/var/tmp/drgnx-hub-4242/hub-546b5fa5.d/backend.sock")
        );
        // past 103 bytes there too: refused
        let long_tmp = format!("/{}", "t".repeat(90));
        let t = Env::new(&[("HOME", "/hm/u"), ("TMPDIR", &long_tmp)], 4242);
        assert!(matches!(
            backend_socket_path(&t, &main),
            Err(PathError::TooLong(_))
        ));
        // every path it gives is within 103 bytes
        for env in [&a, &b] {
            let p = backend_socket_path(env, &socket_path(env)).unwrap();
            assert!(p.as_os_str().len() <= 103, "{p:?}");
        }
    }

    #[test]
    fn private_dir_refuses_a_link_and_another_mode() {
        let root = tempfile::tempdir().unwrap();
        let mode = |p: &Path| std::fs::symlink_metadata(p).unwrap().permissions().mode() & 0o7777;
        // made 0700, parents too
        let d = root.path().join("a/b");
        private_dir(&d).unwrap();
        assert!(d.is_dir());
        assert_eq!(mode(&d), 0o700);
        // a directory of another mode is made 0700
        let open = root.path().join("open");
        std::fs::create_dir(&open).unwrap();
        std::fs::set_permissions(&open, std::fs::Permissions::from_mode(0o755)).unwrap();
        private_dir(&open).unwrap();
        assert_eq!(mode(&open), 0o700);
        // a link to a directory is refused, and what it points at is not chmodded
        let target = root.path().join("target");
        std::fs::create_dir(&target).unwrap();
        std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o755)).unwrap();
        let link = root.path().join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(private_dir(&link).is_err());
        assert_eq!(mode(&target), 0o755);
        // a dangling link is refused and not followed
        let dangling = root.path().join("dangling");
        std::os::unix::fs::symlink(root.path().join("nowhere"), &dangling).unwrap();
        assert!(private_dir(&dangling).is_err());
        assert!(!root.path().join("nowhere").exists());
        // a file is refused
        let file = root.path().join("file");
        std::fs::write(&file, "").unwrap();
        assert!(private_dir(&file).is_err());
    }
}
