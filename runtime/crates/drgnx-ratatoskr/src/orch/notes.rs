//! Merge notes on a task's merges (`docs/develop/orchestration.md`, "Merge notes"): git's side of `vordr::notes`.
//! Blocking (git): callers run it through `clock::blocking`.

use std::path::Path;

use vordr::notes::{self, Hunk, Range, Side};

use crate::orch::gates::git;

/// A side's diff from the merge base, by file.
type Diff = Vec<(String, Vec<Range>)>;

/// What a merge of THEIRS into OURS needs notes for.
#[derive(Debug)]
pub struct Needs {
    pub base: String,
    pub ours: (String, Diff),
    pub theirs: (String, Diff),
    /// Hunks both sides changed.
    pub hunks: Vec<Hunk>,
    /// Shared files both sides changed apart (merged cleanly, still audited).
    pub files: Vec<String>,
}

impl Needs {
    /// The hunk keys a note must name.
    pub fn keys(&self) -> Vec<String> {
        self.hunks
            .iter()
            .map(Hunk::key)
            .chain(self.files.iter().cloned())
            .collect()
    }
}

fn diff(dir: &Path, from: &str, to: &str) -> Result<Diff, String> {
    Ok(notes::ranges(&git(
        dir,
        &["diff", "-U0", "--no-color", "--no-renames", from, to],
    )?))
}

/// What merging THEIRS into OURS (commits in DIR) needs notes for, with SHARED the pack's shared-path globs.
pub fn needs(dir: &Path, ours: &str, theirs: &str, shared: &[String]) -> Result<Needs, String> {
    let base = git(dir, &["merge-base", ours, theirs])?.trim().to_owned();
    let (o, t) = (diff(dir, &base, ours)?, diff(dir, &base, theirs)?);
    let hunks = notes::conflicts(&o, &t);
    let files = notes::shared(&o, &t, &hunks, shared);
    Ok(Needs {
        base,
        ours: (ours.to_owned(), o),
        theirs: (theirs.to_owned(), t),
        hunks,
        files,
    })
}

/// Whether commit SHA (a prefix) on SIDE of N touched the hunk KEY: `git log -L` over the hunk's lines on that side,
/// or `git log -- PATH` for a shared file.
fn touches(dir: &Path, n: &Needs, side: Side, key: &str, sha: &str) -> bool {
    let (tip, diff) = match side {
        Side::Ours => (&n.ours.0, &n.ours.1),
        Side::Theirs => (&n.theirs.0, &n.theirs.1),
    };
    let range = format!("{}..{tip}", n.base);
    let log = match n.hunks.iter().find(|h| h.key() == key) {
        Some(h) => {
            let Some((a, b)) = diff
                .iter()
                .find(|(p, _)| *p == h.path)
                .and_then(|(_, r)| notes::side_lines(r, h))
            else {
                return false;
            };
            let l = format!("{a},{b}:{}", h.path);
            git(dir, &["log", "--format=%x1eC %H", "-L", &l, &range])
        }
        None => git(dir, &["log", "--format=%x1eC %H", &range, "--", key]),
    };
    log.unwrap_or_default()
        .lines()
        .filter_map(|l| l.strip_prefix("\u{1e}C "))
        .any(|c| c.starts_with(sha))
}

/// What keeps the merges in BASE..TIP from passing: each two-parent merge's `Merge-note:` lines against what it
/// needs (its first parent is ours, the merged one theirs).  Empty: they pass.
pub fn check(dir: &Path, base: &str, tip: &str, shared: &[String]) -> Result<Vec<String>, String> {
    let list = git(
        dir,
        &[
            "rev-list",
            "--merges",
            "--parents",
            &format!("{base}..{tip}"),
        ],
    )?;
    let mut out = Vec::new();
    for line in list.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        let short = &parts[0][..parts[0].len().min(12)];
        let [m, ours, theirs] = parts[..] else {
            out.push(format!("merge {short}: more than two parents"));
            continue;
        };
        let n = needs(dir, ours, theirs, shared)?;
        let message = git(dir, &["log", "-1", "--format=%B", m])?;
        let problems = notes::check(&n.keys(), &notes::parse_notes(&message), |s, k, c| {
            touches(dir, &n, s, k, c)
        });
        out.extend(problems.into_iter().map(|p| format!("merge {short}: {p}")));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn run(dir: &Path, args: &[&str]) -> (bool, String) {
        let out = Command::new("git")
            .args([
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "-c",
                "commit.gpgsign=false",
            ])
            .args(args)
            .current_dir(dir)
            .output()
            .unwrap();
        (
            out.status.success(),
            String::from_utf8_lossy(&out.stdout).trim().to_owned(),
        )
    }

    fn sh(dir: &Path, args: &[&str]) -> String {
        let (ok, out) = run(dir, args);
        assert!(ok, "{args:?}");
        out
    }

    fn commit(dir: &Path, file: &str, text: &str, message: &str) -> String {
        let p = dir.join(file);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, text).unwrap();
        sh(dir, &["add", "-A"]);
        sh(dir, &["commit", "-q", "-m", message]);
        sh(dir, &["rev-parse", "HEAD"])
    }

    const LINES: &str = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n";

    /// The commits of [`merged`]: the line's (words in f.txt, a setting) and the task's (a setting, numerals in
    /// f.txt), and the base and the task's commit before its merge.
    struct Shas {
        base: String,
        words: String,
        line_setting: String,
        task_setting: String,
        numerals: String,
    }

    /// A line and a task that both change line 3 of f.txt and, apart, the shared settings/s.el; then the task's merge
    /// of the line resolved, with the message MESSAGE gives.
    fn merged(message: &dyn Fn(&Shas) -> String) -> (tempfile::TempDir, Shas) {
        let d = tempfile::tempdir().unwrap();
        let p = d.path();
        sh(p, &["init", "-q", "-b", "main"]);
        commit(p, "f.txt", LINES, "base");
        let base = commit(p, "settings/s.el", LINES, "shared");
        sh(p, &["checkout", "-q", "-b", "line"]);
        let words = commit(p, "f.txt", &LINES.replace("3\n", "three\n"), "line: words");
        let line_setting = commit(
            p,
            "settings/s.el",
            &LINES.replace("9\n", "nine\n"),
            "line: setting",
        );
        sh(p, &["checkout", "-q", "main"]);
        sh(p, &["checkout", "-q", "-b", "task"]);
        let task_setting = commit(
            p,
            "settings/s.el",
            &LINES.replace("1\n", "one\n"),
            "task: setting",
        );
        let numerals = commit(p, "f.txt", &LINES.replace("3\n", "III\n"), "task: numerals");
        let (ok, _) = run(p, &["merge", "-q", "line"]);
        assert!(!ok, "the merge conflicts");
        std::fs::write(p.join("f.txt"), LINES.replace("3\n", "III three\n")).unwrap();
        sh(p, &["add", "-A"]);
        let s = Shas {
            base,
            words,
            line_setting,
            task_setting,
            numerals,
        };
        sh(p, &["commit", "-q", "-m", &message(&s)]);
        (d, s)
    }

    fn note(hunk: &str, ours: &str, theirs: &str) -> String {
        format!(
            "Merge-note: {hunk} ours={} theirs={} resolution=both | both intents kept\n",
            &ours[..8],
            &theirs[..8]
        )
    }

    #[test]
    fn a_merge_without_notes_for_its_hunks_is_held() {
        let shared = vec!["settings/*".to_string()];
        let (d, s) = merged(&|_| "Merge line into task".into());
        let problems = check(d.path(), &s.base, "task", &shared).unwrap();
        assert_eq!(problems.len(), 2, "{problems:?}");
        assert!(
            problems[0].ends_with("f.txt:3-3: no Merge-note"),
            "{problems:?}"
        );
        assert!(
            problems[1].ends_with("settings/s.el: no Merge-note"),
            "{problems:?}"
        );
        // no shared globs: only the conflicted hunk
        assert_eq!(check(d.path(), &s.base, "task", &[]).unwrap().len(), 1);
        // the task before its merge has nothing to note
        assert!(
            check(d.path(), &s.base, &s.numerals, &shared)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn notes_pass_only_citing_the_commits_that_touched_each_hunk() {
        let shared = vec!["settings/*".to_string()];
        let (d, s) = merged(&|s| {
            format!(
                "Merge line into task\n\n{}{}",
                note("f.txt:3-3", &s.numerals, &s.words),
                note("settings/s.el", &s.task_setting, &s.line_setting)
            )
        });
        assert_eq!(
            check(d.path(), &s.base, "task", &shared).unwrap(),
            Vec::<String>::new()
        );
        // each side's other commit cited: neither touched the hunk
        let (d, s) = merged(&|s| {
            format!(
                "Merge line into task\n\n{}{}",
                note("f.txt:3-3", &s.task_setting, &s.words),
                note("settings/s.el", &s.task_setting, &s.words)
            )
        });
        let problems = check(d.path(), &s.base, "task", &shared).unwrap();
        assert_eq!(problems.len(), 2, "{problems:?}");
        assert!(problems[0].contains("f.txt:3-3: ours"), "{problems:?}");
        assert!(
            problems[1].contains("settings/s.el: theirs"),
            "{problems:?}"
        );
    }
}
