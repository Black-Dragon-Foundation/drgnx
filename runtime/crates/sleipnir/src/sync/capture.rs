//! A job's inputs, frozen at submit (docs/develop/sleipnir.md, "Sync").
//!
//! The overlay is every uncommitted change against `HEAD`: staged, unstaged, untracked-not-ignored and deletions,
//! from `git diff --no-renames --raw -z HEAD` and `git ls-files -o -z --exclude-standard`. Paths are raw bytes
//! throughout, so a name with a space, a newline or bytes that aren't UTF-8 is sent exactly or refused by name.

use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::{self, Read};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use super::git::{Git, line, run, spawn};
use super::{Result, SyncError, check_path, hex, refused};

pub const MODE_FILE: u32 = 0o100644;
pub const MODE_EXEC: u32 = 0o100755;
pub const MODE_LINK: u32 = 0o120000;

/// One overlay or extra entry. A link's `sha256` and `size` are those of its target's bytes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Entry {
    File {
        path: Vec<u8>,
        mode: u32,
        sha256: [u8; 32],
        size: u64,
    },
    Deleted {
        path: Vec<u8>,
    },
}

impl Entry {
    pub fn path(&self) -> &[u8] {
        match self {
            Entry::File { path, .. } | Entry::Deleted { path } => path,
        }
    }
}

/// What a job runs on: the commit, its tree, the overlay manifest and the declared extras, each sorted by path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Inputs {
    pub commit: String,
    pub tree: String,
    pub manifest: Vec<Entry>,
    pub extras: Vec<Entry>,
}

/// Captures the inputs of the worktree whose top level is `repo`, with the declared gitignored `extra` paths
/// (relative to `repo`; a directory is taken whole). Every missing extra refuses the capture, all named at once.
pub fn capture(repo: &Path, extra: &[PathBuf]) -> Result<Inputs> {
    capture_with(repo, extra, &global_config_files())
}

/// `capture`, reading the user's `core.excludesFile` from `global_configs`.
pub(crate) fn capture_with(
    repo: &Path,
    extra: &[PathBuf],
    global_configs: &[PathBuf],
) -> Result<Inputs> {
    let git = Git::for_worktree(repo)?;
    let commit = line(&run(
        "read HEAD",
        git.cmd(["rev-parse", "--verify", "HEAD^{commit}"]),
        None,
    )?);
    let tree = line(&run(
        "read HEAD's tree",
        git.cmd(["rev-parse", "--verify", "HEAD^{tree}"]),
        None,
    )?);

    let mut manifest = BTreeMap::new();
    let diff = run(
        "diff against HEAD",
        git.cmd([
            "diff",
            "--no-renames",
            "--no-ext-diff",
            "--raw",
            "-z",
            "HEAD",
        ]),
        None,
    )?;
    let mut fields = diff.split(|&b| b == 0).filter(|f| !f.is_empty());
    while let Some(head) = fields.next() {
        let path = fields.next().ok_or_else(|| unexpected("diff"))?;
        let f: Vec<&[u8]> = head.split(|&b| b == b' ').collect();
        if f.len() != 5 || !f[0].starts_with(b":") {
            return Err(unexpected("diff"));
        }
        if &f[0][1..] == b"160000" || f[1] == b"160000" {
            return Err(refused(path, "a submodule (its commit can't be sent)"));
        }
        manifest.insert(path.to_vec(), worktree_entry(repo, path)?);
    }

    let mut ls = vec![
        OsString::from("ls-files"),
        "-o".into(),
        "-z".into(),
        "--exclude-standard".into(),
    ];
    if let Some(file) = excludes_file(&git, global_configs)? {
        let mut c = OsString::from("core.excludesFile=");
        c.push(file);
        ls.splice(0..0, [OsString::from("-c"), c]);
    }
    let untracked = run("list untracked files", git.cmd(ls), None)?;
    for path in untracked.split(|&b| b == 0).filter(|p| !p.is_empty()) {
        if path.ends_with(b"/") {
            return Err(refused(
                path,
                "a nested repository (its files can't be named)",
            ));
        }
        manifest.insert(path.to_vec(), worktree_entry(repo, path)?);
    }

    let mut extras = BTreeMap::new();
    let mut missing = Vec::new();
    for p in extra {
        let rel = p.as_os_str().as_bytes();
        check_path(rel).map_err(|why| refused(rel, why))?;
        match fs::symlink_metadata(repo.join(p)) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => missing.push(p.clone()),
            Err(e) => return Err(e.into()),
            Ok(m) if m.is_dir() => walk(repo, rel, &mut extras)?,
            Ok(_) => {
                extras.insert(rel.to_vec(), worktree_entry(repo, rel)?);
            }
        }
    }
    if !missing.is_empty() {
        return Err(SyncError::Missing(missing));
    }
    for path in manifest.keys().chain(extras.keys()) {
        check_path(path).map_err(|why| refused(path, why))?;
    }
    Ok(Inputs {
        commit,
        tree,
        manifest: manifest.into_values().collect(),
        extras: extras.into_values().collect(),
    })
}

/// The input key: sha256 hex over the tree id, the manifest and the extras.
pub fn input_key(inputs: &Inputs) -> String {
    let mut h = Sha256::new();
    h.update(b"sleipnir input key 1\0");
    h.update(inputs.tree.as_bytes());
    for (list, tag) in [(&inputs.manifest, b'm'), (&inputs.extras, b'x')] {
        for e in list {
            let path = e.path();
            h.update([tag]);
            h.update((path.len() as u64).to_le_bytes());
            h.update(path);
            match e {
                Entry::File {
                    mode, sha256, size, ..
                } => {
                    h.update(b"f");
                    h.update(mode.to_le_bytes());
                    h.update(sha256);
                    h.update(size.to_le_bytes());
                }
                Entry::Deleted { .. } => h.update(b"d"),
            }
        }
    }
    hex(&h.finalize())
}

/// The entry for `rel` as the worktree has it now: gone (or a directory where a file was) is a deletion.
fn worktree_entry(repo: &Path, rel: &[u8]) -> Result<Entry> {
    let full = repo.join(OsStr::from_bytes(rel));
    let meta = match fs::symlink_metadata(&full) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return Ok(Entry::Deleted { path: rel.to_vec() });
        }
        r => r?,
    };
    let ft = meta.file_type();
    if ft.is_dir() {
        return Ok(Entry::Deleted { path: rel.to_vec() });
    }
    let (mode, (sha256, size)) = if ft.is_symlink() {
        let target = fs::read_link(&full)?;
        (MODE_LINK, hash(target.as_os_str().as_bytes())?)
    } else if ft.is_file() {
        let mode = if meta.permissions().mode() & 0o100 != 0 {
            MODE_EXEC
        } else {
            MODE_FILE
        };
        (mode, hash(fs::File::open(&full)?)?)
    } else {
        return Err(refused(rel, "neither a file nor a link"));
    };
    Ok(Entry::File {
        path: rel.to_vec(),
        mode,
        sha256,
        size,
    })
}

/// Every file and link under the directory `rel`, never following a link.
fn walk(repo: &Path, rel: &[u8], out: &mut BTreeMap<Vec<u8>, Entry>) -> Result<()> {
    for e in fs::read_dir(repo.join(OsStr::from_bytes(rel)))? {
        let e = e?;
        let mut child = rel.to_vec();
        child.push(b'/');
        child.extend_from_slice(e.file_name().as_bytes());
        if e.file_type()?.is_dir() {
            walk(repo, &child, out)?;
        } else {
            let entry = worktree_entry(repo, &child)?;
            out.insert(child, entry);
        }
    }
    Ok(())
}

fn hash(mut r: impl Read) -> io::Result<([u8; 32], u64)> {
    let mut h = Sha256::new();
    let mut buf = vec![0; 64 * 1024];
    let mut size = 0;
    loop {
        let n = r.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
        size += n as u64;
    }
    let mut out = [0; 32];
    out.copy_from_slice(&h.finalize());
    Ok((out, size))
}

/// The user's `core.excludesFile`, which git would read from their global config (or the repository's): git runs
/// here with no global config, and the user's ignored files must still stay out of the overlay. The files are read
/// as data (`git config --file`); nothing in them runs.
fn excludes_file(git: &Git, global_configs: &[PathBuf]) -> Result<Option<OsString>> {
    let mut found = None;
    let mut look = |mut args: Vec<OsString>| -> Result<()> {
        args.extend(["--includes", "--path", "--get", "core.excludesFile"].map(OsString::from));
        let ran = spawn(git.cmd(args), None)?;
        match ran.code {
            Some(0) => found = Some(OsString::from_vec(line(&ran.stdout).into_bytes())),
            Some(1) => {} // not set there
            _ => return Err(ran.failed("read core.excludesFile")),
        }
        Ok(())
    };
    for f in global_configs.iter().filter(|f| f.is_file()) {
        look(vec!["config".into(), "--file".into(), f.into()])?;
    }
    look(vec!["config".into(), "--local".into()])?;
    Ok(found)
}

/// The global config files git would read: `$GIT_CONFIG_GLOBAL`, else the XDG one and then `~/.gitconfig`.
fn global_config_files() -> Vec<PathBuf> {
    if let Some(p) = std::env::var_os("GIT_CONFIG_GLOBAL") {
        return vec![p.into()];
    }
    let home = std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .map(PathBuf::from);
    let xdg = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|x| !x.is_empty())
        .map(PathBuf::from)
        .or_else(|| home.as_ref().map(|h| h.join(".config")));
    xdg.map(|x| x.join("git/config"))
        .into_iter()
        .chain(home.map(|h| h.join(".gitconfig")))
        .collect()
}

fn unexpected(what: &'static str) -> SyncError {
    SyncError::Git {
        what,
        code: None,
        stderr: "unexpected output".into(),
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::super::SyncError;
    use super::super::slot::{self, Overlay, SlotKey};
    use super::super::testutil::{self, DirBlobs, user_git, write};
    use super::*;

    fn paths(entries: &[Entry]) -> Vec<(&[u8], bool)> {
        entries
            .iter()
            .map(|e| (e.path(), matches!(e, Entry::Deleted { .. })))
            .collect()
    }

    // [D] pure (a temp repo, real git)
    #[test]
    fn missing_extra_input_refuses_naming_it() {
        let t = tempfile::tempdir().unwrap();
        let (repo, _) = testutil::repo(
            t.path(),
            &[(b".gitignore", b"cache/\n"), (b"src.el", b"(x)\n")],
        );
        write(&repo, b"cache/grammars/rust.so", b"\x7fELF");
        let err = capture(
            &repo,
            &[
                PathBuf::from("cache/grammars"),
                PathBuf::from("cache/absent"),
                "gone.txt".into(),
            ],
        )
        .unwrap_err();
        match err {
            SyncError::Missing(m) => assert_eq!(
                m,
                vec![PathBuf::from("cache/absent"), PathBuf::from("gone.txt")]
            ),
            other => panic!("expected Missing, got {other}"),
        }
        let ok = capture(&repo, &[PathBuf::from("cache/grammars")]).unwrap();
        assert_eq!(
            paths(&ok.extras),
            vec![(&b"cache/grammars/rust.so"[..], false)]
        );
        assert!(
            ok.manifest.is_empty(),
            "an ignored file is never in the overlay: {:?}",
            ok.manifest
        );
    }

    // [D] pure (a temp repo, real git)
    #[test]
    fn overlay_includes_staged_and_untracked_and_deletions() {
        let t = tempfile::tempdir().unwrap();
        let (repo, commit) = testutil::repo(
            t.path(),
            &[
                (b".gitignore", b"*.log\n"),
                (b"a", b"a\n"),
                (b"b", b"b\n"),
                (b"c", b"c\n"),
                (b"same", b"same\n"),
            ],
        );
        write(&repo, b"a", b"a changed, not staged\n");
        write(&repo, b"s", b"staged\n");
        user_git(&repo, &["add", "s"]);
        write(&repo, b"u/untracked", b"untracked\n");
        write(&repo, b"debug.log", b"ignored\n");
        fs::remove_file(repo.join("b")).unwrap();
        user_git(&repo, &["rm", "-q", "c"]);
        // touched, not changed: not in the overlay
        fs::write(repo.join("same"), b"same\n").unwrap();
        let i = capture(&repo, &[]).unwrap();
        assert_eq!(i.commit, commit);
        assert_eq!(
            paths(&i.manifest),
            vec![
                (&b"a"[..], false),
                (b"b", true),
                (b"c", true),
                (b"s", false),
                (b"u/untracked", false)
            ]
        );
        let Entry::File {
            mode, size, sha256, ..
        } = &i.manifest[0]
        else {
            panic!()
        };
        assert_eq!((*mode, *size), (MODE_FILE, 22));
        assert_ne!(sha256, &[0; 32]);
    }

    // [D] pure (a temp repo, real git)
    #[test]
    fn same_inputs_same_key() {
        let t = tempfile::tempdir().unwrap();
        let (repo, _) = testutil::repo(t.path(), &[(b"a", b"a\n")]);
        write(&repo, b"new", b"new\n");
        let one = input_key(&capture(&repo, &[]).unwrap());
        assert_eq!(one, input_key(&capture(&repo, &[]).unwrap()));
        assert_eq!(one.len(), 64);
        fs::write(repo.join("new"), b"new\n").unwrap();
        assert_eq!(
            one,
            input_key(&capture(&repo, &[]).unwrap()),
            "a rewrite with the same bytes keeps the key"
        );
        fs::write(repo.join("new"), b"other\n").unwrap();
        assert_ne!(one, input_key(&capture(&repo, &[]).unwrap()));
        use std::os::unix::fs::PermissionsExt;
        fs::write(repo.join("new"), b"new\n").unwrap();
        fs::set_permissions(repo.join("new"), fs::Permissions::from_mode(0o755)).unwrap();
        assert_ne!(
            one,
            input_key(&capture(&repo, &[]).unwrap()),
            "the mode is an input"
        );
    }

    // [D] pure (Review Focus 2: names are sent and written byte-exact)
    #[test]
    fn odd_names_round_trip_byte_exact() {
        let t = tempfile::tempdir().unwrap();
        let (repo, commit) = testutil::repo(
            t.path(),
            &[
                (b"plain", b"p\n"),
                (b"tab\there", b"t\n"),
                (b"old \xc3\xa9\n", b"gone\n"),
            ],
        );
        let odd: [&[u8]; 4] = [
            b"a b",
            b"new\nline",
            b"\xff\xfe.bin",
            b"dir with space/\x01ctl",
        ];
        for (n, name) in odd.iter().enumerate() {
            write(&repo, name, format!("odd {n}\n").as_bytes());
        }
        write(&repo, b"tab\there", b"t changed\n");
        fs::remove_file(testutil::path(&repo, b"old \xc3\xa9\n")).unwrap();
        let i = capture(&repo, &[]).unwrap();
        let mut want: Vec<(&[u8], bool)> = odd.iter().map(|n| (*n, false)).collect();
        want.extend([(&b"old \xc3\xa9\n"[..], true), (b"tab\there", false)]);
        want.sort();
        assert_eq!(paths(&i.manifest), want);

        let blobs = DirBlobs::of(&t.path().join("blobs"), &repo, &i);
        let p = slot::paths(&t.path().join("runner"), &key());
        slot::update(&p, &repo.join(".git"), &commit, &Overlay::of(&i, &blobs)).unwrap();
        for (n, name) in odd.iter().enumerate() {
            assert_eq!(
                fs::read(testutil::path(&p.slot, name)).unwrap(),
                format!("odd {n}\n").as_bytes()
            );
        }
        assert_eq!(
            fs::read(testutil::path(&p.slot, b"tab\there")).unwrap(),
            b"t changed\n"
        );
        assert!(!testutil::path(&p.slot, b"old \xc3\xa9\n").exists());
        assert_eq!(
            testutil::tree(&p.slot),
            testutil::tree(&repo)
                .into_iter()
                .filter(|(k, _)| !k.starts_with(b".git"))
                .collect()
        );
    }

    // [D] pure: a nested repository's files can't be named, so the capture refuses it rather than skip it
    #[test]
    fn a_nested_repository_is_refused_naming_it() {
        let t = tempfile::tempdir().unwrap();
        let (repo, _) = testutil::repo(t.path(), &[(b"a", b"a\n")]);
        fs::create_dir(repo.join("vendored")).unwrap();
        user_git(&repo.join("vendored"), &["init", "-q"]);
        write(&repo, b"vendored/x", b"x\n");
        match capture(&repo, &[]).unwrap_err() {
            SyncError::Refused { path, .. } => assert_eq!(path, b"vendored/"),
            other => panic!("expected Refused, got {other}"),
        }
    }

    // [D] pure: the user's global excludes still apply on the hub, although git runs with no global config
    #[test]
    fn the_users_global_excludes_still_apply() {
        let t = tempfile::tempdir().unwrap();
        let (repo, _) = testutil::repo(t.path(), &[(b"a", b"a\n")]);
        let ignore = t.path().join("global-ignore");
        fs::write(&ignore, "*.secret\n").unwrap();
        let global = t.path().join("gitconfig");
        fs::write(
            &global,
            format!("[core]\n\texcludesFile = {}\n", ignore.display()),
        )
        .unwrap();
        write(&repo, b"key.secret", b"hush\n");
        write(&repo, b"kept", b"kept\n");
        let i = capture_with(&repo, &[], &[global]).unwrap();
        assert_eq!(paths(&i.manifest), vec![(&b"kept"[..], false)]);
    }

    fn key() -> SlotKey {
        SlotKey {
            project: "p".into(),
            worktree: "w".into(),
            trust: "private".into(),
            toolchain: "t".into(),
        }
    }
}
