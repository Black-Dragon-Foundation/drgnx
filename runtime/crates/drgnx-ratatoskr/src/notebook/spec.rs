//! Kernelspecs and a kernel's connection file (design §5.2).
//!
//! A kernelspec is a folder `<kernels dir>/<name>/kernel.json`. The connection file is how the kernel learns where to bind and the key
//! to sign with: created `O_EXCL`, mode 0600, in the session's private folder (0700, ours, not a link), holding an `ipc` transport
//! whose "ip" is a path prefix inside that folder, and deleted when the kernel ends. Its path is all the kernel's argv carries.

use std::path::{Path, PathBuf};

use super::wire::Key;

/// The largest `kernel.json` read.
pub const MAX_SPEC_BYTES: u64 = 64 * 1024;
/// The longest socket path (a unix socket path is about 104 bytes on macOS, 108 on Linux).
pub const MAX_SOCKET_PATH: usize = 96;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Interrupt {
    Signal,
    Message,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Kernelspec {
    /// The folder's name.
    pub name: String,
    pub display_name: String,
    pub language: String,
    pub argv: Vec<String>,
    pub env: Vec<(String, String)>,
    pub interrupt: Interrupt,
    pub dir: PathBuf,
}

/// Which kernel a notebook gets.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Choice {
    /// The named kernelspec, or the only one of the language.
    Found(Kernelspec),
    /// Several of the language: the caller asks (interactive) or reports (not).
    Ask(Vec<String>),
    /// Nothing fits.
    Missing,
}

/// The standard kernel directories, first wins: `$JUPYTER_PATH` entries, the user's data folder, `XDG_DATA_DIRS`, then `/usr/local/share` and `/usr/share`.
pub fn standard_dirs(
    home: &Path,
    jupyter_path: Option<&str>,
    xdg_data_dirs: Option<&str>,
) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    let mut add = |base: &Path| {
        let p = base.join("kernels");
        if base.is_absolute() && !out.contains(&p) {
            out.push(p);
        }
    };
    for e in jupyter_path
        .unwrap_or("")
        .split(':')
        .filter(|e| !e.is_empty())
    {
        add(Path::new(e));
    }
    add(&home.join(".local/share/jupyter"));
    for e in xdg_data_dirs
        .unwrap_or("")
        .split(':')
        .filter(|e| !e.is_empty())
    {
        add(&Path::new(e).join("jupyter"));
    }
    add(Path::new("/usr/local/share/jupyter"));
    add(Path::new("/usr/share/jupyter"));
    out
}

/// A kernelspec that was not used, and why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Skipped {
    pub name: String,
    pub why: String,
}

/// Every valid kernelspec under DIRS (an earlier directory shadows a later one of the same name), sorted by name, and the ones that
/// were skipped with the reason: an entry that has a `kernel.json` and is not used is never dropped silently.
pub fn discover_with_skips(dirs: &[PathBuf]) -> (Vec<Kernelspec>, Vec<Skipped>) {
    let (mut out, mut skipped): (Vec<Kernelspec>, Vec<Skipped>) = (Vec::new(), Vec::new());
    for dir in dirs {
        let Ok(rd) = std::fs::read_dir(dir) else {
            continue;
        };
        for entry in rd.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if out.iter().any(|s| s.name == name) {
                continue;
            }
            match read_spec(&entry.path(), &name) {
                Ok(spec) => out.push(spec),
                Err(Some(why)) => skipped.push(Skipped { name, why }),
                Err(None) => {}
            }
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    (out, skipped)
}

/// [`discover_with_skips`], the skipped ones logged.
pub fn discover(dirs: &[PathBuf]) -> Vec<Kernelspec> {
    let (specs, skipped) = discover_with_skips(dirs);
    for k in skipped {
        tracing::info!(target: "drgnx::notebook", "kernelspec {} not used: {}", k.name, k.why);
    }
    specs
}

/// The kernel for a notebook that names NAME and LANGUAGE (either may be absent).
pub fn choose(specs: &[Kernelspec], name: Option<&str>, language: Option<&str>) -> Choice {
    if let Some(s) = name.and_then(|n| specs.iter().find(|s| s.name == n)) {
        return Choice::Found(s.clone());
    }
    let Some(lang) = language else {
        return Choice::Missing;
    };
    let same: Vec<&Kernelspec> = specs
        .iter()
        .filter(|s| s.language.eq_ignore_ascii_case(lang))
        .collect();
    match same.as_slice() {
        [] => Choice::Missing,
        [one] => Choice::Found((*one).clone()),
        many => Choice::Ask(many.iter().map(|s| s.name.clone()).collect()),
    }
}

impl Kernelspec {
    /// The argv with `{connection_file}` replaced by PATH.
    pub fn argv_for(&self, path: &Path) -> Vec<String> {
        let p = path.to_string_lossy();
        self.argv
            .iter()
            .map(|a| a.replace("{connection_file}", &p))
            .collect()
    }
}

/// The session's private folder: made 0700 if missing; refused if it is a link, is not ours or is open to others.
pub fn private_folder(path: &Path) -> Result<PathBuf, String> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    if std::fs::symlink_metadata(path).is_err() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)
            .map_err(|e| format!("cannot make {}: {e}", path.display()))?;
    }
    let m = std::fs::symlink_metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if m.file_type().is_symlink() {
        return Err(format!(
            "{} is a link, not a private folder",
            path.display()
        ));
    }
    if !m.is_dir() {
        return Err(format!("{} is not a folder", path.display()));
    }
    // SAFETY: geteuid has no preconditions.
    if m.uid() != unsafe { libc::geteuid() } {
        return Err(format!("{} belongs to another user", path.display()));
    }
    if m.mode() & 0o777 != 0o700 {
        return Err(format!(
            "{} must be mode 0700 (it is {:04o})",
            path.display(),
            m.mode() & 0o777
        ));
    }
    Ok(path.to_path_buf())
}

/// A kernel's connection file; the file is deleted when this is dropped.
#[derive(Debug)]
pub struct Connection {
    pub path: PathBuf,
    pub prefix: PathBuf,
    pub key: Key,
}

pub const CHANNELS: [&str; 5] = ["shell", "iopub", "stdin", "control", "hb"];

impl Connection {
    /// A new file `kernel-<id>.json` in FOLDER (which must be [`private_folder`]'s answer).
    pub fn create(folder: &Path, id: &str, kernel_name: &str) -> Result<Connection, String> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        if id.is_empty()
            || !id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
        {
            return Err(format!("{id:?} is not a connection id"));
        }
        let prefix = folder.join(format!("k-{id}"));
        let prefix_text = prefix
            .to_str()
            .ok_or("the session folder's path is not text")?
            .to_string();
        if prefix_text.len() + 2 > MAX_SOCKET_PATH {
            return Err(format!(
                "the socket path under {} is too long for a unix socket",
                folder.display()
            ));
        }
        let key = Key::generate()?;
        let mut body = serde_json::json!({
            "transport": "ipc",
            "ip": prefix_text,
            "signature_scheme": "hmac-sha256",
            "key": key.to_connection_file(),
            "kernel_name": kernel_name,
        });
        for (i, ch) in CHANNELS.iter().enumerate() {
            body[format!("{ch}_port")] = (i + 1).into();
        }
        let path = folder.join(format!("kernel-{id}.json"));
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .map_err(|e| format!("cannot create {}: {e}", path.display()))?;
        if let Err(e) = f.write_all(body.to_string().as_bytes()) {
            let _ = std::fs::remove_file(&path);
            return Err(format!("cannot write {}: {e}", path.display()));
        }
        Ok(Connection { path, prefix, key })
    }

    /// The socket file of CHANNEL (`<prefix>-<n>`).
    pub fn socket(&self, channel: &str) -> Option<PathBuf> {
        let n = CHANNELS.iter().position(|c| *c == channel)? + 1;
        Some(PathBuf::from(format!("{}-{n}", self.prefix.display())))
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Delete the connection files in FOLDER that are not in LIVE (left by kernels that are gone); how many went.
pub fn sweep(folder: &Path, live: &[PathBuf]) -> usize {
    let Ok(rd) = std::fs::read_dir(folder) else {
        return 0;
    };
    let mut gone = 0;
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let path = e.path();
        let is_file = e.file_type().is_ok_and(|t| t.is_file());
        if name.starts_with("kernel-")
            && name.ends_with(".json")
            && is_file
            && !live.contains(&path)
            && std::fs::remove_file(&path).is_ok()
        {
            gone += 1;
        }
    }
    gone
}

/// Whether the group GID has no member but the user it is the primary group of (a "user private group": files `ipykernel install
/// --user` writes under umask 0002 are group-writable by it, and nobody else can write them).
fn private_group(gid: u32) -> bool {
    let mut buf = vec![0u8; 4096];
    loop {
        let mut grp: libc::group = unsafe { std::mem::zeroed() };
        let mut res: *mut libc::group = std::ptr::null_mut();
        // SAFETY: getgrgid_r writes into GRP and BUF, which live through the call, and sets RES to GRP or null.
        let rc = unsafe {
            libc::getgrgid_r(gid, &mut grp, buf.as_mut_ptr().cast(), buf.len(), &mut res)
        };
        if rc == libc::ERANGE && buf.len() < (1 << 20) {
            buf.resize(buf.len() * 4, 0);
            continue;
        }
        // SAFETY: on success `gr_mem` is a null-terminated array of C strings in BUF; it is only read for its first entry.
        return rc == 0
            && !res.is_null()
            && unsafe { grp.gr_mem.is_null() || (*grp.gr_mem).is_null() };
    }
}

/// Whether a kernelspec's folder or file may be trusted, or why not: ours or root's, not writable by others, and writable by its group
/// only when that is the user's own private group (anyone who can write it chooses the command a notebook runs).
pub(crate) fn trust(
    uid: u32,
    gid: u32,
    mode: u32,
    me: (u32, u32),
    private: impl Fn(u32) -> bool,
) -> Result<(), String> {
    if uid != me.0 && uid != 0 {
        return Err("belongs to another user".into());
    }
    if mode & 0o002 != 0 {
        return Err("is writable by everyone".into());
    }
    if mode & 0o020 != 0 && !(gid == me.1 && private(gid)) {
        return Err("is writable by a group that has other members".into());
    }
    Ok(())
}

fn trusted(m: &std::fs::Metadata) -> Result<(), String> {
    use std::os::unix::fs::MetadataExt;
    // SAFETY: geteuid and getegid have no preconditions.
    let me = unsafe { (libc::geteuid(), libc::getegid()) };
    trust(m.uid(), m.gid(), m.mode(), me, private_group)
}

/// KERNEL.JSON opened without following a link and without blocking (a FIFO put there after a check would hold the open), then
/// looked at: a regular file, small enough, trusted. The file and its metadata, or why not.
pub(crate) fn open_spec_file(path: &Path) -> Result<std::fs::File, String> {
    use std::os::unix::fs::OpenOptionsExt;
    let f = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .map_err(|e| format!("cannot be opened: {e}"))?;
    let meta = f.metadata().map_err(|e| format!("cannot be read: {e}"))?;
    if !meta.is_file() {
        return Err("kernel.json is not a regular file".into());
    }
    if meta.len() > MAX_SPEC_BYTES {
        return Err("kernel.json is too large".into());
    }
    trusted(&meta).map_err(|e| format!("kernel.json {e}"))?;
    Ok(f)
}

/// One kernelspec folder: the spec, `Err(None)` for an entry that is not a kernelspec at all, `Err(Some(why))` for one that is and is not
/// used.
fn read_spec(dir: &Path, name: &str) -> Result<Kernelspec, Option<String>> {
    use std::io::Read;
    let valid_name = !name.starts_with('.')
        && name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c));
    if !valid_name {
        return Err(None);
    }
    let Ok(dm) = std::fs::metadata(dir) else {
        return Err(None);
    };
    if !dm.is_dir() || !dir.join("kernel.json").exists() {
        return Err(None);
    }
    trusted(&dm).map_err(|e| Some(format!("its folder {e}")))?;
    let mut f = open_spec_file(&dir.join("kernel.json")).map_err(Some)?;
    let mut text = Vec::new();
    (&mut f)
        .take(MAX_SPEC_BYTES + 1)
        .read_to_end(&mut text)
        .map_err(|e| Some(format!("kernel.json cannot be read: {e}")))?;
    parse_spec(&text, name, dir)
        .ok_or_else(|| Some("kernel.json is not a valid kernelspec".to_string()))
}

fn parse_spec(text: &[u8], name: &str, dir: &Path) -> Option<Kernelspec> {
    let v: serde_json::Value = serde_json::from_slice(text).ok()?;
    let argv: Vec<String> = v
        .get("argv")?
        .as_array()?
        .iter()
        .map(|a| a.as_str().map(String::from))
        .collect::<Option<_>>()?;
    if !argv.iter().any(|a| a.contains("{connection_file}")) {
        return None;
    }
    let env = match v.get("env") {
        None | Some(serde_json::Value::Null) => Vec::new(),
        Some(e) => e
            .as_object()?
            .iter()
            .map(|(k, v)| Some((k.clone(), v.as_str()?.to_string())))
            .collect::<Option<_>>()?,
    };
    let interrupt = match v.get("interrupt_mode").and_then(|m| m.as_str()) {
        None | Some("signal") => Interrupt::Signal,
        Some("message") => Interrupt::Message,
        Some(_) => return None,
    };
    let text_of = |k: &str| v.get(k).and_then(|x| x.as_str()).map(String::from);
    Some(Kernelspec {
        name: name.to_string(),
        display_name: text_of("display_name").unwrap_or_else(|| name.to_string()),
        language: text_of("language").unwrap_or_default(),
        argv,
        env,
        interrupt,
        dir: dir.to_path_buf(),
    })
}

#[cfg(test)]
mod tests;
