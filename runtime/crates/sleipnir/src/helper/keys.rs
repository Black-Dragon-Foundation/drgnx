//! A job's keys in the job helper (docs/develop/sleipnir.md, "Keys"): never on disk, never in swap, never in a core
//! dump, never in podman's argv or stored config.
//!
//! - `serve` hands each key over `D/helper.sock` ([`hand`]): `key NAME LEN\n` and the value's bytes; the helper answers
//!   `ok` or `no WHY`. Only the names the job's spec lists are taken.
//! - The helper holds each value in a [`Locked`] buffer: an anonymous mapping, `mlock`ed and left out of core dumps,
//!   zeroed and unmapped when it goes.
//! - `drgnx-key` asks on `@drgnx-key`, an abstract socket of the job's relay sidecar in the network namespace the job
//!   joins; the sidecar carries each connection to the helper as a key stream (docs/develop/drgnx-px.md, "Key
//!   streams"), and [`answer`] answers its one request line, `get NAME`: `ok LEN\n` and the bytes, `no WHY`, or, when
//!   the key hasn't come within [`KEY_WAIT`], `timeout`, after the helper has recorded the request in `D/key-timeout`;
//!   job-exec reads that record as `infra: key not delivered`. Each answered read is a line in `D/key-use` (the name
//!   and the time, never the value), which `serve` sends up as `key-use` frames.
//! - An `ok` answer is built in a [`Locked`] buffer and written to the channel from there; the relay's own copies of
//!   it (one frame) are zeroed once written (`drgnx_px::shell`).
//!
//! The same store and relay serve a keyed job that stays on the hub's machine.

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use zeroize::Zeroize;

/// The socket `serve` hands keys over, in the attempt's folder.
pub const HELPER_SOCK: &str = "helper.sock";
/// The record of key requests that timed out (one name per line).
pub const KEY_TIMEOUT: &str = crate::linux::jobexec::KEY_TIMEOUT;
/// The record of delivered reads (`{"name":…,"at":…}` per line).
pub const KEY_USE: &str = "key-use";
/// How long a request waits for its key.
pub const KEY_WAIT: Duration = Duration::from_secs(60);
/// `drgnx-key`'s exit status when its key never came.
pub const NOT_DELIVERED: i32 = 75;
/// The largest key value taken.
pub const MAX_KEY: usize = 64 << 10;
/// The longest request line.
pub const MAX_LINE: u64 = 512;

/// A key name: what the job spec lists and `drgnx-key` asks for (letters, digits, `_`, `-`, `.`; at most 128).
pub fn plain_name(n: &str) -> bool {
    !n.is_empty()
        && n.len() <= 128
        && n.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-.".contains(&b))
}

/// Bytes that never reach swap or a core dump: an anonymous private mapping, `mlock`ed and marked `MADV_DONTDUMP`;
/// zeroed, unlocked and unmapped when dropped. It has no `Debug`, `Clone` or `Serialize`.
pub struct Locked {
    ptr: *mut u8,
    len: usize,
    cap: usize,
}

// SAFETY: the mapping is owned by this value alone; access goes through &self / &mut self
unsafe impl Send for Locked {}
unsafe impl Sync for Locked {}

impl Locked {
    /// A locked copy of BYTES. Fails when the memory can't be locked (`RLIMIT_MEMLOCK`): a key is never held in
    /// memory that could be swapped.
    pub fn new(bytes: &[u8]) -> io::Result<Locked> {
        // SAFETY: sysconf has no preconditions
        let page = usize::try_from(unsafe { libc::sysconf(libc::_SC_PAGESIZE) }).unwrap_or(4096);
        let cap = bytes.len().max(1).div_ceil(page) * page;
        // SAFETY: a fresh anonymous mapping; checked for failure before use
        let ptr = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                cap,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANONYMOUS,
                -1,
                0,
            )
        };
        if ptr == libc::MAP_FAILED {
            return Err(io::Error::last_os_error());
        }
        // owned from here: an early return unmaps it
        let mut l = Locked {
            ptr: ptr.cast(),
            len: 0,
            cap,
        };
        // SAFETY: the mapping above, whole
        unsafe {
            if libc::madvise(ptr, cap, libc::MADV_DONTDUMP) != 0 || libc::mlock(ptr, cap) != 0 {
                return Err(io::Error::last_os_error());
            }
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), l.ptr, bytes.len());
        }
        l.len = bytes.len();
        Ok(l)
    }

    /// A locked buffer holding PARTS one after another: a message built around a key without an unlocked copy.
    pub fn concat(parts: &[&[u8]]) -> io::Result<Locked> {
        let len: usize = parts.iter().map(|p| p.len()).sum();
        let mut l = Locked::new(&[])?;
        if len > l.cap {
            l = Locked::new(&vec![0u8; len])?;
        }
        let mut at = 0;
        for p in parts {
            // SAFETY: at + p.len() ≤ len ≤ cap bytes of our live mapping
            unsafe { std::ptr::copy_nonoverlapping(p.as_ptr(), l.ptr.add(at), p.len()) };
            at += p.len();
        }
        l.len = len;
        Ok(l)
    }

    pub fn bytes(&self) -> &[u8] {
        // SAFETY: len ≤ cap bytes of our live mapping
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }
}

impl Drop for Locked {
    fn drop(&mut self) {
        // SAFETY: our live mapping, whole; unmapped once, here
        unsafe {
            std::slice::from_raw_parts_mut(self.ptr, self.cap).zeroize();
            #[cfg(feature = "test-hooks")]
            probe::dropped(std::slice::from_raw_parts(self.ptr, self.cap));
            libc::munlock(self.ptr.cast(), self.cap);
            libc::munmap(self.ptr.cast(), self.cap);
        }
    }
}

/// Test builds only: what the last [`Locked`] dropped on this thread held at the moment before it was unmapped.
#[cfg(feature = "test-hooks")]
pub mod probe {
    use std::cell::Cell;

    thread_local! {
        static LAST: Cell<Option<bool>> = const { Cell::new(None) };
    }

    pub(super) fn dropped(bytes: &[u8]) {
        LAST.with(|l| l.set(Some(bytes.iter().all(|b| *b == 0))));
    }

    /// Whether the last buffer dropped on this thread was all zeros before it was unmapped; `None` when none was.
    pub fn last_zeroed() -> Option<bool> {
        LAST.with(Cell::take)
    }
}

/// Why a request got no key.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Miss {
    /// The job's spec doesn't name it.
    NotListed,
    /// It didn't come in time.
    TimedOut,
}

/// The job's keys: the names its spec lists, and the values that came.
pub struct KeyStore {
    names: Vec<String>,
    keys: Mutex<BTreeMap<String, Locked>>,
    came: Condvar,
}

impl KeyStore {
    pub fn new(names: Vec<String>) -> KeyStore {
        KeyStore {
            names,
            keys: Mutex::new(BTreeMap::new()),
            came: Condvar::new(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, BTreeMap<String, Locked>> {
        self.keys.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Takes NAME's VALUE (locked); a name the job doesn't list, a NUL or an over-long value is refused.
    pub fn put(&self, name: &str, value: &[u8]) -> Result<(), String> {
        if !self.names.iter().any(|n| n == name) {
            return Err(format!("the job doesn't name the key {name}"));
        }
        if value.len() > MAX_KEY || value.contains(&0) {
            return Err(format!("key {name}: a NUL in it, or over {MAX_KEY} bytes"));
        }
        let l = Locked::new(value)
            .map_err(|e| format!("key {name}: memory that can't be locked: {e}"))?;
        self.lock().insert(name.to_string(), l);
        self.came.notify_all();
        Ok(())
    }

    /// Runs F on NAME's value once it is here, waiting up to WAIT for it.
    pub fn with<T>(
        &self,
        name: &str,
        wait: Duration,
        f: impl FnOnce(&[u8]) -> T,
    ) -> Result<T, Miss> {
        if !self.names.iter().any(|n| n == name) {
            return Err(Miss::NotListed);
        }
        let end = Instant::now() + wait;
        let mut keys = self.lock();
        loop {
            if let Some(v) = keys.get(name) {
                return Ok(f(v.bytes()));
            }
            let left = end.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(Miss::TimedOut);
            }
            keys = self
                .came
                .wait_timeout(keys, left)
                .unwrap_or_else(|e| e.into_inner())
                .0;
        }
    }

    /// Drops every value (each is zeroed).
    pub fn clear(&self) {
        self.lock().clear();
    }
}

/// Binds the socket NAME in DIR, mode 0600, at once: bound under a temporary name and renamed, so whoever sees it
/// can connect.
pub fn bind(dir: &Path, name: &str) -> io::Result<UnixListener> {
    let tmp = dir.join(format!(".{name}.tmp"));
    let _ = fs::remove_file(&tmp);
    let l = UnixListener::bind(&tmp)?;
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
    fs::rename(&tmp, dir.join(name))?;
    Ok(l)
}

/// The peer is this user (the job runs as it, in a user namespace that keeps the id).
fn same_user(s: &UnixStream) -> bool {
    rustix::net::sockopt::socket_peercred(s).is_ok_and(|c| c.uid == rustix::process::getuid())
}

/// One request line, at most [`MAX_LINE`] bytes.
fn line(r: &mut BufReader<UnixStream>) -> io::Result<String> {
    let mut s = String::new();
    r.by_ref().take(MAX_LINE).read_line(&mut s)?;
    Ok(s.trim_end_matches('\n').to_string())
}

fn now_s() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn append(path: &Path, text: &str) -> io::Result<()> {
    fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .and_then(|mut f| f.write_all(text.as_bytes()))
}

/// Takes keys on L for STORE (`serve`'s side), one thread per connection.
pub fn serve_hub(l: UnixListener, store: Arc<KeyStore>) {
    std::thread::spawn(move || {
        for s in l.incoming().flatten() {
            let store = store.clone();
            std::thread::spawn(move || take_key(s, &store));
        }
    });
}

fn take_key(s: UnixStream, store: &KeyStore) {
    if !same_user(&s) {
        return;
    }
    let Ok(mut w) = s.try_clone() else { return };
    let mut r = BufReader::new(s);
    let answer = (|| -> Result<(), String> {
        let head = line(&mut r).map_err(|e| e.to_string())?;
        let mut words = head.split(' ');
        let (Some("key"), Some(name), Some(len), None) =
            (words.next(), words.next(), words.next(), words.next())
        else {
            return Err("not `key NAME LEN`".into());
        };
        let len: usize = len.parse().map_err(|_| "LEN is a number")?;
        if len > MAX_KEY {
            return Err(format!("over {MAX_KEY} bytes"));
        }
        let mut value = vec![0u8; len];
        let read = r.read_exact(&mut value);
        let put = read
            .map_err(|e| e.to_string())
            .and_then(|()| store.put(name, &value));
        value.zeroize();
        put
    })();
    let _ = match answer {
        Ok(()) => w.write_all(b"ok\n"),
        Err(why) => w.write_all(format!("no {}\n", why.replace('\n', " ")).as_bytes()),
    };
}

/// What a key request is answered: the key, in locked memory, or a line of text.
pub enum Answer {
    /// `ok LEN\n` and the value.
    Key(Locked),
    /// `no WHY\n` or `timeout\n`.
    Text(Vec<u8>),
}

impl Answer {
    pub fn bytes(&self) -> &[u8] {
        match self {
            Answer::Key(l) => l.bytes(),
            Answer::Text(t) => t,
        }
    }
}

/// Answers one request line REQ (without its newline) from STORE, waiting up to WAIT for the key; the records go in
/// DIR. Blocks while it waits.
pub fn answer(store: &KeyStore, dir: &Path, wait: Duration, req: &str) -> Answer {
    let Some(name) = req.strip_prefix("get ").filter(|n| plain_name(n)) else {
        return Answer::Text(b"no not `get NAME`\n".to_vec());
    };
    let built = store.with(name, wait, |v| {
        Locked::concat(&[format!("ok {}\n", v.len()).as_bytes(), v])
    });
    match built {
        Ok(Ok(l)) => {
            let _ = append(
                &dir.join(KEY_USE),
                &format!("{}\n", serde_json::json!({"name": name, "at": now_s()})),
            );
            Answer::Key(l)
        }
        Ok(Err(e)) => {
            Answer::Text(format!("no key {name}: memory that can't be locked: {e}\n").into_bytes())
        }
        Err(Miss::NotListed) => {
            Answer::Text(format!("no the job doesn't name the key {name}\n").into_bytes())
        }
        Err(Miss::TimedOut) => {
            // recorded first: by the time drgnx-key exits 75, the record that classifies it is there
            let _ = append(&dir.join(KEY_TIMEOUT), &format!("{name}\n"));
            Answer::Text(b"timeout\n".to_vec())
        }
    }
}

/// `serve`'s side: hands NAME's VALUE to the helper listening on SOCK.
pub fn hand(sock: &Path, name: &str, value: &[u8]) -> io::Result<()> {
    if !plain_name(name) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "not a key name",
        ));
    }
    let mut s = UnixStream::connect(sock)?;
    s.set_read_timeout(Some(Duration::from_secs(10)))?;
    s.set_write_timeout(Some(Duration::from_secs(10)))?;
    let mut msg = format!("key {name} {}\n", value.len()).into_bytes();
    msg.extend_from_slice(value);
    let w = s.write_all(&msg);
    msg.zeroize();
    w?;
    let mut r = BufReader::new(s);
    let mut answer = String::new();
    r.by_ref().take(MAX_LINE).read_line(&mut answer)?;
    match answer.trim_end() {
        "ok" => Ok(()),
        a => Err(io::Error::other(format!(
            "the job helper: {}",
            a.strip_prefix("no ").unwrap_or(a)
        ))),
    }
}

/// The names in DIR's timeout record.
pub fn timed_out(dir: &Path) -> Vec<String> {
    fs::read_to_string(dir.join(KEY_TIMEOUT))
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [D] A key that came in a `key` frame is held in a locked buffer, and that buffer is all zeros at the moment
    /// before it is unmapped.
    #[cfg(feature = "test-hooks")]
    #[test]
    fn key_frames_are_zeroed_at_drop() {
        use crate::proto::{Frame, FrameReader, FrameWriter, JobRef, Key, KeyValue, Nonce};
        let value = format!("v{:x}", std::process::id());
        let mut w = FrameWriter::new(Vec::new());
        w.write(&Frame::Key(Key {
            r: JobRef {
                job: "a1".into(),
                attempt: 1,
                nonce: Nonce([7; 16]),
            },
            name: "TOKEN".into(),
            value: KeyValue::new(secrecy::SecretString::from(value.clone())),
        }))
        .unwrap();
        let wire = w.into_inner();
        let Some(Frame::Key(k)) = FrameReader::new(&wire[..]).read().unwrap() else {
            panic!("not a key frame");
        };
        let store = KeyStore::new(vec!["TOKEN".into()]);
        store.put(&k.name, k.value.expose().as_bytes()).unwrap();
        drop(k);
        assert_eq!(
            store.with("TOKEN", Duration::ZERO, |v| v == value.as_bytes()),
            Ok(true),
            "the store holds the frame's value"
        );
        assert_eq!(probe::last_zeroed(), None, "nothing dropped yet");
        store.clear();
        assert_eq!(
            probe::last_zeroed(),
            Some(true),
            "the buffer was zeroed before it was unmapped"
        );
        let l = Locked::new(b"another").unwrap();
        drop(l);
        assert_eq!(probe::last_zeroed(), Some(true));
    }

    /// [D] A request is answered `ok LEN` and the value in locked memory, recorded by name only; an unlisted name, a
    /// malformed line and a key that never came are answered in text, the last recorded as a timeout.
    #[test]
    fn requests_are_answered_from_locked_memory() {
        let d = tempfile::tempdir().unwrap();
        let s = KeyStore::new(vec!["A".into(), "B".into()]);
        s.put("A", b"secret-a").unwrap();
        let a = answer(&s, d.path(), Duration::ZERO, "get A");
        assert!(matches!(a, Answer::Key(_)));
        assert_eq!(a.bytes(), b"ok 8\nsecret-a");
        let uses = fs::read_to_string(d.path().join(KEY_USE)).unwrap();
        assert!(uses.contains("\"A\"") && !uses.contains("secret"), "{uses}");
        for (req, want) in [
            ("get C", "no the job doesn't name the key C\n"),
            ("get", "no not `get NAME`\n"),
            ("get A B", "no not `get NAME`\n"),
            ("put A", "no not `get NAME`\n"),
            ("get B", "timeout\n"),
        ] {
            assert_eq!(
                String::from_utf8_lossy(answer(&s, d.path(), Duration::ZERO, req).bytes()),
                want,
                "{req}"
            );
        }
        assert_eq!(timed_out(d.path()), ["B"]);
        let big = vec![7u8; 9000];
        let l = Locked::concat(&[b"ok 9000\n", &big]).unwrap();
        assert_eq!(&l.bytes()[..8], b"ok 9000\n");
        assert_eq!(&l.bytes()[8..], &big[..]);
    }

    /// [D] Only the names the spec lists are taken or served; a missing key times out, a listed one is served.
    #[test]
    fn only_listed_names_are_taken_or_served() {
        let s = KeyStore::new(vec!["A".into()]);
        assert!(s.put("B", b"x").is_err());
        assert!(s.put("A", b"x\0y").is_err());
        assert_eq!(s.with("B", Duration::ZERO, |_| ()), Err(Miss::NotListed));
        assert_eq!(s.with("A", Duration::ZERO, |_| ()), Err(Miss::TimedOut));
        s.put("A", b"xy").unwrap();
        assert_eq!(
            s.with("A", Duration::ZERO, <[u8]>::to_vec),
            Ok(b"xy".to_vec())
        );
    }
}
