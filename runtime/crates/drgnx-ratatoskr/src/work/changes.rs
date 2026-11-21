//! The Changes place's model: what the agents changed, grouped by the task each worked on (frontend flow plan, Task
//! 10). Task, then file, then hunk; hunks no task owns go in a last group, "Your edits and others". Pure grouping
//! (`group`) over each session's edits, and the reader that collects them from the edit history (`by_task`).

use crate::front::Front;
use runstav::wire::Error;

/// The name of the group of hunks no task owns.
pub const UNTASKED: &str = "Your edits and others";

/// One hunk of a file: the op that wrote it (when the history records one), its place, the agent and, when the agent
/// recorded one in that turn, the reason (its conclusion, in its own words).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HunkRef {
    pub op: Option<u64>,
    pub index: u32,
    pub start_line: u32,
    pub end_line: u32,
    pub agent: Option<String>,
    /// The session that wrote it (its worktree is where a revert goes).
    pub session: Option<String>,
    pub reason: Option<String>,
}

/// One file and what changed in it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileGroup {
    pub path: String,
    pub plus: u32,
    pub minus: u32,
    pub hunks: Vec<HunkRef>,
}

/// One task's edits.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TaskGroup {
    pub task: Option<String>,
    pub title: String,
    pub agent: Option<String>,
    pub files: Vec<FileGroup>,
}

/// One session's edits and the task it works on (id and title).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionEdits {
    pub agent: String,
    pub task: Option<(String, String)>,
    pub files: Vec<FileGroup>,
}

/// SESSIONS' edits grouped by task (by task id); the sessions of one task share a group and a file they both
/// changed appears once, its hunks together. A session on no task, and the hunks of a task nobody names, are in the
/// last group.
pub fn group(sessions: Vec<SessionEdits>) -> Vec<TaskGroup> {
    let mut groups: Vec<TaskGroup> = Vec::new();
    let mut untasked: Vec<FileGroup> = Vec::new();
    for s in sessions {
        let files = match &s.task {
            Some((id, title)) => {
                let at = match groups.iter().position(|g| g.task.as_deref() == Some(id)) {
                    Some(i) => i,
                    None => {
                        groups.push(TaskGroup {
                            task: Some(id.clone()),
                            title: title.clone(),
                            agent: Some(s.agent.clone()),
                            files: Vec::new(),
                        });
                        groups.len() - 1
                    }
                };
                &mut groups[at].files
            }
            None => &mut untasked,
        };
        for f in s.files {
            match files.iter_mut().find(|x| x.path == f.path) {
                Some(x) => {
                    x.plus += f.plus;
                    x.minus += f.minus;
                    x.hunks.extend(f.hunks);
                }
                None => files.push(f),
            }
        }
    }
    groups.sort_by(|a, b| a.task.cmp(&b.task));
    for g in &mut groups {
        g.files.sort_by(|a, b| a.path.cmp(&b.path));
    }
    if !untasked.is_empty() {
        untasked.sort_by(|a, b| a.path.cmp(&b.path));
        groups.push(TaskGroup {
            task: None,
            title: UNTASKED.into(),
            agent: None,
            files: untasked,
        });
    }
    groups
}

/// The hunks of a unified DIFF (`@@ -a,b +c,d @@`), numbered from 0, each by the lines it holds in the new file;
/// AGENT is the one that wrote them.
pub fn hunks_of(diff: &str, agent: &str, session: &str) -> Vec<HunkRef> {
    let mut out = Vec::new();
    for line in diff.lines().filter(|l| l.starts_with("@@")) {
        let new = line
            .split_whitespace()
            .find(|w| w.starts_with('+'))
            .map(|w| w.trim_start_matches('+'));
        let Some(new) = new else { continue };
        let (start, len) = new.split_once(',').map_or((new, "1"), |(a, b)| (a, b));
        let (Ok(start), Ok(len)) = (start.parse::<u32>(), len.parse::<u32>()) else {
            continue;
        };
        out.push(HunkRef {
            op: None,
            index: u32::try_from(out.len()).unwrap_or(u32::MAX),
            start_line: start,
            end_line: start + len.saturating_sub(1),
            agent: Some(agent.to_owned()),
            session: Some(session.to_owned()),
            reason: None,
        });
    }
    out
}

/// The title of each task id in TASKS (bare ids: `T1` is the entity `task:T1`).
async fn task_titles(f: &Front, tasks: Vec<String>) -> std::collections::BTreeMap<String, String> {
    if tasks.is_empty() {
        return std::collections::BTreeMap::new();
    }
    f.writer
        .db
        .read(move |c| {
            let mut out = std::collections::BTreeMap::new();
            for t in &tasks {
                let row: Result<Option<String>, _> = c.query_row(
                    "select title from entity where id = ?1 and retired_tx is null",
                    [format!("task:{t}")],
                    |r| r.get(0),
                );
                if let Ok(Some(title)) = row {
                    out.insert(t.clone(), title);
                }
            }
            Ok(out)
        })
        .await
        .unwrap_or_default()
}

/// The words of each decision id in DECISIONS (the conclusion an agent recorded): its reason.
pub async fn reasons(
    f: &Front,
    decisions: Vec<String>,
) -> std::collections::BTreeMap<String, String> {
    if decisions.is_empty() {
        return std::collections::BTreeMap::new();
    }
    f.writer
        .db
        .read(move |c| {
            let mut out = std::collections::BTreeMap::new();
            for d in &decisions {
                let row: Result<(String, Option<String>, Option<String>), _> = c.query_row(
                    "select kind, title, body from entity where id = ?1 and retired_tx is null",
                    [d],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                );
                if let Ok((kind, title, body)) = row {
                    let text = crate::work::conclusions::from_entity(
                        d,
                        &kind,
                        title.as_deref(),
                        body.as_deref(),
                        &serde_json::Value::Null,
                        0.0,
                    )
                    .text;
                    out.insert(d.clone(), text);
                }
            }
            Ok(out)
        })
        .await
        .unwrap_or_default()
}

/// The hunks of FILE's records among RECORDS (with the REASONS of their decisions), as the Changes view shows
/// them: the operation, the lines it wrote, the agent and the reason it recorded in that turn. None when the history
/// holds no record of the file.
pub fn record_refs(
    records: &[crate::work::edits::RecordHunk],
    reasons: &std::collections::BTreeMap<String, String>,
    path: &str,
    agent: &str,
    session: &str,
) -> Vec<HunkRef> {
    records
        .iter()
        .filter(|h| h.path == path && h.live)
        .map(|h| HunkRef {
            op: u64::try_from(h.op).ok(),
            index: u32::try_from(h.index).unwrap_or(u32::MAX),
            start_line: h.start_line,
            end_line: h.end_line,
            agent: Some(agent.to_owned()),
            session: Some(session.to_owned()),
            reason: h.decision.as_ref().and_then(|d| reasons.get(d).cloned()),
        })
        .collect()
}

/// The edits of every live session, by task: each session's files from the edit history, each file's hunks from its
/// diff. A hunk's `reason` and `op` come with the history's provenance (the cause an agent write records); until
/// then the session is the hunk's agent and its task the hunk's task.
pub async fn by_task(f: &Front) -> Result<Vec<TaskGroup>, Error> {
    let mut sessions = Vec::new();
    let live: Vec<(String, String, Option<String>)> = f
        .core
        .agents
        .live_sessions()
        .iter()
        .map(|s| {
            let snap = s.snapshot();
            let name = snap.name.clone().unwrap_or_else(|| snap.id.clone());
            (snap.id, name, snap.task)
        })
        .collect();
    let titles = task_titles(f, live.iter().filter_map(|l| l.2.clone()).collect()).await;
    for (sid, name, task) in live {
        let task = task.map(|t| {
            let title = titles.get(&t).cloned().unwrap_or_else(|| t.clone());
            (t, title)
        });
        let Some(changed) = crate::work::edits::edited(f, &sid).await? else {
            continue;
        };
        let records = crate::work::edits::record_hunks(f, &sid)
            .await
            .unwrap_or_default();
        let reasons = reasons(
            f,
            records.iter().filter_map(|h| h.decision.clone()).collect(),
        )
        .await;
        let mut files = Vec::new();
        for c in changed.files {
            // the records' own hunks (each with the operation that wrote it and its reason); the diff's when the
            // history holds none of the file
            let mut hunks = record_refs(&records, &reasons, &c.path, &name, &sid);
            if hunks.is_empty() {
                let diff = crate::work::edits::diff_of(f, &sid, &c.path)
                    .await
                    .unwrap_or_default();
                hunks = hunks_of(&diff, &name, &sid);
            }
            files.push(FileGroup {
                hunks,
                path: c.path,
                plus: c.plus,
                minus: c.minus,
            });
        }
        sessions.push(SessionEdits {
            agent: name,
            task,
            files,
        });
    }
    Ok(group(sessions))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hunk(i: u32, a: &str, reason: Option<&str>) -> HunkRef {
        HunkRef {
            op: Some(u64::from(i)),
            index: i,
            start_line: 10 * i + 1,
            end_line: 10 * i + 5,
            agent: Some(a.into()),
            session: Some(format!("s-{a}")),
            reason: reason.map(Into::into),
        }
    }

    fn file(path: &str, hunks: Vec<HunkRef>) -> FileGroup {
        FileGroup {
            path: path.into(),
            plus: 4 * hunks.len() as u32,
            minus: 1,
            hunks,
        }
    }

    fn edits(agent: &str, task: Option<(&str, &str)>, files: Vec<FileGroup>) -> SessionEdits {
        SessionEdits {
            agent: agent.into(),
            task: task.map(|(i, t)| (i.into(), t.into())),
            files,
        }
    }

    #[test]
    fn changes_group_by_task_then_file_then_hunk() {
        let got = group(vec![
            edits(
                "b",
                Some(("t2", "Second")),
                vec![file("z.rs", vec![hunk(0, "b", None)])],
            ),
            edits(
                "a",
                Some(("t1", "First")),
                vec![
                    file("m.rs", vec![hunk(0, "a", None), hunk(1, "a", None)]),
                    file("a.rs", vec![hunk(0, "a", None)]),
                ],
            ),
            edits(
                "c",
                Some(("t1", "First")),
                vec![file("a.rs", vec![hunk(1, "c", None)])],
            ),
        ]);
        let shape: Vec<_> = got
            .iter()
            .map(|g| {
                (
                    g.task.as_deref(),
                    g.files
                        .iter()
                        .map(|f| (f.path.as_str(), f.hunks.len()))
                        .collect(),
                )
            })
            .collect();
        assert_eq!(
            shape,
            vec![
                (Some("t1"), vec![("a.rs", 2), ("m.rs", 2)]),
                (Some("t2"), vec![("z.rs", 1)]),
            ]
        );
        assert_eq!(got[0].title, "First");
        assert_eq!(got[0].agent.as_deref(), Some("a"));
    }

    #[test]
    fn untasked_hunks_go_last() {
        let got = group(vec![
            edits("you", None, vec![file("x.rs", vec![hunk(0, "you", None)])]),
            edits(
                "a",
                Some(("t9", "Nine")),
                vec![file("y.rs", vec![hunk(0, "a", None)])],
            ),
        ]);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].task.as_deref(), Some("t9"));
        assert_eq!(got[1].task, None);
        assert_eq!(got[1].title, UNTASKED);
    }

    #[test]
    fn a_hunk_carries_its_reason() {
        let got = group(vec![edits(
            "a",
            Some(("t1", "First")),
            vec![file(
                "a.rs",
                vec![hunk(0, "a", Some("the lock was taken twice"))],
            )],
        )]);
        assert_eq!(
            got[0].files[0].hunks[0].reason.as_deref(),
            Some("the lock was taken twice")
        );
    }

    #[test]
    fn record_hunks_carry_their_op_and_reason_and_skip_undone_ones() {
        use crate::work::edits::RecordHunk;
        let rec = |op: i64, path: &str, live: bool, decision: Option<&str>| RecordHunk {
            op,
            path: path.into(),
            index: 0,
            start_line: 3,
            end_line: 5,
            live,
            decision: decision.map(Into::into),
        };
        let records = vec![
            rec(7, "a.rs", true, Some("decision:1")),
            rec(8, "a.rs", false, None),
            rec(9, "b.rs", true, None),
        ];
        let reasons = std::collections::BTreeMap::from([(
            "decision:1".to_owned(),
            "fixed the race".to_owned(),
        )]);
        let got = record_refs(&records, &reasons, "a.rs", "Opus", "s1");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].op, Some(7));
        assert_eq!(got[0].reason.as_deref(), Some("fixed the race"));
        assert_eq!(got[0].session.as_deref(), Some("s1"));
        // a write with no conclusion this turn says so (no reason borrowed)
        assert_eq!(
            record_refs(&records, &reasons, "b.rs", "Opus", "s1")[0].reason,
            None
        );
    }

    #[test]
    fn hunks_are_read_from_a_diff() {
        let diff = "--- a\n+++ b\n@@ -1,2 +1,3 @@\n a\n+b\n c\n@@ -10 +11,4 @@\n+x\n";
        let hs = hunks_of(diff, "agent", "s1");
        assert_eq!(
            hs.iter()
                .map(|h| (h.index, h.start_line, h.end_line))
                .collect::<Vec<_>>(),
            vec![(0, 1, 3), (1, 11, 14)]
        );
        assert_eq!(hs[0].agent.as_deref(), Some("agent"));
    }
}
