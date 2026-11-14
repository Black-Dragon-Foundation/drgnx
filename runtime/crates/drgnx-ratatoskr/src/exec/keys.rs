//! A keyed job on this machine (docs/guide/runners.md, "Keys"; docs/develop/hub.md, "Keyed jobs here"): its keys come
//! from the hub's memory over a key socket of its own, as a runner's job gets them from its job helper, and never touch
//! disk.
//!
//! - [`JobKeys`] answers `drgnx-key`'s one request line ([`sleipnir::keyline`]): only a key the job names, once the
//!   hub holds it (asked for with `runners/need-keys`, waited for up to [`keyline::KEY_WAIT`]). Every value it hands
//!   out is added to the job's [`Redactor`] first, so the job's log never holds it; the first hand-out of each key is
//!   recorded as `key_sent` with runner `local` (attempt 0: no runner attempt). A key that doesn't come makes the job's
//!   result `infra: key not delivered` (its `why`, written before the `timeout` answer).
//! - [`serve`] puts it behind a path socket: mode 0600 from the moment it is seen, this user's connections only, and
//!   removed when the job ends. A container job reaches the same answers through its relay sidecar's key streams.

use crate::runners::keys::{self, Keys};
use crate::runners::redact::Redactor;
use runstav::methods::runners::AuditKind;
use secrecy::ExposeSecret;
use sleipnir::keyline;
use std::collections::HashSet;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use zeroize::Zeroizing;

/// The runner a local hand-out is recorded on.
pub const LOCAL_RUNNER: &str = "local";
/// How long a connection has to send its request line.
const REQUEST_LIMIT: Duration = Duration::from_secs(10);

/// One keyed job's keys on this machine.
pub struct JobKeys {
    job: String,
    names: Vec<String>,
    keys: Arc<Keys>,
    dir: PathBuf,
    wait: Duration,
    redact: Arc<Mutex<Redactor>>,
    sent: Mutex<HashSet<String>>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The `why` of a job whose key never came.
pub fn not_delivered() -> String {
    format!("infra: {}", forseti::classify::infra::KEY_NOT_DELIVERED)
}

impl JobKeys {
    /// Job JOB (its folder DIR) naming the keys NAMES, answered from KEYS, each waited for up to WAIT. Its redactor
    /// starts with the values the hub holds now.
    pub fn new(
        job: &str,
        names: Vec<String>,
        keys: Arc<Keys>,
        dir: &Path,
        wait: Duration,
    ) -> Arc<JobKeys> {
        let held: Vec<_> = names.iter().filter_map(|n| keys.value(n)).collect();
        Arc::new(JobKeys {
            job: job.to_string(),
            names,
            keys,
            dir: dir.to_path_buf(),
            wait,
            redact: Arc::new(Mutex::new(Redactor::new(&held))),
            sent: Mutex::new(HashSet::new()),
        })
    }

    /// The job's redactor: what reads its output masks every key handed to it.
    pub fn redactor(&self) -> Arc<Mutex<Redactor>> {
        self.redact.clone()
    }

    /// The answer to one request line REQ (without its newline).
    pub async fn answer(&self, req: &str) -> Zeroizing<Vec<u8>> {
        let Some(name) = keyline::requested(req) else {
            return Zeroizing::new(keyline::not_a_request());
        };
        if !self.names.iter().any(|n| n == name) {
            return Zeroizing::new(keyline::not_listed(name));
        }
        let Some(value) = self.keys.wait_for(name, self.wait).await else {
            // recorded first: by the time drgnx-key exits 75, the result reads it
            self.not_delivered(name);
            return Zeroizing::new(keyline::TIMEOUT.to_vec());
        };
        let v = value.expose_secret().as_bytes();
        if v.len() > keyline::MAX_KEY || v.contains(&0) {
            let why = format!(
                "no key {name}: a NUL in it, or over {} bytes\n",
                keyline::MAX_KEY
            );
            return Zeroizing::new(why.into_bytes());
        }
        // masked before it leaves: the job can print it only after this
        lock(&self.redact).add(&value);
        let mut out = Zeroizing::new(keyline::ok_head(v.len()).into_bytes());
        out.extend_from_slice(v);
        if lock(&self.sent).insert(name.to_string()) {
            let r = sleipnir::proto::JobRef {
                job: self.job.clone(),
                attempt: 0,
                nonce: sleipnir::proto::Nonce([0; 16]),
            };
            let at = crate::clock::wall_secs() as u64;
            if let Some(row) = keys::row(AuditKind::Sent, &r, name, LOCAL_RUNNER, at) {
                self.keys.record(row);
            }
        }
        out
    }

    /// Key NAME didn't come: the job's result is `infra: key not delivered` (unless it already ended otherwise), and
    /// its log says which key.
    fn not_delivered(&self, name: &str) {
        let why = self.dir.join("why");
        if !why.exists() {
            let _ = std::fs::write(&why, not_delivered());
        }
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.dir.join("log"))
        {
            let _ = writeln!(
                f,
                "drgnx: {}: {name} (the hub didn't hold it within {} s)",
                not_delivered(),
                self.wait.as_secs()
            );
        }
    }
}

/// A container job's relay sidecar asks [`JobKeys`] through its key streams.
pub struct Source(pub Arc<JobKeys>);

struct Answer(Zeroizing<Vec<u8>>);

impl drgnx_px::owner::KeyAnswer for Answer {
    fn bytes(&self) -> &[u8] {
        &self.0
    }
}

impl drgnx_px::owner::KeySource for Source {
    fn answer(&self, request: &str) -> drgnx_px::owner::AnswerFuture {
        let (k, req) = (self.0.clone(), request.to_string());
        Box::pin(async move {
            Box::new(Answer(k.answer(&req).await)) as Box<dyn drgnx_px::owner::KeyAnswer>
        })
    }
}

/// The static `drgnx-key` for a podman architecture (`amd64`, `arm64`), as `drgnx runtime install` names it next to
/// the hub: `drgnx-key-<arch>-linux-musl`.
pub fn static_key_name(podman_arch: &str) -> String {
    let arch = if podman_arch == "arm64" {
        "aarch64"
    } else {
        "x86_64"
    };
    format!("drgnx-key-{arch}-linux-musl")
}

/// A job's key socket: removed, and its answers stopped, when dropped.
pub struct Socket {
    path: PathBuf,
    task: tokio::task::JoinHandle<()>,
}

impl Socket {
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for Socket {
    fn drop(&mut self) {
        self.task.abort();
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Binds PATH (mode 0600 before it is seen: bound under a temporary name beside it, then renamed) and answers each of
/// this user's connections from KEYS: one request line, one answer.
pub fn serve(path: &Path, keys: Arc<JobKeys>) -> io::Result<Socket> {
    use std::os::unix::fs::PermissionsExt;
    let dir = path.parent().unwrap_or(Path::new("/"));
    let mut tmp_name = std::ffi::OsString::from(".");
    tmp_name.push(path.file_name().unwrap_or_default());
    tmp_name.push(".tmp");
    let tmp = dir.join(tmp_name);
    let _ = std::fs::remove_file(&tmp);
    let l = std::os::unix::net::UnixListener::bind(&tmp)?;
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
    std::fs::rename(&tmp, path)?;
    l.set_nonblocking(true)?;
    let l = tokio::net::UnixListener::from_std(l)?;
    let task = crate::clock::spawn("exec:key-socket", async move {
        while let Ok((s, _)) = l.accept().await {
            let keys = keys.clone();
            crate::clock::spawn("exec:key-answer", async move { one(s, &keys).await });
        }
    });
    Ok(Socket {
        path: path.to_path_buf(),
        task,
    })
}

async fn one(s: tokio::net::UnixStream, keys: &JobKeys) {
    let mine = s
        .peer_cred()
        .is_ok_and(|c| c.uid() == rustix::process::getuid().as_raw());
    if !mine {
        return;
    }
    let (r, mut w) = s.into_split();
    let mut line = String::new();
    let mut r = BufReader::new(r).take(keyline::MAX_LINE);
    let read = r.read_line(&mut line);
    if !matches!(
        crate::clock::real_timeout(REQUEST_LIMIT, read).await,
        Ok(Ok(_))
    ) {
        return;
    }
    let answer = keys.answer(line.trim_end_matches('\n')).await;
    let _ = w.write_all(&answer).await;
    let _ = w.shutdown().await;
}

/// Copies a keyed job's output OUT into its LOG (appended: a relay's lines may be there already), each chunk through
/// REDACT, and what it held back at the end.
pub async fn pump(
    mut out: impl tokio::io::AsyncRead + Unpin,
    log: PathBuf,
    redact: Arc<Mutex<Redactor>>,
) {
    use zeroize::Zeroize;
    let Ok(mut f) = tokio::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log)
        .await
    else {
        return;
    };
    let mut buf = vec![0u8; 16 << 10];
    loop {
        let n = match out.read(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        let masked = lock(&redact).redact(&buf[..n]);
        buf[..n].zeroize();
        if f.write_all(&masked).await.is_err() || f.flush().await.is_err() {
            break;
        }
    }
    let rest = lock(&redact).finish();
    let _ = f.write_all(&rest).await;
    let _ = f.flush().await;
}

/// The argv that runs ARGV with each of KEYS in the variable of its name, through `drgnx-key` at BIN.
pub fn wrapped_argv(bin: &Path, keys: &[String], argv: &[String]) -> Vec<String> {
    let mut a = vec![bin.to_string_lossy().into_owned(), "exec".into()];
    a.extend(keys.iter().map(|k| format!("{k}={k}")));
    a.push("--".into());
    a.extend(argv.iter().cloned());
    a
}

/// Where job ID's key socket goes: in the session's own folder for a session's job (the only sockets its sandbox may
/// reach are there), else in the job's folder DIR; a path over a socket's limit falls back to the hub's private
/// temporary folder. None: no path fits.
pub fn socket_path(
    env: &runstav::paths::Env,
    session: Option<&str>,
    dir: &Path,
    id: &str,
) -> Option<PathBuf> {
    use std::os::unix::ffi::OsStrExt;
    let fits = |p: &Path| p.as_os_str().as_bytes().len() <= runstav::paths::MAX_SOCKET_PATH;
    let hub = runstav::paths::socket_path(env);
    let name = format!("k-{id}.sock");
    if let Some(sid) = session {
        let p = runstav::paths::session_dir(env, &hub, sid).ok()?.join(name);
        return fits(&p).then_some(p);
    }
    let own = dir.join("key.sock");
    if fits(&own) {
        return Some(own);
    }
    let [_, under_tmp] = runstav::paths::session_parents(env, &hub);
    let p = under_tmp.parent()?.join(name);
    fits(&p).then_some(p)
}

#[cfg(test)]
mod tests {
    use super::*;
    use secrecy::SecretString;
    use std::io::{Read, Write};

    fn held(pairs: &[(&str, &str)]) -> Arc<Keys> {
        let k = Arc::new(Keys::default());
        k.take(
            pairs
                .iter()
                .map(|(n, v)| (n.to_string(), SecretString::from(v.to_string()))),
        );
        k
    }

    /// One request on the socket at PATH, as `drgnx-key` sends it; the whole answer.
    fn ask(path: &Path, req: &str) -> Vec<u8> {
        let mut s = std::os::unix::net::UnixStream::connect(path).unwrap();
        s.write_all(format!("{req}\n").as_bytes()).unwrap();
        let mut out = vec![];
        std::io::BufReader::new(s).read_to_end(&mut out).unwrap();
        out
    }

    /// [D] A job's key socket is its user's alone (0600), answers `get NAME` with the value for a key the job names,
    /// refuses one it doesn't name and a line that isn't a request, records the first hand-out as `key_sent` on
    /// `local`, masks the value in the job's redactor before it leaves, and is gone once dropped.
    #[tokio::test(flavor = "multi_thread")]
    async fn the_key_socket_answers_the_jobs_own_keys_only() {
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let keys = held(&[("TOKEN", "v-3q8Zk"), ("OTHER", "o-9")]);
        let jk = JobKeys::new(
            "x1",
            vec!["TOKEN".into()],
            keys.clone(),
            d.path(),
            Duration::from_secs(5),
        );
        let path = d.path().join("key.sock");
        let sock = serve(&path, jk.clone()).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        let p = path.clone();
        let (a, b, c, e) = tokio::task::spawn_blocking(move || {
            (
                ask(&p, "get TOKEN"),
                ask(&p, "get TOKEN"),
                ask(&p, "get OTHER"),
                ask(&p, "TOKEN"),
            )
        })
        .await
        .unwrap();
        assert_eq!(a, b"ok 7\nv-3q8Zk");
        assert_eq!(b, a);
        assert_eq!(c, b"no the job doesn't name the key OTHER\n");
        assert_eq!(e, b"no not `get NAME`\n");
        let rows = keys.audit(Some("x1"), None);
        assert_eq!(rows.len(), 1, "one row for the first hand-out: {rows:?}");
        assert_eq!(
            (rows[0].kind, rows[0].key.as_str(), rows[0].runner.as_str()),
            (AuditKind::Sent, "TOKEN", LOCAL_RUNNER)
        );
        let mut r = jk.redactor().lock().unwrap().redact(b"say v-3q8Zk.");
        r.extend(jk.redactor().lock().unwrap().finish());
        assert_eq!(r, b"say *******.");
        drop(sock);
        assert!(!path.exists());
    }

    /// [D] A key the hub doesn't hold yet is asked for and handed out when it comes; one that never comes is answered
    /// `timeout`, after the job's `why` says `infra: key not delivered` and its log names the key.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_key_that_comes_late_is_handed_out_and_one_that_never_comes_is_infra() {
        let d = tempfile::tempdir().unwrap();
        let keys = Arc::new(Keys::default());
        let (tx, mut asked) = tokio::sync::mpsc::unbounded_channel();
        keys.set_tell(move |ev, data| {
            let _ = tx.send(format!("{ev} {data}"));
        });
        let jk = JobKeys::new(
            "x2",
            vec!["LATE".into(), "NEVER".into()],
            keys.clone(),
            d.path(),
            Duration::from_secs(2),
        );
        let late = tokio::spawn({
            let jk = jk.clone();
            async move { jk.answer("get LATE").await }
        });
        let first = asked.recv().await.expect("the ask");
        assert!(first.contains("runners/need-keys"), "{first}");
        keys.take([("LATE".to_string(), SecretString::from("l-1".to_string()))]);
        assert_eq!(&late.await.unwrap()[..], b"ok 3\nl-1");
        assert!(!d.path().join("why").exists());
        assert_eq!(&jk.answer("get NEVER").await[..], keyline::TIMEOUT);
        assert_eq!(
            std::fs::read_to_string(d.path().join("why")).unwrap(),
            "infra: key not delivered"
        );
        let log = std::fs::read_to_string(d.path().join("log")).unwrap();
        assert!(log.contains("NEVER"), "{log}");
    }
}
