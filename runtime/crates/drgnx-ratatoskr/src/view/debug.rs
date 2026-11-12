//! The Run and Debug view (docs/develop/debugging.md, "The Run and Debug view"; spec §7): a hub-fed sidebar view as
//! the Explorer is. [`model`] makes its lines and model from the project's sessions, [`rows`] its rows; [`DebugViews`]
//! keeps each view's open nodes and what it fetched, and builds it again whenever a session or a breakpoint changes
//! ([`Debug::on_change`]).
//!
//! At each stop the open paths are fetched again, breadth first, at most [`model::FETCH_CAP`] calls; the rest wait,
//! closed, for the user to open them again. The selected session's last stop's values are kept to mark the changed
//! ones.

pub mod model;
pub mod rows;
#[cfg(test)]
mod tests;

use super::explorer::RowLook;
use super::{Key, lock};
use crate::debug::session::Handle;
use crate::debug::{Debug, Snap};
use crate::dispatch::Caller;
use crate::front::Front;
use model::{Bps, FETCH_CAP, Filter, Input, Line, Opened, SessionView, Tree, Var, Want};
use runstav::methods::Params;
use runstav::methods::debug::{
    DebugChild, DebugChildList, DebugChildren, DebugDataBreakpoint, DebugDataBreakpoints,
    DebugEvaluate, DebugEvaluated, DebugExpand, DebugSetValue, DebugValue, DebugView, DebugWatch,
};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};

/// The level indent when the editor names none, in logical px.
const INDENT: u32 = 12;

/// What one session's view holds between builds: its tree and frames, the frame its scopes are of, the calls this
/// stop made, and the watches evaluated (none: not yet).
#[derive(Clone, Default)]
struct Cached {
    view: SessionView,
    frame: i64,
    calls: usize,
    watched: Option<Vec<String>>,
}

/// One connection's view.
#[derive(Default)]
struct St {
    root: String,
    session: Option<String>,
    filter: Option<String>,
    indent: u32,
    opened: Opened,
    trees: HashMap<String, Cached>,
    /// The session Variables and Watch showed at the last build.
    shown: Option<String>,
    /// The values of the last stop, and of this one (with its session and epoch).
    prev: HashMap<String, String>,
    cur: HashMap<String, String>,
    cur_at: Option<(String, u64)>,
    lines: Arc<Vec<Line>>,
}

/// The Run and Debug views, by (connection, view).
#[derive(Default)]
pub struct DebugViews {
    views: Mutex<HashMap<(u64, String), St>>,
    hooked: OnceLock<()>,
    /// One build at a time.
    gate: tokio::sync::Mutex<()>,
    /// A change came while the views were being built: build them again.
    building: AtomicBool,
    again: AtomicBool,
}

fn err(message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: message.into(),
        path: None,
    }
}

/// C's tree for the session SN now: a new stop (or another frame) starts it again from the stop; a session running
/// again keeps it, dim.
fn refresh_tree(c: &mut Cached, sn: &Snap) {
    match &sn.stop {
        Some(stop) => {
            let same = !c.view.tree.stale
                && c.view.stop.is_some()
                && c.view.tree.epoch == stop.epoch
                && c.frame == stop.frame;
            if !same {
                c.view.tree = Tree::of_stop(&sn.id, stop);
                c.view.thread_frames.clear();
                c.frame = stop.frame;
                c.calls = 0;
                c.watched = None;
            }
        }
        None => c.view.tree.stale = true,
    }
    c.view.id = sn.id.clone();
    c.view.name = sn.name.clone();
    c.view.state = sn.state.to_owned();
    c.view.stop = sn.stop.clone();
}

/// Fetch what VIEW's open nodes still need through H, breadth first, until nothing is missing or the stop's CALLS
/// reach [`FETCH_CAP`] (the rest are capped).
pub(crate) async fn fill(h: &Handle, view: &mut SessionView, calls: &mut usize, opened: &Opened) {
    let Some(epoch) = view.stop.as_ref().map(|s| s.epoch) else {
        return;
    };
    loop {
        let wants = model::wants(view, opened);
        if wants.is_empty() {
            return;
        }
        for w in wants {
            fetch(h, epoch, view, calls, w).await;
        }
    }
}

/// W fetched through H into VIEW, one of the stop's CALLS; past [`FETCH_CAP`] its path is capped instead.
async fn fetch(h: &Handle, epoch: u64, view: &mut SessionView, calls: &mut usize, w: Want) {
    if *calls >= FETCH_CAP {
        view.tree.capped.insert(w.path);
        return;
    }
    *calls += 1;
    if w.command == "stackTrace" {
        let tid = w.args["threadId"].as_i64().unwrap_or(0);
        match h.request("stackTrace", w.args).await {
            Ok(b) => {
                let frames = b["stackFrames"].as_array().cloned().unwrap_or_default();
                view.thread_frames.insert(tid, frames);
            }
            Err(e) => {
                view.tree.failed.insert(w.path, e);
            }
        }
        return;
    }
    match h.variables_with(epoch, w.args).await {
        Ok(vs) => {
            view.tree
                .kids
                .insert(w.path, vs.iter().map(Var::of).collect());
        }
        Err(e) => {
            view.tree.failed.insert(w.path, e);
        }
    }
}

/// Each of EXPRS evaluated in FRAME (`context: watch`): its answer, or the adapter's message.
async fn evaluate_all(
    h: &Handle,
    frame: i64,
    exprs: &[String],
) -> Vec<(String, Result<Var, String>)> {
    let mut out = Vec::with_capacity(exprs.len());
    for e in exprs {
        let r = h
            .request(
                "evaluate",
                json!({"expression": e, "frameId": frame, "context": "watch"}),
            )
            .await
            .map(|b| Var::of(&b));
        out.push((e.clone(), r));
    }
    out
}

/// ROOT's breakpoints as the view shows them: each adapter type's exception filters (one per type of SNAPS), the
/// function breakpoints, each file's.
fn bps_of(d: &Debug, root: &str, snaps: &[Snap]) -> Bps {
    let (functions, files) = d.bp_lists(root);
    let mut filters = vec![];
    let mut types = BTreeSet::new();
    for sn in snaps {
        if !types.insert(sn.adapter.clone()) {
            continue;
        }
        let on = d.filters_on(root, &sn.adapter, &sn.caps);
        for f in sn.caps["exceptionBreakpointFilters"]
            .as_array()
            .into_iter()
            .flatten()
        {
            let Some(id) = f["filter"].as_str() else {
                continue;
            };
            filters.push(Filter {
                ty: sn.adapter.clone(),
                id: id.to_owned(),
                label: f["label"].as_str().unwrap_or(id).to_owned(),
                on: on.iter().any(|o| o == id),
            });
        }
    }
    Bps {
        filters,
        functions,
        files,
        data: d.data_lists(root),
    }
}

impl DebugViews {
    /// Build every view again at each change of a session or breakpoint (once per hub).
    fn hook(&self, f: &Front) {
        self.hooked.get_or_init(|| {
            let weak: Option<Weak<Front>> = f.core.views.front_weak();
            f.debug.debug(f).on_change(Arc::new(move || {
                if let Some(front) = weak.as_ref().and_then(Weak::upgrade) {
                    crate::clock::spawn("debug-view:build", async move {
                        front.core.views.debugs.build_all(&front).await;
                    });
                }
            }));
        });
    }

    /// Every view built again; a change meanwhile builds them once more.
    pub async fn build_all(&self, f: &Front) {
        self.again.store(true, Ordering::SeqCst);
        if self.building.swap(true, Ordering::SeqCst) {
            return;
        }
        while self.again.swap(false, Ordering::SeqCst) {
            let keys: Vec<(u64, String)> = lock(&self.views).keys().cloned().collect();
            for (conn, view) in keys {
                self.build(f, conn, &view).await;
            }
        }
        self.building.store(false, Ordering::SeqCst);
    }

    /// CONN's VIEW built again: its sessions' trees brought to their stops and filled, its lines, model and rows.
    async fn build(&self, f: &Front, conn: u64, view: &str) {
        let _gate = self.gate.lock().await;
        let key = (conn, view.to_owned());
        let Some((root, sel, opened, mut cache)) = lock(&self.views).get_mut(&key).map(|st| {
            (
                st.root.clone(),
                st.session.clone(),
                st.opened.clone(),
                std::mem::take(&mut st.trees),
            )
        }) else {
            return;
        };
        let d = f.debug.debug(f).clone();
        let snaps = d.snapshot(&root);
        let watches = d.watches(&root);
        let selected = sel
            .filter(|s| snaps.iter().any(|x| &x.id == s))
            .or_else(|| {
                snaps
                    .iter()
                    .find(|x| x.stop.is_some())
                    .map(|x| x.id.clone())
            })
            .or_else(|| snaps.first().map(|x| x.id.clone()));
        let mut sessions = Vec::with_capacity(snaps.len());
        let mut trees = HashMap::new();
        for sn in &snaps {
            let mut c = cache.remove(&sn.id).unwrap_or_default();
            refresh_tree(&mut c, sn);
            if let (Some(stop), Some(h)) = (&sn.stop, d.session(&sn.id)) {
                if selected.as_ref() == Some(&sn.id) && c.watched.as_ref() != Some(&watches) {
                    c.view.tree.watches = evaluate_all(&h, stop.frame, &watches).await;
                    c.watched = Some(watches.clone());
                }
                fill(&h, &mut c.view, &mut c.calls, &opened).await;
            }
            sessions.push(c.view.clone());
            trees.insert(sn.id.clone(), c);
        }
        let bps = bps_of(&d, &root, &snaps);
        let mut views = lock(&self.views);
        let Some(st) = views.get_mut(&key) else {
            return;
        };
        st.trees = trees;
        st.shown = selected.clone();
        // a new stop of the selected session: this stop's values become the last stop's
        let at = selected
            .as_ref()
            .and_then(|id| snaps.iter().find(|s| &s.id == id))
            .and_then(|s| s.stop.as_ref().map(|t| (s.id.clone(), t.epoch)));
        if at.is_some() && at != st.cur_at {
            let same = st.cur_at.as_ref().map(|c| &c.0) == at.as_ref().map(|a| &a.0);
            st.prev = if same {
                std::mem::take(&mut st.cur)
            } else {
                HashMap::new()
            };
            st.cur_at = at.clone();
        }
        let (ls, values) = model::lines(&Input {
            sessions: &sessions,
            selected: selected.as_deref(),
            watches: &watches,
            bps: &bps,
            opened: &st.opened,
            prev: &st.prev,
        });
        if at.is_some() {
            st.cur = values;
        }
        let ls = match &st.filter {
            Some(t) => model::filter(ls, t),
            None => ls,
        };
        st.lines = Arc::new(ls);
        let (lines, indent) = (st.lines.clone(), st.indent);
        drop(views);
        publish(f, conn, view, &lines, indent);
    }

    /// CONN's VIEW after NODE, a node of the selected session's Variables, was opened or closed, and the pages SHUT with
    /// it (an open past the page cap closes the one opened longest ago): only their subtrees are fetched, walked and sent
    /// (their lines, their model nodes and list splices in one `view-model`, their rows in one patch), the rest kept as
    /// they are. False, having done nothing, when that does not hold (a filter, another session shown, a new stop, a
    /// line with no [`model::Src`]): then the caller builds the whole view.
    async fn splice(&self, f: &Front, conn: u64, view: &str, node: &str, shut: &[String]) -> bool {
        let _gate = self.gate.lock().await;
        let key = (conn, view.to_owned());
        let d = f.debug.debug(f).clone();
        let taken = {
            let mut views = lock(&self.views);
            let Some(st) = views.get_mut(&key) else {
                return false;
            };
            let Some(sid) = st.shown.clone() else {
                return false;
            };
            let line = st.lines.iter().find(|l| l.id == node).cloned();
            let fresh = |c: &Cached| {
                d.stop_of(&sid).is_some_and(|s| {
                    !c.view.tree.stale && c.view.tree.epoch == s.epoch && c.frame == s.frame
                })
            };
            match (line, st.trees.get(&sid)) {
                (Some(line), Some(c)) if st.filter.is_none() && line.src.is_some() && fresh(c) => {
                    let c = st.trees.remove(&sid).unwrap_or_default();
                    Some((sid, line, c, st.opened.clone()))
                }
                _ => None,
            }
        };
        let Some((sid, line, mut c, opened)) = taken else {
            return false;
        };
        // fetch what NODE's subtree still needs, breadth first, as a whole build's fill would (a shut page needs none)
        if let (Some(h), Some(epoch)) = (d.session(&sid), c.view.stop.as_ref().map(|s| s.epoch)) {
            let none = HashMap::new();
            loop {
                let wants = {
                    let sessions = std::slice::from_ref(&c.view);
                    let input = Input {
                        sessions,
                        selected: Some(&sid),
                        watches: &[],
                        bps: &Bps::default(),
                        opened: &opened,
                        prev: &none,
                    };
                    model::subtree(&input, &line)
                        .map(|t| t.1)
                        .unwrap_or_default()
                };
                if wants.is_empty() {
                    break;
                }
                for w in wants {
                    fetch(&h, epoch, &mut c.view, &mut c.calls, w).await;
                }
            }
        }
        let spliced = {
            let mut views = lock(&self.views);
            let Some(st) = views.get_mut(&key) else {
                return true;
            };
            // each subtree's span (start, end, its lines now), the last first; a shut page no longer drawn has none
            let mut spans: Vec<(usize, usize, Vec<Line>)> = Vec::new();
            let mut whole = false;
            for id in shut
                .iter()
                .map(String::as_str)
                .filter(|s| *s != node)
                .chain([node])
            {
                let Some(i) = st.lines.iter().position(|l| l.id == id) else {
                    whole |= id == node;
                    continue;
                };
                let walked = {
                    let sessions = std::slice::from_ref(&c.view);
                    let input = Input {
                        sessions,
                        selected: Some(&sid),
                        watches: &[],
                        bps: &Bps::default(),
                        opened: &st.opened,
                        prev: &st.prev,
                    };
                    model::subtree(&input, &st.lines[i])
                };
                match walked {
                    Some((ls, _, values)) => {
                        st.cur.extend(values);
                        spans.push((i, model::subtree_end(&st.lines, i), ls));
                    }
                    None => whole = true,
                }
            }
            st.trees.insert(sid, c);
            spans.sort_by_key(|s| std::cmp::Reverse(s.0));
            whole |= spans.windows(2).any(|w| w[1].1 > w[0].0);
            (!whole).then(|| {
                let lines = Arc::make_mut(&mut st.lines);
                for (i, end, ls) in &spans {
                    lines.splice(*i..*end, ls.iter().cloned());
                }
                (spans, st.lines.clone(), st.indent)
            })
        };
        let Some((spans, lines, indent)) = spliced else {
            self.build(f, conn, view).await;
            return true;
        };
        let views = &f.core.views;
        let nodes = spans
            .iter()
            .map(|(i, end, ls)| {
                let nodes = ls.iter().map(|l| (l.id.clone(), model::node(l))).collect();
                (*i, end - i, nodes)
            })
            .collect();
        if !views.splice_model(f, conn, view, model::LIST, nodes) {
            publish(f, conn, view, &lines, indent);
            return true;
        }
        for class in views.classes(conn, view) {
            let key = (conn, view.to_owned(), class);
            let spliced = views.publish_spliced(f, &key, |env, _| {
                let look = RowLook::of(env, indent, 2);
                let mut images = BTreeMap::new();
                let rows = spans
                    .iter()
                    .map(|(i, end, ls)| {
                        let (rs, imgs) = rows::rows(ls, &look);
                        images.extend(imgs);
                        (*i, end - i, rs)
                    })
                    .collect();
                (rows, images.into_iter().collect())
            });
            if !spliced {
                views.publish_built(f, &key, |env, _| {
                    rows::rows(&lines, &RowLook::of(env, indent, 2))
                });
            }
        }
        true
    }

    /// KEY's rows from its view's last lines, for a class that just got its env; false when it is no such view.
    pub(super) fn env_build(&self, f: &Front, key: &Key) -> bool {
        let Some((lines, indent)) = lock(&self.views)
            .get(&(key.0, key.1.clone()))
            .map(|st| (st.lines.clone(), st.indent))
        else {
            return false;
        };
        f.core
            .views
            .publish_model(f, key.0, &key.1, model::doc(&lines));
        f.core.views.publish_built(f, key, |env, _| {
            rows::rows(&lines, &RowLook::of(env, indent, 2))
        });
        true
    }

    /// CONN's VIEW closed.
    pub(super) fn stop(&self, conn: u64, view: &str) {
        lock(&self.views).remove(&(conn, view.to_owned()));
    }

    /// CONN went.
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.views).retain(|(c, _), _| *c != conn);
    }

    /// The selected session's cached view and the line NODE of CONN's VIEW, with its parent's line.
    fn line(
        &self,
        conn: u64,
        view: &str,
        node: &str,
    ) -> Option<(Option<String>, Line, Option<Line>)> {
        let views = lock(&self.views);
        let st = views.get(&(conn, view.to_owned()))?;
        let l = st.lines.iter().find(|l| l.id == node)?.clone();
        let parent = l
            .parent
            .as_ref()
            .and_then(|p| st.lines.iter().find(|x| &x.id == p))
            .cloned();
        Some((st.shown.clone(), l, parent))
    }
}

fn field<'a>(l: &'a Line, name: &str) -> Option<&'a Value> {
    l.fields.iter().find(|(k, _)| *k == name).map(|(_, v)| v)
}

/// LINES' model and rows to every class CONN shows VIEW in.
fn publish(f: &Front, conn: u64, view: &str, lines: &Arc<Vec<Line>>, indent: u32) {
    let views = &f.core.views;
    views.publish_model(f, conn, view, model::doc(lines));
    for class in views.classes(conn, view) {
        let key = (conn, view.to_owned(), class);
        views.publish_built(f, &key, |env, _| {
            rows::rows(lines, &RowLook::of(env, indent, 2))
        });
    }
}

/// `debug/view`: CALLER's VIEW shows P's project (its open nodes kept while the project is the same).
async fn subscribe(f: &Front, c: &Caller, p: DebugView) -> Result<bool, Error> {
    let dv = &f.core.views.debugs;
    dv.hook(f);
    {
        let mut views = lock(&dv.views);
        let st = views.entry((c.conn_id, p.view.clone())).or_default();
        if st.root != p.root {
            *st = St::default();
            st.root = p.root.clone();
        }
        st.session = p.session;
        st.filter = p.filter.filter(|f| !f.is_empty());
        st.indent = p.indent.unwrap_or(INDENT);
    }
    dv.build(f, c.conn_id, &p.view).await;
    Ok(true)
}

/// `debug/expand`: a node opened or closed; "Load more frames" fetches the next page of the stopped thread's.
async fn expand(f: &Front, c: &Caller, p: DebugExpand) -> Result<bool, Error> {
    let dv = &f.core.views.debugs;
    let key = (c.conn_id, p.view.clone());
    // a variable's or a chunk's subtree alone (`DebugViews::splice`) unless the open closed other pages
    let (mut splice, mut shut) = (false, Vec::new());
    if let Some(rest) = p.node.strip_prefix("m:") {
        let (sid, tid) = rest
            .rsplit_once(':')
            .and_then(|(s, t)| Some((s.to_owned(), t.parse::<i64>().ok()?)))
            .ok_or_else(|| err(format!("no such node {}", p.node)))?;
        let d = f.debug.debug(f).clone();
        let stop = d
            .stop_of(&sid)
            .ok_or_else(|| err("the session is not stopped"))?;
        let h = d
            .session(&sid)
            .ok_or_else(|| err("the session has ended"))?;
        let more = h.more_frames(stop.epoch, tid).await.map_err(err)?;
        if let Some(c) = lock(&dv.views)
            .get_mut(&key)
            .and_then(|st| st.trees.get_mut(&sid))
        {
            let frames = c
                .view
                .thread_frames
                .entry(tid)
                .or_insert_with(|| stop.frames.clone());
            frames.extend(more);
        }
    } else {
        let mut views = lock(&dv.views);
        let st = views
            .get_mut(&key)
            .ok_or_else(|| err(format!("no Run and Debug view {}", p.view)))?;
        let gone = st.opened.set(&p.node, p.open);
        for c in st.trees.values_mut() {
            c.view.tree.forget(&gone);
        }
        if p.open {
            // the user asks for it: a capped or failed node is fetched again, past this stop's cap
            for c in st.trees.values_mut() {
                if c.view.tree.capped.remove(&p.node) | c.view.tree.failed.remove(&p.node).is_some()
                {
                    c.calls = 0;
                }
            }
        }
        splice = p.node.starts_with("v:") && gone.iter().all(|g| g.starts_with("v:"));
        shut = gone;
    }
    if !(splice && dv.splice(f, c.conn_id, &p.view, &p.node, &shut).await) {
        dv.build(f, c.conn_id, &p.view).await;
    }
    Ok(true)
}

/// `debug/watch`: the project's watch list changed; every view of it evaluates them again.
fn watch(f: &Front, p: DebugWatch) -> Result<Vec<String>, Error> {
    let d = f.debug.debug(f);
    let mut list = d.watches(&p.root);
    let at = |i: Option<u32>| {
        i.map(|i| i as usize)
            .filter(|i| *i < list.len())
            .ok_or_else(|| err("no watch at that index"))
    };
    match p.op.as_str() {
        "add" => list.push(p.expr.unwrap_or_default()),
        "edit" => {
            let i = at(p.index)?;
            list[i] = p.expr.unwrap_or_default();
        }
        "remove" => {
            let i = at(p.index)?;
            list.remove(i);
        }
        _ => {
            let i = at(p.index)?;
            let e = list.remove(i);
            let to = (p.to.unwrap_or(0) as usize).min(list.len());
            list.insert(to, e);
        }
    }
    d.set_watches(&p.root, list.clone());
    Ok(list)
}

/// `debug/set-value`: a variable or watch set (`setExpression` preferred when the adapter has it and the node an
/// `evaluateName`); its scope is fetched again.
async fn set_value(f: &Front, c: &Caller, p: DebugSetValue) -> Result<DebugValue, Error> {
    let dv = &f.core.views.debugs;
    let (shown, line, parent) = dv
        .line(c.conn_id, &p.view, &p.node)
        .ok_or_else(|| err(format!("no node {}", p.node)))?;
    let sid = shown.ok_or_else(|| err("no session is shown"))?;
    let root = lock(&dv.views)
        .get(&(c.conn_id, p.view.clone()))
        .map(|s| s.root.clone())
        .unwrap_or_default();
    let d = f.debug.debug(f).clone();
    let snap = d
        .snapshot(&root)
        .into_iter()
        .find(|s| s.id == sid)
        .ok_or_else(|| err("the session has ended"))?;
    let stop = snap.stop.ok_or_else(|| err("the session is not stopped"))?;
    let h = d
        .session(&sid)
        .ok_or_else(|| err("the session has ended"))?;
    let has = |cap: &str| snap.caps[cap].as_bool() == Some(true);
    let expr = field(&line, "evaluate_name").and_then(Value::as_str);
    let parent_ref = parent
        .as_ref()
        .and_then(|l| field(l, "reference"))
        .and_then(Value::as_i64);
    let body = match (expr, parent_ref) {
        (Some(e), _) if has("supportsSetExpression") => {
            h.request(
                "setExpression",
                json!({"expression": e, "value": p.value, "frameId": stop.frame}),
            )
            .await
        }
        (_, Some(r)) if has("supportsSetVariable") && line.kind == "var" => {
            h.request(
                "setVariable",
                json!({"variablesReference": r, "name": line.label, "value": p.value}),
            )
            .await
        }
        _ => Err("the adapter cannot set this value".to_owned()),
    }
    .map_err(err)?;
    // what changed may show anywhere: the open nodes and the watches are fetched again
    if let Some(c) = lock(&dv.views)
        .get_mut(&(c.conn_id, p.view.clone()))
        .and_then(|st| st.trees.get_mut(&sid))
    {
        c.view.tree.kids.clear();
        c.view.tree.failed.clear();
        c.calls = 0;
        c.watched = None;
    }
    dv.build(f, c.conn_id, &p.view).await;
    Ok(DebugValue {
        value: body["value"].as_str().unwrap_or(&p.value).to_owned(),
    })
}

/// `debug/data-breakpoint`: a session's data breakpoints; `add` names the variable by its container and name, or by
/// a variable node of the view (its parent's reference and its label).
async fn data_breakpoint(
    f: &Front,
    c: &Caller,
    p: DebugDataBreakpoint,
) -> Result<DebugDataBreakpoints, Error> {
    let d = f.debug.debug(f).clone();
    let (session, target) = match (&p.view, &p.node) {
        (Some(view), Some(node)) if p.op == "add" => {
            let dv = &f.core.views.debugs;
            let (shown, line, parent) = dv
                .line(c.conn_id, view, node)
                .ok_or_else(|| err(format!("no node {node}")))?;
            if line.kind != "var" {
                return Err(err("not a variable"));
            }
            let reference = parent
                .as_ref()
                .and_then(|l| field(l, "reference"))
                .and_then(Value::as_i64)
                .ok_or_else(|| err("this variable has no container to watch it in"))?;
            let sid = shown.ok_or_else(|| err("no session is shown"))?;
            (sid, Some((reference, line.label.clone())))
        }
        _ => {
            let sid = p.session.clone().unwrap_or_default();
            let target = p.reference.zip(p.name.clone());
            (sid, target)
        }
    };
    let breakpoints = match p.op.as_str() {
        "add" => {
            let (reference, name) = target.ok_or_else(|| err("no variable to watch"))?;
            d.add_data_breakpoint(&session, reference, &name, p.access_type.clone())
                .await
        }
        "remove" => {
            d.remove_data_breakpoint(&session, p.data_id.as_deref().unwrap_or_default())
                .await
        }
        _ => d.data_breakpoints(&session),
    }
    .map_err(err)?;
    Ok(DebugDataBreakpoints {
        session,
        breakpoints,
    })
}

/// `debug/evaluate`: an expression in a stopped session's frame.
async fn evaluate(f: &Front, p: DebugEvaluate) -> Result<DebugEvaluated, Error> {
    let d = f.debug.debug(f).clone();
    let h = d
        .session(&p.session)
        .ok_or_else(|| err(format!("no debug session {}", p.session)))?;
    let frame = p.frame.or_else(|| d.stop_of(&p.session).map(|s| s.frame));
    let mut args = json!({"expression": p.expr, "context": p.context});
    if let Some(fr) = frame {
        args["frameId"] = json!(fr);
    }
    let b = h.request("evaluate", args).await.map_err(err)?;
    let v = Var::of(&b);
    Ok(DebugEvaluated {
        result: v.value,
        ty: v.ty,
        reference: (v.reference > 0).then_some(v.reference),
        epoch: d.stop_of(&p.session).map(|s| s.epoch),
    })
}

/// `debug/children`: a console value's children while its stop lasts.
async fn children(f: &Front, p: DebugChildren) -> Result<DebugChildList, Error> {
    let d = f.debug.debug(f).clone();
    let h = d
        .session(&p.session)
        .ok_or_else(|| err(format!("no debug session {}", p.session)))?;
    let epoch = p
        .epoch
        .or_else(|| d.stop_of(&p.session).map(|s| s.epoch))
        .ok_or_else(|| err("the session runs: its values are gone"))?;
    let vs = h
        .variables_with(epoch, json!({"variablesReference": p.reference}))
        .await
        .map_err(err)?;
    Ok(DebugChildList {
        variables: vs
            .iter()
            .map(|v| {
                let v = Var::of(v);
                DebugChild {
                    name: v.name,
                    value: v.value,
                    ty: v.ty,
                    reference: (v.reference > 0).then_some(v.reference),
                }
            })
            .collect(),
    })
}

fn answer<T: serde::Serialize>(r: Result<T, Error>) -> Result<Value, Error> {
    r.map(|v| json!(v))
}

/// P served by the Run and Debug view's methods, or handed back (not one of theirs).
pub async fn serve(
    front: &Front,
    caller: &Caller,
    p: Params,
) -> Result<Result<Value, Error>, Box<Params>> {
    Ok(match p {
        Params::DebugView(p) => answer(subscribe(front, caller, p).await),
        Params::DebugExpand(p) => answer(expand(front, caller, p).await),
        Params::DebugWatch(p) => answer(watch(front, p)),
        Params::DebugSetValue(p) => answer(set_value(front, caller, p).await),
        Params::DebugDataBreakpoint(p) => answer(data_breakpoint(front, caller, p).await),
        Params::DebugEvaluate(p) => answer(evaluate(front, p).await),
        Params::DebugChildren(p) => answer(children(front, p).await),
        other => return Err(Box::new(other)),
    })
}
