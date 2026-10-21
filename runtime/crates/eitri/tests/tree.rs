//! Random trees with random links: `open_beneath` (and `open_path`) never follow a link and never leave the root.
//!
//! The oracle walks the root with `lstat`, one component at a time, following no link: every `Ok` must be the
//! `(dev, ino)` that walk finds, and a path whose walk meets a link must give `Link`.

use std::fs;
use std::os::fd::{AsFd, OwnedFd};
use std::os::unix::fs::{MetadataExt, symlink};
use std::path::{Path, PathBuf};

use eitri::{FsError, Kind, open_beneath, open_path};
use proptest::prelude::*;

const NAMES: [&str; 4] = ["a", "b", "c", "d"];
const PARTS: [&str; 6] = ["a", "b", "c", "d", ".", ".."];

#[derive(Debug, Clone)]
enum Node {
    Dir,
    File,
    /// An index into the link targets `targets()` builds.
    Link(usize),
}

fn node() -> impl Strategy<Value = Node> {
    prop_oneof![
        Just(Node::Dir),
        Just(Node::File),
        (0usize..12).prop_map(Node::Link)
    ]
}

/// Inside, outside, `/`, the root itself by its absolute path, and `..` in its many forms.
fn targets(root: &Path, outside: &Path) -> Vec<PathBuf> {
    let mut t: Vec<PathBuf> = ["..", "../..", "/", "/etc", "a", "../a", "a/b", "b", "."]
        .map(PathBuf::from)
        .into();
    t.push(root.to_path_buf());
    t.push(root.join("a"));
    t.push(outside.join("f"));
    t
}

#[derive(Debug, PartialEq)]
enum Expect {
    Ok {
        dev: u64,
        ino: u64,
        is_dir: bool,
    },
    Escapes,
    Link,
    /// Not found, or a file where a directory must be: some error that is neither `Ok` nor a followed link.
    OtherErr,
}

fn oracle(root: &Path, parts: &[&str]) -> Expect {
    if parts.contains(&"..") {
        return Expect::Escapes;
    }
    let mut cur = root.to_path_buf();
    let mut meta = fs::symlink_metadata(&cur).unwrap();
    for part in parts {
        if !meta.is_dir() {
            return Expect::OtherErr;
        }
        if *part == "." {
            continue;
        }
        cur.push(part);
        meta = match fs::symlink_metadata(&cur) {
            Ok(m) => m,
            Err(_) => return Expect::OtherErr,
        };
        if meta.file_type().is_symlink() {
            return Expect::Link;
        }
    }
    Expect::Ok {
        dev: meta.dev(),
        ino: meta.ino(),
        is_dir: meta.is_dir(),
    }
}

fn seen(r: Result<eitri::Pinned, FsError>) -> Expect {
    match r {
        Ok(p) => Expect::Ok {
            dev: p.dev,
            ino: p.ino,
            is_dir: p.is_dir,
        },
        Err(FsError::Escapes) => Expect::Escapes,
        Err(FsError::Link { .. }) => Expect::Link,
        Err(_) => Expect::OtherErr,
    }
}

proptest! {
    #[test]
    fn random_trees_never_escape_or_follow(
        nodes in prop::collection::vec((0usize..16, 0usize..NAMES.len(), node()), 0..14),
        paths in prop::collection::vec(prop::collection::vec(0usize..PARTS.len(), 1..5), 1..16),
    ) {
        let tmp = tempfile::tempdir().unwrap();
        // The root's own absolute path has no link in it (macOS: /var → /private/var).
        let root = tmp.path().canonicalize().unwrap();
        let outside = tempfile::tempdir().unwrap();
        fs::write(outside.path().join("f"), b"outside").unwrap();
        let targets = targets(&root, outside.path());

        let mut dirs = vec![root.clone()];
        for (parent, name, kind) in &nodes {
            let p = dirs[parent % dirs.len()].join(NAMES[*name]);
            if fs::symlink_metadata(&p).is_ok() {
                continue;
            }
            match kind {
                Node::Dir => {
                    fs::create_dir(&p).unwrap();
                    dirs.push(p);
                }
                Node::File => fs::write(&p, b"in").unwrap(),
                Node::Link(t) => symlink(&targets[*t], &p).unwrap(),
            }
        }

        let fd: OwnedFd = fs::File::open(&root).unwrap().into();
        for idx in &paths {
            let parts: Vec<&str> = idx.iter().map(|i| PARTS[*i]).collect();
            let rel = parts.join("/");
            let want = oracle(&root, &parts);
            let got = seen(open_beneath(fd.as_fd(), Path::new(&rel), Kind::Any));
            prop_assert_eq!(&got, &want, "open_beneath {}", rel);
            if want != Expect::Escapes {
                let got = seen(open_path(&root.join(&rel), Kind::Any));
                prop_assert_eq!(&got, &want, "open_path {}", rel);
            }
        }
    }
}
