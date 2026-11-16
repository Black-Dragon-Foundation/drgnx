//! The `changes` view's rows (frontend flow plan, Task 10): what the agents changed, task → file → hunk, from
//! [`crate::work::changes`]. Plain `RowBuilder` text until the kit draws them (Task 27); each hunk row carries the
//! actions the place offers as the text property `drgnx-action`: `open` (the file at the hunk), `comment` (a steer to
//! the hunk's agent, anchored to the hunk) and `revert` (`history/revert/hunk`).

use crate::dispatch::Caller;
use crate::front::Front;
use crate::view::{Key, Views};
use crate::work::changes::TaskGroup;
use drgnx_rows::{Row, RowBuilder};
use runstav::methods::changes::{Set, Subscribe, ViewId};
use runstav::wire::{Error, ErrorCode};
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard};

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The Changes views of every connection: the groups each last read.
#[derive(Default)]
pub struct Changes {
    views: Mutex<HashMap<(u64, String), Vec<TaskGroup>>>,
}

impl Changes {
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.views).retain(|(c, _), _| *c != conn);
    }
}

impl Views {
    /// The rows of KEY's Changes view for its class; false when the view is none.
    pub(super) fn changes_build(&self, f: &Front, key: &Key) -> bool {
        let Some(groups) = lock(&self.changes.views)
            .get(&(key.0, key.1.clone()))
            .cloned()
        else {
            return false;
        };
        self.publish_built(f, key, |_, _| (rows(&groups), Vec::new()));
        true
    }

    /// CONN's VIEW shows GROUPS now: every class gets the rows that changed.
    fn changes_show(&self, f: &Front, conn: u64, view: &str, groups: Vec<TaskGroup>) {
        lock(&self.changes.views).insert((conn, view.to_owned()), groups.clone());
        self.publish_rows(f, conn, view, rows(&groups));
    }
}

/// `changes/subscribe`: the view shows what the agents changed, by task.
pub async fn subscribe(f: &Front, c: &Caller, p: Subscribe) -> Result<bool, Error> {
    let groups = crate::work::changes::by_task(f).await?;
    f.core.views.changes_show(f, c.conn_id, &p.view, groups);
    Ok(true)
}

/// `changes/set`: refresh reads the sessions' edits again.
pub async fn set(f: &Front, c: &Caller, p: Set) -> Result<bool, Error> {
    let known = lock(&f.core.views.changes.views).contains_key(&(c.conn_id, p.view.clone()));
    if !known {
        return Err(Error {
            code: ErrorCode::InvalidParams,
            message: "not a Changes view (changes/subscribe first)".into(),
            path: Some("view".into()),
        });
    }
    if p.refresh {
        let groups = crate::work::changes::by_task(f).await?;
        f.core.views.changes_show(f, c.conn_id, &p.view, groups);
    }
    Ok(true)
}

/// `changes/close`.
pub fn close(f: &Front, c: &Caller, p: ViewId) -> Result<bool, Error> {
    Ok(lock(&f.core.views.changes.views)
        .remove(&(c.conn_id, p.view))
        .is_some())
}

/// The rows of GROUPS: a task row, its file rows, each file's hunk rows, in that order.
pub fn rows(groups: &[TaskGroup]) -> Vec<Row> {
    let mut out = Vec::new();
    for (n, g) in groups.iter().enumerate() {
        let mut b = RowBuilder::new(format!("task:{n}"));
        b.push(&g.title, None);
        if let Some(a) = &g.agent {
            b.push(&format!(" · {a}"), None);
        }
        let end = b.pos();
        if let Some(t) = &g.task {
            b.prop(0, end, "drgnx-work-id", json!(format!("task:{t}")));
        }
        out.push(b.finish());
        for (m, f) in g.files.iter().enumerate() {
            let mut b = RowBuilder::new(format!("file:{n}:{m}"));
            b.push(&format!("  {}  +{} −{}", f.path, f.plus, f.minus), None);
            let end = b.pos();
            b.prop(0, end, "drgnx-action", json!(["open", f.path, 1]));
            out.push(b.finish());
            for h in &f.hunks {
                let mut b = RowBuilder::new(format!("hunk:{n}:{m}:{}", h.index));
                b.push(&format!("    lines {}–{}", h.start_line, h.end_line), None);
                if let Some(a) = &h.agent {
                    b.push(&format!(" · {a}"), None);
                }
                b.push(
                    &match &h.reason {
                        Some(r) => format!(" · {r}"),
                        None => " · no reason recorded".to_owned(),
                    },
                    None,
                );
                b.push("  open  comment  revert", None);
                let end = b.pos();
                b.prop(
                    0,
                    end,
                    "drgnx-action",
                    json!(["open", f.path, h.start_line]),
                );
                b.prop(
                    0,
                    end,
                    "drgnx-hunk",
                    json!({"path": f.path, "op": h.op, "index": h.index, "agent": h.agent, "session": h.session}),
                );
                out.push(b.finish());
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::work::changes::{FileGroup, HunkRef};

    #[test]
    fn rows_run_task_file_hunk_and_a_hunk_says_when_it_has_no_reason() {
        let groups = vec![TaskGroup {
            task: Some("t1".into()),
            title: "First".into(),
            agent: Some("a".into()),
            files: vec![FileGroup {
                path: "a.rs".into(),
                plus: 4,
                minus: 1,
                hunks: vec![
                    HunkRef {
                        op: Some(3),
                        index: 0,
                        start_line: 2,
                        end_line: 6,
                        agent: Some("a".into()),
                        session: Some("s1".into()),
                        reason: Some("fixed the race".into()),
                    },
                    HunkRef {
                        op: None,
                        index: 1,
                        start_line: 9,
                        end_line: 9,
                        agent: Some("a".into()),
                        session: Some("s1".into()),
                        reason: None,
                    },
                ],
            }],
        }];
        let rows = rows(&groups);
        let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
        assert_eq!(keys, ["task:0", "file:0:0", "hunk:0:0:0", "hunk:0:0:1"]);
        assert!(rows[2].text.contains("fixed the race"), "{:?}", rows[2]);
        assert!(rows[3].text.contains("no reason recorded"), "{:?}", rows[3]);
        assert!(rows[2].props.iter().any(|p| p.2 == "drgnx-action"));
    }
}
