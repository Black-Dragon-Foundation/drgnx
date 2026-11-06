//! The edit history in the nightly backup: one checked copy of each project's `history.db`, `history-<project>.db`
//! beside `work.db`'s dated copies, replaced each night and never rotated (the 2 GiB cap per project bounds it).  A
//! copy that fails is reported and logged; it never stops the other copies or the `work.db` one.

use runstav::methods::graph::HistoryCopy;
use std::path::Path;

/// Copy every project history under HUB (`<hub>/history/<project>/history.db`) into BACKUP, in project order.
pub fn copy_all(hub: &Path, backup: &Path) -> Vec<HistoryCopy> {
    let Ok(rd) = std::fs::read_dir(hub.join("history")) else {
        return Vec::new();
    };
    let mut projects: Vec<String> = rd
        .flatten()
        .filter(|e| e.path().join("history.db").exists())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    projects.sort();
    projects
        .into_iter()
        .map(|project| {
            let dest = backup.join(format!("history-{project}.db"));
            let src = hub.join("history").join(&project).join("history.db");
            let done = verdandi::vacuum_file(&src, &dest);
            if let Err(e) = &done {
                tracing::warn!(project, "the edit history's backup failed: {e}");
            }
            HistoryCopy {
                project,
                path: dest.to_string_lossy().into_owned(),
                ok: done.is_ok(),
                bytes: done.unwrap_or(0),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A hub folder holding the histories of PROJECTS (a store each), and an empty backup folder.
    fn fx(projects: &[&str]) -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf) {
        let d = tempfile::tempdir().unwrap();
        let hub = d.path().join("hub");
        for p in projects {
            drop(verdandi::History::open(&hub.join("history").join(p)).unwrap());
        }
        let backup = d.path().join("data/backup");
        std::fs::create_dir_all(&backup).unwrap();
        (d, hub, backup)
    }

    // pattern: D
    #[test]
    fn history_db_is_copied_beside_work_db() {
        let (_d, hub, backup) = fx(&["p1"]);
        std::fs::write(backup.join("work-20261107.db"), b"work").unwrap();
        let got = copy_all(&hub, &backup);
        assert_eq!(got.len(), 1);
        assert!(got[0].ok && got[0].bytes > 0, "{got:?}");
        assert_eq!(got[0].project, "p1");
        assert_eq!(
            std::path::Path::new(&got[0].path),
            backup.join("history-p1.db")
        );
        assert!(backup.join("history-p1.db").exists());
        assert!(backup.join("work-20261107.db").exists());
    }

    // pattern: D
    #[test]
    fn one_history_copy_per_project_is_kept() {
        let (_d, hub, backup) = fx(&["p1", "p2"]);
        copy_all(&hub, &backup);
        copy_all(&hub, &backup);
        let mut names: Vec<_> = std::fs::read_dir(&backup)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(names, ["history-p1.db", "history-p2.db"]);
    }

    // pattern: D
    #[test]
    fn a_failed_history_copy_keeps_the_work_db_copy() {
        let (_d, hub, backup) = fx(&["p1", "p2"]);
        std::fs::write(backup.join("work-20261107.db"), b"work").unwrap();
        // p1's file is no database any more
        std::fs::write(hub.join("history/p1/history.db"), b"not sqlite").unwrap();
        let got = copy_all(&hub, &backup);
        assert_eq!(got.len(), 2);
        assert!(!got[0].ok && got[0].bytes == 0, "{got:?}");
        assert!(got[1].ok, "the next project is still copied: {got:?}");
        assert!(!backup.join("history-p1.db").exists());
        assert_eq!(
            std::fs::read(backup.join("work-20261107.db")).unwrap(),
            b"work"
        );
    }
}
