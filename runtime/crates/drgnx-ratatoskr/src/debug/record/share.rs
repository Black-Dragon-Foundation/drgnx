//! Send a run (spec §19.7 D9; the user's ruling 2026-11-13): a recorded run, with the files that ran, sealed into one
//! file under a one-time key that is shown once as a share code and never stored; the recipient adds it to their own
//! runs, read-only, under their own keyring's key. The hub only writes the file; sending it is the user's.
//!
//! - **The file**: `DRSHARE1\n`, a salt, then the sealed stream in pieces of at most [`PIECE`] bytes, each `u32` LE
//!   length and ChaCha20-Poly1305 (the run files' cipher, [`super::runkey::FileKey`]) bound to its number and to
//!   whether it is the last, so a piece cannot be dropped, moved or cut off.
//! - **The stream** (zstd): records of a kind byte and a `u32` LE length: the run's record ([`super::RunMeta`], its
//!   start opened), every frame of its file, and the launch snapshot as a git pack of its tree (`rev-list --objects`,
//!   `pack-objects`). At most [`SHARE_MAX`] bytes before compression.
//! - **The code**: the key's 32 bytes in base32 (52 letters, groups of four; case, dashes and spaces ignored).
//! - **Import**: the pack goes into the recipient's shadow repository through `index-pack --strict` (git's own fsck of
//!   every object, so a tree naming `..` or `.git` is refused), the tree is kept as the run's ref, the paths under the
//!   sender's project are moved under the recipient's, and the frames are written into a new run file under the
//!   recipient's key. The run is marked [`super::Imported`] and kept 14 days from the import.

use super::{Frame, Imported, Records, RunMeta, RunSnapshot, lock, runkey};
use serde_json::Value;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use zeroize::Zeroizing;

const MAGIC: &[u8] = b"DRSHARE1\n";
/// The largest sealed piece's plain size.
pub const PIECE: usize = 1024 * 1024;
/// The most a shared run holds before compression (its file is capped at 64 MB; the rest is the files that ran).
pub const SHARE_MAX: u64 = 512 * 1024 * 1024;
const LEVEL: i32 = 3;
const META: u8 = 1;
const FRAME: u8 = 2;
const PACK: u8 = 3;
const ALPHABET: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/// What an export made: the share code that opens it (shown once, never stored) and the file's size.
#[derive(Debug)]
pub struct Exported {
    pub code: String,
    pub bytes: u64,
}

impl Records {
    /// Run ID sealed into the file TO under a one-time key: its share code. Off the hub's workers.
    pub async fn export_run(&self, id: &str, to: &Path) -> Result<Exported, String> {
        self.written().await;
        let meta = self.read_meta(id).ok_or_else(|| format!("no run {id}"))?;
        if meta.start.is_null() && lock(&self.key).is_none() {
            return Err(format!("run {id} cannot be read until the keyring unlocks"));
        }
        if lock(&self.live).contains_key(id) {
            return Err(format!(
                "run {id} is still recording: send it once it has ended"
            ));
        }
        let frames = self.reader(id)?.frames();
        let to = to.to_owned();
        crate::clock::blocking(move || export(&meta, &frames, &to))
            .await
            .map_err(|e| e.to_string())?
    }

    /// The run in FROM, opened with CODE, added to ROOT's runs read-only: its new id. Off the hub's workers.
    pub async fn import_run(&self, root: &str, from: &Path, code: &str) -> Result<String, String> {
        let key = parse_code(code).ok_or("that is not a share code (52 letters and digits 2–7)")?;
        let mine = self.key_to_record().await.map_err(|u| u.why())?;
        let from = from.to_owned();
        let (meta, frames, pack) = crate::clock::blocking(move || open(&from, &key))
            .await
            .map_err(|e| e.to_string())??;
        let ms = (crate::clock::wall_secs() * 1000.0) as u64;
        let id = format!(
            "r{ms}-{}",
            self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1
        );
        let n = self.list(root).iter().map(|m| m.n).max().unwrap_or(0) + 1;
        let (from_root, to_root) = (meta.root.clone(), root.to_owned());
        let snapshot = match (meta.snapshot.as_ref(), pack) {
            (Some(s), Some(pack)) => {
                let (checkpoints, tree, name) = (
                    self.opts.checkpoints.clone(),
                    s.tree.clone(),
                    format!("refs/drgnx/debug/{id}"),
                );
                let source = PathBuf::from(root);
                let held = self.snap.clone();
                let (c, src) = (checkpoints.clone(), source.clone());
                crate::clock::blocking(move || {
                    let _one = lock(&held);
                    unpack(&c, &src, &pack, &tree, &name)
                })
                .await
                .map_err(|e| e.to_string())??;
                Some(RunSnapshot {
                    checkpoints,
                    source,
                    tree: s.tree.clone(),
                })
            }
            _ => None,
        };
        let now = crate::clock::wall_secs();
        let mut start = meta.start.clone();
        rebase(&mut start, &from_root, &to_root);
        let probes = meta
            .probes
            .iter()
            .map(|p| {
                let mut p = p.clone();
                p.path = moved(&p.path, &from_root, &to_root).unwrap_or(p.path);
                p
            })
            .collect();
        let new = RunMeta {
            id: id.clone(),
            n,
            root: to_root.clone(),
            session: String::new(),
            start,
            snapshot,
            head: None,
            unsaved: meta
                .unsaved
                .iter()
                .map(|p| moved(p, &from_root, &to_root).unwrap_or_else(|| p.clone()))
                .collect(),
            ended: Some(now),
            pinned: false,
            task: None,
            probes,
            imported: Some(Imported { at: now, n: meta.n }),
            ..meta
        };
        let path = self.file(&id, "drun");
        let cap = self.opts.file_cap;
        let written = crate::clock::blocking(move || -> Result<u64, String> {
            let mut f = super::RunFile::create(&path, cap, &mine).map_err(|e| e.to_string())?;
            for fr in frames {
                let mut v = serde_json::to_value(&fr).map_err(|e| e.to_string())?;
                rebase(&mut v, &from_root, &to_root);
                let fr: Frame = serde_json::from_value(v).map_err(|e| e.to_string())?;
                f.append(fr);
            }
            f.flush();
            Ok(f.size())
        })
        .await
        .map_err(|e| e.to_string())??;
        let mut new = new;
        new.size = written;
        self.write_meta(&new);
        self.put(&new);
        Ok(id)
    }
}

/// META and FRAMES (and the snapshot's tree, as a pack) sealed into TO under a new key: the code.
fn export(meta: &RunMeta, frames: &[Frame], to: &Path) -> Result<Exported, String> {
    let key = runkey::random_key();
    let mut raw: Vec<u8> = Vec::new();
    let mut put = |kind: u8, bytes: &[u8]| -> Result<(), String> {
        if raw.len() as u64 + bytes.len() as u64 + 5 > SHARE_MAX {
            return Err(format!(
                "the run and the files that ran are over {} MB: too big to send",
                SHARE_MAX / 1024 / 1024
            ));
        }
        raw.push(kind);
        raw.extend_from_slice(
            &u32::try_from(bytes.len())
                .map_err(|e| e.to_string())?
                .to_le_bytes(),
        );
        raw.extend_from_slice(bytes);
        Ok(())
    };
    let mut m = meta.clone();
    // what only the sender's machine means
    m.session = String::new();
    m.task = None;
    m.pinned = false;
    put(META, &serde_json::to_vec(&m).map_err(|e| e.to_string())?)?;
    for f in frames {
        put(FRAME, &serde_json::to_vec(f).map_err(|e| e.to_string())?)?;
    }
    if let Some(s) = &meta.snapshot {
        put(PACK, &pack(s)?)?;
    }
    let comp = Zeroizing::new(zstd::bulk::compress(&raw, LEVEL).map_err(|e| e.to_string())?);
    drop(Zeroizing::new(raw));
    let salt = runkey::new_salt();
    let cipher = runkey::FileKey::new(&key, &salt);
    let tmp = to.with_extension("drgnx-tmp");
    let mut out = std::fs::File::create(&tmp).map_err(|e| format!("{}: {e}", tmp.display()))?;
    let mut write = || -> std::io::Result<u64> {
        out.write_all(MAGIC)?;
        out.write_all(&salt)?;
        let pieces: Vec<&[u8]> = comp.chunks(PIECE).collect();
        let last = pieces.len().max(1) - 1;
        let mut size = (MAGIC.len() + salt.len()) as u64;
        for i in 0..=last {
            let plain = pieces.get(i).copied().unwrap_or_default();
            let sealed = cipher.seal(&aad(i, i == last), plain);
            out.write_all(&(sealed.len() as u32).to_le_bytes())?;
            out.write_all(&sealed)?;
            size += 4 + sealed.len() as u64;
        }
        out.sync_all()?;
        Ok(size)
    };
    let bytes = write().map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, to).map_err(|e| format!("{}: {e}", to.display()))?;
    Ok(Exported {
        code: code_of(&key),
        bytes,
    })
}

/// The run in FROM opened with KEY: its record, its frames, the pack of the files that ran.
#[allow(clippy::type_complexity)]
fn open(from: &Path, key: &runkey::Key) -> Result<(RunMeta, Vec<Frame>, Option<Vec<u8>>), String> {
    let wrong = || "the share code does not open this file (or the file was changed)".to_owned();
    let mut f = std::fs::File::open(from).map_err(|e| format!("{}: {e}", from.display()))?;
    let mut head = vec![0u8; MAGIC.len() + runkey::SALT_LEN];
    f.read_exact(&mut head)
        .map_err(|_| "not a sent run".to_owned())?;
    if &head[..MAGIC.len()] != MAGIC {
        return Err("not a sent run".into());
    }
    let salt: [u8; runkey::SALT_LEN] = head[MAGIC.len()..].try_into().map_err(|_| wrong())?;
    let cipher = runkey::FileKey::new(key, &salt);
    let mut comp = Zeroizing::new(Vec::new());
    let mut i = 0usize;
    loop {
        let mut len = [0u8; 4];
        f.read_exact(&mut len).map_err(|_| wrong())?;
        let n = u32::from_le_bytes(len) as usize;
        if n > PIECE + 64 {
            return Err(wrong());
        }
        let mut sealed = vec![0u8; n];
        f.read_exact(&mut sealed).map_err(|_| wrong())?;
        if let Some(p) = cipher.open(&aad(i, false), &sealed) {
            comp.extend_from_slice(&p);
        } else if let Some(p) = cipher.open(&aad(i, true), &sealed) {
            comp.extend_from_slice(&p);
            break;
        } else {
            return Err(wrong());
        }
        i += 1;
    }
    let mut raw = Zeroizing::new(Vec::new());
    zstd::stream::read::Decoder::new(&comp[..])
        .map_err(|e| e.to_string())?
        .take(SHARE_MAX + 1)
        .read_to_end(&mut raw)
        .map_err(|_| wrong())?;
    if raw.len() as u64 > SHARE_MAX {
        return Err("the sent run is too big".into());
    }
    let (mut meta, mut frames, mut pack) = (None, Vec::new(), None);
    let mut at = 0usize;
    while at < raw.len() {
        let kind = raw[at];
        let n = raw
            .get(at + 1..at + 5)
            .map(|b| u32::from_le_bytes(b.try_into().unwrap_or_default()) as usize)
            .ok_or_else(wrong)?;
        let body = raw.get(at + 5..at + 5 + n).ok_or_else(wrong)?;
        match kind {
            META => {
                meta = Some(serde_json::from_slice::<RunMeta>(body).map_err(|e| e.to_string())?)
            }
            FRAME => frames.push(serde_json::from_slice::<Frame>(body).map_err(|e| e.to_string())?),
            PACK => pack = Some(body.to_vec()),
            _ => return Err(wrong()),
        }
        at += 5 + n;
    }
    Ok((meta.ok_or_else(wrong)?, frames, pack))
}

fn aad(i: usize, last: bool) -> Vec<u8> {
    format!("drgnx run share {i} {}", if last { "last" } else { "more" }).into_bytes()
}

/// The snapshot's tree as a git pack (its objects, from the shadow repository).
fn pack(s: &RunSnapshot) -> Result<Vec<u8>, String> {
    let repo = crate::timeline::snapshot::repo_of(&s.checkpoints, &s.source);
    let objects = git(&repo, &["rev-list", "--objects", &s.tree], None)?;
    git(&repo, &["pack-objects", "--stdout", "-q"], Some(&objects))
}

/// PACK into SOURCE's shadow repository under CHECKPOINTS (checked by git's fsck), TREE kept as the ref NAME.
fn unpack(
    checkpoints: &Path,
    source: &Path,
    pack: &[u8],
    tree: &str,
    name: &str,
) -> Result<(), String> {
    if tree.len() != 40 || !tree.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("the sent run names no tree".into());
    }
    let repo = crate::timeline::snapshot::ensure_repo(checkpoints, source)?;
    git(&repo, &["index-pack", "--strict", "--stdin"], Some(pack))?;
    let kind = git(&repo, &["cat-file", "-t", tree], None)?;
    if String::from_utf8_lossy(&kind).trim() != "tree" {
        return Err("the sent run's snapshot is not a tree".into());
    }
    crate::timeline::snapshot::keep(checkpoints, source, name, tree)
}

/// GIT ARGS in REPO (the snapshots' environment: no user or system config), INPUT on its stdin: its output.
fn git(repo: &Path, args: &[&str], input: Option<&[u8]>) -> Result<Vec<u8>, String> {
    let mut c = Command::new("git");
    c.env("GIT_DIR", repo)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_WORK_TREE")
        .current_dir(repo)
        .args(args)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = c.spawn().map_err(|e| format!("git: {e}"))?;
    let feed = input.map(<[u8]>::to_vec);
    let stdin = child.stdin.take();
    let writer = std::thread::spawn(move || {
        if let (Some(mut s), Some(b)) = (stdin, feed) {
            let _ = s.write_all(&b);
        }
    });
    let out = child.wait_with_output().map_err(|e| format!("git: {e}"))?;
    let _ = writer.join();
    if !out.status.success() {
        return Err(format!(
            "git {}: {}",
            args.first().unwrap_or(&""),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(out.stdout)
}

/// PATH moved from under FROM to under TO; none when it is not under FROM.
fn moved(path: &str, from: &str, to: &str) -> Option<String> {
    if from.is_empty() {
        return None;
    }
    if path == from {
        return Some(to.to_owned());
    }
    let rest = path.strip_prefix(from)?.strip_prefix('/')?;
    Some(format!("{}/{rest}", to.trim_end_matches('/')))
}

/// Every string in V that is a path under FROM, moved under TO.
fn rebase(v: &mut Value, from: &str, to: &str) {
    match v {
        Value::String(s) => {
            if let Some(m) = moved(s, from, to) {
                *s = m;
            }
        }
        Value::Array(a) => a.iter_mut().for_each(|x| rebase(x, from, to)),
        Value::Object(o) => o.values_mut().for_each(|x| rebase(x, from, to)),
        _ => {}
    }
}

/// KEY as a share code: base32, groups of four.
fn code_of(key: &runkey::Key) -> String {
    let mut bits: u64 = 0;
    let mut n = 0u32;
    let mut out = String::new();
    for &b in key.iter() {
        bits = (bits << 8) | u64::from(b);
        n += 8;
        while n >= 5 {
            n -= 5;
            out.push(ALPHABET[((bits >> n) & 31) as usize] as char);
        }
    }
    if n > 0 {
        out.push(ALPHABET[((bits << (5 - n)) & 31) as usize] as char);
    }
    out.as_bytes()
        .chunks(4)
        .map(|c| String::from_utf8_lossy(c).into_owned())
        .collect::<Vec<_>>()
        .join("-")
}

/// A share code back into its key: any case, dashes and spaces ignored; none when it is not one.
fn parse_code(code: &str) -> Option<runkey::Key> {
    let letters: Vec<u8> = code
        .bytes()
        .filter(|b| !matches!(b, b'-' | b' ' | b'\t' | b'\n'))
        .map(|b| b.to_ascii_uppercase())
        .collect();
    if letters.len() != 52 {
        return None;
    }
    let mut key = Zeroizing::new([0u8; 32]);
    let (mut bits, mut n, mut i) = (0u64, 0u32, 0usize);
    for c in letters {
        let v = ALPHABET.iter().position(|&a| a == c)? as u64;
        bits = (bits << 5) | v;
        n += 5;
        if n >= 8 {
            n -= 8;
            if i < 32 {
                key[i] = (bits >> n) as u8;
            }
            i += 1;
        }
    }
    // 52 letters carry 260 bits: the last 4 are zero in a real code
    (i == 32 && bits & ((1 << n) - 1) == 0).then_some(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_code_reads_back_in_any_case_and_a_changed_one_does_not() {
        let k = runkey::random_key();
        let c = code_of(&k);
        assert_eq!(c.len(), 52 + 12, "{c}");
        assert_eq!(parse_code(&c).as_deref(), Some(&*k));
        assert_eq!(
            parse_code(&c.to_lowercase().replace('-', " ")).as_deref(),
            Some(&*k)
        );
        assert!(parse_code(&c[..c.len() - 1]).is_none());
        assert!(
            parse_code(&format!("{}1", &c[..c.len() - 1])).is_none(),
            "1 is not a letter of it"
        );
    }

    #[test]
    fn only_paths_under_the_project_move() {
        let mut v =
            serde_json::json!({"path": "/a/p/x.py", "other": "/a/px.py", "same": "/a/p", "n": 3});
        rebase(&mut v, "/a/p", "/b/q");
        assert_eq!(
            v,
            serde_json::json!({"path": "/b/q/x.py", "other": "/a/px.py", "same": "/b/q", "n": 3})
        );
    }
}
