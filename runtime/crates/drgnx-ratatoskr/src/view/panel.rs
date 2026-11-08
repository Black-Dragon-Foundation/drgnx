//! The agent panel's rows (docs/develop/hub.md, "The agent panel's rows"): an editor that shows session SID's panel
//! sends `view/env` for the view `agent-panel/SID`, and the hub sends it the transcript's rows as patches
//! (`view-patch`); the rows themselves are [`crate::agents::session::rows`]'.  Per (connection, view, class) a cache
//! keeps each group's rows, so an update builds only the groups whose entries changed, and the store's diff sends only
//! their rows.  What the user chose (the step types open, rows opened by hand, how far back the rows go) is per
//! (connection, view): `agents/panel/look`.  The steps' facts (time, cost, checkpoint, undone, subagent, hooks) come
//! from the step bus as steps close, and from the `step` table when a panel first shows a session and after a revert.
//! Before its rows each (connection, view) gets the panel's model ([`panel_doc`], `view-model`): its steps, each with
//! its kind and whether it has a diff, so the editor's keys find the next of a kind without asking; an appended entry
//! sends its new steps alone. Every row names its step (`drgnx-work-id`).

use super::model::Doc;
use super::{Key, lock};
use crate::agents::session::Session;
use crate::agents::session::rows::{self, Cx, Facts, Look};
use crate::dispatch::Caller;
use crate::front::Front;
use drgnx_rows::fit::{self, FontSet};
use drgnx_rows::{Row, RowBuilder};
use runstav::methods::agents::{Entry, EntryType, PanelLook};
use runstav::methods::timeline::Step;
use runstav::methods::view::{Display, ViewEnv};
use runstav::wire::Error;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, OnceLock, Weak};

/// The view name of session SID's panel.
pub fn view_of(sid: &str) -> String {
    format!("{PREFIX}{sid}")
}

const PREFIX: &str = "agent-panel/";

/// The entries a panel's rows start with: the last this many, and as many again each time the editor asks for older.
pub const WINDOW: usize = 200;

/// The most steps a panel's model holds (Sjá's cap on a list sent whole): the newest.
const MODEL_MAX: usize = 20_000;

/// One step of a panel's model: its group's head index, its entry's type, and whether it is a tool call with a diff.
pub type Head = (usize, EntryType, bool);

/// Whether tool entry E has an edit ([`rows::diffs_of`] not empty), without copying its texts.
fn has_diff(e: &Entry) -> bool {
    let item = |i: &Value| i.get("type").and_then(Value::as_str) == Some("diff");
    e.rest
        .get("content")
        .and_then(Value::as_array)
        .is_some_and(|a| a.iter().any(item))
        || e.rest.get("rawInput").is_some_and(|r| {
            r.get("old").is_some_and(Value::is_string) && r.get("new").is_some_and(Value::is_string)
        })
}

/// The steps of ENTRIES (index, entry, in order, contiguous) that draw rows: each group's head ([`rows::groups`]; a
/// plan and a usage draw none).
pub fn heads_of(entries: &[(usize, &Entry)]) -> Vec<Head> {
    let first = entries.first().map_or(0, |e| e.0);
    rows::groups(entries)
        .into_iter()
        .filter_map(|(h, _)| {
            let e = entries.get(h - first)?.1;
            let diff = e.kind == EntryType::Tool && has_diff(e);
            (!matches!(e.kind, EntryType::Plan | EntryType::Usage)).then_some((h, e.kind, diff))
        })
        .collect()
}

/// A panel's model of HEADS: a `list` scheme of the steps alone (`e:I`, kind the entry's type, fields `entry` and
/// `diff`, 1 for a tool call with an edit).  No step links to another and no list is kept: Sjá sends a list whole
/// when it changes, so a list of the tool calls would go whole with each one.  A new step adds its node and nothing
/// else changes; the editor finds the next step of a kind among the rows it draws.
pub fn panel_doc(heads: &[Head]) -> Doc {
    let heads = &heads[heads.len().saturating_sub(MODEL_MAX)..];
    let mut d = Doc {
        descriptor: json!({
            "scheme": "list",
            "chain_kinds": [],
            "match_fields": [],
            "lists": [],
            "classes": ["selected"],
            "flags": [],
            "forms": [],
            "start": null,
        }),
        ..Doc::default()
    };
    for h in heads {
        d.nodes.insert(format!("e:{}", h.0), node_of(h));
    }
    d
}

/// Step H's node in a panel's model.
fn node_of(h: &Head) -> Value {
    json!({"id": format!("e:{}", h.0), "kind": h.1, "flags": 0, "fields": [["entry", h.0], ["diff", u8::from(h.2)]]})
}

/// A panel's model to send: the whole of these steps, or these steps added to (or changed in) the one last sent.
#[derive(Debug, PartialEq)]
enum Made {
    Whole(Vec<Head>),
    Steps(Vec<Head>),
}

/// A session's groups from an index on, only those holding one of a set of indexes when given.
type GroupsFn<'a> = dyn Fn(usize, Option<&BTreeSet<usize>>) -> Vec<rows::GroupIn> + 'a;

/// A session's facts: a number that changes with them, and step seq → facts.
type SessionFacts = (u64, BTreeMap<u64, Facts>);

/// A session's transcript as the rows read it: its id, how many entries it has, its groups from an index on (only
/// those holding one of a set of indexes, when given), and whether an Always grant covers a tool entry.
struct Source<'a> {
    sid: &'a str,
    n: usize,
    groups: &'a GroupsFn<'a>,
    always: &'a dyn Fn(&runstav::methods::agents::Entry) -> bool,
}

/// What one (connection, view, class) was built from, and each group's rows.
#[derive(Default)]
struct Cache {
    /// The env epoch, width, look and facts it was built for: any change builds every group again.
    sig: Option<(u64, u32, u64, u64)>,
    groups: BTreeMap<usize, Vec<Row>>,
}

/// One (connection, view)'s choices, and a number that changes with them.
#[derive(Default)]
struct Chosen {
    look: Look,
    from: Option<usize>,
    version: u64,
    /// The (first entry, entry count) the last model sent was made of.
    modeled: Option<(usize, usize)>,
    /// The steps of the last model sent; none when the next one goes whole.
    heads: Option<Vec<Head>>,
}

/// The panels' state: the looks, the caches and the steps' facts.
#[derive(Default)]
pub struct Panels {
    chosen: Mutex<BTreeMap<(u64, String), Chosen>>,
    caches: Mutex<BTreeMap<Key, Cache>>,
    /// Session → (a number that changes with its facts, step seq → facts).
    facts: Mutex<BTreeMap<String, SessionFacts>>,
    front: OnceLock<Weak<Front>>,
}

/// The facts of step S.
pub fn facts_of(s: &Step) -> Facts {
    Facts {
        start: Some(s.start),
        end: s.end,
        cost: s.cost,
        revertible: s.revertible,
        undone: s.undone_by.is_some(),
        parent_tool: s.detail.as_ref().and_then(|d| d.parent_tool.clone()),
        hooks: s.hooks.clone(),
    }
}

impl Panels {
    /// Keep the front and follow the steps as they close.
    pub fn bind(self: &Arc<Self>, front: &Arc<Front>) {
        if self.front.set(Arc::downgrade(front)).is_err() {
            return;
        }
        let mut bus = front.core.agents.subscribe_steps();
        let me = Arc::downgrade(self);
        crate::clock::spawn("view:panel-steps", async move {
            loop {
                match bus.recv().await {
                    Ok(ev) => {
                        let Some(me) = me.upgrade() else { return };
                        me.step(&ev.session, &ev.step);
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => return,
                }
            }
        });
    }

    fn front(&self) -> Option<Arc<Front>> {
        self.front.get().and_then(Weak::upgrade)
    }

    /// Step STEP of session SID closed: its facts, and the panels that show the session built again.
    fn step(&self, sid: &str, step: &Step) {
        {
            let mut facts = lock(&self.facts);
            let Some((v, map)) = facts.get_mut(sid) else {
                return; // no panel shows it: its facts are read when one does
            };
            map.insert(step.seq, facts_of(step));
            *v += 1;
        }
        if let Some(f) = self.front() {
            self.build_session(&f, sid, None);
        }
    }

    /// The facts of session SID read again from the `step` table (a panel first shows it, or a revert changed which
    /// steps are undone), then its panels built again.
    pub fn load_facts(self: &Arc<Self>, sid: &str) {
        let Some(f) = self.front() else { return };
        lock(&self.facts)
            .entry(sid.to_owned())
            .or_insert((0, BTreeMap::new()));
        let (me, sid) = (self.clone(), sid.to_owned());
        crate::clock::spawn("view:panel-facts", async move {
            let hub = Caller {
                class: runstav::registry::Class::Service,
                sid: None,
                job: None,
                conn_id: 0,
            };
            let Ok(p) =
                serde_json::from_value(json!({"scope": "session", "id": sid, "limit": 500}))
            else {
                return;
            };
            let Ok(answer) = crate::timeline::get(&f, &hub, p).await else {
                return;
            };
            {
                let mut facts = lock(&me.facts);
                let (v, map) = facts.entry(sid.clone()).or_insert((0, BTreeMap::new()));
                for s in &answer.steps {
                    map.insert(s.seq, facts_of(s));
                }
                *v += 1;
            }
            me.build_session(&f, &sid, None);
        });
    }

    /// A revert or a fork was applied: the sessions shown read their facts again (which steps are undone).
    pub fn history_applied(self: &Arc<Self>) {
        let shown: Vec<String> = lock(&self.facts).keys().cloned().collect();
        for sid in shown {
            self.load_facts(&sid);
        }
    }

    /// `agents/panel/look`: CONN's choices for VIEW, and its rows built again.
    pub fn look(&self, f: &Front, conn: u64, p: PanelLook) -> bool {
        let view = p.view.into_inner();
        let Some(sid) = view.strip_prefix(PREFIX) else {
            return false;
        };
        {
            let mut chosen = lock(&self.chosen);
            let c = chosen.entry((conn, view.clone())).or_default();
            if let Some(open) = p.open {
                c.look.open = open.into_iter().map(|t| t.into_inner()).collect();
            }
            if let Some(rows) = p.rows {
                c.look.rows = rows.into_iter().collect();
            }
            if p.older == Some(true) {
                c.from = c.from.map(|from| from.saturating_sub(WINDOW));
            }
            c.version += 1;
        }
        self.build_session(f, sid, Some(conn));
        true
    }

    /// Build every panel of session SID (only CONN's, when given) and send what changed.  DIRTY: the entry indexes that
    /// changed (none: every group is built again).
    pub fn build_session(&self, f: &Front, sid: &str, conn: Option<u64>) {
        self.changed_in(f, sid, conn, None);
    }

    /// Session S's entries DIRTY changed (its `emit`): its panels build those groups again.
    pub fn changed(&self, s: &Session, dirty: &BTreeSet<usize>) {
        let Some(f) = self.front() else { return };
        let view = view_of(&s.id);
        if f.core.views.keys_of(&view).is_empty() {
            return;
        }
        self.build_keys(&f, s, &view, None, Some(dirty));
    }

    fn changed_in(&self, f: &Front, sid: &str, conn: Option<u64>, dirty: Option<&BTreeSet<usize>>) {
        let Ok(s) = f.core.agents.find(sid) else {
            return;
        };
        let view = view_of(sid);
        self.build_keys(f, &s, &view, conn, dirty);
    }

    fn build_keys(
        &self,
        f: &Front,
        s: &Session,
        view: &str,
        conn: Option<u64>,
        dirty: Option<&BTreeSet<usize>>,
    ) {
        let keys: Vec<Key> = f
            .core
            .views
            .keys_of(view)
            .into_iter()
            .filter(|k| conn.is_none_or(|c| c == k.0))
            .collect();
        if keys.is_empty() {
            return;
        }
        let sid = s.id.clone();
        let first = !lock(&self.facts).contains_key(&sid);
        if first {
            f.core.views.panels.load_facts(&sid);
        }
        // the model before the rows, which name its version; a connection's first rows of the view start it again
        let conns: BTreeSet<u64> = keys.iter().map(|k| k.0).collect();
        for c in conns {
            let restart = !lock(&self.caches).keys().any(|k| k.0 == c && k.1 == view);
            if restart {
                f.core.views.model_restart(c, view);
            }
            // a streamed chunk of a message changes no step: the model is made again only when the entries or the window
            // changed, on a full build, or when a tool call changed (its diff); new entries make their steps alone
            let force = restart || dirty.is_none();
            let tool = dirty.and_then(|d| s.first_tool(d));
            if let Some(start) = self.model_due(c, view, s.entry_count(), force, tool) {
                let heads = match self.model_made(c, view, start, s.panel_heads(start)) {
                    Made::Steps(steps) => {
                        let nodes = steps.iter().map(node_of).collect();
                        if f.core.views.extend_model(f, c, view, nodes) {
                            continue;
                        }
                        self.model_heads(c, view)
                    }
                    Made::Whole(heads) => heads,
                };
                f.core.views.publish_model(f, c, view, panel_doc(&heads));
            }
        }
        for key in keys {
            f.core.views.publish_built(f, &key, |env, fonts| {
                (self.rows_for(s, &key, env, fonts, dirty), Vec::new())
            });
        }
    }

    /// The entry CONN's VIEW's model is made again from, of N entries, when it is due: FORCE, the window or N changed
    /// since the last, or the tool call at TOOL changed.  The first entry it shows (the newest [`WINDOW`] until it asks
    /// for older) when it goes whole (FORCE, the window changed, none sent); else the earlier of the last step and TOOL.
    fn model_due(
        &self,
        conn: u64,
        view: &str,
        n: usize,
        force: bool,
        tool: Option<usize>,
    ) -> Option<usize> {
        let mut chosen = lock(&self.chosen);
        let c = chosen.entry((conn, view.to_owned())).or_default();
        let from = *c.from.get_or_insert(n.saturating_sub(WINDOW));
        let same = c.modeled.is_some_and(|(f, m)| f == from && m <= n);
        let due = force || !same || c.modeled != Some((from, n)) || tool.is_some();
        c.modeled = Some((from, n));
        if force || !same {
            c.heads = None;
        }
        if !due {
            return None;
        }
        let last = c.heads.as_ref().map(|h| h.last().map_or(from, |h| h.0));
        Some(last.map_or(from, |l| tool.map_or(l, |t| l.min(t.max(from)))))
    }

    /// CONN's VIEW's steps from START on are now TAIL: the model to send, its steps alone when a model went whole
    /// before, none went since, and the cap ([`MODEL_MAX`]) holds.
    fn model_made(&self, conn: u64, view: &str, start: usize, tail: Vec<Head>) -> Made {
        let mut chosen = lock(&self.chosen);
        let c = chosen.entry((conn, view.to_owned())).or_default();
        let Some(heads) = c.heads.as_mut() else {
            c.heads = Some(tail.clone());
            return Made::Whole(tail);
        };
        let keep = heads.partition_point(|h| h.0 < start);
        let old = heads.split_off(keep);
        let kept = old.iter().all(|o| tail.iter().any(|t| t.0 == o.0));
        let steps: Vec<Head> = tail.iter().filter(|t| !old.contains(t)).copied().collect();
        heads.extend(tail);
        if kept && heads.len() <= MODEL_MAX {
            Made::Steps(steps)
        } else {
            Made::Whole(heads.clone())
        }
    }

    /// The steps of CONN's VIEW's last model.
    fn model_heads(&self, conn: u64, view: &str) -> Vec<Head> {
        let chosen = lock(&self.chosen);
        chosen
            .get(&(conn, view.to_owned()))
            .and_then(|c| c.heads.clone())
            .unwrap_or_default()
    }

    fn rows_for(
        &self,
        s: &Session,
        key: &Key,
        env: &ViewEnv,
        fonts: &FontSet,
        dirty: Option<&BTreeSet<usize>>,
    ) -> Vec<Row> {
        let src = Source {
            sid: &s.id,
            n: s.entry_count(),
            groups: &|from: usize, only: Option<&BTreeSet<usize>>| s.panel_groups(from, only),
            always: &|e: &runstav::methods::agents::Entry| s.always_covers(e),
        };
        self.rows_of(&src, key, env, fonts, dirty)
    }

    /// KEY's rows now: the groups DIRTY touches built again (all of them when the env, the look or the facts changed),
    /// the others from the cache.
    fn rows_of(
        &self,
        src: &Source,
        key: &Key,
        env: &ViewEnv,
        fonts: &FontSet,
        dirty: Option<&BTreeSet<usize>>,
    ) -> Vec<Row> {
        let (sid, n) = (src.sid, src.n);
        let (look, from, look_v) = {
            let mut chosen = lock(&self.chosen);
            let c = chosen.entry((key.0, key.1.clone())).or_default();
            let from = *c.from.get_or_insert(n.saturating_sub(WINDOW));
            (c.look.clone(), from, c.version)
        };
        let all = lock(&self.facts);
        let empty = BTreeMap::new();
        let (facts_v, facts) = all.get(sid).map_or((0, &empty), |(v, m)| (*v, m));
        let sig = Some((env.epoch, env.width_px, look_v, facts_v));
        let mut caches = lock(&self.caches);
        let cache = caches.entry(key.clone()).or_default();
        let whole = cache.sig != sig
            || dirty.is_none()
            || cache.groups.keys().next().is_some_and(|h| *h < from)
            || cache.groups.keys().next_back().is_some_and(|h| *h >= n);
        let only = if whole { None } else { dirty };
        if whole {
            cache.groups.clear();
        }
        cache.sig = sig;
        let right = |text: &str| -> u32 {
            let w = match env.display {
                Display::Gui => fit::width(fonts, "ui", text).ceil() as u32,
                Display::Tty => text.chars().count() as u32 * env.cell.0.max(1),
            };
            env.width_px.saturating_sub(w + env.cell.0.max(1))
        };
        let cx = Cx {
            look: &look,
            facts,
            always: src.always,
            right: &right,
        };
        for g in (src.groups)(from, only) {
            let thoughts: Vec<&runstav::methods::agents::Entry> = g.thoughts.iter().collect();
            let mut built = rows::group_rows(g.head, &g.entry, &thoughts, g.blocks.as_deref(), &cx);
            // each row names its step, the model's node, for the editor's selection
            for r in &mut built {
                let end = r.text.chars().count() as u32;
                r.props.push((
                    0,
                    end,
                    "drgnx-work-id".into(),
                    json!(format!("e:{}", g.head)),
                ));
            }
            cache.groups.insert(g.head, built);
        }
        let mut out = Vec::new();
        if from > 0 {
            let mut b = RowBuilder::new("more");
            b.push(
                "  ↑ earlier steps load when you scroll up",
                Some("drgnx-agent-panel-subtle"),
            );
            out.push(b.finish());
        }
        for rows in cache.groups.values() {
            out.extend(rows.iter().cloned());
        }
        out
    }

    /// Session SID's Always grants changed: its panels built again (the tool rows' Always lines).
    pub fn refresh(&self, sid: &str) {
        if let Some(f) = self.front() {
            self.build_session(&f, sid, None);
        }
    }

    /// Connection CONN is gone, or closed VIEW (none: all its views).
    pub fn gone(&self, conn: u64, view: Option<&str>) {
        let mine = |c: &u64, v: &String| *c == conn && view.is_none_or(|w| w == v);
        lock(&self.chosen).retain(|(c, v), _| !mine(c, v));
        lock(&self.caches).retain(|(c, v, _), _| !mine(c, v));
    }

    /// The facts of sessions no panel shows any more are dropped.
    pub fn prune(&self, shown: &BTreeSet<String>) {
        lock(&self.facts).retain(|sid, _| shown.contains(sid));
    }
}

/// Whether VIEW is an agent panel's, and then its session.
pub fn session_of(view: &str) -> Option<&str> {
    view.strip_prefix(PREFIX)
}

/// `agents/panel/look`.
pub fn look(f: &Front, c: &Caller, p: PanelLook) -> Result<bool, Error> {
    Ok(f.core.views.panels.look(f, c.conn_id, p))
}

#[cfg(test)]
#[path = "panel/tests.rs"]
mod tests;
