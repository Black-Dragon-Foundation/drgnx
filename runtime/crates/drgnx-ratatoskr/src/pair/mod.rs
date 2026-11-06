//! Pair mode (docs/guide/pair-mode.md, docs/develop/pair-routing.md): a chat edits the user's own checkout, live,
//! through one door the hub controls.  The sandbox still binds the checkout read-only for the chat; the hub applies
//! each write through the editor that has the file open.
//!
//! This module holds the gates every hub-served read and every pair write pass first:
//! - [`gate`]: the matrix's `chat.project-edit` (instead of the chat column's `code.edit`, which stays never) and
//!   `chat.project-read`; a path inside the checkout and never `.git/`, the agents' own configuration
//!   (`lock::PROTECTED_RO`), a CI or build file (`code.ci-config` is never for a chat) or a credential file.
//! - [`read_gate`]: `chat.project-read`; a path inside the checkout and never a file the sandbox hides from the agent
//!   (Gleipnir's hide list and the secrets table), so a hub-served read never hands over what the sandbox hides.

pub mod door;
pub mod writes;

use norn::matrix::{Action, Effective, Verdict, decide};
use std::path::{Path, PathBuf};

/// Why a pair read or write is refused: the text the agent gets.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal(pub String);

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

fn refuse<T>(text: impl Into<String>) -> Result<T, Refusal> {
    Err(Refusal(text.into()))
}

fn absolute(path: &Path) -> Result<(), Refusal> {
    if path.is_absolute() {
        return Ok(());
    }
    refuse(format!(
        "{}: give the file's absolute path, inside your project",
        path.display()
    ))
}

/// PATH's true name and its path relative to ROOT's, or why not: absolute only; every link and `..` that exists is
/// resolved (the deepest existing ancestor through `canonicalize`, the rest, which cannot hold a link, lexically), so a
/// link or `..` out of the checkout is outside it.
fn inside(root: &Path, path: &Path) -> Result<(PathBuf, PathBuf), Refusal> {
    use std::path::Component;
    absolute(path)?;
    let root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    let (base, rest) = path
        .ancestors()
        .find_map(|a| {
            a.canonicalize()
                .ok()
                .map(|real| (real, path.strip_prefix(a).unwrap_or(Path::new(""))))
        })
        .unwrap_or_else(|| (PathBuf::from("/"), path));
    let mut real = base;
    for c in rest.components() {
        match c {
            Component::ParentDir => {
                real.pop();
            }
            Component::Normal(n) => real.push(n),
            Component::CurDir | Component::RootDir | Component::Prefix(_) => {}
        }
    }
    match real.strip_prefix(&root) {
        Ok(rel) => Ok((real.clone(), rel.to_path_buf())),
        Err(_) => refuse(format!(
            "{}: outside your project ({}); only files inside it are served or written",
            path.display(),
            root.display()
        )),
    }
}

/// Whether REL (relative to the checkout) names a credential file: a name of Gleipnir's [`SECRET_FILES`] or one of
/// the key files the snapshots leave out, at any depth.
///
/// [`SECRET_FILES`]: gleipnir::toolchain::SECRET_FILES
fn credential(rel: &Path) -> bool {
    let s = rel.to_string_lossy();
    let base = rel
        .file_name()
        .map(|b| b.to_string_lossy())
        .unwrap_or_default();
    gleipnir::toolchain::SECRET_FILES.iter().any(|n| {
        if n.contains('/') {
            s == *n || s.ends_with(&format!("/{n}"))
        } else {
            base == *n
        }
    }) || crate::timeline::snapshot::ALSO_SECRET
        .iter()
        .any(|n| match n.strip_prefix('*') {
            Some(ext) => base.ends_with(ext),
            None => base == *n,
        })
}

/// `chat.project-read` never: refused, naming the row.
fn readable(eff: &Effective) -> Result<(), Refusal> {
    if decide(eff, Action::ChatProjectRead, None) == Verdict::Never {
        return refuse(
            "chat.project-read is never for this chat (its preset or a column of the matrix): the hub serves it \
             nothing of your project",
        );
    }
    Ok(())
}

/// Whether a chat with the cells EFF may write PATH in the checkout ROOT through the door: its resolved path, or why
/// not.  `chat.project-edit` decides (Ask: the user's Pair toggle is allowed; whether it is on is the door's), never
/// `code.edit`.
pub fn gate(eff: &Effective, root: &Path, path: &Path) -> Result<PathBuf, Refusal> {
    absolute(path)?;
    if decide(eff, Action::ChatProjectEdit, None) == Verdict::Never {
        return refuse(
            "chat.project-edit is never for this chat (its preset or a column of the matrix): pair mode cannot be \
             turned on; ask the user",
        );
    }
    readable(eff)?;
    let (real, rel) = inside(root, path)?;
    let r = rel.to_string_lossy();
    if rel.components().any(|c| c.as_os_str() == ".git") {
        return refuse(format!("{r}: .git is never written by a chat"));
    }
    if crate::agents::lock::PROTECTED_RO
        .iter()
        .any(|q| r == *q || r.strip_prefix(q).is_some_and(|t| t.starts_with('/')))
    {
        return refuse(format!(
            "{r}: the agents' own configuration is never written by a chat"
        ));
    }
    if credential(&rel) {
        return refuse(format!("{r}: a credential file is never written by a chat"));
    }
    if crate::runner::git::is_ci_or_build(&r) {
        return refuse(format!(
            "{r}: a CI or build file; code.ci-config is never for a chat"
        ));
    }
    Ok(real)
}

/// Whether a chat with the cells EFF may be served PATH in the checkout ROOT (`read_file`, ACP `fs/read_text_file`,
/// `pair-read`): its resolved path, or why not.  A path outside the checkout (the user's private files among them) is
/// never served.
pub fn read_gate(eff: &Effective, root: &Path, path: &Path) -> Result<PathBuf, Refusal> {
    absolute(path)?;
    readable(eff)?;
    let (real, rel) = inside(root, path)?;
    if credential(&rel) {
        return refuse(format!(
            "{}: a credential file, hidden from agents",
            rel.display()
        ));
    }
    Ok(real)
}

#[cfg(test)]
mod tests {
    use super::*;
    use norn::matrix::{Cell, Preset, Role, Who, effective, preset};

    fn cell(v: Verdict) -> Cell {
        Cell {
            verdict: v,
            limit: None,
        }
    }

    fn chat(p: Preset) -> Effective {
        effective(
            &[&preset(p)],
            &Who {
                role: Some(Role::Chat),
                ..Who::default()
            },
        )
    }

    fn checkout() -> (tempfile::TempDir, PathBuf) {
        let d = tempfile::tempdir().unwrap();
        let root = d.path().canonicalize().unwrap();
        std::fs::create_dir_all(root.join("src")).unwrap();
        std::fs::write(root.join("src/main.rs"), "fn main() {}\n").unwrap();
        (d, root)
    }

    /// [D] The chat's `code.edit` is never in every preset and decides nothing here; `chat.project-edit` does.
    #[test]
    fn gate_uses_project_edit_not_code_edit() {
        let (_d, root) = checkout();
        let f = root.join("src/main.rs");
        assert_eq!(gate(&chat(Preset::Balanced), &root, &f), Ok(f.clone()));
        assert_eq!(gate(&chat(Preset::Autonomous), &root, &f), Ok(f.clone()));
        let r = gate(&chat(Preset::Cautious), &root, &f).unwrap_err();
        assert!(r.0.contains("chat.project-edit"), "{r}");
        // code.edit allowed, chat.project-edit never: refused
        let mut e = chat(Preset::Cautious);
        e.cells.insert(Action::CodeEdit, cell(Verdict::Allow));
        assert!(gate(&e, &root, &f).is_err());
        // code.edit never, chat.project-edit allowed: the door opens
        let mut e = chat(Preset::Autonomous);
        e.cells.insert(Action::CodeEdit, cell(Verdict::Never));
        assert_eq!(gate(&e, &root, &f), Ok(f.clone()));
        // a write needs the read too
        e.cells
            .insert(Action::ChatProjectRead, cell(Verdict::Never));
        let r = gate(&e, &root, &f).unwrap_err();
        assert!(r.0.contains("chat.project-read"), "{r}");
    }

    /// [D] `.git/`, the agents' own configuration and a path out of the checkout (through `..` or a link) are never
    /// written, each with its reason.
    #[test]
    fn door_refuses_protected_paths() {
        let (_d, root) = checkout();
        let outside = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(outside.path(), root.join("out")).unwrap();
        let e = chat(Preset::Autonomous);
        for (rel, why) in [
            (".git/config", ".git"),
            (".git/hooks/pre-commit", ".git"),
            (".claude/settings.json", "configuration"),
            (".codex/config.toml", "configuration"),
            (".gemini/settings.json", "configuration"),
            (".envrc", "configuration"),
            ("mise.toml", "configuration"),
            ("out/x.txt", "outside"),
            ("src/../../escape.txt", "outside"),
            (".env", "credential"),
            ("deploy/id_ed25519", "credential"),
            ("certs/server.key", "credential"),
        ] {
            let r = gate(&e, &root, &root.join(rel)).unwrap_err();
            assert!(r.0.contains(why), "{rel}: {r}");
        }
        let r = gate(&e, &root, Path::new("src/main.rs")).unwrap_err();
        assert!(r.0.contains("absolute"), "{r}");
        assert!(gate(&e, &root, &root.join("src/new.rs")).is_ok());
    }

    /// [D] A chat never writes a CI or build file, whatever its cells say: `code.ci-config` is never for a chat.
    #[test]
    fn ci_files_are_never_writable_by_a_chat() {
        let (_d, root) = checkout();
        let mut e = chat(Preset::Autonomous);
        e.cells.insert(Action::CodeCiConfig, cell(Verdict::Allow));
        for rel in [
            ".github/workflows/ci.yml",
            ".github/ci.yml",
            "Makefile",
            "sub/Makefile.am",
            "build.rs",
            "scripts/release.sh",
        ] {
            let r = gate(&e, &root, &root.join(rel)).unwrap_err();
            assert!(r.0.contains("code.ci-config"), "{rel}: {r}");
        }
    }

    /// [D] A hub-served read never hands over what the sandbox hides: Gleipnir's credential files and the secrets
    /// table, at any depth; other files read, `.git/` included.
    #[test]
    fn read_refuses_hidden_credential_files() {
        let (_d, root) = checkout();
        std::fs::create_dir_all(root.join("a/b")).unwrap();
        for f in [
            ".npmrc",
            "a/.pypirc",
            "a/b/.env",
            "credentials.toml",
            "secrets.env",
        ] {
            std::fs::write(root.join(f), "token").unwrap();
        }
        let e = chat(Preset::Balanced);
        for rel in [
            ".npmrc",
            "a/.pypirc",
            "a/b/.env",
            "credentials.toml",
            "secrets.env",
            "keys/id_rsa",
            "tls/site.pem",
        ] {
            let r = read_gate(&e, &root, &root.join(rel)).unwrap_err();
            assert!(r.0.contains("credential"), "{rel}: {r}");
        }
        let f = root.join("src/main.rs");
        assert_eq!(read_gate(&e, &root, &f), Ok(f));
        assert!(read_gate(&e, &root, &root.join(".git/HEAD")).is_ok());
        let outside = tempfile::tempdir().unwrap();
        let r = read_gate(&e, &root, &outside.path().join("x")).unwrap_err();
        assert!(r.0.contains("outside"), "{r}");
        let mut never = chat(Preset::Balanced);
        never
            .cells
            .insert(Action::ChatProjectRead, cell(Verdict::Never));
        let r = read_gate(&never, &root, &root.join("src/main.rs")).unwrap_err();
        assert!(r.0.contains("chat.project-read"), "{r}");
    }
}
