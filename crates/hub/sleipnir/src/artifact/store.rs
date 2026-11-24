//! The artifact store: `<root>/artifacts/<project>@<role>@<kind>@<key>/`, one folder per committed artifact.
//!
//! - **Parts.** A build writes `<name>.part` ([`Store::begin`]) and [`PartDir::commit`] renames it into place, so a
//!   half-made artifact is never at a name [`Store::path`] answers. A part that is dropped without a commit (a failed
//!   build) is removed; one left by a crash is replaced by the next `begin` of that key.
//! - **Read-only.** A committed artifact's files lose their write bits; a job mounts the folder read-only on top.
//! - **Register.** Commit adds the artifact to the disk register as an `Artifact` item, id
//!   [`forseti::artifact::item_id`], owned by the project. The guard keeps it while the hub's pins name it active, and
//!   evicts it by age or budget otherwise.
//! - **Paths.** The project and role are in the folder's name, so two projects' (or a gate's and an author's) builds of
//!   one key are two folders and two register items. Every word is one path component ([`component`]).

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use forseti::artifact::item_id;
use forseti::disk::{DiskItem, ItemKind};
use forseti::{ArtifactKey, JobTrust, Role};

use super::key_ok;
use crate::sync::cache::component;
use crate::sync::register::Register;

/// The folder of the store under the runner folder.
pub const DIR: &str = "artifacts";

/// The kinds a store keeps.
pub const KINDS: [&str; 2] = ["image", "command"];

/// The artifacts of the runner folder ROOT.
#[derive(Clone, Debug)]
pub struct Store {
    root: PathBuf,
}

/// An artifact being built: its folder is `<name>.part` until [`PartDir::commit`].
#[derive(Debug)]
pub struct PartDir {
    part: PathBuf,
    done: PathBuf,
    project: String,
    role: Role,
    key: ArtifactKey,
    committed: bool,
}

fn io_err(what: &str, p: &Path, e: std::io::Error) -> villa::Error {
    villa::Error::io(format!("the artifact store: {what} {}: {e}", p.display())).with_source(e)
}

impl Store {
    /// The store of runner folder ROOT.
    pub fn at(root: &Path) -> Store {
        Store {
            root: root.to_path_buf(),
        }
    }

    /// `<root>/artifacts`.
    pub fn dir(&self) -> PathBuf {
        self.root.join(DIR)
    }

    fn name(project: &str, role: Role, kind: &str, key: &ArtifactKey) -> String {
        format!("{}@{}@{kind}@{}", component(project), role.name(), key.0)
    }

    fn check(kind: &str, key: &ArtifactKey) -> villa::Result<()> {
        if !KINDS.contains(&kind) {
            return Err(villa::Error::invalid(format!(
                "an artifact is an image or a command, not {kind:?}"
            )));
        }
        if !key_ok(&key.0) {
            return Err(villa::Error::invalid(format!(
                "an artifact's key is 64 hex digits, not {:?}",
                key.0
            )));
        }
        Ok(())
    }

    /// Starts the artifact KEY of PROJECT in ROLE: an empty `<name>.part` folder (one a crash left is replaced). A key
    /// that is committed already is refused: the caller uses it ([`Store::path`]) instead of building it again.
    pub fn begin(
        &self,
        project: &str,
        role: Role,
        kind: &str,
        key: &ArtifactKey,
    ) -> villa::Result<PartDir> {
        Self::check(kind, key)?;
        let dir = self.dir();
        let done = dir.join(Self::name(project, role, kind, key));
        if done.exists() {
            return Err(villa::Error::conflict(format!(
                "the artifact {} is committed already",
                key.0
            )));
        }
        let part = done.with_file_name(format!(
            "{}.part",
            done.file_name()
                .and_then(|n| n.to_str())
                .unwrap_or_default()
        ));
        fs::create_dir_all(&dir).map_err(|e| io_err("making", &dir, e))?;
        if part.exists() {
            fs::remove_dir_all(&part).map_err(|e| io_err("clearing", &part, e))?;
        }
        fs::create_dir(&part).map_err(|e| io_err("making", &part, e))?;
        Ok(PartDir {
            part,
            done,
            project: project.to_string(),
            role,
            key: key.clone(),
            committed: false,
        })
    }

    /// The part [`PartDir::release`] left for KEY of PROJECT in ROLE, taken up again to commit or drop: the build ran in
    /// another process, so the part outlives the `begin` that made it.
    pub fn resume(
        &self,
        project: &str,
        role: Role,
        kind: &str,
        key: &ArtifactKey,
    ) -> villa::Result<PartDir> {
        Self::check(kind, key)?;
        let done = self.dir().join(Self::name(project, role, kind, key));
        let part = done.with_file_name(format!(
            "{}.part",
            done.file_name()
                .and_then(|n| n.to_str())
                .unwrap_or_default()
        ));
        if !part.is_dir() {
            return Err(villa::Error::not_found(format!(
                "no part of the artifact {} is being built",
                key.0
            )));
        }
        Ok(PartDir {
            part,
            done,
            project: project.to_string(),
            role,
            key: key.clone(),
            committed: false,
        })
    }

    /// The folder of the committed artifact KEY of PROJECT in ROLE; none while it is only a part, or absent.
    pub fn path(
        &self,
        project: &str,
        role: Role,
        kind: &str,
        key: &ArtifactKey,
    ) -> Option<PathBuf> {
        Self::check(kind, key).ok()?;
        let p = self.dir().join(Self::name(project, role, kind, key));
        fs::symlink_metadata(&p)
            .ok()
            .filter(|m| m.is_dir())
            .map(|_| p)
    }
}

impl PartDir {
    /// The folder the build writes into.
    pub fn path(&self) -> &Path {
        &self.part
    }

    /// Leaves the part in place for a build that runs in another process ([`Store::resume`] takes it up again): the
    /// folder to mount. Until then nothing removes it but the next `begin` of the key.
    pub fn release(mut self) -> PathBuf {
        self.committed = true;
        self.part.clone()
    }

    /// The artifact's committed place (it is not there before [`PartDir::commit`]).
    pub fn done(&self) -> &Path {
        &self.done
    }

    /// Makes the part the artifact: every file read-only, the folder renamed into place, the artifact in REG at NOW.
    /// Returns its folder. When another build committed the key first, this part is dropped and that one is returned.
    pub fn commit(mut self, reg: &mut Register, now: u64) -> villa::Result<PathBuf> {
        readonly(&self.part)?;
        match crate::fsio::rename_dir(&self.part, &self.done) {
            Ok(()) => {}
            // a folder that is not empty: the key was committed meanwhile
            Err(e) if self.done.exists() => {
                tracing::debug!(error = %e, "the artifact store: the key was committed first");
                fs::remove_dir_all(&self.part).map_err(|e| io_err("removing", &self.part, e))?;
            }
            Err(e) => return Err(io_err("committing", &self.done, e)),
        }
        self.committed = true;
        let rel = self
            .done
            .strip_prefix(reg.root())
            .map_err(|_| villa::Error::refused("an artifact outside the runner folder"))?
            .to_path_buf();
        reg.add(
            DiskItem {
                id: item_id(self.role, &self.project, &self.key),
                kind: ItemKind::Artifact,
                owner: self.project.clone(),
                machine: String::new(),
                bytes: 0,
                last_used: now,
                created: now,
                name: None,
                budget_bytes: None,
                trust: JobTrust::PrivateKeys,
            },
            &rel,
        )?;
        Ok(self.done.clone())
    }
}

impl Drop for PartDir {
    /// A build that did not commit leaves no part behind.
    fn drop(&mut self) {
        if !self.committed
            && let Err(e) = fs::remove_dir_all(&self.part)
        {
            tracing::debug!(error = %e, "the artifact store: the part was already gone");
        }
    }
}

/// Every file under DIR loses its write bits (a link is left as it is); folders stay as they are, so the guard can
/// remove the artifact later.
fn readonly(dir: &Path) -> villa::Result<()> {
    for e in fs::read_dir(dir).map_err(|e| io_err("reading", dir, e))? {
        let e = e.map_err(|e| io_err("reading", dir, e))?;
        let p = e.path();
        let t = e.file_type().map_err(|e| io_err("reading", &p, e))?;
        if t.is_dir() {
            readonly(&p)?;
        } else if t.is_file() {
            let m = fs::symlink_metadata(&p).map_err(|e| io_err("reading", &p, e))?;
            let mode = m.permissions().mode() & !0o222;
            fs::set_permissions(&p, fs::Permissions::from_mode(mode))
                .map_err(|e| io_err("protecting", &p, e))?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use forseti::disk::{DiskRules, Pins};
    use std::collections::BTreeSet;

    fn key(c: char) -> ArtifactKey {
        ArtifactKey(c.to_string().repeat(64))
    }

    // [D] tmpfs root
    #[test]
    fn a_part_is_never_visible() {
        let t = tempfile::tempdir().unwrap();
        let store = Store::at(t.path());
        let k = key('a');
        let part = store.begin("p", Role::Gate, "command", &k).unwrap();
        crate::fsio::write(part.path().join("out.txt"), "x").unwrap();
        // while it is a part the store answers none, and the part is not at the committed name
        assert_eq!(store.path("p", Role::Gate, "command", &k), None);
        assert!(!part.done().exists());
        // a build that never commits leaves nothing
        let gone = part.path().to_path_buf();
        drop(part);
        assert!(!gone.exists());
        assert_eq!(store.path("p", Role::Gate, "command", &k), None);
        // a part a crash left is replaced by the next begin
        let crashed = store.begin("p", Role::Gate, "command", &k).unwrap();
        std::mem::forget(crashed);
        let again = store.begin("p", Role::Gate, "command", &k).unwrap();
        assert!(
            fs::read_dir(again.path()).unwrap().next().is_none(),
            "a fresh part is empty"
        );
        // only a committed folder is answered
        let mut reg = Register::open(t.path()).unwrap();
        let done = again.commit(&mut reg, 5).unwrap();
        assert_eq!(store.path("p", Role::Gate, "command", &k), Some(done));
        // the role and the project partition the store
        assert_eq!(store.path("p", Role::Author, "command", &k), None);
        assert_eq!(store.path("q", Role::Gate, "command", &k), None);
        // the names are checked
        assert!(store.begin("p", Role::Gate, "fetch", &k).is_err());
        assert!(
            store
                .begin("p", Role::Gate, "image", &ArtifactKey("../x".into()))
                .is_err()
        );
    }

    // [D] tmpfs root
    #[test]
    fn a_released_part_is_resumed_and_committed_by_another_process() {
        let t = tempfile::tempdir().unwrap();
        let store = Store::at(t.path());
        let k = key('9');
        let at = store
            .begin("p", Role::Gate, "command", &k)
            .unwrap()
            .release();
        assert!(at.is_dir(), "a released part stays");
        crate::fsio::write(at.join("f"), "x").unwrap();
        // the same store, as another process would open it
        let again = Store::at(t.path());
        let mut reg = Register::open(t.path()).unwrap();
        let done = again
            .resume("p", Role::Gate, "command", &k)
            .unwrap()
            .commit(&mut reg, 3)
            .unwrap();
        assert!(done.join("f").exists());
        assert!(again.resume("p", Role::Gate, "command", &k).is_err());
    }

    // [D] tmpfs root
    #[test]
    fn a_committed_artifact_is_registered_and_read_only() {
        let t = tempfile::tempdir().unwrap();
        let store = Store::at(t.path());
        let mut reg = Register::open(t.path()).unwrap();
        let k = key('b');
        let part = store.begin("proj", Role::Author, "command", &k).unwrap();
        fs::create_dir(part.path().join("bin")).unwrap();
        crate::fsio::write(part.path().join("bin/tool"), "#!/bin/sh\n").unwrap();
        fs::set_permissions(
            part.path().join("bin/tool"),
            fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        let done = part.commit(&mut reg, 42).unwrap();
        let mode = fs::metadata(done.join("bin/tool"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o222, 0, "no write bit: {mode:o}");
        assert_eq!(mode & 0o111, 0o111, "its executable bits stay: {mode:o}");
        // an Artifact item under the id the hub's pins use
        let id = item_id(Role::Author, "proj", &k);
        let (item, rel) = reg.get(&id).expect("registered");
        assert_eq!(
            (item.kind, item.owner.as_str(), item.last_used),
            (ItemKind::Artifact, "proj", 42)
        );
        assert_eq!(done, t.path().join(&rel));
        // the register is the one on disk: another process reads it
        assert!(Register::open(t.path()).unwrap().get(&id).is_some());
        // a second build of the key is refused: the committed one is used
        assert!(store.begin("proj", Role::Author, "command", &k).is_err());
    }

    // [D] tmpfs root
    #[test]
    fn a_needed_key_is_active_for_the_guard() {
        use crate::sync::guard::{Df, GB, plan};
        let t = tempfile::tempdir().unwrap();
        let store = Store::at(t.path());
        let mut reg = Register::open(t.path()).unwrap();
        let (needed, idle) = (key('c'), key('d'));
        for k in [&needed, &idle] {
            store
                .begin("p", Role::Gate, "command", k)
                .unwrap()
                .commit(&mut reg, 0)
                .unwrap();
        }
        let items = reg.items();
        let low = Df {
            total: 500 * GB,
            avail: 10 * GB,
        };
        let week = 7 * 24 * 3600;
        let r = DiskRules::standard();
        // idle for a week, below the floor: both go
        let all = plan(low, 0, &items, &Pins::default(), &r, week);
        assert_eq!(all.len(), 2, "{all:?}");
        // the hub names one needed (active): only the other goes
        let pins = Pins {
            active: BTreeSet::from([item_id(Role::Gate, "p", &needed)]),
            ..Pins::default()
        };
        let some = plan(low, 0, &items, &pins, &r, week);
        assert_eq!(
            some.iter().map(|e| e.id.clone()).collect::<Vec<_>>(),
            [item_id(Role::Gate, "p", &idle)]
        );
    }
}
