//! The summary handoff (Task 26): what a session that moves to another model, or that could be neither resumed nor
//! loaded after a hub restart, is told about the one it replaces.  Built from the parts the graph already has: the
//! task's brief (Task 22), the decisions the old session recorded (Task 21), the task's newest report (Task 21), the
//! worktree's HEAD and the old session's steps (Task 19).  No conversation is copied: the old transcript stays on disk.

use crate::front::Front;
use std::path::Path;

/// The summary's size cap (the brief is cut first).
const CAP: usize = 16 * 1024;
const BRIEF_CAP: usize = 6 * 1024;

/// What the summary is made of; a part the graph cannot say is `None` or empty and left out.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Facts {
    pub brief: Option<String>,
    /// One line per decision the old session recorded.
    pub decisions: Vec<String>,
    /// The task's newest report, as lines.
    pub report: Option<String>,
    /// The worktree's HEAD: short sha and subject.
    pub head: Option<String>,
    /// How many steps the old session took, and the last tools it used.
    pub steps: Option<String>,
    /// The old session's last step snapshot (a ref in the shadow repository).
    pub snapshot: Option<String>,
}

fn cut(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut n = max;
    while !s.is_char_boundary(n) {
        n -= 1;
    }
    &s[..n]
}

/// The summary text for FACTS.
pub fn compose(f: &Facts) -> String {
    let mut out = String::from(
        "[Handoff: you continue the work of another agent, in the same directory. Its conversation is not available; \
         this summary is what it left. Check the repository before you go on.]\n",
    );
    if let Some(h) = &f.head {
        out.push_str(&format!("\n## Head\n{h}\n"));
    }
    if let Some(b) = &f.brief {
        let b = cut(b, BRIEF_CAP);
        out.push_str(&format!("\n## Brief\n{b}\n"));
    }
    if !f.decisions.is_empty() {
        out.push_str("\n## Decisions it recorded\n");
        for d in &f.decisions {
            out.push_str(&format!("- {d}\n"));
        }
    }
    if let Some(r) = &f.report {
        out.push_str(&format!("\n## Its report\n{r}\n"));
    }
    if let Some(s) = &f.steps {
        out.push_str(&format!("\n## Its steps\n{s}\n"));
    }
    if let Some(s) = &f.snapshot {
        out.push_str(&format!("Last snapshot of the tree: {s}\n"));
    }
    if out.len() > CAP {
        out.truncate(cut(&out, CAP).len());
    }
    out
}

/// HEAD of the repository at CWD, `<short sha> <subject>`.
fn head_of(cwd: &Path) -> Option<String> {
    let o = std::process::Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(["log", "-1", "--format=%h %s"])
        .output()
        .ok()?;
    let t = String::from_utf8_lossy(&o.stdout).trim().to_owned();
    (o.status.success() && !t.is_empty()).then_some(t)
}

fn report_text(r: &runstav::methods::plans::Report) -> String {
    let mut s = format!("tip {}", r.tip);
    if !r.commits.is_empty() {
        s.push_str(&format!("; commits {}", r.commits.join(", ")));
    }
    for c in &r.checks {
        s.push_str(&format!(
            "; check {}: {} passed, {} failed",
            c.name.as_str(),
            c.passed,
            c.failed
        ));
    }
    if let Some(d) = &r.differences {
        s.push_str(&format!("\ndifferences: {d}"));
    }
    if let Some(i) = &r.interfaces {
        s.push_str(&format!("\ninterfaces: {i}"));
    }
    s
}

/// STEPS as of step UP_TO when given: those at or before it in its own conversation (the cut's filter,
/// `rewind::same_line`: no step a revert abandoned, unless UP_TO is one of them); every step without a cut.
fn kept(steps: &[norn::read::steps::Step], up_to: Option<i64>) -> Vec<&norn::read::steps::Step> {
    let Some(u) = up_to else {
        return steps.iter().collect();
    };
    let line = steps.iter().find(|s| s.seq == u).and_then(|s| s.undone_by);
    steps
        .iter()
        .filter(|s| s.seq <= u && super::rewind::same_line(line, u, s.seq, s.undone_by))
        .collect()
}

/// What SESSION's STEPS say, cut at step UP_TO when given ([`kept`]): how many there are and their last tools, the
/// last snapshot, and the worktree's head recorded at the cut (`step.head`; none without a cut: the tree's own is
/// read).
pub(crate) fn step_facts(
    steps: &[norn::read::steps::Step],
    up_to: Option<i64>,
) -> (Option<String>, Option<String>, Option<String>) {
    let steps = kept(steps, up_to);
    let tools: Vec<String> = steps
        .iter()
        .rev()
        .filter_map(|x| x.tool.clone())
        .take(8)
        .collect();
    let snapshot = steps.iter().rev().find_map(|x| x.snapshot.clone());
    let summary = (!steps.is_empty()).then(|| {
        format!(
            "{} steps; last tools (newest first): {}",
            steps.len(),
            if tools.is_empty() {
                "none".to_owned()
            } else {
                tools.join(", ")
            }
        )
    });
    let head = up_to.and_then(|_| steps.iter().rev().find_map(|x| x.head.clone()));
    (summary, snapshot, head)
}

/// The facts of session SID working in CWD on TASK (an entity id, `JOB#N` or none), read from the graph and the tree;
/// with UP_TO, its steps cut at that `seq` and the head the step recorded there.
pub async fn gather(
    front: &Front,
    sid: &str,
    cwd: &Path,
    task: Option<&str>,
    up_to: Option<i64>,
) -> Facts {
    let brief = match task {
        Some(t) => crate::brief::for_dispatch(front, t, Some(sid)).await,
        None => None,
    };
    let (s, t) = (sid.to_owned(), task.map(str::to_owned));
    let read = front
        .writer
        .db
        .read(move |c| {
            // a step names its session by entity id
            let steps = norn::read::steps::for_session(c, &format!("session:{s}"), 0)?;
            let ids: std::collections::HashSet<i64> = steps.iter().map(|x| x.id).collect();
            let kept_ids: std::collections::HashSet<i64> =
                kept(&steps, up_to).iter().map(|x| x.id).collect();
            let log_version = up_to
                .and_then(|u| steps.iter().find(|x| x.seq == u))
                .and_then(|x| x.log_version);
            // with a cut: a decision stamped in a step the cut keeps; one with no stamp (or a stamp whose step is
            // gone) unless its version is after the cut's, as a revert's withdrawal reads it
            let in_cut = |stamp: Option<i64>, ver: Option<i64>| match (up_to, stamp.filter(|i| ids.contains(i))) {
                (None, _) => true,
                (Some(_), Some(id)) => kept_ids.contains(&id),
                (Some(_), None) => !matches!((ver, log_version), (Some(v), Some(l)) if v > l),
            };
            let mut decisions = Vec::new();
            let mut st = c.prepare(
                "select id, title, status, body, json_extract(data, '$.step'), json_extract(data, '$.ver') \
                 from entity where kind = 'decision' and retired_tx is null \
                 and json_extract(data, '$.session') = ?1 order by n",
            )?;
            let rows = st.query_map([&s], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, Option<i64>>(4)?,
                    r.get::<_, Option<i64>>(5)?,
                ))
            })?;
            for row in rows {
                let (id, title, status, body, stamp, ver) = row?;
                if !in_cut(stamp, ver) {
                    continue;
                }
                let mut line = format!("{id}: {}", title.unwrap_or_default());
                if let Some(b) = body.filter(|b| !b.is_empty()) {
                    line.push_str(&format!(" ({})", cut(&b, 400)));
                }
                if let Some(st) = status {
                    line.push_str(&format!(" [{st}]"));
                }
                decisions.push(line);
            }
            let report = match &t {
                Some(t) => {
                    let id = if t.contains(':') {
                        t.clone()
                    } else {
                        norn::write::tasks::entity_id(t)
                    };
                    match urdr::graph::entity::by_id(c, &id)? {
                        Some(te) => crate::runner::effects::reports_of(c, te.n)?
                            .first()
                            .map(|e| crate::runner::effects::report_of(c, e))
                            .transpose()?
                            .map(|r| report_text(&r)),
                        None => None,
                    }
                }
                None => None,
            };
            Ok((decisions, report, step_facts(&steps, up_to)))
        })
        .await;
    let (decisions, report, (steps, snapshot, at_cut)) = match read {
        Ok(x) => x,
        Err(e) => {
            tracing::warn!(sid, "handoff: the graph could not be read: {e}");
            (Vec::new(), None, (None, None, None))
        }
    };
    let head = match (up_to, at_cut) {
        (Some(_), head) => head,
        (None, _) => {
            let cwd = cwd.to_owned();
            crate::clock::blocking(move || head_of(&cwd))
                .await
                .ok()
                .flatten()
        }
    };
    Facts {
        brief,
        decisions,
        report,
        head,
        steps,
        snapshot,
    }
}

/// The summary a session that replaces SID is prompted with; with UP_TO, of SID as it was at that step.
pub async fn summary(
    front: &Front,
    sid: &str,
    cwd: &Path,
    task: Option<&str>,
    up_to: Option<i64>,
) -> String {
    compose(&gather(front, sid, cwd, task, up_to).await)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_has_brief_decisions_report_and_head() {
        let s = compose(&Facts {
            brief: Some("Build the parser.".into()),
            decisions: vec!["decision:7: use a PEG [current]".into()],
            report: Some("tip abc123; commits abc123".into()),
            head: Some("abc1234 parser: first cut".into()),
            steps: Some("3 steps; last tools (newest first): edit".into()),
            snapshot: Some("refs/drgnx/s/a1/3".into()),
        });
        for want in [
            "## Brief\nBuild the parser.",
            "decision:7: use a PEG",
            "## Its report\ntip abc123",
            "## Head\nabc1234 parser: first cut",
            "3 steps",
            "refs/drgnx/s/a1/3",
        ] {
            assert!(s.contains(want), "{want:?} missing in {s}");
        }
    }

    fn step(seq: i64, tool: &str, snapshot: &str, head: Option<&str>) -> norn::read::steps::Step {
        norn::read::steps::Step {
            id: seq,
            session: "a1".into(),
            task: None,
            plan: None,
            project: None,
            agent: None,
            provider: None,
            seq,
            class: norn::write::steps::StepClass::Tool,
            start: seq as f64,
            end: Some(seq as f64),
            tool: Some(tool.into()),
            tool_kind: None,
            message_id: None,
            turn_id: None,
            snapshot: Some(snapshot.into()),
            log_version: None,
            tokens_in: 0,
            tokens_out: 0,
            cache_read: 0,
            cache_write: 0,
            cost: None,
            cost_unit: None,
            acp: None,
            head: head.map(Into::into),
            history_op: None,
            undone_by: None,
        }
    }

    // test-pattern: D
    #[test]
    fn up_to_cuts_steps_and_head() {
        let steps = [
            step(1, "read", "refs/drgnx/s/a1/1", Some("aaaa111")),
            step(2, "edit", "refs/drgnx/s/a1/2", None),
            step(3, "bash", "refs/drgnx/s/a1/3", Some("cccc333")),
        ];
        let (summary, snapshot, head) = step_facts(&steps, Some(2));
        assert_eq!(
            summary.as_deref(),
            Some("2 steps; last tools (newest first): edit, read")
        );
        assert_eq!(snapshot.as_deref(), Some("refs/drgnx/s/a1/2"));
        assert_eq!(head.as_deref(), Some("aaaa111"), "the head at the cut");
        // no cut: every step, and the head is the tree's own (read by the caller)
        let (summary, snapshot, head) = step_facts(&steps, None);
        assert!(summary.unwrap().starts_with("3 steps"));
        assert_eq!(snapshot.as_deref(), Some("refs/drgnx/s/a1/3"));
        assert_eq!(head, None);
    }

    /// A summary at a step of the conversation a revert began names nothing of the steps that revert abandoned, nor of
    /// what came after the step: not their tools, snapshot, head or decisions.
    // test-pattern: D
    #[tokio::test(flavor = "multi_thread")]
    async fn summary_up_to_names_nothing_of_an_abandoned_line() {
        let d = tempfile::tempdir().unwrap();
        let f = crate::runner::graph_plan_tests::front(d.path());
        f.writer
            .db
            .write(
                urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "test"),
                |tx| {
                    // steps 2 and 3 were abandoned by the revert (record 9) to step 1; step 4 is the new conversation's
                    tx.sql().execute(
                        "insert into step (session, seq, class, start, tool, snapshot, head, undone_by) values \
                         ('session:s1', 1, 'tool', 1.0, 'Read kept.txt', 'refs/kept/1', 'aaaa111', null), \
                         ('session:s1', 2, 'tool', 2.0, 'Write gone.txt', 'refs/gone/2', 'bbbb222', 9), \
                         ('session:s1', 3, 'tool', 3.0, 'Bash gone', 'refs/gone/3', 'cccc333', 9), \
                         ('session:s1', 4, 'tool', 4.0, 'Edit new.txt', 'refs/kept/4', null, null), \
                         ('session:s1', 5, 'tool', 5.0, 'Read after.txt', 'refs/after/5', 'eeee555', null)",
                        [],
                    )?;
                    let project = tx.meta().project;
                    for (n, seq, title, status) in [
                        (1, 1, "kept choice", None),
                        (2, 2, "gone choice", Some("withdrawn")),
                        (3, 5, "after choice", None),
                    ] {
                        let step: i64 = tx.sql().query_row(
                            "select id from step where session = 'session:s1' and seq = ?1",
                            [seq],
                            |r| r.get(0),
                        )?;
                        urdr::graph::entity::create(
                            tx,
                            urdr::graph::entity::EntityNew {
                                id: format!("decision:{n}"),
                                kind: "decision".into(),
                                project,
                                title: Some(title.into()),
                                status: status.map(Into::into),
                                body: None,
                                priority: None,
                                assignee: None,
                                data: serde_json::json!({"session": "s1", "step": step}),
                                origin: urdr::graph::entity::Origin::Recorded,
                                source: None,
                            },
                        )?;
                    }
                    Ok(())
                },
            )
            .await
            .unwrap();
        let s = summary(&f, "s1", d.path(), None, Some(4)).await;
        for want in [
            "2 steps; last tools (newest first): Edit new.txt, Read kept.txt",
            "refs/kept/4",
            "## Head\naaaa111",
            "kept choice",
        ] {
            assert!(s.contains(want), "{want:?} missing in {s}");
        }
        for gone in ["gone", "bbbb222", "cccc333", "after", "eeee555"] {
            assert!(!s.contains(gone), "{gone:?} named in {s}");
        }
    }

    #[test]
    fn an_empty_part_is_left_out_and_a_long_brief_is_cut() {
        let s = compose(&Facts {
            brief: Some("é".repeat(BRIEF_CAP)),
            ..Facts::default()
        });
        assert!(
            !s.contains("## Decisions") && !s.contains("## Its report") && !s.contains("## Head")
        );
        assert!(s.len() <= CAP);
    }
}
