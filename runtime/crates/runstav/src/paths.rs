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
    /// A session id that is not a file name of letters, digits, `-` and `_`.
    BadName(String),
}

impl fmt::Display for PathError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            PathError::TooLong(p) => write!(
                f,
                "the socket path {} is over {MAX_SOCKET_PATH} bytes (set TMPDIR to a shorter directory)",
                p.display()
            ),
            PathError::BadName(n) => write!(
                f,
                "the session id {n:?} is not a name of letters, digits, - and _"
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

/// `(drgnx-paths-dir 'config)`: a name ending in "/".
pub fn config_dir(env: &Env) -> PathBuf {
    PathBuf::from(dir(
        env,
        Some("DRGNX_CONFIG_DIR"),
        "XDG_CONFIG_HOME",
        ".config",
    ))
}

fn state(env: &Env) -> String {
    dir(env, None, "XDG_STATE_HOME", ".local/state")
}

/// `(drgnx-state-dir)`: a name ending in "/" (`runtime.db` and the hub's log are under its `hub/`).
pub fn state_dir(env: &Env) -> PathBuf {
    PathBuf::from(state(env))
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
        None => expand_in(&name, &expand_in("hub", &state(env))),
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

/// The agent-class hub socket in a session dir ([`session_dir`]), design §4.2.
pub const SESSION_HUB_SOCKET: &str = "hub.sock";

/// The longest socket name a session dir holds (`hub.sock`, `mcp.sock`, `search.sock`, `gateway.sock`): it sizes the
/// fallback.
const SESSION_LONGEST_SOCKET: &str = "gateway.sock";

/// Where session dirs are made, for the hub SOCKET names: `<socket dir>/s` and `<tmp>/drgnx-hub-UID/s` (the
/// fallback).  Gleipnir's run parents: a sandbox is given one direct child of these.
pub fn session_parents(env: &Env, socket: &Path) -> [PathBuf; 2] {
    [
        socket.parent().unwrap_or(Path::new("/")).join("s"),
        PathBuf::from(expand_in("s", &private_tmp(env))),
    ]
}

/// One agent session's private directory (design §4.2): `<socket dir>/s/SID/`, holding that session's sockets
/// (`hub.sock`, agent class; later `mcp.sock`, `search.sock`, `gateway.sock`).  Never `hub-HASH.d/`, the backend's
/// (review M10): a sandbox is given `s/SID` alone, so nothing bound into it reaches `backend.sock`.  When its longest
/// socket would be over 103 bytes, `<tmp>/drgnx-hub-UID/s/SID/`; over there too, [`PathError::TooLong`].  SID is a
/// name of letters, digits, `-` and `_` ([`PathError::BadName`] otherwise).
pub fn session_dir(env: &Env, socket: &Path, sid: &str) -> Result<PathBuf, PathError> {
    let name_ok = !sid.is_empty()
        && sid
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    if !name_ok {
        return Err(PathError::BadName(sid.to_string()));
    }
    let fits = |dir: &Path| dir.join(SESSION_LONGEST_SOCKET).as_os_str().len() <= MAX_SOCKET_PATH;
    let [beside, under_tmp] = session_parents(env, socket).map(|p| p.join(sid));
    if fits(&beside) {
        return Ok(beside);
    }
    if fits(&under_tmp) {
        return Ok(under_tmp);
    }
    Err(PathError::TooLong(under_tmp.join(SESSION_LONGEST_SOCKET)))
}

/// [`session_dir`], made: its root (the socket dir, or `<tmp>/drgnx-hub-UID`), `s/` and `s/SID/` each made private
/// ([`private_dir`]: 0700, ours, not a link) and then checked with [`trusted_dir`].  An unusable path is
/// `InvalidInput`.
pub fn make_session_dir(env: &Env, socket: &Path, sid: &str) -> io::Result<PathBuf> {
    let dir = session_dir(env, socket, sid)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e.to_string()))?;
    let parent = dir.parent().unwrap_or(Path::new("/"));
    for d in [parent.parent().unwrap_or(Path::new("/")), parent, &dir] {
        private_dir(d)?;
        trusted_dir(d)?;
    }
    Ok(dir)
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

/// Why a hub directory fails [`trusted_dir`], in the Lisp client's words (`drgnx-hub--untrusted`).
fn untrusted(dir: &Path, is_dir: bool, uid: u32, mode: u32) -> Option<String> {
    let mode = mode & 0o777;
    if !is_dir {
        Some(format!("{} is not a directory", dir.display()))
    } else if uid != rustix::process::geteuid().as_raw() {
        Some(format!("{} belongs to another user", dir.display()))
    } else if mode & 0o077 != 0 {
        Some(format!(
            "{} is open to other users (mode {mode:o}; it must be 700)",
            dir.display()
        ))
    } else {
        None
    }
}

/// The hub directory DIR (the socket's), opened without following a link, once it is a real directory owned by this
/// euid with no access for others (`mode & 0o077 == 0`): nothing but this user can then have made what is in it.
/// Every client path (a ping, a v0 call, a user connection, the lock's holder, and so `ensure`, `stop`, `status`,
/// `doctor` and `restart`) checks it before it reads, connects to or signals anything.  A refusal is
/// `PermissionDenied` with the Lisp client's text; a directory that is not there is `NotFound` (no hub).  What is in it
/// is read through the descriptor ([`open_in_trusted`]), so a directory swapped in after the check is never read.
pub fn trusted_dir(dir: &Path) -> io::Result<std::os::fd::OwnedFd> {
    let refuse = |why: String| io::Error::new(io::ErrorKind::PermissionDenied, why);
    let fd = match rustix::fs::open(
        dir,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    ) {
        Ok(fd) => fd,
        Err(rustix::io::Errno::NOENT) => {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("{} does not exist (no hub)", dir.display()),
            ));
        }
        // a link (ELOOP), a file (ENOTDIR), another user's (EACCES): say which from what is there
        Err(e) => {
            let why = std::fs::symlink_metadata(dir).ok().and_then(|m| {
                use std::os::unix::fs::MetadataExt;
                untrusted(dir, m.is_dir(), m.uid(), m.mode())
            });
            return Err(refuse(why.unwrap_or_else(|| {
                format!("{} cannot be opened: {e}", dir.display())
            })));
        }
    };
    let st = rustix::fs::fstat(&fd)?;
    let is_dir = FileType::from_raw_mode(st.st_mode as _) == FileType::Directory;
    match untrusted(dir, is_dir, st.st_uid, st.st_mode as u32) {
        Some(why) => Err(refuse(why)),
        None => Ok(fd),
    }
}

/// The file NAME in a directory [`trusted_dir`] gave, opened for reading without following a link, when it is a
/// regular file owned by this euid (`NotFound` when it is not there; else a refusal).
pub fn open_in_trusted(dir: &std::os::fd::OwnedFd, name: &Path) -> io::Result<std::fs::File> {
    let fd = rustix::fs::openat(
        dir,
        name,
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(io::Error::from)?;
    let st = rustix::fs::fstat(&fd)?;
    let refuse = |why: &str| {
        io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} {why}", name.display()),
        )
    };
    if FileType::from_raw_mode(st.st_mode as _) != FileType::RegularFile {
        return Err(refuse("is not a file"));
    }
    if st.st_uid != rustix::process::geteuid().as_raw() {
        return Err(refuse("belongs to another user"));
    }
    Ok(std::fs::File::from(fd))
}

/// Refused unless NAME in a directory [`trusted_dir`] gave is this euid's (it is not followed when a link); `NotFound`
/// when it is not there.  The socket, before a client connects to it.
pub fn owned_in_trusted(dir: &std::os::fd::OwnedFd, name: &Path) -> io::Result<()> {
    let st = rustix::fs::statat(dir, name, rustix::fs::AtFlags::SYMLINK_NOFOLLOW)
        .map_err(io::Error::from)?;
    if st.st_uid != rustix::process::geteuid().as_raw() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} belongs to another user", name.display()),
        ));
    }
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
    fn config_dir_follows_drgnx_paths_dir() {
        let e = |vars: &[(&str, &str)]| config_dir(&Env::new(vars, 1));
        assert_eq!(
            e(&[("HOME", "/hm"), ("DRGNX_CONFIG_DIR", "/c/x")]),
            Path::new("/c/x/")
        );
        assert_eq!(
            e(&[("HOME", "/hm"), ("XDG_CONFIG_HOME", "/xc")]),
            Path::new("/xc/drgnx/")
        );
        // a relative value counts for nothing
        assert_eq!(
            e(&[("HOME", "/hm"), ("DRGNX_CONFIG_DIR", "c")]),
            Path::new("/hm/.config/drgnx/")
        );
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

    /// Review M10: an agent session's sockets are in `s/SID/`, never in or around the backend's `hub-HASH.d/`.
    #[test]
    fn session_dirs_are_apart_from_the_backend_and_within_103_bytes() {
        let env = Env::new(
            &[
                ("HOME", "/hm/u"),
                ("XDG_RUNTIME_DIR", "/tmp"),
                ("DRGNX_DATA_DIR", "/srv/a"),
            ],
            4242,
        );
        let socket = socket_path(&env);
        let stem = socket.file_stem().unwrap().to_str().unwrap();
        let s1 = session_dir(&env, &socket, "s1").unwrap();
        assert_eq!(s1, Path::new("/tmp/drgnx/s/s1"));
        let backend_dir = backend_socket_path(&env, &socket).unwrap();
        let backend_dir = backend_dir.parent().unwrap();
        assert_eq!(
            backend_dir,
            Path::new("/tmp/drgnx").join(format!("{stem}.d"))
        );
        // neither holds the other: a sandbox given s/SID never reaches backend.sock, nor the reverse
        assert!(!s1.starts_with(backend_dir) && !backend_dir.starts_with(&s1));
        assert!(!backend_dir.starts_with(s1.parent().unwrap()));
        assert_eq!(
            session_parents(&env, &socket),
            [
                PathBuf::from("/tmp/drgnx/s"),
                PathBuf::from("/tmp/drgnx-hub-4242/s")
            ]
        );
        // a name only: never a path, a dot name or empty
        for bad in ["", ".", "..", "a/b", "../d", "a b", "a\0b", "é"] {
            assert_eq!(
                session_dir(&env, &socket, bad),
                Err(PathError::BadName(bad.into())),
                "{bad:?}"
            );
        }
        for good in ["s1", "0123456789ab", "a-b_C"] {
            assert!(session_dir(&env, &socket, good).is_ok(), "{good:?}");
        }
        // sized for gateway.sock: 103 bytes fit beside the socket, 104 go under <tmp>
        let t = Env::new(&[("HOME", "/hm/u"), ("TMPDIR", "/var/tmp")], 4242);
        let sid = "0123456789ab";
        let room = |n: usize| {
            // "<dir>/hub-546b5fa5.sock" whose "<dir>/s/SID/gateway.sock" is n bytes
            let dir = format!(
                "/{}",
                "d".repeat(n - "/s/0123456789ab/gateway.sock".len() - 1)
            );
            PathBuf::from(format!("{dir}/hub-546b5fa5.sock"))
        };
        let fits = session_dir(&t, &room(103), sid).unwrap();
        assert_eq!(fits.join("gateway.sock").as_os_str().len(), 103);
        assert!(fits.starts_with(room(103).parent().unwrap()));
        assert_eq!(
            session_dir(&t, &room(104), sid).unwrap(),
            Path::new("/var/tmp/drgnx-hub-4242/s/0123456789ab")
        );
        let long_tmp = format!("/{}", "t".repeat(80));
        let t = Env::new(&[("HOME", "/hm/u"), ("TMPDIR", &long_tmp)], 4242);
        assert!(matches!(
            session_dir(&t, &room(104), sid),
            Err(PathError::TooLong(_))
        ));
    }

    #[test]
    fn make_session_dir_makes_each_level_private_and_refuses_a_link() {
        let root = tempfile::tempdir().unwrap();
        let mode = |p: &Path| std::fs::symlink_metadata(p).unwrap().permissions().mode() & 0o7777;
        let run = root.path().join("run");
        let env = Env::new(
            &[
                ("HOME", "/hm/u"),
                ("XDG_RUNTIME_DIR", run.to_str().unwrap()),
                ("DRGNX_DATA_DIR", "/srv/a"),
            ],
            4242,
        );
        std::fs::create_dir(&run).unwrap();
        let socket = socket_path(&env);
        let made = make_session_dir(&env, &socket, "s1").unwrap();
        assert_eq!(made, run.join("drgnx/s/s1"));
        for d in [run.join("drgnx"), run.join("drgnx/s"), made.clone()] {
            assert_eq!(mode(&d), 0o700, "{d:?}");
        }
        // again: the same, fine
        assert_eq!(make_session_dir(&env, &socket, "s1").unwrap(), made);
        // a session dir that is a link (to the backend's dir, say) is refused and not followed
        let backend = run.join("drgnx/hub-x.d");
        std::fs::create_dir(&backend).unwrap();
        std::os::unix::fs::symlink(&backend, run.join("drgnx/s/s2")).unwrap();
        assert!(make_session_dir(&env, &socket, "s2").is_err());
        // and so is s/ itself as a link
        std::fs::remove_dir_all(run.join("drgnx/s")).unwrap();
        std::os::unix::fs::symlink(&backend, run.join("drgnx/s")).unwrap();
        assert!(make_session_dir(&env, &socket, "s3").is_err());
        assert!(!backend.join("s3").exists());
        // a bad name is refused before anything is made
        let e = make_session_dir(&env, &socket, "../x").unwrap_err();
        assert_eq!(e.kind(), io::ErrorKind::InvalidInput);
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

    #[test]
    fn private_dir_refuses_another_users_directory() {
        // review M14: only root can make one here (the container's root job)
        if !rustix::process::geteuid().is_root() {
            return;
        }
        let root = tempfile::tempdir().unwrap();
        let theirs = root.path().join("theirs");
        std::fs::create_dir(&theirs).unwrap();
        std::fs::set_permissions(&theirs, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::os::unix::fs::chown(&theirs, Some(65534), Some(65534)).unwrap();
        let e = private_dir(&theirs).unwrap_err();
        assert!(e.to_string().ends_with("belongs to another user"), "{e}");
        // and it is not chmodded
        assert_eq!(
            std::fs::metadata(&theirs).unwrap().permissions().mode() & 0o777,
            0o755
        );
    }

    /// The refusal's text, or "ok".
    fn judged(dir: &Path) -> String {
        match trusted_dir(dir) {
            Ok(_) => "ok".into(),
            Err(e) if e.kind() == io::ErrorKind::NotFound => format!("missing: {e}"),
            Err(e) => {
                assert_eq!(e.kind(), io::ErrorKind::PermissionDenied, "{e}");
                e.to_string()
            }
        }
    }

    #[test]
    fn trusted_dir_takes_only_a_private_directory_of_this_user() {
        let root = tempfile::tempdir().unwrap();
        let d = root.path().join("drgnx");
        assert!(judged(&d).starts_with("missing: "), "{}", judged(&d));
        std::fs::create_dir(&d).unwrap();
        for (mode, ok) in [
            (0o700, true),
            (0o500, true),
            (0o755, false),
            (0o711, false),
            (0o770, false),
            (0o701, false),
        ] {
            std::fs::set_permissions(&d, std::fs::Permissions::from_mode(mode)).unwrap();
            let got = judged(&d);
            if ok {
                assert_eq!(got, "ok", "mode {mode:o}");
            } else {
                assert!(
                    got.ends_with(&format!(
                        "is open to other users (mode {mode:o}; it must be 700)"
                    )),
                    "{got}"
                );
            }
        }
        std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o700)).unwrap();
        // a link to a private directory is refused (never followed), and so is a file
        let link = root.path().join("link");
        std::os::unix::fs::symlink(&d, &link).unwrap();
        assert!(
            judged(&link).ends_with("is not a directory"),
            "{}",
            judged(&link)
        );
        let file = root.path().join("file");
        std::fs::write(&file, "").unwrap();
        assert!(
            judged(&file).ends_with("is not a directory"),
            "{}",
            judged(&file)
        );
        // another user's (only root can make one here)
        if rustix::process::geteuid().is_root() {
            let theirs = root.path().join("theirs");
            std::fs::create_dir(&theirs).unwrap();
            std::fs::set_permissions(&theirs, std::fs::Permissions::from_mode(0o700)).unwrap();
            std::os::unix::fs::chown(&theirs, Some(65534), Some(65534)).unwrap();
            assert!(
                judged(&theirs).ends_with("belongs to another user"),
                "{}",
                judged(&theirs)
            );
        }
    }

    #[test]
    fn what_is_in_a_trusted_dir_is_read_through_it_never_through_a_link() {
        let root = tempfile::tempdir().unwrap();
        let d = root.path().join("drgnx");
        std::fs::create_dir(&d).unwrap();
        std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o700)).unwrap();
        let fd = trusted_dir(&d).unwrap();
        std::fs::write(d.join("hub-x.cap"), "c").unwrap();
        let mut text = String::new();
        std::io::Read::read_to_string(
            &mut open_in_trusted(&fd, Path::new("hub-x.cap")).unwrap(),
            &mut text,
        )
        .unwrap();
        assert_eq!(text, "c");
        assert!(owned_in_trusted(&fd, Path::new("hub-x.cap")).is_ok());
        // not there
        let missing = open_in_trusted(&fd, Path::new("nope")).unwrap_err();
        assert_eq!(missing.kind(), io::ErrorKind::NotFound);
        assert_eq!(
            owned_in_trusted(&fd, Path::new("nope")).unwrap_err().kind(),
            io::ErrorKind::NotFound
        );
        // a link to a file elsewhere is not followed
        let outside = root.path().join("outside");
        std::fs::write(&outside, "secret").unwrap();
        std::os::unix::fs::symlink(&outside, d.join("hub-y.cap")).unwrap();
        assert!(open_in_trusted(&fd, Path::new("hub-y.cap")).is_err());
        // a directory is no file
        std::fs::create_dir(d.join("sub")).unwrap();
        assert!(
            open_in_trusted(&fd, Path::new("sub"))
                .unwrap_err()
                .to_string()
                .ends_with("is not a file")
        );
        if rustix::process::geteuid().is_root() {
            std::os::unix::fs::chown(d.join("hub-x.cap"), Some(65534), Some(65534)).unwrap();
            for e in [
                open_in_trusted(&fd, Path::new("hub-x.cap")).unwrap_err(),
                owned_in_trusted(&fd, Path::new("hub-x.cap")).unwrap_err(),
            ] {
                assert!(e.to_string().ends_with("belongs to another user"), "{e}");
            }
        }
    }
}
