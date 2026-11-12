//! The Run and Debug view's model (docs/develop/debugging.md, "The Run and Debug view"; spec §7): what one view
//! shows of its project's sessions, as [`Line`]s in the order drawn, and the requests that fill it ([`wants`]). Pure:
//! no I/O, no clock.
//!
//! Node ids are paths, stable across stops, so a step patches only the rows whose value changed and the editor's
//! selection survives it: a scope `v:SESSION:SCOPE`, a variable `PARENT/NAME`, a chunk `PARENT/[100..199]`, a watch
//! `w:EXPR`, a thread `t:SESSION:THREAD`, a frame `f:SESSION:THREAD:N` (its place in the stack), a run of hidden
//! frames `h:SESSION:THREAD:N`, more frames `m:SESSION:THREAD`, a session `s:SESSION`, an exception filter
//! `x:TYPE:FILTER`, a function breakpoint `fn:NAME`, a source breakpoint `b:ID`. A `/` or `%` in a name is
//! escaped (`%2F`, `%25`); a name seen twice under one parent gets `#2`, `#3`.

use crate::debug::session::Stop;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};

/// A node with more indexed children than this shows them in chunks of this many (VS Code's chunk size).
pub const CHUNK: i64 = 100;
/// The most `variables` (and `stackTrace`) calls a stop makes to fetch the expanded paths again.
pub const FETCH_CAP: usize = 200;
/// The most pages (a chunk of at most [`CHUNK`] elements) a view keeps open: opening one more closes the one opened
/// longest ago and lets its elements go, so a long look through a big list holds what 64 pages hold (spec §12).
pub const PAGE_CAP: usize = 64;

/// Whether ID is a page: a chunk (`…/[A..B]`) of at most [`CHUNK`] elements.
pub fn is_page(id: &str) -> bool {
    let last = id.rsplit('/').next().unwrap_or("");
    let Some((a, b)) = last
        .strip_prefix('[')
        .and_then(|s| s.strip_suffix(']'))
        .and_then(|s| s.split_once(".."))
    else {
        return false;
    };
    matches!((a.parse::<i64>(), b.parse::<i64>()), (Ok(a), Ok(b)) if a <= b && b - a < CHUNK)
}

/// A DAP `Variable`, `Scope` or `evaluate` answer, as the view reads it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Var {
    pub name: String,
    pub value: String,
    pub ty: Option<String>,
    pub reference: i64,
    pub named: Option<i64>,
    pub indexed: Option<i64>,
    pub evaluate_name: Option<String>,
    /// `memoryReference`: its bytes can be read (the memory view).
    pub memory: Option<String>,
    /// `presentationHint.lazy`: the value is fetched on a click.
    pub lazy: bool,
    /// A scope marked `expensive`: collapsed until opened.
    pub expensive: bool,
}

impl Var {
    pub fn of(v: &Value) -> Var {
        let s = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
        let i = |k: &str| v.get(k).and_then(Value::as_i64);
        Var {
            name: s("name").unwrap_or_default(),
            value: s("value").or_else(|| s("result")).unwrap_or_default(),
            ty: s("type").filter(|t| !t.is_empty()),
            reference: i("variablesReference").unwrap_or(0),
            named: i("namedVariables"),
            indexed: i("indexedVariables"),
            evaluate_name: s("evaluateName").filter(|e| !e.is_empty()),
            memory: s("memoryReference").filter(|m| !m.is_empty()),
            lazy: v.pointer("/presentationHint/lazy").and_then(Value::as_bool) == Some(true),
            expensive: v.get("expensive").and_then(Value::as_bool) == Some(true),
        }
    }

    /// Whether its children come in chunks.
    fn chunked(&self) -> bool {
        self.indexed.unwrap_or(0) > CHUNK
    }
}

/// NAME as one segment of a path.
pub fn seg(name: &str) -> String {
    name.replace('%', "%25").replace('/', "%2F")
}

/// The chunks of COUNT indexed children from START: [`CHUNK`] each, or [`CHUNK`] times that while there would be more
/// than [`CHUNK`] of them (so 100,000 is ten chunks of 10,000, each of which is a hundred of 100).
pub fn chunks(start: i64, count: i64) -> Vec<(i64, i64)> {
    let mut size = CHUNK;
    while (count + size - 1) / size > CHUNK {
        size *= CHUNK;
    }
    (0..(count + size - 1) / size)
        .map(|n| {
            let s = start + n * size;
            (s, size.min(start + count - s))
        })
        .collect()
}

/// What a session's view holds of its stop: the scopes, the children fetched by path, the watches' answers.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Tree {
    pub epoch: u64,
    /// The session runs again: the nodes are drawn dim and do not expand until the next stop.
    pub stale: bool,
    pub scopes: Vec<Var>,
    /// The children fetched, by the path of their parent (a chunk's own path for its page).
    pub kids: HashMap<String, Vec<Var>>,
    /// Expanded paths past this stop's fetch cap: shown closed, "expand again".
    pub capped: BTreeSet<String>,
    /// A path whose fetch failed, with the adapter's message.
    pub failed: HashMap<String, String>,
    /// Each watch's answer in the selected frame (an error kept as its message).
    pub watches: Vec<(String, Result<Var, String>)>,
}

impl Tree {
    /// Let the elements of the pages GONE go, and all under them.
    pub fn forget(&mut self, gone: &[String]) {
        if gone.is_empty() {
            return;
        }
        let under = |k: &String| {
            gone.iter().any(|g| {
                k.strip_prefix(g.as_str())
                    .is_some_and(|r| r.is_empty() || r.starts_with('/'))
            })
        };
        self.kids.retain(|k, _| !under(k));
        self.capped.retain(|k| !under(k));
        self.failed.retain(|k, _| !under(k));
    }

    /// SESSION's STOP: its scopes, with the variables the stop fetched (an expensive scope's are not).
    pub fn of_stop(session: &str, stop: &Stop) -> Tree {
        let mut t = Tree {
            epoch: stop.epoch,
            ..Tree::default()
        };
        for (path, sv) in scope_paths(session, stop) {
            if let Some(vars) = &sv.variables {
                t.kids.insert(path, vars.iter().map(Var::of).collect());
            }
            t.scopes.push(Var::of(&sv.scope));
        }
        t
    }
}

fn scope_paths<'a>(
    session: &str,
    stop: &'a Stop,
) -> Vec<(String, &'a crate::debug::session::ScopeVars)> {
    let mut seen = HashMap::new();
    stop.scopes
        .iter()
        .map(|sv| {
            let name = sv.scope.get("name").and_then(Value::as_str).unwrap_or("");
            (unique(&format!("v:{session}:"), name, &mut seen), sv)
        })
        .collect()
}

/// PARENT's child NAME's path: `#2`, `#3` for a name seen again under PARENT (SEEN counts them).
fn unique(prefix: &str, name: &str, seen: &mut HashMap<String, u32>) -> String {
    let n = seen.entry(name.to_owned()).or_insert(0);
    *n += 1;
    if *n == 1 {
        format!("{prefix}{}", seg(name))
    } else {
        format!("{prefix}{}#{n}", seg(name))
    }
}

/// Which nodes are open: each node has a default (a section, a cheap scope, the stopped thread and a session open;
/// the rest closed), and the user's opening or closing of it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Opened {
    pub open: BTreeSet<String>,
    pub shut: BTreeSet<String>,
    /// The open pages, the one opened longest ago first (at most [`PAGE_CAP`]).
    pub pages: VecDeque<String>,
}

impl Opened {
    pub fn is_open(&self, id: &str, default: bool) -> bool {
        if default {
            !self.shut.contains(id)
        } else {
            self.open.contains(id)
        }
    }

    /// ID opened (OPEN) or closed by the user. Returns the pages that closed: ID itself when it is a page closed, or
    /// the one opened longest ago when ID is one page past [`PAGE_CAP`]; their elements are to go
    /// ([`Tree::forget`]).
    pub fn set(&mut self, id: &str, open: bool) -> Vec<String> {
        if open {
            self.shut.remove(id);
            self.open.insert(id.to_owned());
        } else {
            self.open.remove(id);
            self.shut.insert(id.to_owned());
        }
        let mut gone = vec![];
        if is_page(id) {
            self.pages.retain(|p| p != id);
            if open {
                self.pages.push_back(id.to_owned());
                while self.pages.len() > PAGE_CAP {
                    let old = self.pages.pop_front().unwrap_or_default();
                    self.open.remove(&old);
                    gone.push(old);
                }
            } else {
                gone.push(id.to_owned());
            }
        }
        gone
    }
}

/// A request that fills an open node: `variables` (or `stackTrace` for a thread's frames) with ARGS, its answer kept
/// under PATH. DEPTH orders them breadth first.
#[derive(Clone, Debug, PartialEq)]
pub struct Want {
    pub path: String,
    pub command: &'static str,
    pub args: Value,
    pub depth: usize,
}

/// One session as the view shows it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SessionView {
    pub id: String,
    pub name: String,
    /// `starting`, `running` or `stopped`.
    pub state: String,
    pub stop: Option<Stop>,
    pub tree: Tree,
    /// Another thread's frames, fetched when its node was opened; the stopped thread's with more pages.
    pub thread_frames: BTreeMap<i64, Vec<Value>>,
}

/// An exception filter of an adapter type: its id, label, and whether it is on.
#[derive(Clone, Debug, PartialEq)]
pub struct Filter {
    pub ty: String,
    pub id: String,
    pub label: String,
    pub on: bool,
}

/// The project's breakpoints: the exception filters of its sessions' adapters, the function breakpoints, each file's
/// source breakpoints (the store's view of them).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Bps {
    pub filters: Vec<Filter>,
    pub functions: Vec<Value>,
    pub files: Vec<(String, Vec<Value>)>,
}

/// Everything one view is built from.
pub struct Input<'a> {
    pub sessions: &'a [SessionView],
    /// The session Variables and Watch show (none: the first stopped one).
    pub selected: Option<&'a str>,
    pub watches: &'a [String],
    pub bps: &'a Bps,
    pub opened: &'a Opened,
    /// The values of the last stop, by `evaluateName` (else path): a value that differs is marked changed.
    pub prev: &'a HashMap<String, String>,
}

/// One row of the view.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Line {
    pub id: String,
    pub parent: Option<String>,
    pub depth: usize,
    /// `section`, `scope`, `var`, `chunk`, `watch`, `session`, `thread`, `frame`, `hidden`, `label`, `more`, `filter`,
    /// `function`, `breakpoint`.
    pub kind: &'static str,
    pub label: String,
    pub value: Option<String>,
    pub ty: Option<String>,
    /// Dim text after the label: a frame's `file line:col`, a breakpoint's condition.
    pub detail: Option<String>,
    /// A thread's state (`PAUSED ON BREAKPOINT`, `RUNNING`).
    pub chip: Option<String>,
    /// Open or closed; none for a node that has no children.
    pub open: Option<bool>,
    /// A tick box (a filter, a breakpoint), ticked or not.
    pub ticked: Option<bool>,
    pub changed: bool,
    pub dim: bool,
    pub error: bool,
    /// The selected frame.
    pub current: bool,
    /// Past the stop's fetch cap: "expand again".
    pub capped: bool,
    /// A lazy value not fetched yet: `(…)`.
    pub lazy: bool,
    /// What the editor's commands read of it (session, frame, evaluateName, path, line …).
    pub fields: Vec<(&'static str, Value)>,
    /// What drew a variable's or a chunk's line, so its subtree can be walked again alone ([`subtree`]); never sent.
    pub src: Option<Src>,
}

/// What drew a line of the Variables section: a variable (or scope) of a kind, or a chunk (start, count, the reference
/// it pages).
#[derive(Clone, Debug, PartialEq)]
pub enum Src {
    Var(Var, &'static str),
    Chunk(i64, i64, i64),
}

/// The requests that fill S's open nodes not fetched yet (Variables, Watch, other threads' frames), breadth first.
/// A stale session wants nothing; nor does a capped or failed path.
pub fn wants(s: &SessionView, opened: &Opened) -> Vec<Want> {
    let watches: Vec<String> = s.tree.watches.iter().map(|(e, _)| e.clone()).collect();
    let bps = Bps::default();
    let prev = HashMap::new();
    let input = Input {
        sessions: std::slice::from_ref(s),
        selected: Some(&s.id),
        watches: &watches,
        bps: &bps,
        opened,
        prev: &prev,
    };
    let mut cx = Cx::new(&input);
    cx.all();
    let mut w = cx.wants;
    w.sort_by_key(|w| w.depth);
    w
}

/// The view's lines from INPUT, and the value of every variable and watch shown (by `evaluateName`, else path) for
/// the next stop's changed marks.
pub fn lines(input: &Input) -> (Vec<Line>, HashMap<String, String>) {
    let mut cx = Cx::new(input);
    cx.all();
    (cx.lines, cx.values)
}

/// LINES with only the rows whose label or value contains TEXT (any case), the rows above them, and the sections.
pub fn filter(lines: Vec<Line>, text: &str) -> Vec<Line> {
    let text = text.to_lowercase();
    let hit = |l: &Line| {
        l.label.to_lowercase().contains(&text)
            || l.value
                .as_ref()
                .is_some_and(|v| v.to_lowercase().contains(&text))
    };
    let mut keep: BTreeSet<String> = BTreeSet::new();
    for l in lines.iter().rev() {
        if l.kind == "section" || keep.contains(&l.id) || hit(l) {
            keep.insert(l.id.clone());
            if let Some(p) = &l.parent {
                keep.insert(p.clone());
            }
        }
    }
    lines.into_iter().filter(|l| keep.contains(&l.id)).collect()
}

/// What a walk made: its lines, the requests they still need (breadth first), the values they show.
pub type Walk = (Vec<Line>, Vec<Want>, HashMap<String, String>);

/// The lines of the selected session's Variables node LINE (a variable, a scope or a chunk) and all under it, as
/// [`lines`] would draw them from INPUT, with the requests they still need (breadth first) and the values they show;
/// None for a line not drawn by the Variables walk (no [`Src`]). An expand costs its subtree, not the view.
pub fn subtree(input: &Input, line: &Line) -> Option<Walk> {
    let src = line.src.as_ref()?;
    let parent = line.parent.as_deref()?;
    let mut cx = Cx::new(input);
    let tree = &cx.selected()?.tree;
    match src {
        Src::Var(v, kind) => cx.var(tree, line.id.clone(), parent, line.depth, v, kind),
        Src::Chunk(start, count, reference) => cx.chunk(
            tree,
            line.id.clone(),
            parent,
            line.depth,
            *start,
            *count,
            *reference,
        ),
    }
    let mut w = cx.wants;
    w.sort_by_key(|w| w.depth);
    Some((cx.lines, w, cx.values))
}

/// The index past the subtree of LINES' line I: the next line no deeper than it.
pub fn subtree_end(lines: &[Line], i: usize) -> usize {
    let depth = lines[i].depth;
    lines[i + 1..]
        .iter()
        .position(|l| l.depth <= depth)
        .map_or(lines.len(), |k| i + 1 + k)
}

/// The model node of LINE ([`doc`]).
pub fn node(l: &Line) -> Value {
    let mut fields = vec![json!(["label", l.label])];
    for (k, v) in [
        ("value", &l.value),
        ("type", &l.ty),
        ("detail", &l.detail),
        ("chip", &l.chip),
    ] {
        if let Some(v) = v {
            fields.push(json!([k, v]));
        }
    }
    for (k, on) in [
        ("dim", l.dim),
        ("error", l.error),
        ("changed", l.changed),
        ("current", l.current),
        ("capped", l.capped),
        ("lazy", l.lazy),
    ] {
        if on {
            fields.push(json!([k, 1]));
        }
    }
    if let Some(t) = l.ticked {
        fields.push(json!(["ticked", i64::from(t)]));
    }
    if l.open.is_some() {
        fields.push(json!(["openable", 1]));
    }
    for (k, v) in &l.fields {
        fields.push(json!([k, v]));
    }
    let mut node = json!({"id": l.id, "kind": l.kind, "flags": u8::from(l.open == Some(true)),
                          "fields": fields});
    if let Some(p) = &l.parent {
        node["parent"] = json!(p);
    }
    node
}

/// The model's one list: the lines' order ([`doc`]).
pub const LIST: &str = "order";

/// The model of LINES: a `tree` with a node per line (its kind, `expanded` when open, its parent) whose fields are the
/// label, the value and what the commands read; the list `order` in the lines' order.
pub fn doc(lines: &[Line]) -> super::super::model::Doc {
    let mut d = super::super::model::Doc {
        descriptor: json!({
            "scheme": "tree",
            "chain_kinds": [],
            "match_fields": ["label"],
            "lists": ["order"],
            "classes": ["selected", "match", "dim", "ticked"],
            "flags": ["expanded"],
            "forms": [],
            "start": "order",
        }),
        ..Default::default()
    };
    let mut order = Vec::with_capacity(lines.len());
    for l in lines {
        d.nodes.insert(l.id.clone(), node(l));
        order.push(l.id.clone());
    }
    d.lists.insert(LIST.into(), order);
    d
}

/// The walk over the view: the lines, the requests the open nodes still need, and the values shown.
struct Cx<'a> {
    input: &'a Input<'a>,
    lines: Vec<Line>,
    wants: Vec<Want>,
    values: HashMap<String, String>,
}

/// The children of a variable or chunk: variables (by their path) and chunks (path, start, count, the reference
/// they page).
enum Kid {
    Var(String, Var),
    Chunk(String, i64, i64, i64),
}

fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

fn reason_chip(reason: &str) -> String {
    match reason {
        "breakpoint" | "function breakpoint" | "data breakpoint" | "instruction breakpoint" => {
            "PAUSED ON BREAKPOINT".into()
        }
        "exception" => "PAUSED ON EXCEPTION".into(),
        "step" | "goto" => "PAUSED ON STEP".into(),
        "entry" => "PAUSED ON ENTRY".into(),
        _ => "PAUSED".into(),
    }
}

fn subtle(f: &Value) -> bool {
    f.get("presentationHint").and_then(Value::as_str) == Some("subtle")
        || f.pointer("/source/presentationHint")
            .and_then(Value::as_str)
            == Some("deemphasize")
}

impl<'a> Cx<'a> {
    fn new(input: &'a Input<'a>) -> Self {
        Cx {
            input,
            lines: Vec::new(),
            wants: Vec::new(),
            values: HashMap::new(),
        }
    }

    fn selected(&self) -> Option<&'a SessionView> {
        let ss = self.input.sessions;
        match self.input.selected {
            Some(id) => ss.iter().find(|s| s.id == id),
            None => ss.iter().find(|s| s.stop.is_some()).or(ss.first()),
        }
    }

    fn push(&mut self, l: Line) {
        self.lines.push(l);
    }

    fn want(&mut self, tree: &Tree, path: &str, command: &'static str, args: Value, depth: usize) {
        if tree.stale || tree.capped.contains(path) || tree.failed.contains_key(path) {
            return;
        }
        self.wants.push(Want {
            path: path.to_owned(),
            command,
            args,
            depth,
        });
    }

    /// A section's header; whether it is open.
    fn section(&mut self, name: &str, title: &str) -> bool {
        let id = format!("section:{name}");
        let open = self.input.opened.is_open(&id, true);
        self.push(Line {
            id,
            kind: "section",
            label: title.into(),
            open: Some(open),
            ..Line::default()
        });
        open
    }

    fn all(&mut self) {
        if self.section("variables", "VARIABLES") {
            self.variables();
        }
        if self.section("watch", "WATCH") {
            self.watch();
        }
        if self.section("callstack", "CALL STACK") {
            self.call_stack();
        }
        if self.section("breakpoints", "BREAKPOINTS") {
            self.breakpoints();
        }
    }

    fn variables(&mut self) {
        let Some(s) = self.selected() else { return };
        let tree = &s.tree;
        let mut seen = HashMap::new();
        for scope in &tree.scopes {
            let id = unique(&format!("v:{}:", s.id), &scope.name, &mut seen);
            self.var(tree, id, "section:variables", 1, scope, "scope");
        }
    }

    /// VAR's resolved form at ID: a lazy one fetched shows its one child's value (its own children then come from
    /// `ID/(…)`); whether it is still waiting for its click; the key its children are kept under.
    fn resolve(tree: &Tree, id: &str, var: &Var) -> (Var, bool, String) {
        if !(var.lazy && var.reference > 0) {
            return (var.clone(), false, id.to_owned());
        }
        match tree.kids.get(id).map(Vec::as_slice) {
            Some([one]) => (
                Var {
                    name: var.name.clone(),
                    evaluate_name: var.evaluate_name.clone(),
                    lazy: false,
                    ..one.clone()
                },
                false,
                format!("{id}/(…)"),
            ),
            _ => (var.clone(), true, id.to_owned()),
        }
    }

    /// VAR's children kept under KEY, their paths under PREFIX; Err with the request that fetches them.
    fn kids(tree: &Tree, key: &str, prefix: &str, var: &Var) -> Result<Vec<Kid>, Value> {
        let mut out = Vec::new();
        let mut seen = HashMap::new();
        let mut named = |vs: &Vec<Var>, out: &mut Vec<Kid>| {
            for v in vs {
                out.push(Kid::Var(
                    unique(&format!("{prefix}/"), &v.name, &mut seen),
                    v.clone(),
                ));
            }
        };
        if var.chunked() {
            if var.named != Some(0) {
                match tree.kids.get(key) {
                    Some(vs) => named(vs, &mut out),
                    None => {
                        return Err(
                            json!({"variablesReference": var.reference, "filter": "named"}),
                        );
                    }
                }
            }
            for (s, c) in chunks(0, var.indexed.unwrap_or(0)) {
                out.push(Kid::Chunk(
                    format!("{prefix}/[{s}..{}]", s + c - 1),
                    s,
                    c,
                    var.reference,
                ));
            }
            return Ok(out);
        }
        match tree.kids.get(key) {
            Some(vs) => named(vs, &mut out),
            None => return Err(json!({"variablesReference": var.reference})),
        }
        Ok(out)
    }

    #[allow(clippy::too_many_arguments)]
    fn var(
        &mut self,
        tree: &Tree,
        id: String,
        parent: &str,
        depth: usize,
        var: &Var,
        kind: &'static str,
    ) {
        let (eff, pending, key) = Self::resolve(tree, &id, var);
        let has_kids = eff.reference > 0 && !pending;
        let capped = tree.capped.contains(&id) || tree.capped.contains(&key);
        let wanted = self
            .input
            .opened
            .is_open(&id, kind == "scope" && !var.expensive);
        // an old stop's open nodes stay open (dim); nothing is fetched for them
        let open = has_kids && wanted && !capped;
        let value_key = eff.evaluate_name.clone().unwrap_or_else(|| id.clone());
        let mut changed = false;
        if kind != "scope" && !pending {
            changed = !tree.stale
                && self
                    .input
                    .prev
                    .get(&value_key)
                    .is_some_and(|p| *p != eff.value);
            self.values.insert(value_key, eff.value.clone());
        }
        let mut fields = vec![];
        if let Some(e) = &eff.evaluate_name {
            fields.push(("evaluate_name", json!(e)));
        }
        if eff.reference > 0 {
            fields.push(("reference", json!(eff.reference)));
        }
        if let Some(m) = &eff.memory {
            fields.push(("memory_reference", json!(m)));
        }
        if kind == "scope" && var.expensive {
            fields.push(("expensive", json!(1)));
        }
        self.push(Line {
            id: id.clone(),
            parent: Some(parent.to_owned()),
            depth,
            kind,
            label: eff.name.clone(),
            value: (kind != "scope" && !pending).then(|| eff.value.clone()),
            ty: eff.ty.clone(),
            open: (has_kids && !tree.stale).then_some(open),
            changed,
            dim: tree.stale,
            capped,
            lazy: pending,
            fields,
            src: Some(Src::Var(var.clone(), kind)),
            ..Line::default()
        });
        if pending && wanted {
            self.want(
                tree,
                &id,
                "variables",
                json!({"variablesReference": var.reference}),
                depth,
            );
        }
        if open {
            self.children(tree, &key, &id, depth, &eff);
        }
    }

    fn children(&mut self, tree: &Tree, key: &str, id: &str, depth: usize, var: &Var) {
        match Self::kids(tree, key, id, var) {
            Ok(kids) => {
                for k in kids {
                    match k {
                        Kid::Var(path, v) => self.var(tree, path, id, depth + 1, &v, "var"),
                        Kid::Chunk(path, s, c, r) => self.chunk(tree, path, id, depth + 1, s, c, r),
                    }
                }
            }
            Err(args) => self.want(tree, key, "variables", args, depth),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn chunk(
        &mut self,
        tree: &Tree,
        id: String,
        parent: &str,
        depth: usize,
        start: i64,
        count: i64,
        reference: i64,
    ) {
        let open = self.input.opened.is_open(&id, false) && !tree.capped.contains(&id);
        self.push(Line {
            id: id.clone(),
            parent: Some(parent.to_owned()),
            depth,
            kind: "chunk",
            label: format!("[{start} … {}]", start + count - 1),
            open: (!tree.stale).then_some(open),
            dim: tree.stale,
            capped: tree.capped.contains(&id),
            fields: vec![("reference", json!(reference))],
            src: Some(Src::Chunk(start, count, reference)),
            ..Line::default()
        });
        if !open {
            return;
        }
        if count > CHUNK {
            for (s, c) in chunks(start, count) {
                self.chunk(
                    tree,
                    format!("{id}/[{s}..{}]", s + c - 1),
                    &id,
                    depth + 1,
                    s,
                    c,
                    reference,
                );
            }
            return;
        }
        match tree.kids.get(&id) {
            Some(vs) => {
                let mut seen = HashMap::new();
                for v in vs.clone() {
                    let path = unique(&format!("{id}/"), &v.name, &mut seen);
                    self.var(tree, path, &id, depth + 1, &v, "var");
                }
            }
            None => self.want(
                tree,
                &id,
                "variables",
                json!({"variablesReference": reference, "filter": "indexed", "start": start, "count": count}),
                depth,
            ),
        }
    }

    fn watch(&mut self) {
        let s = self.selected().filter(|s| s.stop.is_some() || s.tree.stale);
        let mut seen = HashMap::new();
        for expr in self.input.watches {
            let id = unique("w:", expr, &mut seen);
            let answer = s.and_then(|s| {
                s.tree
                    .watches
                    .iter()
                    .find(|(e, _)| e == expr)
                    .map(|(_, a)| (s, a))
            });
            match answer {
                Some((s, Ok(v))) => {
                    let v = Var {
                        name: expr.clone(),
                        evaluate_name: Some(expr.clone()),
                        ..v.clone()
                    };
                    self.var(&s.tree, id, "section:watch", 1, &v, "watch");
                }
                Some((s, Err(m))) => self.push(Line {
                    id,
                    parent: Some("section:watch".into()),
                    depth: 1,
                    kind: "watch",
                    label: expr.clone(),
                    value: Some(m.clone()),
                    error: true,
                    dim: s.tree.stale,
                    ..Line::default()
                }),
                None => self.push(Line {
                    id,
                    parent: Some("section:watch".into()),
                    depth: 1,
                    kind: "watch",
                    label: expr.clone(),
                    dim: true,
                    ..Line::default()
                }),
            }
        }
    }

    fn call_stack(&mut self) {
        let many = self.input.sessions.len() >= 2;
        for s in self.input.sessions {
            let (parent, depth) = if many {
                let id = format!("s:{}", s.id);
                let open = self.input.opened.is_open(&id, true);
                let chip = match &s.stop {
                    Some(st) => reason_chip(&st.reason),
                    None => s.state.to_uppercase(),
                };
                self.push(Line {
                    id: id.clone(),
                    parent: Some("section:callstack".into()),
                    depth: 1,
                    kind: "session",
                    label: s.name.clone(),
                    chip: Some(chip),
                    open: Some(open),
                    fields: vec![("session", json!(s.id))],
                    ..Line::default()
                });
                if !open {
                    continue;
                }
                (id, 2)
            } else {
                ("section:callstack".to_owned(), 1)
            };
            let Some(stop) = &s.stop else { continue };
            for t in &stop.threads {
                let Some(tid) = t.get("id").and_then(Value::as_i64) else {
                    continue;
                };
                let id = format!("t:{}:{tid}", s.id);
                let stopped = tid == stop.thread;
                let open = self.input.opened.is_open(&id, stopped);
                let chip = if stopped {
                    reason_chip(&stop.reason)
                } else if stop.all_threads {
                    "PAUSED".into()
                } else {
                    "RUNNING".into()
                };
                self.push(Line {
                    id: id.clone(),
                    parent: Some(parent.clone()),
                    depth,
                    kind: "thread",
                    label: t
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_owned(),
                    chip: Some(chip),
                    open: Some(open),
                    fields: vec![("session", json!(s.id)), ("thread", json!(tid))],
                    ..Line::default()
                });
                if !open {
                    continue;
                }
                // the stopped thread's frames are the stop's, with the pages "Load more frames" fetched
                let frames: &[Value] = if let Some(f) = s.thread_frames.get(&tid) {
                    f
                } else if stopped {
                    &stop.frames
                } else {
                    self.want(
                        &s.tree,
                        &id,
                        "stackTrace",
                        json!({"threadId": tid, "startFrame": 0, "levels": 20}),
                        depth,
                    );
                    continue;
                };
                self.frames(
                    s,
                    tid,
                    &id,
                    depth + 1,
                    frames,
                    stopped.then_some(stop.frame),
                );
                let total = stop.total_frames.unwrap_or(0);
                if stopped && total > frames.len() as i64 {
                    self.push(Line {
                        id: format!("m:{}:{tid}", s.id),
                        parent: Some(id.clone()),
                        depth: depth + 1,
                        kind: "more",
                        label: "Load more frames".into(),
                        fields: vec![("session", json!(s.id)), ("thread", json!(tid))],
                        ..Line::default()
                    });
                }
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn frames(
        &mut self,
        s: &SessionView,
        tid: i64,
        parent: &str,
        depth: usize,
        frames: &[Value],
        current: Option<i64>,
    ) {
        let mut n = 0;
        while n < frames.len() {
            let run = frames[n..].iter().take_while(|f| subtle(f)).count();
            if run >= 2 {
                let id = format!("h:{}:{tid}:{n}", s.id);
                let open = self.input.opened.is_open(&id, false);
                self.push(Line {
                    id: id.clone(),
                    parent: Some(parent.to_owned()),
                    depth,
                    kind: "hidden",
                    label: format!("{run} frames hidden"),
                    open: Some(open),
                    dim: true,
                    ..Line::default()
                });
                if open {
                    for (k, f) in frames[n..n + run].iter().enumerate() {
                        self.frame(s, tid, n + k, &id, depth + 1, f, current);
                    }
                }
                n += run;
                continue;
            }
            self.frame(s, tid, n, parent, depth, &frames[n], current);
            n += 1;
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn frame(
        &mut self,
        s: &SessionView,
        tid: i64,
        n: usize,
        parent: &str,
        depth: usize,
        f: &Value,
        current: Option<i64>,
    ) {
        let fid = f.get("id").and_then(Value::as_i64).unwrap_or(0);
        let name = f
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned();
        if f.get("presentationHint").and_then(Value::as_str) == Some("label") {
            self.push(Line {
                id: format!("f:{}:{tid}:{n}", s.id),
                parent: Some(parent.to_owned()),
                depth,
                kind: "label",
                label: name,
                dim: true,
                ..Line::default()
            });
            return;
        }
        let src = f.get("source");
        let path = src.and_then(|s| s.get("path")).and_then(Value::as_str);
        let file = src
            .and_then(|s| s.get("name"))
            .and_then(Value::as_str)
            .or(path.map(basename));
        let line = f.get("line").and_then(Value::as_i64).unwrap_or(0);
        let col = f.get("column").and_then(Value::as_i64).filter(|c| *c > 0);
        let detail = file.map(|file| match col {
            Some(c) => format!("{file} {line}:{c}"),
            None => format!("{file} {line}"),
        });
        let mut fields = vec![
            ("session", json!(s.id)),
            ("thread", json!(tid)),
            ("frame", json!(fid)),
            ("line", json!(line)),
        ];
        if let Some(p) = path {
            fields.push(("path", json!(p)));
        }
        if let Some(r) = src
            .and_then(|s| s.get("sourceReference"))
            .and_then(Value::as_i64)
            .filter(|r| *r > 0)
        {
            fields.push(("ref", json!(r)));
        }
        self.push(Line {
            id: format!("f:{}:{tid}:{n}", s.id),
            parent: Some(parent.to_owned()),
            depth,
            kind: "frame",
            label: name,
            detail,
            current: current == Some(fid),
            dim: subtle(f) || s.tree.stale,
            fields,
            ..Line::default()
        });
    }

    fn breakpoints(&mut self) {
        let bps = self.input.bps;
        let parent = Some("section:breakpoints".to_owned());
        for f in &bps.filters {
            self.push(Line {
                id: format!("x:{}:{}", f.ty, f.id),
                parent: parent.clone(),
                depth: 1,
                kind: "filter",
                label: f.label.clone(),
                ticked: Some(f.on),
                fields: vec![("type", json!(f.ty)), ("filter", json!(f.id))],
                ..Line::default()
            });
        }
        let mut seen = HashMap::new();
        for f in &bps.functions {
            let name = f.get("name").and_then(Value::as_str).unwrap_or("");
            self.push(Line {
                id: unique("fn:", name, &mut seen),
                parent: parent.clone(),
                depth: 1,
                kind: "function",
                label: name.to_owned(),
                detail: f
                    .get("condition")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                fields: vec![("name", json!(name))],
                ..Line::default()
            });
        }
        for (path, list) in &bps.files {
            for b in list {
                let Some(bid) = b.get("id").and_then(Value::as_u64) else {
                    continue;
                };
                let line = b.get("line").and_then(Value::as_u64).unwrap_or(0);
                let text = |k: &str| b.get(k).and_then(Value::as_str).map(str::to_owned);
                let verified = b.get("verified").and_then(Value::as_bool) == Some(true);
                let mut fields = vec![
                    ("id", json!(bid)),
                    ("path", json!(path)),
                    ("line", json!(line)),
                    ("verified", json!(i64::from(verified))),
                ];
                if let Some(m) = text("message") {
                    fields.push(("message", json!(m)));
                }
                self.push(Line {
                    id: format!("b:{bid}"),
                    parent: parent.clone(),
                    depth: 1,
                    kind: "breakpoint",
                    label: format!("{}:{line}", basename(path)),
                    detail: text("condition").or(text("log")).or(text("hit")),
                    ticked: Some(b.get("enabled").and_then(Value::as_bool) != Some(false)),
                    dim: !verified,
                    fields,
                    ..Line::default()
                });
            }
        }
    }
}
