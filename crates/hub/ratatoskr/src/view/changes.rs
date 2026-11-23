//! The `changes` view's rows (frontend flow plan, Task 10): what the agents changed, task → file → hunk, from
//! [`crate::work::changes`]. Plain `RowBuilder` text until the kit draws them (Task 27); each hunk row carries the
//! actions the place offers as the text property `drgnx-action`: `open` (the file at the hunk), `comment` (a steer to
//! the hunk's agent, anchored to the hunk) and `revert` (`history/revert/hunk`).

use crate::dispatch::Caller;
use crate::front::Front;
use crate::view::{Key, Views};
use crate::work::changes::TaskGroup;
use rodd::kit::{self, Action, Comp, DiffLine, Hunk, KitEnv, RowKind, State, Status};
use rodd::{Row, RowBuilder};
use runstav::methods::changes::{Filter, Set, Subscribe, ViewId};
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
    filters: Mutex<HashMap<(u64, String), Filter>>,
}

impl Changes {
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.views).retain(|(c, _), _| *c != conn);
        lock(&self.filters).retain(|(c, _), _| *c != conn);
    }
}

/// GROUPS kept by FILTER: the task's groups, or the agent's; no filter (or an empty one) keeps them all.
pub fn filter_groups(groups: Vec<TaskGroup>, filter: Option<&Filter>) -> Vec<TaskGroup> {
    let Some(f) = filter else { return groups };
    groups
        .into_iter()
        .filter(|g| {
            f.task.as_ref().is_none_or(|t| g.task.as_ref() == Some(t))
                && f.agent.as_ref().is_none_or(|a| g.agent.as_ref() == Some(a))
        })
        .collect()
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
        self.publish_built(f, key, |env, _| {
            (rows(&groups, &super::kit_env(env)), Vec::new())
        });
        true
    }

    /// CONN's VIEW shows GROUPS now: every class gets the rows that changed.
    fn changes_show(&self, f: &Front, conn: u64, view: &str, groups: Vec<TaskGroup>) {
        let key = (conn, view.to_owned());
        let groups = filter_groups(groups, lock(&self.changes.filters).get(&key));
        lock(&self.changes.views).insert(key, groups);
        for class in self.classes(conn, view) {
            self.changes_build(f, &(conn, view.to_owned(), class));
        }
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
    if let Some(mut filter) = p.filter {
        // Work names an agent by its session id; the groups carry the agent's name
        if let Some(a) = filter.agent.as_mut()
            && let Some(name) = f.core.agents.live_sessions().iter().find_map(|s| {
                let snap = s.snapshot();
                (snap.id == *a).then(|| snap.name.clone().unwrap_or(snap.id))
            })
        {
            *a = name;
        }
        filter.task = filter.task.filter(|t| !t.is_empty());
        filter.agent = filter.agent.filter(|a| !a.is_empty());
        let key = (c.conn_id, p.view.clone());
        if filter == Filter::default() {
            lock(&f.core.views.changes.filters).remove(&key);
        } else {
            lock(&f.core.views.changes.filters).insert(key, filter);
        }
        let groups = crate::work::changes::by_task(f).await?;
        f.core.views.changes_show(f, c.conn_id, &p.view, groups);
    } else if p.refresh {
        let groups = crate::work::changes::by_task(f).await?;
        f.core.views.changes_show(f, c.conn_id, &p.view, groups);
    }
    Ok(true)
}

/// `changes/close`.
pub fn close(f: &Front, c: &Caller, p: ViewId) -> Result<bool, Error> {
    lock(&f.core.views.changes.filters).remove(&(c.conn_id, p.view.clone()));
    Ok(lock(&f.core.views.changes.views)
        .remove(&(c.conn_id, p.view))
        .is_some())
}

/// A slot 1–12 for AGENT's mark (its name's bytes, so the same agent has the same colour in every view).
fn slot_of(agent: &str) -> u8 {
    (agent.bytes().map(u32::from).sum::<u32>() % 12) as u8 + 1
}

/// The rows of GROUPS in ENV's class, drawn with the kit: a task is a section header (its title, the number of files)
/// then the agent's mark and name and the running status dot with its word (a group is a live session's edits); each file
/// a tree row with its path and `+N −M` that opens it; each hunk a diff block (head with Open, Comment and Revert, the
/// `@@` row, and the hunk's reason in the agent's words, or the plain fact that there is none).  The hunk's identity
/// (`drgnx-hunk`) rides on every row of its block.
pub fn rows(groups: &[TaskGroup], env: &KitEnv) -> Vec<Row> {
    let mut out = Vec::new();
    for (n, g) in groups.iter().enumerate() {
        let mut b = RowBuilder::new(format!("task:{n}"));
        kit::expand(
            &mut b,
            env,
            &Comp::SectionHeader {
                title: g.title.clone(),
                collapsible: false,
                collapsed: false,
                count: u32::try_from(g.files.len()).ok(),
                state: State::Rest,
                action: None,
            },
        );
        if let Some(a) = &g.agent {
            b.push(" ", None);
            kit::expand(
                &mut b,
                env,
                &Comp::AgentMark {
                    slot: slot_of(a),
                    handle: a
                        .chars()
                        .next()
                        .map(|c| c.to_uppercase().to_string())
                        .unwrap_or_default(),
                },
            );
            b.push(&format!(" {a} "), None);
        }
        kit::expand(
            &mut b,
            env,
            &Comp::StatusDot {
                status: Status::Running,
                word: true,
            },
        );
        let end = b.pos();
        if let Some(t) = &g.task {
            b.prop(0, end, "drgnx-work-id", json!(format!("task:{t}")));
        }
        out.push(b.finish());
        for (m, f) in g.files.iter().enumerate() {
            let mut b = RowBuilder::new(format!("file:{n}:{m}"));
            kit::expand(
                &mut b,
                env,
                &Comp::Row {
                    kind: RowKind::Tree,
                    depth: 1,
                    twisty: None,
                    text: format!("{}  +{} \u{2212}{}", f.path, f.plus, f.minus),
                    state: State::Rest,
                    icon: None,
                    action: Some(Action {
                        kind: "open".into(),
                        args: vec![json!(f.path), json!(1)],
                    }),
                },
            );
            out.push(b.finish());
            for h in &f.hunks {
                let action = |kind: &str, args: Vec<serde_json::Value>| Action {
                    kind: kind.into(),
                    args,
                };
                let reason = h
                    .reason
                    .clone()
                    .unwrap_or_else(|| "no reason recorded".to_owned());
                let who = h.agent.clone().unwrap_or_default();
                let block = Comp::DiffBlock {
                    file: f.path.clone(),
                    added: 0,
                    removed: 0,
                    hunks: vec![Hunk {
                        header: format!(
                            "@@ lines {}\u{2013}{} \u{b7} {who} @@",
                            h.start_line, h.end_line
                        ),
                        lines: vec![(DiffLine::Ctx, h.start_line, reason)],
                    }],
                    buttons: vec![
                        (
                            "Open".into(),
                            action("open", vec![json!(f.path), json!(h.start_line)]),
                        ),
                        (
                            "Comment".into(),
                            action(
                                "comment",
                                vec![json!(f.path), json!(h.start_line), json!(h.session)],
                            ),
                        ),
                        (
                            "Revert".into(),
                            action(
                                "revert",
                                vec![json!(f.path), json!(h.op), json!(h.index), json!(h.session)],
                            ),
                        ),
                    ],
                    icon: None,
                    width: None,
                };
                let hunk = json!({"path": f.path, "op": h.op, "index": h.index, "agent": h.agent, "session": h.session});
                for mut r in kit::expand_rows(env, &format!("hunk:{n}:{m}:{}", h.index), &block) {
                    let end = u32::try_from(r.text.chars().count()).unwrap_or(u32::MAX);
                    r.props.push((0, end, "drgnx-hunk".into(), hunk.clone()));
                    out.push(r);
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::work::changes::{FileGroup, HunkRef};

    fn kit() -> KitEnv<'static> {
        KitEnv {
            scale: 1.0,
            tty: false,
            glyphs: &[],
            ascii: false,
            density: Default::default(),
            icons: None,
        }
    }

    fn groups() -> Vec<TaskGroup> {
        vec![TaskGroup {
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
        }]
    }

    #[test]
    fn changes_by_task_groups_are_kit_rows_with_their_reasons() {
        let rows = rows(&groups(), &kit());
        let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
        // the task's section header, its file row, then each hunk as a kit diff block (head, `@@` row, reason line)
        assert_eq!(
            keys,
            [
                "task:0",
                "file:0:0",
                "hunk:0:0:0/0",
                "hunk:0:0:0/h0",
                "hunk:0:0:0/h0/0",
                "hunk:0:0:1/0",
                "hunk:0:0:1/h0",
                "hunk:0:0:1/h0/0"
            ]
        );
        // the task: its title, the agent and the status word the kit's dot carries (a live session is running)
        assert!(
            rows[0].text.contains("First") && rows[0].text.contains("running"),
            "{:?}",
            rows[0]
        );
        assert!(rows[0].text.contains('a'), "{:?}", rows[0]);
        assert!(rows[0].props.iter().any(|p| p.2 == "drgnx-work-id"));
        // the file: its path and its counts, a tree row that opens the file
        assert!(
            rows[1].text.contains("a.rs")
                && rows[1].text.contains("+4")
                && rows[1].text.contains("\u{2212}1")
        );
        assert!(rows[1].props.iter().any(|p| p.2 == "drgnx-action"));
        // the hunk's reason in the agent's words, or the plain fact that there is none
        assert!(rows[4].text.contains("fixed the race"), "{:?}", rows[4]);
        assert!(rows[7].text.contains("no reason recorded"), "{:?}", rows[7]);
        // Open, Comment and Revert are kit buttons on the block's head; the hunk's identity rides on every row
        let head = &rows[2];
        for label in ["Open", "Comment", "Revert"] {
            assert!(head.text.contains(label), "{:?}", head);
        }
        let kinds: Vec<String> = head
            .props
            .iter()
            .filter(|p| p.2 == "drgnx-action")
            .map(|p| p.3[0].as_str().unwrap_or_default().to_owned())
            .collect();
        assert_eq!(kinds, ["open", "comment", "revert"]);
        assert!(rows[4].props.iter().any(|p| p.2 == "drgnx-hunk"));
    }

    fn two_tasks() -> Vec<TaskGroup> {
        let mut b = groups();
        b[0].task = Some("t2".into());
        b[0].title = "Second".into();
        b[0].agent = Some("b".into());
        let mut all = groups();
        all.extend(b);
        all
    }

    /// Flow Task 27: `e` on a task or agent in Work opens the Changes place filtered to it: `changes/set` takes a
    /// filter, and the view's groups are only that task's (or that agent's).
    #[test]
    fn a_task_filter_keeps_only_that_tasks_group() {
        let f = runstav::methods::changes::Filter {
            task: Some("t2".into()),
            agent: None,
        };
        let kept = filter_groups(two_tasks(), Some(&f));
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].task.as_deref(), Some("t2"));
    }

    #[test]
    fn an_agent_filter_keeps_that_agents_groups() {
        let f = runstav::methods::changes::Filter {
            task: None,
            agent: Some("a".into()),
        };
        let kept = filter_groups(two_tasks(), Some(&f));
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].agent.as_deref(), Some("a"));
    }

    #[test]
    fn no_filter_keeps_every_group_and_a_filter_that_matches_nothing_keeps_none() {
        assert_eq!(filter_groups(two_tasks(), None).len(), 2);
        let f = runstav::methods::changes::Filter {
            task: Some("nope".into()),
            agent: None,
        };
        assert!(filter_groups(two_tasks(), Some(&f)).is_empty());
    }
}
