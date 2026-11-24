//! A checkout's git folders, read as an agent-writable pointer is read: no link is followed.

use std::os::fd::AsFd;
use std::path::{Path, PathBuf};

/// P with its `.` and `..` components taken away by name (no link is read): a linked worktree's `commondir` (`../..`)
/// names its project's common folder as the main worktree's `.git` is named, so both share one history.
fn tidy(p: &Path) -> PathBuf {
    use std::path::Component;
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            c => out.push(c),
        }
    }
    out
}

/// ROOT's git directory and its common folder, read as an agent-writable pointer is: no link followed.  A `.git` file
/// (a linked worktree) is followed to its `gitdir:` and `commondir`.  The common folder, which names the project's
/// history, is given by its true name: git writes a linked worktree's `gitdir:` resolved, so a project under a link
/// (macOS's /var, a moved home) would otherwise be two projects, its main tree's and its worktrees'.
pub fn git_dirs(root: &Path) -> Option<(PathBuf, PathBuf)> {
    let (git_dir, common) = git_dirs_as_named(root)?;
    let common = std::fs::canonicalize(&common).unwrap_or(common);
    Some((git_dir, common))
}

fn git_dirs_as_named(root: &Path) -> Option<(PathBuf, PathBuf)> {
    use rustix::fs::{Mode, OFlags};
    let dir = rustix::fs::open(
        root,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .ok()?;
    let dot = root.join(".git");
    if eitri::open_beneath(dir.as_fd(), Path::new(".git"), eitri::Kind::Dir).is_ok() {
        return Some((dot.clone(), dot));
    }
    let text =
        String::from_utf8(eitri::read_regular(dir.as_fd(), Path::new(".git"), 4096).ok()?).ok()?;
    let target = text.trim().strip_prefix("gitdir:")?.trim();
    let gitdir = if Path::new(target).is_absolute() {
        PathBuf::from(target)
    } else {
        root.join(target)
    };
    let gd = rustix::fs::open(
        &gitdir,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .ok()?;
    let common = eitri::read_regular(gd.as_fd(), Path::new("commondir"), 4096)
        .ok()
        .and_then(|b| String::from_utf8(b).ok())
        .map_or_else(|| gitdir.clone(), |c| gitdir.join(c.trim()));
    Some((gitdir, tidy(&common)))
}
