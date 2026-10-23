//! Notices to the agents a change affects (Task 13; call 11): `message` rows of kind `task-changed`, coalesced per
//! task per recipient while unread, written in the change's tx (`write::notices`). Who is told:
//! - a change to a task tells its assignee and its lease holder, before and after the change (a claim tells the
//!   previous assignee, a reassign the old holder and `to`, a handoff `to`);
//! - `complete` tells the task's maker too;
//! - a blocker that closes, or a `blocks` link removed, tells the dependent's assignee "now ready";
//! - "only I close my tasks" tells the user of a close proposal.
//!
//! Never the caller about its own change, and never the user otherwise (the user follows the cockpit's feed). The
//! hub's `notify()` after `COMMIT` is the caller's (the tools'), so the delivery wakes.

use urdr::Connection;
use urdr::graph::entity::{self, Ent};
use urdr::graph::schema::SENTINEL;
use urdr::graph::{Tx, WriteError};

use super::is_ready;
use crate::scope::Caller;
use crate::write::notices::{Notice, notice, unread};

/// AGENT's unread notices (for `notices: n` on every tool answer). AGENT is the actor tasks name it by
/// (`agent:SID`, `ext:KIND:PID-HASH`): an assignee or holder.
pub fn notices_unread(conn: &Connection, agent: &str) -> Result<u32, urdr::SqliteError> {
    unread(conn, agent)
}

/// Tell RECIPIENT about E (as it is now) changed by CALLER: FIELDS, the note's id, what it means (SAYS). Nothing when
/// RECIPIENT is the caller; the user only when SAYS is a close proposal.
pub(crate) fn tell(
    tx: &mut Tx<'_>,
    caller: &Caller,
    e: &Ent,
    recipient: &str,
    fields: &[&str],
    note: Option<&str>,
    says: Option<&str>,
) -> Result<(), WriteError> {
    if recipient.is_empty()
        || recipient == caller.actor
        || (recipient == "user" && says != Some("close proposed"))
    {
        return Ok(());
    }
    let now = entity::by_n(tx.sql(), e.n)?.unwrap_or_else(|| e.clone());
    let at = tx.at();
    notice(
        tx,
        Notice {
            recipient: recipient.to_owned(),
            entity: e.n,
            task: now.id.clone(),
            title: now.title.clone(),
            fields: fields.iter().map(|f| (*f).to_owned()).collect(),
            by: caller.actor.clone(),
            note: note.map(str::to_owned),
            says: says.map(str::to_owned),
        },
        at,
    )?;
    Ok(())
}

/// Tell the agents BEFORE's change affects: its assignee and lease holder before the change and after it.
pub(crate) fn changed(
    tx: &mut Tx<'_>,
    caller: &Caller,
    before: &Ent,
    fields: &[&str],
    note: Option<&str>,
    says: Option<&str>,
) -> Result<(), WriteError> {
    let after = entity::by_n(tx.sql(), before.n)?.unwrap_or_else(|| before.clone());
    let mut who: Vec<String> = Vec::new();
    for w in [
        &before.assignee,
        &before.lease.holder,
        &after.assignee,
        &after.lease.holder,
    ]
    .into_iter()
    .flatten()
    {
        if !who.contains(w) {
            who.push(w.clone());
        }
    }
    for w in who {
        tell(tx, caller, before, &w, fields, note, says)?;
    }
    Ok(())
}

/// BLOCKER closed: each task it blocked that is ready now tells its assignee "now ready".
pub(crate) fn now_ready(tx: &mut Tx<'_>, caller: &Caller, blocker: i64) -> Result<(), WriteError> {
    let deps: Vec<i64> = {
        let mut stmt = tx.sql().prepare(
            "select dst from link where src = ?1 and kind = 'blocks' and tx_to = ?2 order by dst",
        )?;
        stmt.query_map((blocker, SENTINEL), |r| r.get(0))?
            .collect::<Result<_, _>>()?
    };
    for d in deps {
        if !is_ready(tx.sql(), d, tx.at())? {
            continue;
        }
        if let Some(e) = entity::by_n(tx.sql(), d)?
            && let Some(a) = e.assignee.clone()
        {
            tell(tx, caller, &e, &a, &["ready"], None, Some("now ready"))?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::tests::{Fx, ok};
    use super::super::{TaskAnswer, TaskOp};
    use serde_json::Value;

    /// The unread notices of AGENT, oldest first, as JSON.
    fn notices_of(fx: &Fx, agent: &str) -> Vec<Value> {
        let mut stmt =
            fx.c.prepare(
                "select text from message where recipient = ?1 and entity is not null \
                 and state in ('queued', 'delivered') order by id",
            )
            .unwrap();
        stmt.query_map([agent], |r| r.get::<_, String>(0))
            .unwrap()
            .map(|t| serde_json::from_str(&t.unwrap()).unwrap())
            .collect()
    }

    #[test]
    fn the_assignee_is_told() {
        let mut fx = Fx::new();
        let (a, b) = (fx.agent("a"), fx.agent("b"));
        let t = fx.task(&a, "fix the parser");
        let lease = fx.claim(&a, &t);
        assert_eq!(lease, 1);
        let ver = fx.ver(&t);
        ok(fx.run(
            &b,
            TaskOp::Update {
                id: t.clone(),
                ver,
                title: Some("fix the lexer".into()),
                body: None,
                priority: None,
                acceptance: None,
                status: None,
            },
        ));
        let got = notices_of(&fx, "agent:a");
        assert_eq!(got.len(), 1);
        let n = &got[0];
        assert_eq!(n["kind"], "task-changed");
        assert_eq!(n["task"], t.as_str());
        assert_eq!(n["title"], "fix the lexer");
        assert_eq!(n["fields"], serde_json::json!(["title"]));
        assert_eq!(n["by"], "agent:b");
        assert_eq!(
            super::notices_unread(&fx.c, "agent:a").unwrap(),
            1,
            "counted for the tools"
        );
        // The row is a message from the tracker about the task, in the change's tx.
        let (sender, entity, tx): (String, i64, i64) =
            fx.c.query_row(
                "select sender, entity, tx from message where recipient = 'agent:a'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(sender, "tracker");
        assert_eq!(entity, fx.n(&t));
        assert_eq!(Value::from(tx), n["tx"]);
    }

    #[test]
    fn coalesced_while_unread() {
        let mut fx = Fx::new();
        let (a, b) = (fx.agent("a"), fx.agent("b"));
        let t = fx.task(&a, "one");
        fx.claim(&a, &t);
        for (i, label) in ["x", "y"].iter().enumerate() {
            ok(fx.run(
                &b,
                TaskOp::Label {
                    id: t.clone(),
                    add: vec![(*label).into()],
                    remove: vec![],
                },
            ));
            assert_eq!(notices_of(&fx, "agent:a").len(), 1, "change {i}");
        }
        let ver = fx.ver(&t);
        ok(fx.run(
            &b,
            TaskOp::Update {
                id: t.clone(),
                ver,
                title: None,
                body: None,
                priority: Some(2),
                acceptance: None,
                status: None,
            },
        ));
        let got = notices_of(&fx, "agent:a");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0]["changes"], 3);
        assert_eq!(got[0]["fields"], serde_json::json!(["labels", "priority"]));
        // Once read, the next change is a new notice.
        fx.c.execute(
            "update message set state = 'read' where recipient = 'agent:a'",
            [],
        )
        .unwrap();
        assert_eq!(super::notices_unread(&fx.c, "agent:a").unwrap(), 0);
        ok(fx.run(
            &b,
            TaskOp::Label {
                id: t.clone(),
                add: vec!["z".into()],
                remove: vec![],
            },
        ));
        let got = notices_of(&fx, "agent:a");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0]["changes"], 1);
        assert_eq!(super::notices_unread(&fx.c, "agent:a").unwrap(), 1);
        let rows: i64 =
            fx.c.query_row(
                "select count(*) from message where recipient = 'agent:a'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(rows, 2, "the read one is kept as it was");
    }

    #[test]
    fn unblock_says_now_ready() {
        let mut fx = Fx::new();
        let (a, b) = (fx.agent("a"), fx.agent("b"));
        let first = fx.task(&a, "first");
        let second = fx.task(&a, "second");
        let third = fx.task(&a, "third");
        fx.link(&a, &first, "blocks", &second);
        fx.link(&a, &third, "blocks", &second);
        // c is to do the second task once it is ready.
        let ver = fx.ver(&second);
        ok(fx.run(
            &a,
            TaskOp::Reassign {
                id: second.clone(),
                ver,
                to: Some("agent:c".into()),
                note: "c takes this one".into(),
            },
        ));
        fx.c.execute("update message set state = 'read'", [])
            .unwrap();
        // The first blocker done: the second still waits on the third, so nobody hears "now ready".
        fx.claim(&b, &first);
        let ver = fx.ver(&first);
        ok(fx.run(
            &b,
            TaskOp::Update {
                id: first.clone(),
                ver,
                title: None,
                body: None,
                priority: None,
                acceptance: None,
                status: Some("done".into()),
            },
        ));
        assert!(notices_of(&fx, "agent:c").is_empty());
        // The third unlinked: ready now.
        ok(fx.run(
            &b,
            TaskOp::Unlink {
                src: third.clone(),
                kind: "blocks".into(),
                dst: second.clone(),
            },
        ));
        let got = notices_of(&fx, "agent:c");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0]["says"], serde_json::json!(["now ready"]));
        assert_eq!(got[0]["task"], second.as_str());
        // A blocker set done says it too.
        let fourth = fx.task(&a, "fourth");
        fx.link(&a, &fourth, "blocks", &second);
        fx.c.execute("update message set state = 'read'", [])
            .unwrap();
        let ver = fx.ver(&fourth);
        ok(fx.run(
            &b,
            TaskOp::Update {
                id: fourth.clone(),
                ver,
                title: None,
                body: None,
                priority: None,
                acceptance: None,
                status: Some("done".into()),
            },
        ));
        let got = notices_of(&fx, "agent:c");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0]["says"], serde_json::json!(["now ready"]));
    }

    #[test]
    fn the_caller_is_never_told_about_itself() {
        let mut fx = Fx::new();
        let a = fx.agent("a");
        let t = fx.task(&a, "mine");
        let lease = fx.claim(&a, &t);
        ok(fx.run(
            &a,
            TaskOp::Label {
                id: t.clone(),
                add: vec!["x".into()],
                remove: vec![],
            },
        ));
        let ver = fx.ver(&t);
        ok(fx.run(
            &a,
            TaskOp::Update {
                id: t.clone(),
                ver,
                title: Some("still mine".into()),
                body: None,
                priority: None,
                acceptance: None,
                status: None,
            },
        ));
        let done = fx.run(
            &a,
            TaskOp::Complete {
                id: t.clone(),
                lease,
                note: Some("finished".into()),
            },
        );
        assert!(matches!(done, Ok(TaskAnswer::Done { .. })), "{done:?}");
        assert!(notices_of(&fx, "agent:a").is_empty());
        assert_eq!(super::notices_unread(&fx.c, "agent:a").unwrap(), 0);
    }
}
