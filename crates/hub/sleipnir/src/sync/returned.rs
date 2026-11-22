//! What a job that wrote its private copy gives back (docs/develop/sleipnir.md, "What comes back"), read from the copy
//! as data: no git runs inside it (a job controls everything there, `.git` included).
//!
//! - [`changes`]: the files its `writes` globs name that differ from the slot, as a `git diff --full-index` patch the
//!   hub reads (`runners::returned::Patch::parse`) and checks (`patch_ok`) before it touches your tree. Text only: a
//!   binary file, a link, or a path git would quote is listed in [`Changes::left`] with why, never guessed at.
//! - [`outputs`]: the files its `outputs` globs name (and `reports/`), as a ustar archive of regular files and folders
//!   (`archive_ok` on the hub). A link or anything else is left out and listed.
//! - [`glob_ok`]: the one glob both sides match `writes` and `outputs` with; [`blob_id`]: git's id of a file's bytes,
//!   which the patch's `index` lines carry and the hub compares with what the job was submitted with.

use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use sha1::{Digest, Sha1};

/// The changes of a job's copy, and what was left out of them (path, why).
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Changes {
    pub patch: Vec<u8>,
    pub left: Vec<(String, String)>,
}

/// A job's outputs as a ustar archive, and what was left out (path, why).
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Outputs {
    pub tar: Vec<u8>,
    pub left: Vec<(String, String)>,
}

/// Git's blob id of BYTES (sha1 of `blob LEN\0` and the bytes), in hex.
pub fn blob_id(bytes: &[u8]) -> String {
    let mut h = Sha1::new();
    h.update(format!("blob {}\0", bytes.len()).as_bytes());
    h.update(bytes);
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// Whether PATH matches the glob PATTERN: `*` and `?` within one name, `**` as a whole segment any number of folders,
/// a trailing `/` the folder and all in it.
pub fn glob_ok(pattern: &str, path: &str) -> bool {
    let whole;
    let pattern = match pattern.strip_suffix('/') {
        Some(dir) => {
            whole = format!("{dir}/**");
            whole.as_str()
        }
        None => pattern,
    };
    let p: Vec<&str> = pattern
        .split('/')
        .filter(|s| !s.is_empty() && *s != ".")
        .collect();
    let s: Vec<&str> = path.split('/').collect();
    segments(&p, &s)
}

fn segments(p: &[&str], s: &[&str]) -> bool {
    match p.split_first() {
        None => s.is_empty(),
        Some((&"**", rest)) => (0..=s.len()).any(|i| segments(rest, &s[i..])),
        Some((first, rest)) => s
            .split_first()
            .is_some_and(|(h, t)| segment(first.as_bytes(), h.as_bytes()) && segments(rest, t)),
    }
}

/// One name against one pattern segment (`*` any run, `?` one byte), with one point to come back to.
fn segment(p: &[u8], s: &[u8]) -> bool {
    let (mut pi, mut si) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while si < s.len() {
        if pi < p.len() && (p[pi] == b'?' || p[pi] == s[si]) {
            pi += 1;
            si += 1;
        } else if pi < p.len() && p[pi] == b'*' {
            star = Some((pi, si));
            pi += 1;
        } else if let Some((sp, ss)) = star {
            pi = sp + 1;
            si = ss + 1;
            star = Some((sp, ss + 1));
        } else {
            return false;
        }
    }
    p[pi..].iter().all(|b| *b == b'*')
}

/// A file found under a root: a regular file's mode, or what else it is.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Found {
    File(u32),
    Other(&'static str),
}

/// Every non-folder under ROOT by its path relative to ROOT (`/`-separated), the top `.git` left out; a name that is
/// not UTF-8 is listed as such, never read.
fn walk(root: &Path) -> io::Result<BTreeMap<String, Found>> {
    fn go(root: &Path, rel: &str, out: &mut BTreeMap<String, Found>) -> io::Result<()> {
        let dir = if rel.is_empty() {
            root.to_path_buf()
        } else {
            root.join(rel)
        };
        for e in fs::read_dir(dir)? {
            let e = e?;
            let Some(name) = e.file_name().to_str().map(str::to_owned) else {
                out.insert(
                    format!("{rel}/{}", e.file_name().to_string_lossy()),
                    Found::Other("a name that is not UTF-8"),
                );
                continue;
            };
            if rel.is_empty() && name == ".git" {
                continue;
            }
            let path = if rel.is_empty() {
                name
            } else {
                format!("{rel}/{name}")
            };
            let ft = e.file_type()?;
            if ft.is_dir() {
                go(root, &path, out)?;
            } else if ft.is_file() {
                let mode = e.metadata()?.permissions().mode();
                out.insert(
                    path,
                    Found::File(if mode & 0o111 != 0 {
                        0o100755
                    } else {
                        0o100644
                    }),
                );
            } else if ft.is_symlink() {
                out.insert(path, Found::Other("a link"));
            } else {
                out.insert(path, Found::Other("not a regular file"));
            }
        }
        Ok(())
    }
    let mut out = BTreeMap::new();
    if root.is_dir() {
        go(root, "", &mut out)?;
    }
    Ok(out)
}

/// Why git would quote PATH in a patch (the hub reads no quoted path), or none.
fn quoted(path: &str) -> Option<&'static str> {
    path.bytes()
        .any(|b| b < 0x20 || b == 0x7f || b == b'"' || b == b'\\' || b >= 0x80)
        .then_some("a name git would quote")
}

/// Bytes as text for a diff: none for binary (a NUL in the first 8000 bytes, as git decides, or not UTF-8).
fn text(bytes: &[u8]) -> Option<&str> {
    if bytes.iter().take(8000).any(|b| *b == 0) {
        return None;
    }
    std::str::from_utf8(bytes).ok()
}

/// The changes of COPY against SLOT in the files the WRITES globs name (created, changed, deleted, a mode changed),
/// as one patch, in path order.
pub fn changes(slot: &Path, copy: &Path, writes: &[String]) -> io::Result<Changes> {
    let (before, after) = (walk(slot)?, walk(copy)?);
    let mut paths: Vec<&String> = before.keys().chain(after.keys()).collect();
    paths.sort();
    paths.dedup();
    let mut out = Changes::default();
    for path in paths {
        if !writes.iter().any(|g| glob_ok(g, path)) {
            continue;
        }
        let (old, new) = (before.get(path), after.get(path));
        let leave = |why: &str, out: &mut Changes| out.left.push((path.clone(), why.to_owned()));
        if let Some(Found::Other(why)) = new.or(old).filter(|f| matches!(f, Found::Other(_))) {
            leave(why, &mut out);
            continue;
        }
        if let Some(why) = quoted(path) {
            leave(why, &mut out);
            continue;
        }
        let read = |root: &Path, f: Option<&Found>| -> io::Result<Option<(Vec<u8>, u32)>> {
            match f {
                Some(Found::File(m)) => Ok(Some((fs::read(root.join(path))?, *m))),
                _ => Ok(None),
            }
        };
        let (a, b) = (read(slot, old)?, read(copy, new)?);
        if a == b {
            continue;
        }
        let (a_text, b_text) = (
            a.as_ref().map(|(x, _)| text(x)),
            b.as_ref().map(|(x, _)| text(x)),
        );
        if a_text == Some(None) || b_text == Some(None) {
            leave("a binary file", &mut out);
            continue;
        }
        let zero = "0".repeat(40);
        let id = |f: &Option<(Vec<u8>, u32)>| f.as_ref().map_or(zero.clone(), |(x, _)| blob_id(x));
        let mut d = format!("diff --git a/{path} b/{path}\n");
        match (&a, &b) {
            (None, Some((_, m))) => d.push_str(&format!("new file mode {m:o}\n")),
            (Some((_, m)), None) => d.push_str(&format!("deleted file mode {m:o}\n")),
            (Some((_, ma)), Some((_, mb))) if ma != mb => {
                d.push_str(&format!("old mode {ma:o}\nnew mode {mb:o}\n"))
            }
            _ => {}
        }
        let same_mode = match (&a, &b) {
            (Some((_, ma)), Some((_, mb))) if ma == mb => format!(" {ma:o}"),
            _ => String::new(),
        };
        d.push_str(&format!("index {}..{}{same_mode}\n", id(&a), id(&b)));
        let (x, y) = (
            a_text.flatten().unwrap_or_default(),
            b_text.flatten().unwrap_or_default(),
        );
        if x != y {
            let (from, to) = (
                if a.is_some() {
                    format!("a/{path}")
                } else {
                    "/dev/null".into()
                },
                if b.is_some() {
                    format!("b/{path}")
                } else {
                    "/dev/null".into()
                },
            );
            let diff = similar::TextDiff::from_lines(x, y);
            d.push_str(
                &diff
                    .unified_diff()
                    .context_radius(3)
                    .header(&from, &to)
                    .to_string(),
            );
        }
        out.patch.extend_from_slice(d.as_bytes());
    }
    Ok(out)
}

/// The files of COPY the OUTPUTS globs name, and everything under `reports/`, as a ustar archive (folders first,
/// paths in order); a link, a non-regular file or a name too long for ustar is left out and listed.
pub fn outputs(copy: &Path, outputs: &[String]) -> io::Result<Outputs> {
    let mut out = Outputs::default();
    let mut dirs: Vec<String> = Vec::new();
    for (path, found) in walk(copy)? {
        if !(outputs.iter().any(|g| glob_ok(g, &path)) || glob_ok("reports/", &path)) {
            continue;
        }
        let Found::File(mode) = found else {
            let Found::Other(why) = found else { continue };
            out.left.push((path, why.to_owned()));
            continue;
        };
        let bytes = fs::read(copy.join(&path))?;
        let mut parents: Vec<String> = Vec::new();
        let mut at = path.as_str();
        while let Some((dir, _)) = at.rsplit_once('/') {
            parents.push(format!("{dir}/"));
            at = dir;
        }
        let mut ok = true;
        for d in parents.iter().rev() {
            if !dirs.contains(d) {
                if !header(&mut out.tar, d, 0o755, 0, b'5') {
                    ok = false;
                    break;
                }
                dirs.push(d.clone());
            }
        }
        if !ok || !header(&mut out.tar, &path, mode & 0o777, bytes.len() as u64, b'0') {
            out.left
                .push((path, "a name too long for the archive".into()));
            continue;
        }
        out.tar.extend_from_slice(&bytes);
        out.tar.resize(out.tar.len().div_ceil(512) * 512, 0);
    }
    out.tar.resize(out.tar.len() + 1024, 0);
    Ok(out)
}

/// A ustar header for NAME (split into prefix and name when longer than 100 bytes); false when it can't hold it.
fn header(tar: &mut Vec<u8>, name: &str, mode: u32, size: u64, typ: u8) -> bool {
    let n = name.as_bytes();
    let (prefix, name) = if n.len() <= 100 {
        (&b""[..], n)
    } else {
        match (0..n.len())
            .rev()
            .find(|&i| n[i] == b'/' && i <= 155 && n.len() - i - 1 <= 100 && i > 0)
        {
            Some(i) => (&n[..i], &n[i + 1..]),
            None => return false,
        }
    };
    let mut h = [0u8; 512];
    h[..name.len()].copy_from_slice(name);
    let octal = |h: &mut [u8; 512], at: usize, len: usize, v: u64| {
        let s = format!("{v:0w$o}", w = len - 1);
        h[at..at + len - 1].copy_from_slice(s.as_bytes());
    };
    octal(&mut h, 100, 8, u64::from(mode));
    octal(&mut h, 108, 8, 0);
    octal(&mut h, 116, 8, 0);
    octal(&mut h, 124, 12, size);
    octal(&mut h, 136, 12, 0);
    h[156] = typ;
    h[257..263].copy_from_slice(b"ustar\0");
    h[263..265].copy_from_slice(b"00");
    h[345..345 + prefix.len()].copy_from_slice(prefix);
    h[148..156].copy_from_slice(b"        ");
    let sum: u64 = h.iter().map(|b| u64::from(*b)).sum();
    let s = format!("{sum:06o}\0 ");
    h[148..156].copy_from_slice(s.as_bytes());
    tar.extend_from_slice(&h);
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn tree(files: &[(&str, &str, u32)]) -> tempfile::TempDir {
        let d = tempfile::tempdir().unwrap();
        for (p, text, mode) in files {
            let f = d.path().join(p);
            fs::create_dir_all(f.parent().unwrap()).unwrap();
            fs::write(&f, text).unwrap();
            fs::set_permissions(&f, fs::Permissions::from_mode(*mode)).unwrap();
        }
        d
    }

    // [D] git's own id of a file's bytes
    #[test]
    fn a_blob_id_is_gits() {
        assert_eq!(blob_id(b""), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
        assert_eq!(
            blob_id(b"hello\n"),
            "ce013625030ba8dba906f756967f9e9ca394464a"
        );
    }

    // [D] created, changed, deleted and a mode change, in the writes only, with full index lines
    #[test]
    fn the_changes_are_a_git_patch_of_the_writes() {
        let slot = tree(&[
            ("src/a.txt", "one\ntwo\n", 0o644),
            ("src/gone.txt", "bye\n", 0o644),
            ("src/run.sh", "echo\n", 0o644),
            ("README", "same\n", 0o644),
        ]);
        let copy = tree(&[
            ("src/a.txt", "one\nTWO\n", 0o644),
            ("src/new.txt", "hi\n", 0o644),
            ("src/run.sh", "echo\n", 0o755),
            ("README", "changed outside the writes\n", 0o644),
        ]);
        let c = changes(slot.path(), copy.path(), &["src/".into()]).unwrap();
        assert!(c.left.is_empty(), "{:?}", c.left);
        let p = String::from_utf8(c.patch).unwrap();
        let want = format!(
            "diff --git a/src/a.txt b/src/a.txt\nindex {}..{} 100644\n--- a/src/a.txt\n+++ b/src/a.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n\
             diff --git a/src/gone.txt b/src/gone.txt\ndeleted file mode 100644\nindex {}..{}\n--- a/src/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-bye\n\
             diff --git a/src/new.txt b/src/new.txt\nnew file mode 100644\nindex {}..{}\n--- /dev/null\n+++ b/src/new.txt\n@@ -0,0 +1 @@\n+hi\n\
             diff --git a/src/run.sh b/src/run.sh\nold mode 100644\nnew mode 100755\nindex {}..{}\n",
            blob_id(b"one\ntwo\n"),
            blob_id(b"one\nTWO\n"),
            blob_id(b"bye\n"),
            "0".repeat(40),
            "0".repeat(40),
            blob_id(b"hi\n"),
            blob_id(b"echo\n"),
            blob_id(b"echo\n"),
        );
        assert_eq!(p, want);
    }

    // [D] nothing is guessed: a binary file, a link and a name git would quote are listed, not in the patch
    #[test]
    fn binary_files_links_and_quoted_names_are_left_out() {
        let slot = tree(&[("w/bin", "a\0b", 0o644)]);
        let copy = tree(&[("w/bin", "a\0c", 0o644), ("w/tab\tname", "x\n", 0o644)]);
        symlink("/etc/passwd", copy.path().join("w/link")).unwrap();
        let c = changes(slot.path(), copy.path(), &["w/".into()]).unwrap();
        assert!(c.patch.is_empty(), "{}", String::from_utf8_lossy(&c.patch));
        assert_eq!(
            c.left,
            vec![
                ("w/bin".to_string(), "a binary file".to_string()),
                ("w/link".to_string(), "a link".to_string()),
                (
                    "w/tab\tname".to_string(),
                    "a name git would quote".to_string()
                ),
            ]
        );
    }

    // [D] the job's .git at the top is never read
    #[test]
    fn the_copys_git_folder_is_never_read() {
        let slot = tree(&[]);
        let copy = tree(&[(".git/hooks/post-checkout", "evil\n", 0o755)]);
        let c = changes(slot.path(), copy.path(), &["**".into()]).unwrap();
        assert!(c.patch.is_empty() && c.left.is_empty());
    }

    // [D] the archive holds the outputs and reports/ as regular files and folders, a link left out
    #[test]
    fn the_outputs_are_a_ustar_of_regular_files() {
        let copy = tree(&[
            ("dist/app.txt", "built\n", 0o644),
            ("reports/junit.xml", "<testsuite/>", 0o644),
            ("src/x.rs", "fn main() {}\n", 0o644),
        ]);
        symlink("/etc/passwd", copy.path().join("dist/leak")).unwrap();
        let o = outputs(copy.path(), &["dist/".into()]).unwrap();
        assert_eq!(
            o.left,
            vec![("dist/leak".to_string(), "a link".to_string())]
        );
        let names: Vec<(String, u8)> = o
            .tar
            .chunks(512)
            .filter(|h| h[257..262] == *b"ustar")
            .map(|h| {
                let end = h[..100].iter().position(|b| *b == 0).unwrap_or(100);
                (String::from_utf8_lossy(&h[..end]).into_owned(), h[156])
            })
            .collect();
        assert_eq!(
            names,
            vec![
                ("dist/".to_string(), b'5'),
                ("dist/app.txt".to_string(), b'0'),
                ("reports/".to_string(), b'5'),
                ("reports/junit.xml".to_string(), b'0'),
            ]
        );
        assert_eq!(o.tar.len() % 512, 0);
    }

    // [D] the glob both sides use
    #[test]
    fn globs_match_by_segment() {
        assert!(glob_ok("src/", "src/a/b.rs"));
        assert!(glob_ok("**/*.lock", "a/b/Cargo.lock"));
        assert!(glob_ok("*.md", "README.md"));
        assert!(!glob_ok("*.md", "docs/README.md"));
        assert!(!glob_ok("src/", "srcx/a"));
    }
}
