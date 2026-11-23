//! Where a record file written through `records/write` or `plans/write` may live: exactly
//! `docs/{specs|decisions|plans}/<repo>/<name>.md` under the project root, made of plain components, with no link
//! and no nested git repository on the way, and not there yet.

use runstav::methods::records::RecordKind;
use std::io::Write;
use std::path::{Component, Path, PathBuf};

/// The folder a kind of record is written into.
fn folder(kind: RecordKind) -> Option<&'static str> {
    match kind {
        RecordKind::Specs => Some("specs"),
        RecordKind::Decisions => Some("decisions"),
        RecordKind::Plans => Some("plans"),
        _ => None,
    }
}

fn plain(part: &str) -> bool {
    !part.is_empty()
        && part
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// ROOT joined with REL when REL is a place a record of KIND may be created at; else what is wrong.  The caller
/// then creates the file with [`create_new_file`].
pub(crate) fn planning_path(root: &Path, rel: &str, kind: RecordKind) -> Result<PathBuf, String> {
    let want = folder(kind).ok_or("that kind of record has no planning folder")?;
    let shape = format!("docs/{want}/<repo>/<name>.md");
    let mut parts = Vec::new();
    for c in Path::new(rel).components() {
        match c {
            Component::Normal(p) => parts.push(p.to_string_lossy().into_owned()),
            _ => {
                return Err(format!(
                    "{rel:?} must be a plain relative path like {shape}"
                ));
            }
        }
    }
    if parts.iter().any(|p| !plain(p)) {
        return Err(format!(
            "{rel:?}: path parts take only letters, digits, `.`, `_` and `-`"
        ));
    }
    if parts.len() != 4 || parts[0] != "docs" || parts[1] != want {
        return Err(format!("{rel:?} must be exactly {shape}"));
    }
    let name = &parts[3];
    if !name.ends_with(".md") || name.len() == 3 {
        return Err(format!("{rel:?} must end in `.md`"));
    }
    if kind == RecordKind::Plans && name.ends_with(".ledger.md") {
        return Err(format!("{rel:?}: a ledger is not a plan"));
    }
    // every folder that exists on the way is a real folder, and none holds a repository of its own
    let mut at = root.to_path_buf();
    for p in &parts[..3] {
        at.push(p);
        match std::fs::symlink_metadata(&at) {
            Ok(m) if m.file_type().is_symlink() => {
                return Err(format!("{} is a link", at.display()));
            }
            // `is_dir` follows a link: a link to a folder is caught by the check above, nothing else
            Ok(_) if !at.is_dir() => return Err(format!("{} is not a folder", at.display())),
            Ok(_) => {
                if std::fs::symlink_metadata(at.join(".git")).is_ok() {
                    return Err(format!("{} holds a git repository", at.display()));
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => break,
            Err(e) => return Err(format!("{}: {e}", at.display())),
        }
    }
    let file = root.join(rel);
    if std::fs::symlink_metadata(&file).is_ok() {
        return Err(format!("{} exists already", file.display()));
    }
    Ok(file)
}

/// TEXT as the new file PATH: its folders made, the file created with `create_new` (it fails on anything already
/// there, a link planted since the check included), its folder under ROOT as the real filesystem has it.
pub(crate) fn create_new_file(root: &Path, path: &Path, text: &str) -> Result<(), String> {
    let dir = path.parent().ok_or("no folder")?;
    std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let (real_dir, real_root) = (dir.canonicalize(), root.canonicalize());
    match (real_dir, real_root) {
        (Ok(d), Ok(r)) if d.starts_with(&r) => {}
        _ => return Err(format!("{} is not under {}", dir.display(), root.display())),
    }
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    f.write_all(text.as_bytes())
        .and_then(|()| f.sync_all())
        .map_err(|e| format!("{}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root() -> tempfile::TempDir {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(d.path().join("docs/specs/r")).unwrap();
        std::fs::create_dir_all(d.path().join("docs/plans/r")).unwrap();
        d
    }

    #[test]
    fn path_rules_refuse_each_escape() {
        let d = root();
        let r = d.path();
        std::fs::write(r.join("docs/specs/r/exists.md"), "x").unwrap();
        // a symlinked folder, and a nested repository
        std::fs::create_dir_all(r.join("elsewhere")).unwrap();
        std::os::unix::fs::symlink(r.join("elsewhere"), r.join("docs/specs/linked")).unwrap();
        std::fs::create_dir_all(r.join("docs/specs/repo/.git")).unwrap();
        let spec = RecordKind::Specs;
        for (rel, kind) in [
            ("../x.md", spec),
            ("/abs.md", spec),
            ("docs/specs/a.md", spec),
            ("docs/specs/r/a.txt", spec),
            ("docs/specs/r/a.MD", spec),
            ("docs/plans/r/a.md", spec),
            ("docs/specs/r/sub/a.md", spec),
            ("docs/specs/r/../r/a.md", spec),
            ("docs/specs/linked/a.md", spec),
            ("docs/specs/repo/a.md", spec),
            ("docs/specs/r/exists.md", spec),
            ("docs/specs/r/a b.md", spec),
            ("docs/plans/r/a.ledger.md", RecordKind::Plans),
            ("docs/specs/r/a.md", RecordKind::Ledgers),
        ] {
            assert!(planning_path(r, rel, kind).is_err(), "{rel} as {kind:?}");
        }
        // what is allowed, a new folder included
        assert!(planning_path(r, "docs/specs/r/new.md", spec).is_ok());
        assert!(planning_path(r, "docs/decisions/r/new.md", RecordKind::Decisions).is_ok());
        assert!(planning_path(r, "docs/plans/fresh/new.md", RecordKind::Plans).is_ok());
        // a link planted between the check and the create: `create_new` fails and writes nothing
        let file = planning_path(r, "docs/specs/r/race.md", spec).unwrap();
        std::fs::write(r.join("elsewhere/target.md"), "keep").unwrap();
        std::os::unix::fs::symlink(r.join("elsewhere/target.md"), &file).unwrap();
        assert!(create_new_file(r, &file, "text").is_err());
        assert_eq!(
            std::fs::read_to_string(r.join("elsewhere/target.md")).unwrap(),
            "keep"
        );
    }
}
