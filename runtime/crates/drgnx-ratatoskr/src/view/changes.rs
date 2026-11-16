//! The `changes` view's rows (frontend flow plan, Task 10): what the agents changed, task → file → hunk, from
//! [`crate::work::changes`]. Plain `RowBuilder` text until the kit draws them (Task 27); each hunk row carries the
//! actions the place offers as the text property `drgnx-action`: `open` (the file at the hunk), `comment` (a steer to
//! the hunk's agent, anchored to the hunk) and `revert` (`history/revert/hunk`).

use crate::work::changes::TaskGroup;
use drgnx_rows::{Row, RowBuilder};
use serde_json::json;

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
                    json!({"path": f.path, "op": h.op, "index": h.index, "agent": h.agent}),
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
                        reason: Some("fixed the race".into()),
                    },
                    HunkRef {
                        op: None,
                        index: 1,
                        start_line: 9,
                        end_line: 9,
                        agent: Some("a".into()),
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
