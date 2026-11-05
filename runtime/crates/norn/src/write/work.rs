//! The Work space's hub-only records (agent system part 2, Task 1): asks and the links from them, a timeline step's
//! detail, a worktree's base.  The hub writes them as `("hub", Class::System)`; an agent, a user connection or the
//! scan never does, so each writer refuses any other author and nothing is written.

use crate::migrate9::ORIGINS;
use crate::store::{CoordError, WTx};
use serde::{Deserialize, Serialize};
use serde_json::json;
use urdr::graph::entity::{self, EntityNew, Origin};
use urdr::graph::guard::{self, Guard};
use urdr::graph::link;
use urdr::graph::tx::Class;

/// The refusal text for a write of a hub-only record by anyone else.
pub const HUB_ONLY: &str = "asks, step details and worktree bases are the hub's";

/// The most sources a conclusion may name.
pub const MAX_SOURCES: usize = 12;

/// Put the class rule of kind `ask` into GUARD: only a system-class author writes it.
pub fn register(guard: &mut Guard) {
    guard::register(guard, "ask", Class::System, HUB_ONLY);
}

fn hub_only(tx: &WTx<'_>) -> Result<(), CoordError> {
    let m = tx.meta();
    if m.class == Class::System && m.actor == "hub" {
        Ok(())
    } else {
        Err(CoordError::Refused(HUB_ONLY.into()))
    }
}

/// What a conclusion names: a file with optional lines, or a page.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(untagged)]
pub enum Source {
    Path {
        /// A file the conclusion rests on
        path: String,
        /// First and last line, 1-based
        #[serde(default, skip_serializing_if = "Option::is_none")]
        lines: Option<[u32; 2]>,
    },
    Url {
        /// A page the conclusion rests on
        url: String,
    },
}

/// Refuse more than [`MAX_SOURCES`] sources, an empty path or url, and lines that run backwards.
pub fn check_sources(sources: &[Source]) -> Result<(), CoordError> {
    if sources.len() > MAX_SOURCES {
        return Err(CoordError::Refused(format!(
            "at most {MAX_SOURCES} sources; name the ones that matter"
        )));
    }
    for s in sources {
        let bad = match s {
            Source::Path { path, lines } => {
                path.is_empty() || lines.is_some_and(|[a, b]| a == 0 || b < a)
            }
            Source::Url { url } => url.is_empty(),
        };
        if bad {
            return Err(CoordError::Refused(format!("a bad source: {s:?}")));
        }
    }
    Ok(())
}

/// One `step_detail` row: what a timeline step read, searched or fetched.  No content is kept.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct StepDetail {
    /// The timeline step's id.
    pub step: i64,
    pub tool: Option<String>,
    pub kind: Option<String>,
    pub path: Option<String>,
    pub line_start: Option<i64>,
    pub line_end: Option<i64>,
    pub query: Option<String>,
    pub url: Option<String>,
    pub title: Option<String>,
    /// One of [`ORIGINS`].
    pub origin: String,
}

/// Where a worktree branched from.
#[derive(Clone, Debug, PartialEq)]
pub struct WorktreeBase {
    pub worktree: String,
    pub repo: String,
    pub base_branch: Option<String>,
    pub base_commit: Option<String>,
    pub base_tree: Option<String>,
    /// Seconds since the epoch.
    pub at: f64,
}

/// A new ask.  `channel` is one of `say chat manager brainstorm`.
#[derive(Clone, Debug, PartialEq)]
pub struct AskNew {
    pub text: String,
    pub at: f64,
    pub channel: String,
    pub session: Option<String>,
    pub message_id: Option<String>,
    pub project: Option<i64>,
}

/// Record the detail of a timeline step (replacing an earlier one of the same step: the detail is taken again at
/// the step's close).
pub fn put_step_detail(tx: &WTx<'_>, d: StepDetail) -> Result<(), CoordError> {
    hub_only(tx)?;
    if !ORIGINS.contains(&d.origin.as_str()) {
        return Err(CoordError::Refused(format!(
            "step detail origin {:?} is not one of {ORIGINS:?}",
            d.origin
        )));
    }
    tx.sql().execute(
        "insert or replace into step_detail (step, tool, kind, path, line_start, line_end, query, url, title, origin) \
         values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        (
            d.step,
            &d.tool,
            &d.kind,
            &d.path,
            d.line_start,
            d.line_end,
            &d.query,
            &d.url,
            &d.title,
            &d.origin,
        ),
    )?;
    Ok(())
}

/// Record where a worktree branched from (replacing the row of the same worktree).
pub fn put_base(tx: &WTx<'_>, b: WorktreeBase) -> Result<(), CoordError> {
    hub_only(tx)?;
    tx.sql().execute(
        "insert or replace into worktree_base (worktree, repo, base_branch, base_commit, base_tree, at) \
         values (?1, ?2, ?3, ?4, ?5, ?6)",
        (
            &b.worktree,
            &b.repo,
            &b.base_branch,
            &b.base_commit,
            &b.base_tree,
            b.at,
        ),
    )?;
    Ok(())
}

/// Stamp CONCLUSION (`decision:N`, a finding's note id) with the timeline step its MCP call was made in; none: the
/// step is unknown (no step key).  The hub's own record: whatever the agent said of the step is not kept.  A conclusion
/// that is gone is skipped.
pub fn stamp_step(tx: &mut WTx<'_>, conclusion: &str, step: Option<i64>) -> Result<(), CoordError> {
    hub_only(tx)?;
    let Some(e) = entity::by_id(tx.sql(), conclusion)? else {
        return Ok(());
    };
    if !matches!(e.kind.as_str(), "decision" | "note") {
        return Err(CoordError::Refused(format!(
            "{conclusion} is no conclusion"
        )));
    }
    entity::update(
        tx,
        e.n,
        None,
        entity::Changes {
            data_patch: Some(json!({ "step": step })),
            ..entity::Changes::default()
        },
    )?;
    Ok(())
}

/// Create an `ask` entity; answers its id.
pub fn new_ask(tx: &mut WTx<'_>, a: AskNew) -> Result<String, CoordError> {
    hub_only(tx)?;
    if !["say", "chat", "manager", "brainstorm"].contains(&a.channel.as_str()) {
        return Err(CoordError::Refused(format!(
            "an ask comes from say, chat, manager or brainstorm, not {:?}",
            a.channel
        )));
    }
    let id = format!("ask:{}", tx.id());
    let mut data = json!({"text": a.text, "at": a.at, "by": "user", "channel": a.channel});
    if let Some(s) = &a.session {
        data["session"] = json!(s);
    }
    if let Some(m) = &a.message_id {
        data["message_id"] = json!(m);
    }
    entity::create(
        tx,
        EntityNew {
            id: id.clone(),
            kind: "ask".into(),
            project: a.project,
            title: Some(a.text.chars().take(40).collect()),
            status: None,
            body: Some(a.text),
            priority: None,
            assignee: None,
            data,
            origin: Origin::Recorded,
            source: None,
        },
    )?;
    Ok(id)
}

/// Link ASK `asked` TO (a spec, plan, task or session id); a link already there is left as it is.
pub fn link_asked(tx: &mut WTx<'_>, ask: &str, to: &str) -> Result<(), CoordError> {
    hub_only(tx)?;
    fn end(tx: &WTx<'_>, id: &str) -> Result<entity::Ent, CoordError> {
        entity::by_id(tx.sql(), id)?.ok_or_else(|| CoordError::Refused(format!("no entity {id}")))
    }
    let (a, b) = (end(tx, ask)?, end(tx, to)?);
    if !crate::kinds::link_allowed("asked", &a.kind, &b.kind) {
        return Err(CoordError::Refused(format!(
            "asked does not join a {} to a {}",
            a.kind, b.kind
        )));
    }
    link::add(tx, a.n, "asked", b.n, None, Origin::Recorded, None)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::{db7, tx_of};
    use urdr::graph::tx::{Class, TxMeta};

    fn guarded_tx<'a>(c: &'a mut urdr::Connection, class: Class, actor: &str) -> WTx<'a> {
        let mut g = Guard::default();
        crate::grants::register(&mut g);
        WTx::for_test(c, TxMeta::new(actor, class, "test"), std::sync::Arc::new(g))
    }

    fn ask() -> AskNew {
        AskNew {
            text: "fix deferred testing rows".into(),
            at: 1.0,
            channel: "say".into(),
            session: None,
            message_id: None,
            project: None,
        }
    }

    fn detail() -> StepDetail {
        StepDetail {
            step: 1,
            tool: Some("Read".into()),
            path: Some("src/a.rs".into()),
            origin: "acp".into(),
            ..StepDetail::default()
        }
    }

    fn base() -> WorktreeBase {
        WorktreeBase {
            worktree: "/w/a".into(),
            repo: "/w".into(),
            base_branch: Some("main".into()),
            base_commit: None,
            base_tree: None,
            at: 1.0,
        }
    }

    /// Pattern D: every writer, from every author but the hub, writes nothing and says why.
    #[test]
    fn agent_write_of_ask_is_refused() {
        let mut c = db7();
        for (class, actor) in [
            (Class::Agent, "agent:s1"),
            (Class::User, "user"),
            (Class::Ext, "ext:s2"),
            (Class::System, "scan:/w"),
        ] {
            let mut tx = guarded_tx(&mut c, class, actor);
            let refused = CoordError::Refused(HUB_ONLY.into());
            assert_eq!(new_ask(&mut tx, ask()), Err(refused.clone()), "{actor}");
            assert_eq!(
                put_step_detail(&tx, detail()),
                Err(refused.clone()),
                "{actor}"
            );
            assert_eq!(put_base(&tx, base()), Err(refused.clone()), "{actor}");
            assert_eq!(
                link_asked(&mut tx, "ask:1", "task:t"),
                Err(refused),
                "{actor}"
            );
            // the graph's own door is shut to the kind as well
            let direct = entity::create(
                &mut tx,
                EntityNew {
                    id: "ask:direct".into(),
                    kind: "ask".into(),
                    project: None,
                    title: None,
                    status: None,
                    body: None,
                    priority: None,
                    assignee: None,
                    data: json!({}),
                    origin: Origin::Recorded,
                    source: None,
                },
            );
            assert_eq!(direct.is_ok(), class == Class::System, "{actor}");
            drop(tx);
        }
        for t in ["step_detail", "worktree_base"] {
            let n: i64 = c
                .query_row(&format!("select count(*) from {t}"), [], |r| r.get(0))
                .unwrap();
            assert_eq!(n, 0, "{t}");
        }
    }

    #[test]
    fn the_hub_writes_an_ask_and_links_it() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        entity::create(
            &mut tx,
            EntityNew {
                id: "task:t".into(),
                kind: "task".into(),
                project: None,
                title: Some("t".into()),
                status: None,
                body: None,
                priority: None,
                assignee: None,
                data: json!({}),
                origin: Origin::Recorded,
                source: None,
            },
        )
        .unwrap();
        let id = new_ask(&mut tx, ask()).unwrap();
        link_asked(&mut tx, &id, "task:t").unwrap();
        // asking twice leaves one link; a wrong end is refused
        link_asked(&mut tx, &id, "task:t").unwrap();
        assert!(link_asked(&mut tx, "task:t", &id).is_err());
        let bad = AskNew {
            channel: "shout".into(),
            ..ask()
        };
        assert!(new_ask(&mut tx, bad).is_err());
        tx.sql()
            .execute_batch(
                "insert into step (session, seq, class, start) values ('session:s', 1, 'tool', 1.0)",
            )
            .unwrap();
        put_step_detail(&tx, detail()).unwrap();
        put_step_detail(
            &tx,
            StepDetail {
                line_start: Some(3),
                ..detail()
            },
        )
        .unwrap();
        put_base(&tx, base()).unwrap();
        put_base(
            &tx,
            WorktreeBase {
                base_commit: Some("abc".into()),
                ..base()
            },
        )
        .unwrap();
        tx.commit_for_test().unwrap();
        let asks = crate::read::work::asks_of(&c, &["task:t", "session:none"]).unwrap();
        assert_eq!(asks, [("task:t".to_string(), id)]);
        let b = crate::read::work::base(&c, "/w/a").unwrap().unwrap();
        assert_eq!(b.base_commit.as_deref(), Some("abc"));
        let d = crate::read::work::step_detail(&c, 1).unwrap().unwrap();
        assert_eq!(
            (d.path.as_deref(), d.line_start),
            (Some("src/a.rs"), Some(3))
        );
        assert_eq!(crate::read::work::step_detail(&c, 2).unwrap(), None);
        let tx = tx_of(&mut c);
        let bad = StepDetail {
            origin: "guess".into(),
            ..detail()
        };
        assert!(put_step_detail(&tx, bad).is_err());
    }

    #[test]
    fn sources_over_12_is_refused() {
        let one = |i: u32| Source::Path {
            path: format!("f{i}.rs"),
            lines: Some([1, 2]),
        };
        let twelve: Vec<Source> = (0..12).map(one).collect();
        assert_eq!(check_sources(&twelve), Ok(()));
        let thirteen: Vec<Source> = (0..13).map(one).collect();
        assert!(matches!(
            check_sources(&thirteen),
            Err(CoordError::Refused(_))
        ));
        let backwards = [Source::Path {
            path: "a".into(),
            lines: Some([5, 2]),
        }];
        assert!(check_sources(&backwards).is_err());
        let url = [Source::Url {
            url: "https://x".into(),
        }];
        assert_eq!(check_sources(&url), Ok(()));
        let parsed: Vec<Source> =
            serde_json::from_value(json!([{"path": "a", "lines": [1, 3]}, {"url": "u"}])).unwrap();
        assert_eq!(parsed.len(), 2);
    }
}
