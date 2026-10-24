//! The decision log's writers (Task 6): `drgnx-coord--held` and `drgnx-coord-decide` (`core/drgnx-coord.el`).

use super::event::{Event, EventKind, event};
use super::meta;
use super::tasks::ACTIVE;
use crate::read::decisions::{Decision, decisions_since};
use crate::read::tasks::{opt, task_row};
use crate::store::{CoordError, Tx, WTx};
use serde_json::json;
use urdr::graph::entity::{self, Changes, EntityNew, Origin};
use urdr::graph::link;

/// Decisions one agent may record per minute; more are refused (`drgnx-coord-decision-rate`).
pub const DECISION_RATE: i64 = 6;

/// The write was held: the log moved on since the writer read it (`(:held t :version V :changes DECISIONS)`).
#[derive(Debug, Clone, PartialEq)]
pub struct Held {
    pub version: u64,
    /// The decisions after the writer's version, newest first.
    pub changes: Vec<Decision>,
}

/// `None` when SEEN is the current version (or absent); else the held answer.  A SEEN the log has not reached is
/// refused (`drgnx-coord--held`).
pub fn held_check(tx: &Tx, seen: Option<u64>) -> Result<Option<Held>, CoordError> {
    let v = meta::version(tx)?;
    let Some(seen) = seen else { return Ok(None) };
    if seen > v {
        return Err(CoordError::Refused(format!(
            "seen_version {seen} is from the future: the decision log is at {v} (call read_decisions)"
        )));
    }
    if v > seen {
        return Ok(Some(Held {
            version: v,
            changes: decisions_since(tx, seen, None)?,
        }));
    }
    Ok(None)
}

/// What `drgnx-coord-decide` takes.
#[derive(Debug, Clone, Default)]
pub struct Decide {
    pub kind: String,
    pub subject: String,
    pub task: Option<String>,
    pub paths: Option<String>,
    pub reason: Option<String>,
    pub author: String,
    pub seen: Option<u64>,
    /// A decision's number: marked replaced when this one is current.
    pub replaces: Option<i64>,
    pub job: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum DecideResult {
    Ok {
        n: i64,
        status: String,
        version: u64,
    },
    Held(Held),
    Error(String),
}

/// Record a decision of JOB by AUTHOR, who read the log at SEEN, at time NOW (`drgnx-coord-decide`).  The user's is
/// current; an agent's is current inside its own claimed TASK (and, when replacing, only its own decision of that
/// task), else proposed.  More than [`DECISION_RATE`] a minute from one agent are refused.
pub fn decide(tx: &mut WTx<'_>, d: Decide, now: f64) -> Result<DecideResult, CoordError> {
    if let Some(h) = held_check(tx.sql(), d.seen)? {
        return Ok(DecideResult::Held(h));
    }
    let user = d.author == "user";
    if !user {
        let recent: i64 = tx.sql().query_row(
            "select count(*) from decision where author = ?1 and at > ?2",
            (&d.author, now - 60.0),
            |r| r.get(0),
        )?;
        if recent >= DECISION_RATE {
            return Ok(DecideResult::Error(format!(
                "too many decisions in a minute ({DECISION_RATE}): wait, or ask the user"
            )));
        }
    }
    let own = match (&d.task, user) {
        (Some(task), false) => task_row(tx.sql(), task)?.is_some_and(|row| {
            row.agent.as_deref() == Some(d.author.as_str())
                && row.status.as_deref().is_some_and(|s| ACTIVE.contains(&s))
        }),
        _ => false,
    };
    let replaced: Option<(Option<String>, Option<String>)> =
        match d.replaces {
            Some(n) => opt(tx.sql().query_row(
                "select author, task from decision where n = ?1",
                [n],
                |r| Ok((r.get(0)?, r.get(1)?)),
            ))?,
            None => None,
        };
    let own_replace = d.replaces.is_none()
        || replaced
            .as_ref()
            .is_some_and(|(a, t)| a.as_deref() == Some(d.author.as_str()) && *t == d.task);
    let status = if user || (own && own_replace) {
        "current"
    } else {
        "proposed"
    };
    let v = meta::bump_version(tx)?;
    // the next number: one past the highest, as the table's rowid was (a retired decision keeps its number)
    let n: i64 = tx.sql().query_row(
        "select coalesce(max(json_extract(data, '$.n')), 0) + 1 from entity where kind = 'decision'",
        [],
        |r| r.get(0),
    )?;
    // the `decision` view's columns: `data` holds what the table kept beside the entity's own title, status, body
    let mut data = serde_json::Map::new();
    data.insert("n".into(), json!(n));
    for (k, val) in [
        ("kind", json!(d.kind)),
        ("task", json!(d.task)),
        ("paths", json!(d.paths)),
        ("author", json!(d.author)),
        ("at", json!(now)),
        ("ver", json!(v as i64)),
        ("job", json!(d.job)),
    ] {
        if !val.is_null() {
            data.insert(k.into(), val);
        }
    }
    // `replaces` is the `supersedes` link to the decision it names; a number nothing has stays in `data`
    let target = match d.replaces {
        Some(r) => entity::by_id(tx.sql(), &format!("decision:{r}"))?,
        None => None,
    };
    if let (Some(r), None) = (d.replaces, &target) {
        data.insert("replaces".into(), json!(r));
    }
    let project = tx.meta().project;
    let made = entity::create(
        tx,
        EntityNew {
            id: format!("decision:{n}"),
            kind: "decision".into(),
            project,
            title: Some(d.subject.clone()),
            status: Some(status.into()),
            body: d.reason.clone(),
            priority: None,
            assignee: None,
            data: serde_json::Value::Object(data),
            origin: Origin::Recorded,
            source: None,
        },
    )?;
    if let Some(old) = &target {
        link::add(
            tx,
            made.n,
            "supersedes",
            old.n,
            None,
            Origin::Recorded,
            None,
        )?;
    }
    event(
        tx,
        Event {
            at: now,
            agent: Some(d.author.clone()),
            job: d.job.clone(),
            task: d.task.clone(),
            kind: EventKind::Decision,
            summary: format!("#{n} {}: {} ({status})", d.kind, d.subject),
            data: Some(json!({"n": n, "kind": d.kind, "status": status, "version": v})),
            turn: false,
        },
    )?;
    if let (Some(old), "current") = (&target, status) {
        entity::update(
            tx,
            old.n,
            None,
            Changes {
                status: Some(Some("replaced".into())),
                data_patch: Some(json!({"ver": v as i64})),
                ..Changes::default()
            },
        )?;
    }
    // its author knows it: not told of it as news (it read the log at SEEN, the one before)
    if !user && d.seen.is_some_and(|s| s + 1 == v) {
        meta::set_seen(tx, &d.author, v)?;
    }
    Ok(DecideResult::Ok {
        n,
        status: status.to_string(),
        version: v,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::{db7, tx_of};

    fn d(author: &str, seen: Option<u64>) -> Decide {
        Decide {
            kind: "build".into(),
            subject: "x".into(),
            author: author.into(),
            seen,
            ..Decide::default()
        }
    }

    #[test]
    fn a_future_seen_is_refused_and_an_old_one_is_held() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        assert!(matches!(
            held_check(tx.sql(), Some(3)),
            Err(CoordError::Refused(_))
        ));
        decide(&mut tx, d("user", None), 1.0).unwrap();
        let h = held_check(tx.sql(), Some(0)).unwrap().unwrap();
        assert_eq!((h.version, h.changes.len()), (1, 1));
        assert_eq!(held_check(tx.sql(), Some(1)).unwrap(), None);
        assert_eq!(held_check(tx.sql(), None).unwrap(), None);
    }

    #[test]
    fn the_rate_is_six_a_minute_per_agent() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        for _ in 0..DECISION_RATE {
            assert!(matches!(
                decide(&mut tx, d("a1", None), 100.0).unwrap(),
                DecideResult::Ok { .. }
            ));
        }
        assert!(matches!(
            decide(&mut tx, d("a1", None), 101.0).unwrap(),
            DecideResult::Error(_)
        ));
        assert!(matches!(
            decide(&mut tx, d("a1", None), 200.0).unwrap(),
            DecideResult::Ok { .. }
        ));
    }

    #[test]
    fn a_decision_is_an_entity_and_a_replacement_a_supersedes_link() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        decide(&mut tx, d("user", None), 1.0).unwrap();
        let mut second = d("user", Some(1));
        second.replaces = Some(1);
        let DecideResult::Ok { n, status, .. } = decide(&mut tx, second, 2.0).unwrap() else {
            panic!("held")
        };
        assert_eq!((n, status.as_str()), (2, "current"));
        // the view says what the table did
        let rows: Vec<(i64, String, Option<i64>)> = {
            let mut st = tx
                .sql()
                .prepare("select n, status, replaces from decision order by n")
                .unwrap();
            st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert_eq!(
            rows,
            [
                (1, "replaced".to_string(), None),
                (2, "current".to_string(), Some(1))
            ]
        );
        let links: i64 = tx
            .sql()
            .query_row(
                "select count(*) from link where kind = 'supersedes' and tx_to = ?1",
                [urdr::graph::schema::SENTINEL],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(links, 1);
        // a number nothing has stays as the number
        let mut third = d("user", None);
        third.replaces = Some(9);
        decide(&mut tx, third, 3.0).unwrap();
        let replaces: Option<i64> = tx
            .sql()
            .query_row("select replaces from decision where n = 3", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(replaces, Some(9));
    }
}
