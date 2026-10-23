//! The graph tools — `graph_read`, `access_request` (Task 14; storage §6.1, §6.4).

use std::collections::HashMap;

use mimir::{BoxFuture, Tool};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{Value, json};
use urdr::Connection;
use urdr::graph::entity;
use urdr::graph::link::Direction;
use urdr::graph::schema::SENTINEL;
use urdr::graph::walk::{self, Budget, PathQ, Seen, Walk, WalkError, WalkOut};

use super::tracker::{Answer, Look, RichTool, caller_of, err, rich};
use super::{Coord, Ctx, Identity};
use crate::store::CoordError;
use crate::tracker::opt;
use crate::trust::authored;
use crate::write::cards::{NewCard, card_create};

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![rich(GraphRead), rich(AccessRequest)]
}

// ------------------------------------------------------------------------------------------------------ graph_read

#[derive(Deserialize, JsonSchema)]
struct GraphReadArgs {
    /// neighbors, path, history or who_touched
    op: String,
    /// neighbors, history: the entity's id
    id: Option<String>,
    /// neighbors, path: only these link kinds (required past depth 3)
    kinds: Option<Vec<String>>,
    /// neighbors: out, in or both (default)
    direction: Option<String>,
    /// neighbors: how far (1 to 4, default 1)
    depth: Option<i64>,
    /// neighbors, path: as the graph was at this tx
    as_of: Option<i64>,
    /// path: start at this entity
    start: Option<String>,
    /// path: end at this entity
    end: Option<String>,
    /// path: at most this many links (1 to 6, default 3; kinds are required past 3)
    max_depth: Option<i64>,
    /// history, who_touched: only changes from this tx on
    since: Option<i64>,
    /// who_touched: the file's path
    path: Option<String>,
}

struct GraphRead;

impl RichTool for GraphRead {
    type Args = GraphReadArgs;
    const NAME: &'static str = "graph_read";
    const DESCRIPTION: &'static str = "Walk the work graph: neighbors of an entity, the shortest path between two, an entity's history (who changed what), who_touched a file. Answers say truncated and hidden";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: GraphReadArgs,
    ) -> BoxFuture<'a, Result<Answer, String>> {
        Box::pin(graph_read(coord, who, args))
    }
}

fn need<T>(v: Option<T>, field: &str, op: &str) -> Result<T, String> {
    v.ok_or_else(|| format!("{op} needs {field}"))
}

/// The entity ID as the caller sees it (`n`), else "no such entity".
fn entity_n(look: &Look<'_>, id: &str) -> Result<i64, CoordError> {
    entity::by_id(look.conn, id)?
        .filter(|e| e.retired_tx.is_none() && look.seen(e) != Seen::Hidden)
        .map(|e| e.n)
        .ok_or_else(|| CoordError::Refused(format!("no such entity: {id}")))
}

fn walk_text(e: WalkError) -> String {
    match e {
        WalkError::Refused(t) => t,
        WalkError::Sql(t) => format!("the walk failed: {t}"),
    }
}

async fn graph_read(coord: &Coord, who: &Identity, a: GraphReadArgs) -> Result<Answer, String> {
    let caller = caller_of(coord, who, false).await?;
    let now = coord.now();
    match a.op.as_str() {
        "neighbors" => {
            let id = need(a.id, "id", "neighbors")?;
            let depth = a.depth.unwrap_or(1);
            if !(1..=4).contains(&depth) {
                return Err("depth is 1 to 4".into());
            }
            let direction = match a.direction.as_deref() {
                None | Some("both") => Direction::Both,
                Some("out") => Direction::Out,
                Some("in") => Direction::In,
                Some(o) => return Err(format!("direction is out, in or both, not {o:?}")),
            };
            let kinds = a.kinds.unwrap_or_default();
            let (n, scope) = coord
                .db()
                .read(move |c| {
                    let look = Look::new(c, &caller, now)?;
                    Ok((entity_n(&look, &id)?, look.scope))
                })
                .await
                .map_err(err)?;
            let pool = &coord.graph().ok_or("the graph store is not open yet")?.pool;
            let out = walk::neighbors(
                pool,
                Walk {
                    from: n,
                    kinds,
                    direction,
                    depth: depth as u32,
                    as_of: a.as_of,
                },
                &scope,
                Budget::default(),
            )
            .await
            .map_err(walk_text)?;
            walk_answer(coord, out).await
        }
        "path" => {
            let (from, to) = (need(a.start, "start", "path")?, need(a.end, "end", "path")?);
            let max_depth = a.max_depth.unwrap_or(3);
            if !(1..=6).contains(&max_depth) {
                return Err("max_depth is 1 to 6".into());
            }
            let kinds = a.kinds.unwrap_or_default();
            let (ends, scope) = coord
                .db()
                .read(move |c| {
                    let look = Look::new(c, &caller, now)?;
                    Ok(((entity_n(&look, &from)?, entity_n(&look, &to)?), look.scope))
                })
                .await
                .map_err(err)?;
            let pool = &coord.graph().ok_or("the graph store is not open yet")?.pool;
            let out = walk::path(
                pool,
                PathQ {
                    from: ends.0,
                    to: ends.1,
                    kinds,
                    max_depth: max_depth as u32,
                    as_of: a.as_of,
                },
                &scope,
                Budget::default(),
            )
            .await
            .map_err(walk_text)?;
            walk_answer(coord, out).await
        }
        "history" => {
            let id = need(a.id, "id", "history")?;
            let since = a.since;
            coord
                .db()
                .read(move |c| {
                    let look = Look::new(c, &caller, now)?;
                    let n = entity_n(&look, &id)?;
                    let e = entity::by_n(c, n)?.ok_or_else(|| CoordError::Refused(format!("no such entity: {id}")))?;
                    if look.seen(&e) != Seen::Full {
                        return Err(CoordError::Refused(format!("no such entity: {id}")));
                    }
                    let versions = urdr::graph::hist::history(c, n, since)?;
                    let mut text = vec![format!("{} ({} versions)", e.id, versions.len())];
                    for v in &versions {
                        text.push(format!("ver {} tx {} by {} ({}): {}", v.ver, v.tx, v.actor, v.class.as_str(), v.fields.join(", ")));
                    }
                    Ok(Answer {
                        text: text.join("\n"),
                        structured: json!({"id": e.id, "versions": versions, "truncated": null, "hidden": 0}),
                        links: vec![e.id],
                    })
                })
                .await
                .map_err(err)
        }
        "who_touched" => {
            let path = need(a.path, "path", "who_touched")?;
            let since = a.since;
            coord
                .db()
                .read(move |c| who_touched(c, &caller, now, &path, since))
                .await
                .map_err(err)
        }
        other => Err(format!(
            "op is neighbors, path, history or who_touched, not {other:?}"
        )),
    }
}

/// A walk's nodes (titles with their authors) and links (by id), with `truncated` and `hidden`.
async fn walk_answer(coord: &Coord, out: WalkOut) -> Result<Answer, String> {
    coord
        .db()
        .read(move |c| {
            let mut ids: HashMap<i64, String> = HashMap::new();
            let (mut nodes, mut text, mut links) = (Vec::new(), Vec::new(), Vec::new());
            for n in &out.nodes {
                ids.insert(n.n, n.id.clone());
                let title = match entity::by_n(c, n.n)? {
                    Some(e) => authored(c, &e, "title")?,
                    None => None,
                };
                let shown = title.as_ref().map(|t| t.render()).unwrap_or_default();
                text.push(format!("{} ({}) depth {} {shown}", n.id, n.kind, n.depth));
                let mut o = json!({"id": n.id, "kind": n.kind, "depth": n.depth, "title": title, "seen": n.seen});
                if let Some(h) = n.hot {
                    o["hot"] = json!(h);
                    text.push(format!("  {} has {h} links: not expanded", n.id));
                }
                nodes.push(o);
                links.push(n.id.clone());
            }
            let edges: Vec<Value> = out
                .links
                .iter()
                .filter_map(|e| Some(json!({"src": ids.get(&e.src)?, "kind": e.kind, "dst": ids.get(&e.dst)?})))
                .collect();
            for e in &edges {
                text.push(format!("{} -{}-> {}", e["src"].as_str().unwrap_or(""), e["kind"].as_str().unwrap_or(""), e["dst"].as_str().unwrap_or("")));
            }
            text.push(format!(
                "truncated: {}; hidden: {}",
                out.truncated.map_or("no".to_owned(), |t| json!(t).as_str().unwrap_or("").to_owned()),
                out.hidden
            ));
            Ok(Answer {
                text: text.join("\n"),
                structured: json!({"nodes": nodes, "links": edges, "truncated": out.truncated, "hidden": out.hidden}),
                links,
            })
        })
        .await
        .map_err(err)
}

/// The sessions that touched the file PATH (`file ← touched ← session → run_by → agent`) from tx SINCE, and where
/// the file is now: `current`, `moved` (to the end of its `renamed_to` links) or `gone`.
fn who_touched(
    c: &Connection,
    caller: &crate::scope::Caller,
    now: f64,
    path: &str,
    since: Option<i64>,
) -> Result<Answer, CoordError> {
    let look = Look::new(c, caller, now)?;
    let id = if path.starts_with("file:") {
        path.to_owned()
    } else {
        format!("file:{path}")
    };
    let live =
        entity::by_id(c, &id)?.filter(|e| e.retired_tx.is_none() && look.seen(e) != Seen::Hidden);
    let mut hidden = 0;
    let mut touched = Vec::new();
    let mut state = "gone";
    let mut moved_to = None;
    if let Some(file) = &live {
        state = "current";
        // follow `renamed_to` to the end (a chain longer than ten is cut there)
        let mut at = file.n;
        for _ in 0..10 {
            let next: Option<i64> = opt(c.query_row(
                &format!("select dst from link where src = ?1 and kind = 'renamed_to' and tx_to = {SENTINEL} order by id limit 1"),
                [at],
                |r| r.get(0),
            ))?;
            match next {
                Some(n) => at = n,
                None => break,
            }
        }
        if at != file.n {
            state = "moved";
            moved_to = entity::by_n(c, at)?.map(|e| e.id);
        }
        let mut stmt = c.prepare(&format!(
            "select s.n, l.tx_from from link l join entity s on s.n = l.src \
             where l.dst = ?1 and l.kind = 'touched' and l.tx_to = {SENTINEL} and l.tx_from >= ?2 \
             and s.retired_tx is null order by l.tx_from desc limit 200"
        ))?;
        let rows: Vec<(i64, i64)> = stmt
            .query_map((file.n, since.unwrap_or(0)), |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<Result<_, _>>()?;
        for (sn, tx) in rows {
            let Some(s) = entity::by_n(c, sn)? else {
                continue;
            };
            if look.seen(&s) == Seen::Hidden {
                hidden += 1;
                continue;
            }
            let agent: Option<String> = opt(c.query_row(
                &format!(
                    "select a.id from link r join entity a on a.n = r.dst \
                     where r.src = ?1 and r.kind = 'run_by' and r.tx_to = {SENTINEL} limit 1"
                ),
                [sn],
                |r| r.get(0),
            ))?;
            let at: Option<f64> =
                opt(c.query_row("select at from tx where id = ?1", [tx], |r| r.get(0)))?;
            touched.push(json!({"session": s.id, "agent": agent, "tx": tx, "at": at}));
            if touched.len() == super::tracker::LIST_MAX {
                break;
            }
        }
    }
    let mut text = vec![format!(
        "{id}: {state}{}",
        moved_to
            .as_ref()
            .map_or(String::new(), |m| format!(" to {m}"))
    )];
    for t in &touched {
        text.push(format!(
            "{} (agent {}) tx {}",
            t["session"].as_str().unwrap_or(""),
            t["agent"].as_str().unwrap_or("?"),
            t["tx"]
        ));
    }
    text.push(format!("truncated: no; hidden: {hidden}"));
    Ok(Answer {
        text: text.join("\n"),
        structured: json!({"path": id, "state": state, "moved_to": moved_to, "touched": touched, "truncated": null, "hidden": hidden}),
        links: live.map(|e| e.id).into_iter().collect(),
    })
}

// ------------------------------------------------------------------------------------------------- access_request

#[derive(Deserialize, JsonSchema)]
struct AccessRequestArgs {
    /// The project you need to read
    project: String,
    /// Why
    reason: String,
}

struct AccessRequest;

impl RichTool for AccessRequest {
    type Args = AccessRequestArgs;
    const NAME: &'static str = "access_request";
    const DESCRIPTION: &'static str = "Ask the user to let you read another project. Never waits: the user decides on a card, and a granted read shows up in your scope. Answers the same whether or not the project exists";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: AccessRequestArgs,
    ) -> BoxFuture<'a, Result<Answer, String>> {
        Box::pin(access_request(coord, who, args))
    }
}

async fn access_request(
    coord: &Coord,
    who: &Identity,
    a: AccessRequestArgs,
) -> Result<Answer, String> {
    who.me()?;
    if let Some(rule) = runstav::secrets::looks_like_secret(&a.reason) {
        return Err(format!(
            "the reason looks like a secret ({rule}); do not store credentials"
        ));
    }
    let target = runstav::text::one_line(&a.project, 80, false);
    let reason = runstav::text::cut(&a.reason, 500).0;
    let caller = caller_of(coord, who, true).await?;
    let now = coord.now();
    let meta = caller.tx_meta("mcp:access_request");
    let card = coord
        .db()
        .write(meta, move |tx| {
            let known: bool = {
                let by_alias: Option<i64> = opt(tx.sql().query_row(
                    "select project from project_alias where slug = ?1",
                    [&target],
                    |r| r.get(0),
                ))?;
                by_alias.is_some()
                    || entity::by_id(tx.sql(), &target)?.is_some_and(|e| e.kind == "project" && e.retired_tx.is_none())
            };
            let session = caller.session.clone().unwrap_or_else(|| caller.actor.clone());
            let profile = caller.profile.clone().unwrap_or_else(|| "no profile".into());
            let mine: String = match caller.project {
                Some(p) => opt(tx.sql().query_row(
                    "select slug from project_alias where project = ?1 order by tx, slug limit 1",
                    [p],
                    |r| r.get(0),
                ))?
                .or(entity::by_n(tx.sql(), p)?.map(|e| e.id))
                .unwrap_or_else(|| "its project".into()),
                None => "no project".into(),
            };
            // an open request of this session for this target is the same card
            let open: Option<i64> = opt(tx.sql().query_row(
                "select id from card where kind = 'access' and state = 'open' \
                 and json_extract(data, '$.session') = ?1 and json_extract(data, '$.target') = ?2 order by id limit 1",
                (&session, &target),
                |r| r.get(0),
            ))?;
            if let Some(id) = open {
                return Ok(id);
            }
            let unknown = if known { "" } else { " (unknown project)" };
            card_create(
                tx,
                NewCard {
                    job: None,
                    task: None,
                    kind: Some("access".into()),
                    title: Some(format!("{session} ({profile}) in {mine} asks to read {target}{unknown}")),
                    data: Some(json!({
                        "session": session, "profile": caller.profile, "project": mine, "target": target,
                        "reason": reason, "known": known,
                        "choices": ["session", "project", "profile", "refuse"],
                    })),
                },
                now,
            )
        })
        .await
        .map_err(err)?;
    coord.hub().notify();
    Ok(Answer {
        text: format!("requested: card {card}. The user decides; go on without it for now"),
        structured: json!({"requested": card}),
        links: Vec::new(),
    })
}
