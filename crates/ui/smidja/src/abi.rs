//! The C door (design §12): one entry point, `smidja_call`, on the thread that holds Emacs's global lock.
//!
//! C passes an op (a number from [`smidja_op`], which maps the op's name) and its arguments as flat values in prefix
//! order: nil, integers, floats, strings, symbols, and lists (a list token's `int_` counts the elements that follow).
//! The answer comes back the same way. No Lisp object reaches Rust and Rust never calls Emacs: Sjá's pattern.
//!
//! One workbench per process (`reset` makes a fresh one). The argument forms (README "The door"):
//! - ids (windows, groups, tabs, overlays) and versions are integers; an origin is the symbol `user` or `program`;
//! - a ref is `(file PATH [AT])`, `(buffer ID NAME)`, `(page KIND [KEY])`, `(session ID)` or `(output CHANNEL)`;
//! - options and fields are property lists with keyword keys (`:group 3 :focus t`); a key absent is "not given";
//! - a refused intent answers `(refused REASON)`; a bad argument is `SMIDJA_E_ARG`, an unknown op `SMIDJA_E_OP`.
//!
//! The `trace` op is the door's trace sink: while on, each call records its op and microseconds (`smidja.call`).

use crate::chrome::ChromeDesc;
use crate::decl::Decl;
use crate::focus::{BottomRef, Dir, FocusTarget, Vis};
use crate::intent::{How, OpenOpts, TabFields, Target};
use crate::layout::{Dir4, MoveTarget, Side};
use crate::model::{
    Axis, EdgeKey, Focus, GroupId, Node, Origin, OverlayId, OverlayKind, PlaceState, Rect, Ref,
    Refusal, Region, RightTab, SideFold, Source, TabId, Version, WinId, WinSize, Workbench,
};
use crate::multi::TearOut;
use crate::persist::Resolved;
use crate::preset::{CenterSpec, Preset, SideSpec};
use crate::query::{Snapshot, Token};
use std::cell::RefCell;
use std::time::Instant;

pub const SMIDJA_OK: i32 = 0;
pub const SMIDJA_E_PANIC: i32 = -1;
pub const SMIDJA_E_ARG: i32 = -2;
pub const SMIDJA_E_OP: i32 = -3;

pub const SMIDJA_NIL: i32 = 0;
pub const SMIDJA_INT: i32 = 1;
pub const SMIDJA_STR: i32 = 2;
pub const SMIDJA_LIST: i32 = 3;
pub const SMIDJA_SYM: i32 = 4;
pub const SMIDJA_FLOAT: i32 = 5;

/// One flat value, in or out. Layout equals `smidja_val` in `include/smidja.h`.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct SmidjaVal {
    pub tag: i32,
    pub int_: i64,
    pub float_: f64,
    pub ptr: *const u8,
    pub len: usize,
}

/// A value as a tree.
#[derive(Clone, Debug, PartialEq)]
pub enum Val {
    Nil,
    Int(i64),
    Float(f64),
    Str(String),
    Sym(String),
    List(Vec<Val>),
}

/// The ops, by number (the index). §12's list, then the door's own and the restore steps.
pub const OPS: &[&str] = &[
    "declare",
    "window_new",
    "window_close",
    "set_window_size",
    "set_monitors",
    "open",
    "pin",
    "close",
    "reopen_closed",
    "select",
    "show_context",
    "navigate",
    "overlay",
    "dismiss",
    "focus",
    "cycle_region",
    "side",
    "resize",
    "bottom",
    "split",
    "move_tab",
    "swap",
    "stack",
    "focus_dir",
    "full_size",
    "resize_split",
    "close_group",
    "tear_out",
    "apply_preset",
    "restore_previous_layout",
    "update_tab",
    "set_attention",
    "set_edges",
    "begin_temp_layout",
    "end_temp_layout",
    "buffer_gone",
    "realisation",
    "chrome",
    "query",
    "snapshot",
    "restore",
    "save",
    "load",
    // the door's own
    "reset",
    "trace",
    "version",
    // more intents and reads
    "pin_detail",
    "next_layout",
    "save_project_layout",
    "set_project",
    "set_place_state",
    "roles",
    "fold",
    "resolve",
    "restore_tick",
    "pending_refs",
    "take_notices",
];

/// The ops of §12 (the first 43 of [`OPS`]).
pub const SECTION_12: usize = 43;

/// The last answer's tokens and the bytes their strings point into.
type Answer = (Vec<SmidjaVal>, Vec<Box<[u8]>>);

struct Door {
    wb: Workbench,
    snapshots: Vec<Snapshot>,
    trace: Option<Vec<(&'static str, u64)>>,
    /// The chrome the glue last built per OS window (what is on screen): the `chrome` op's answer, the hit tests'.
    chrome: Vec<ChromeDesc>,
}

thread_local! {
    static DOOR: RefCell<Door> = RefCell::new(Door {
        wb: Workbench::new(),
        snapshots: Vec::new(),
        trace: None,
        chrome: Vec::new(),
    });
    /// The last answer's tokens and the bytes their strings point into.
    static ANSWER: RefCell<Answer> = const { RefCell::new((Vec::new(), Vec::new())) };
}

/// Why a call has no answer.
#[derive(Debug, PartialEq)]
pub enum Bad {
    Arg(String),
    Op,
}

type R<T> = Result<T, Bad>;

fn bad<T>(what: impl Into<String>) -> R<T> {
    Err(Bad::Arg(what.into()))
}

/// The number of the op named NAME, or -1.
pub fn op_number(name: &str) -> i32 {
    let name = name.replace('-', "_");
    OPS.iter().position(|o| *o == name).map_or(-1, |i| i as i32)
}

/// The workbench, for the glue (hit tests and chrome read it without a Lisp call).
pub fn with_workbench<T>(f: impl FnOnce(&mut Workbench) -> T) -> T {
    DOOR.with(|d| f(&mut d.borrow_mut().wb))
}

/// How many door calls ran (each one is a Lisp call): chrome's hover, drag and scroll paths never add to it.
pub fn calls() -> u64 {
    CALLS.load(std::sync::atomic::Ordering::Relaxed)
}

static CALLS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Keep DESC as its window's chrome on screen (the glue, after it built the scene).
pub fn set_chrome(desc: ChromeDesc) {
    DOOR.with(|d| {
        let mut d = d.borrow_mut();
        d.chrome.retain(|c| c.window != desc.window);
        d.chrome.push(desc);
    })
}

/// F over window W's chrome on screen, if any.
pub fn with_chrome<T>(w: u64, f: impl FnOnce(Option<&ChromeDesc>) -> T) -> T {
    DOOR.with(|d| f(d.borrow().chrome.iter().find(|c| c.window == w)))
}

// ---- reading arguments

struct Args<'a> {
    v: &'a [Val],
    at: usize,
}

impl<'a> Args<'a> {
    fn next(&mut self) -> &'a Val {
        let x = self.v.get(self.at).unwrap_or(&Val::Nil);
        self.at += 1;
        x
    }
    fn int(&mut self) -> R<i64> {
        int(self.next())
    }
    fn id(&mut self) -> R<u64> {
        u64::try_from(self.int()?).or_else(|_| bad("a negative id"))
    }
    fn str(&mut self) -> R<String> {
        string(self.next())
    }
    fn origin(&mut self) -> R<Origin> {
        match sym(self.next())?.as_str() {
            "user" => Ok(Origin::User),
            "program" => Ok(Origin::Program),
            o => bad(format!("an origin: {o}")),
        }
    }
}

fn int(v: &Val) -> R<i64> {
    match v {
        Val::Int(i) => Ok(*i),
        _ => bad(format!("an integer, not {v:?}")),
    }
}

fn float(v: &Val) -> R<f64> {
    match v {
        Val::Int(i) => Ok(*i as f64),
        Val::Float(f) => Ok(*f),
        _ => bad(format!("a number, not {v:?}")),
    }
}

fn string(v: &Val) -> R<String> {
    match v {
        Val::Str(s) => Ok(s.clone()),
        _ => bad(format!("a string, not {v:?}")),
    }
}

fn opt_string(v: &Val) -> R<Option<String>> {
    match v {
        Val::Nil => Ok(None),
        v => string(v).map(Some),
    }
}

fn sym(v: &Val) -> R<String> {
    match v {
        Val::Sym(s) => Ok(s.clone()),
        _ => bad(format!("a symbol, not {v:?}")),
    }
}

fn list(v: &Val) -> R<&[Val]> {
    match v {
        Val::List(xs) => Ok(xs),
        Val::Nil => Ok(&[]),
        _ => bad(format!("a list, not {v:?}")),
    }
}

fn truthy(v: &Val) -> bool {
    !matches!(v, Val::Nil)
}

/// A head symbol and its rest: `(HEAD REST...)` or a bare `HEAD`.
fn form(v: &Val) -> R<(String, &[Val])> {
    match v {
        Val::Sym(s) => Ok((s.clone(), &[])),
        Val::List(xs) if !xs.is_empty() => Ok((sym(&xs[0])?, &xs[1..])),
        _ => bad(format!("a form, not {v:?}")),
    }
}

/// The value of KEY (a keyword, `:group`) in the property list PL: None when absent.
fn prop<'a>(pl: &'a [Val], key: &str) -> Option<&'a Val> {
    pl.chunks(2).find_map(|c| match c {
        [Val::Sym(k), v] if k == key => Some(v),
        _ => None,
    })
}

fn nth(xs: &[Val], i: usize) -> &Val {
    xs.get(i).unwrap_or(&Val::Nil)
}

fn r#ref(v: &Val) -> R<Ref> {
    let (h, r) = form(v)?;
    Ok(match h.as_str() {
        "file" => Ref::File {
            path: string(nth(r, 0))?,
            at: opt_string(nth(r, 1))?,
        },
        "buffer" => Ref::Buffer {
            id: string(nth(r, 0))?,
            name: string(nth(r, 1))?,
        },
        "page" => Ref::Page {
            page_kind: string(nth(r, 0))?,
            key: opt_string(nth(r, 1))?,
        },
        "session" => Ref::Session {
            id: string(nth(r, 0))?,
        },
        "output" => Ref::Output {
            channel: string(nth(r, 0))?,
        },
        h => return bad(format!("a ref: {h}")),
    })
}

fn region(v: &Val) -> R<Region> {
    Ok(match sym(v)?.as_str() {
        "rail" => Region::Rail,
        "left" => Region::Left,
        "center" => Region::Center,
        "right" => Region::Right,
        "bottom" => Region::Bottom,
        r => return bad(format!("a region: {r}")),
    })
}

fn right_tab(v: &Val) -> R<RightTab> {
    let s = sym(v)?;
    RightTab::from_name(&s).map_or_else(|| bad(format!("a right tab: {s}")), Ok)
}

fn vis(v: &Val) -> R<Vis> {
    Ok(match sym(v)?.as_str() {
        "show" => Vis::Show,
        "hide" => Vis::Hide,
        "toggle" => Vis::Toggle,
        x => return bad(format!("show, hide or toggle: {x}")),
    })
}

fn dir4(v: &Val) -> R<Dir4> {
    Ok(match sym(v)?.as_str() {
        "left" => Dir4::Left,
        "right" => Dir4::Right,
        "up" => Dir4::Up,
        "down" => Dir4::Down,
        x => return bad(format!("a direction: {x}")),
    })
}

fn side(v: &Val) -> R<Side> {
    Ok(match sym(v)?.as_str() {
        "right" => Side::Right,
        "down" => Side::Down,
        x => return bad(format!("right or down: {x}")),
    })
}

pub const OVERLAY_KINDS: &[(&str, OverlayKind)] = &[
    ("palette", OverlayKind::Palette),
    ("quick-open", OverlayKind::QuickOpen),
    ("switcher", OverlayKind::Switcher),
    ("menu", OverlayKind::Menu),
    ("toast", OverlayKind::Toast),
    ("card", OverlayKind::Card),
    ("quick-help", OverlayKind::QuickHelp),
    ("find-bar", OverlayKind::FindBar),
    ("debug-toolbar", OverlayKind::DebugToolbar),
    ("completion", OverlayKind::Completion),
    ("minibuffer", OverlayKind::Minibuffer),
    ("side", OverlayKind::Side),
];

fn overlay_kind(v: &Val) -> R<OverlayKind> {
    let s = sym(v)?;
    OVERLAY_KINDS
        .iter()
        .find(|(n, _)| *n == s)
        .map_or_else(|| bad(format!("an overlay kind: {s}")), |(_, k)| Ok(*k))
}

fn overlay_name(k: OverlayKind) -> &'static str {
    OVERLAY_KINDS
        .iter()
        .find(|(_, x)| *x == k)
        .map_or("?", |(n, _)| n)
}

fn win_size(v: &Val) -> R<WinSize> {
    let (h, r) = form(v)?;
    let a = u32::try_from(int(nth(r, 0))?).or_else(|_| bad("a size"))?;
    let b = u32::try_from(int(nth(r, 1))?).or_else(|_| bad("a size"))?;
    match h.as_str() {
        "px" => Ok(WinSize::Px { w: a, h: b }),
        "cells" => Ok(WinSize::Cells { cols: a, lines: b }),
        x => bad(format!("px or cells: {x}")),
    }
}

fn edge_key(v: &Val) -> R<EdgeKey> {
    let (h, r) = form(v)?;
    match h.as_str() {
        "region" => Ok(EdgeKey::Region(region(nth(r, 0))?)),
        "group" => Ok(EdgeKey::Group(GroupId(int(nth(r, 0))? as u64))),
        "section" => Ok(EdgeKey::Section(
            u32::try_from(int(nth(r, 0))?).map_err(|_| Bad::Arg("section index".into()))?,
        )),
        x => bad(format!("region, group or section: {x}")),
    }
}

fn rect(v: &Val) -> R<Rect> {
    let xs = list(v)?;
    let n = |i| -> R<i32> { i32::try_from(int(nth(xs, i))?).or_else(|_| bad("a coordinate")) };
    Ok(Rect {
        x: n(0)?,
        y: n(1)?,
        w: n(2)?,
        h: n(3)?,
    })
}

fn center_spec(v: &Val) -> R<CenterSpec> {
    let (h, r) = form(v)?;
    Ok(match h.as_str() {
        "page" => CenterSpec::Page(string(nth(r, 0))?),
        "recent" => CenterSpec::Recent,
        "zen" => CenterSpec::Zen,
        "split" => CenterSpec::Split(
            Box::new(center_spec(nth(r, 0))?),
            Box::new(center_spec(nth(r, 1))?),
        ),
        x => return bad(format!("a center spec: {x}")),
    })
}

fn side_spec(v: Option<&Val>) -> R<SideSpec> {
    let Some(v) = v else {
        return Ok(SideSpec::AsItWas);
    };
    let (h, r) = form(v)?;
    Ok(match h.as_str() {
        "show" => SideSpec::Show(opt_string(nth(r, 0))?),
        "hide" => SideSpec::Hide,
        "as-it-was" => SideSpec::AsItWas,
        x => return bad(format!("a side spec: {x}")),
    })
}

fn opt_prop_string(pl: &[Val], key: &str) -> R<Option<String>> {
    prop(pl, key).map_or(Ok(None), opt_string)
}

fn decl(v: &Val) -> R<Decl> {
    let (h, r) = form(v)?;
    let name = string(nth(r, 0))?;
    let pl = r.get(1..).unwrap_or(&[]);
    Ok(match h.as_str() {
        "tab-kind" => Decl::TabKind { kind: name },
        "bottom-kind" => Decl::BottomKind { kind: name },
        "selection-kind" => Decl::SelectionKind {
            kind: name,
            detail: opt_prop_string(pl, ":detail")?,
        },
        "page-kind" => Decl::PageKind {
            title: opt_prop_string(pl, ":title")?.unwrap_or_else(|| name.clone()),
            icon: opt_prop_string(pl, ":icon")?.unwrap_or_default(),
            place: opt_prop_string(pl, ":place")?,
            selects: opt_prop_string(pl, ":selects")?,
            view: opt_prop_string(pl, ":view")?,
            kind: name,
        },
        "place" => Decl::Place {
            icon: opt_prop_string(pl, ":icon")?.unwrap_or_default(),
            view: opt_prop_string(pl, ":view")?,
            sections: prop(pl, ":sections")
                .map_or(Ok(&[][..]), list)?
                .iter()
                .map(string)
                .collect::<R<_>>()?,
            home: opt_prop_string(pl, ":home")?,
            foot: prop(pl, ":foot").is_some_and(truthy),
            place: name,
        },
        "preset" => Decl::Preset(Preset {
            center: center_spec(prop(pl, ":center").unwrap_or(&Val::Sym("recent".into())))?,
            left: side_spec(prop(pl, ":left"))?,
            right: side_spec(prop(pl, ":right"))?,
            bottom: side_spec(prop(pl, ":bottom"))?,
            hide_chrome: prop(pl, ":hide-chrome").is_some_and(truthy),
            name,
        }),
        x => return bad(format!("a declaration: {x}")),
    })
}

fn open_opts(v: &Val) -> R<OpenOpts> {
    let pl = list(v)?;
    Ok(OpenOpts {
        group: prop(pl, ":group")
            .map(int)
            .transpose()?
            .map(|g| GroupId(g as u64)),
        at: opt_prop_string(pl, ":at")?,
        focus: prop(pl, ":focus").map(truthy),
        debug_stop: prop(pl, ":debug-stop").is_some_and(truthy),
        kind: opt_prop_string(pl, ":kind")?,
    })
}

fn tab_fields(v: &Val) -> R<TabFields> {
    let pl = list(v)?;
    Ok(TabFields {
        title: opt_prop_string(pl, ":title")?,
        icon: opt_prop_string(pl, ":icon")?,
        marks: prop(pl, ":marks")
            .map(|m| list(m)?.iter().map(string).collect::<R<Vec<_>>>())
            .transpose()?,
        dirty: prop(pl, ":dirty").map(truthy),
        ref_path: opt_prop_string(pl, ":ref-path")?,
    })
}

fn source(v: &Val) -> R<Source> {
    let (h, r) = form(v)?;
    Ok(match h.as_str() {
        "left" => Source::Left,
        "bottom" => Source::Bottom,
        "center" => Source::Center(
            GroupId(int(nth(r, 0))? as u64),
            TabId(int(nth(r, 1))? as u64),
        ),
        "right" => Source::Right(right_tab(nth(r, 0))?),
        x => return bad(format!("a source: {x}")),
    })
}

fn target(v: &Val) -> R<Target> {
    let (h, r) = form(v)?;
    Ok(match h.as_str() {
        "detail" => Target::Detail,
        "agents" => Target::Agents,
        "agents-session" => Target::AgentsSession(string(nth(r, 0))?),
        "inbox" => Target::Inbox(opt_string(nth(r, 0))?),
        "pull-requests" => Target::PullRequests(opt_string(nth(r, 0))?),
        x => return bad(format!("a target: {x}")),
    })
}

fn focus_target(v: &Val) -> R<FocusTarget> {
    let (h, r) = form(v)?;
    Ok(match h.as_str() {
        "region" => FocusTarget::Region(region(nth(r, 0))?),
        "group" => FocusTarget::Group(GroupId(int(nth(r, 0))? as u64)),
        "tab" => FocusTarget::Tab(TabId(int(nth(r, 0))? as u64)),
        x => return bad(format!("a focus target: {x}")),
    })
}

fn move_target(v: &Val) -> R<MoveTarget> {
    let (h, r) = form(v)?;
    Ok(match h.as_str() {
        "group" => MoveTarget::Group(GroupId(int(nth(r, 0))? as u64)),
        "new-group" => MoveTarget::NewGroup(GroupId(int(nth(r, 0))? as u64), side(nth(r, 1))?),
        "bottom" => MoveTarget::Bottom,
        "new-os-window" => MoveTarget::NewOsWindow,
        x => return bad(format!("a move target: {x}")),
    })
}

// ---- writing answers

fn sy(s: &str) -> Val {
    Val::Sym(s.to_string())
}

fn st(s: &str) -> Val {
    Val::Str(s.to_string())
}

fn n(i: u64) -> Val {
    Val::Int(i as i64)
}

fn opt<T>(x: Option<T>, f: impl FnOnce(T) -> Val) -> Val {
    x.map_or(Val::Nil, f)
}

fn refused(r: Refusal) -> Val {
    Val::List(vec![sy("refused"), Val::Str(r.reason)])
}

fn version(r: Result<Version, Refusal>) -> Val {
    r.map_or_else(refused, |v| n(v.0))
}

fn ref_val(r: &Ref) -> Val {
    Val::List(match r {
        Ref::File { path, at } => vec![sy("file"), st(path), opt(at.as_deref(), st)],
        Ref::Buffer { id, name } => vec![sy("buffer"), st(id), st(name)],
        Ref::Page { page_kind, key } => vec![sy("page"), st(page_kind), opt(key.as_deref(), st)],
        Ref::Session { id } => vec![sy("session"), st(id)],
        Ref::Output { channel } => vec![sy("output"), st(channel)],
    })
}

fn region_name(r: &Region) -> &'static str {
    match r {
        Region::Rail => "rail",
        Region::Left => "left",
        Region::Center => "center",
        Region::Right => "right",
        Region::Bottom => "bottom",
    }
}

fn focus_val(f: &Focus) -> Val {
    match f {
        Focus::Left => sy("left"),
        Focus::Right => sy("right"),
        Focus::Bottom => sy("bottom"),
        Focus::Center(g) => Val::List(vec![sy("center"), n(g.0)]),
        Focus::Overlay(o, r) => Val::List(vec![sy("overlay"), n(o.0), focus_val(r)]),
    }
}

fn node_val(t: &Node) -> Val {
    match t {
        Node::Leaf(g) => Val::List(vec![sy("leaf"), n(g.0)]),
        Node::Split {
            axis,
            children,
            weights,
        } => {
            let mut v = vec![
                sy(match axis {
                    Axis::Row => "row",
                    Axis::Column => "column",
                }),
                Val::List(weights.iter().map(|w| Val::Float(f64::from(*w))).collect()),
            ];
            v.extend(children.iter().map(node_val));
            Val::List(v)
        }
    }
}

fn realisation_val(wb: &Workbench, w: WinId) -> Val {
    let Some(r) = wb.realisation(w) else {
        return Val::Nil;
    };
    Val::List(vec![
        sy(":version"),
        n(r.version.0),
        sy(":regions"),
        Val::List(
            r.regions
                .iter()
                .map(|x| {
                    Val::List(vec![
                        sy(region_name(&x.region)),
                        bool_val(x.visible),
                        bool_val(x.folded),
                        n(u64::from(x.size)),
                    ])
                })
                .collect(),
        ),
        sy(":tree"),
        node_val(&r.tree),
        sy(":groups"),
        Val::List(
            r.groups
                .iter()
                .map(|g| {
                    Val::List(vec![
                        n(g.id.0),
                        opt(g.active, |t| n(t.0)),
                        opt(g.r.as_ref(), ref_val),
                        opt(g.attached.as_ref(), ref_val),
                    ])
                })
                .collect(),
        ),
        sy(":bottom"),
        opt(r.bottom.as_ref(), |(t, rf)| {
            Val::List(vec![n(t.0), ref_val(rf)])
        }),
        sy(":focus"),
        focus_val(&r.focus),
        sy(":temp"),
        Val::List(
            r.temp
                .iter()
                .map(|(g, t)| Val::List(vec![n(g.0), n(t.0)]))
                .collect(),
        ),
        sy(":overlays"),
        Val::List(
            r.overlays
                .iter()
                .map(|(o, k)| Val::List(vec![n(o.0), sy(overlay_name(*k))]))
                .collect(),
        ),
    ])
}

fn bool_val(b: bool) -> Val {
    if b { sy("t") } else { Val::Nil }
}

fn tokens_val(toks: &[Token]) -> Val {
    let mut stack: Vec<Vec<Val>> = vec![Vec::new()];
    for t in toks {
        match t {
            Token::Int(i) => stack.last_mut().unwrap().push(Val::Int(*i)),
            Token::Str(s) => stack.last_mut().unwrap().push(st(s)),
            Token::Sym(s) => stack.last_mut().unwrap().push(sy(s)),
            Token::Open => stack.push(Vec::new()),
            Token::Close => {
                if stack.len() > 1 {
                    let l = stack.pop().unwrap();
                    stack.last_mut().unwrap().push(Val::List(l));
                }
            }
        }
    }
    let mut top = stack.swap_remove(0);
    if top.len() == 1 {
        top.pop().unwrap()
    } else {
        Val::List(top)
    }
}

fn fold_name(f: SideFold) -> Val {
    sy(match f {
        SideFold::Open => "open",
        SideFold::Folded => "folded",
    })
}

// ---- the ops

fn run(door: &mut Door, op: usize, v: &[Val]) -> R<Val> {
    let wb = &mut door.wb;
    let mut a = Args { v, at: 0 };
    let name = *OPS.get(op).ok_or(Bad::Op)?;
    Ok(match name {
        "declare" => n(wb.declare(decl(a.next())?).0),
        "window_new" => {
            let monitor = a.str()?;
            let size = win_size(a.next())?;
            let scale = float(a.next())? as f32;
            let tty = truthy(a.next());
            n(wb.window_new(&monitor, size, scale, tty).0)
        }
        "window_close" => version(wb.window_close(WinId(a.id()?), a.origin()?)),
        "set_window_size" => {
            let w = WinId(a.id()?);
            let size = win_size(a.next())?;
            version(wb.set_window_size(w, size, float(a.next())? as f32))
        }
        "set_monitors" => {
            let ms = list(a.next())?.iter().map(string).collect::<R<_>>()?;
            n(wb.set_monitors(ms).0)
        }
        "open" => {
            let w = WinId(a.id()?);
            let r = r#ref(a.next())?;
            let how = match sym(a.next())?.as_str() {
                "preview" => How::Preview,
                "pin" => How::Pin,
                "reveal" => How::Reveal,
                x => return bad(format!("preview, pin or reveal: {x}")),
            };
            let o = open_opts(a.next())?;
            match wb.open(w, r, how, o, a.origin()?) {
                Ok((v, t)) => Val::List(vec![n(v.0), opt(t, |t| n(t.0))]),
                Err(e) => refused(e),
            }
        }
        "pin" => version(wb.pin(TabId(a.id()?), a.origin()?)),
        "close" => version(wb.close(TabId(a.id()?), a.origin()?)),
        "reopen_closed" => version(wb.reopen_closed(WinId(a.id()?), a.origin()?)),
        "select" => {
            let w = WinId(a.id()?);
            let kind = a.str()?;
            let id = a.str()?;
            let src = source(a.next())?;
            version(wb.select(w, &kind, &id, src, a.origin()?))
        }
        "show_context" => {
            let w = WinId(a.id()?);
            let t = target(a.next())?;
            let focus = truthy(a.next());
            version(wb.show_context(w, t, focus, a.origin()?))
        }
        "navigate" => {
            let w = WinId(a.id()?);
            let place = a.str()?;
            match wb.navigate(w, &place, a.origin()?) {
                Ok((v, t)) => Val::List(vec![n(v.0), opt(t, |t| n(t.0))]),
                Err(e) => refused(e),
            }
        }
        "overlay" => {
            let w = WinId(a.id()?);
            let k = overlay_kind(a.next())?;
            let spec = opt_string(a.next())?.unwrap_or_default();
            match wb.overlay(w, k, &spec, a.origin()?) {
                Ok((v, o)) => Val::List(vec![n(v.0), n(o.0)]),
                Err(e) => refused(e),
            }
        }
        "dismiss" => {
            let w = WinId(a.id()?);
            let o = match a.next() {
                Val::Nil => None,
                x => Some(OverlayId(int(x)? as u64)),
            };
            version(wb.dismiss(w, o, a.origin()?))
        }
        "focus" => {
            let w = WinId(a.id()?);
            let t = focus_target(a.next())?;
            let o = a.origin()?;
            match a.next() {
                Val::Nil => version(wb.focus(w, t, o)),
                Val::Sym(k) if k == "key" => version(wb.focus_key(w, t, o)),
                v => return bad(format!("key or nothing: {v:?}")),
            }
        }
        "cycle_region" => {
            let w = WinId(a.id()?);
            let d = match sym(a.next())?.as_str() {
                "next" => Dir::Next,
                "prev" => Dir::Prev,
                x => return bad(format!("next or prev: {x}")),
            };
            version(wb.cycle_region(w, d, a.origin()?))
        }
        "side" => {
            let w = WinId(a.id()?);
            let r = region(a.next())?;
            let s = vis(a.next())?;
            version(wb.side(w, r, s, a.origin()?))
        }
        "resize" => {
            let w = WinId(a.id()?);
            let r = region(a.next())?;
            let size = u32::try_from(a.int()?).or_else(|_| bad("a size"))?;
            version(wb.resize(w, r, size, a.origin()?))
        }
        "bottom" => {
            let w = WinId(a.id()?);
            let b = match a.next() {
                Val::Str(k) => BottomRef::Kind(k.clone()),
                x => match form(x)? {
                    (h, r) if h == "tab" => BottomRef::Tab(TabId(int(nth(r, 0))? as u64)),
                    (h, _) => return bad(format!("a bottom kind or (tab T): {h}")),
                },
            };
            let s = vis(a.next())?;
            version(wb.bottom(w, b, s, a.origin()?))
        }
        "split" => {
            let g = GroupId(a.id()?);
            let s = side(a.next())?;
            match wb.split(g, s, a.origin()?) {
                Ok((v, g)) => Val::List(vec![n(v.0), n(g.0)]),
                Err(e) => refused(e),
            }
        }
        "move_tab" => {
            let t = TabId(a.id()?);
            let m = move_target(a.next())?;
            version(wb.move_tab(t, m, a.origin()?))
        }
        "swap" => {
            let g = GroupId(a.id()?);
            let d = dir4(a.next())?;
            version(wb.swap(g, d, a.origin()?))
        }
        "stack" => {
            let g = GroupId(a.id()?);
            let d = dir4(a.next())?;
            version(wb.stack(g, d, a.origin()?))
        }
        "focus_dir" => {
            let w = WinId(a.id()?);
            let d = dir4(a.next())?;
            version(wb.focus_dir(w, d, a.origin()?))
        }
        "full_size" => version(wb.full_size(WinId(a.id()?), a.origin()?)),
        "resize_split" => {
            let w = WinId(a.id()?);
            let path = list(a.next())?
                .iter()
                .map(|x| usize::try_from(int(x)?).or_else(|_| bad("a path index")))
                .collect::<R<Vec<_>>>()?;
            let weights = list(a.next())?
                .iter()
                .map(|x| float(x).map(|f| f as f32))
                .collect::<R<Vec<_>>>()?;
            version(wb.resize_split(w, &path, &weights, a.origin()?))
        }
        "close_group" => version(wb.close_group(GroupId(a.id()?), a.origin()?)),
        "tear_out" => {
            let (h, r) = form(a.next())?;
            let what = match h.as_str() {
                "tab" => TearOut::Tab(TabId(int(nth(r, 0))? as u64)),
                "group" => TearOut::Group(GroupId(int(nth(r, 0))? as u64)),
                x => return bad(format!("(tab T) or (group G): {x}")),
            };
            match wb.tear_out(what, a.origin()?) {
                Ok((v, w)) => Val::List(vec![n(v.0), n(w.0)]),
                Err(e) => refused(e),
            }
        }
        "apply_preset" => {
            let w = WinId(a.id()?);
            let p = a.str()?;
            version(wb.apply_preset(w, &p, a.origin()?))
        }
        "restore_previous_layout" => {
            version(wb.restore_previous_layout(WinId(a.id()?), a.origin()?))
        }
        "update_tab" => {
            let t = TabId(a.id()?);
            version(wb.update_tab(t, tab_fields(a.next())?))
        }
        "set_attention" => {
            let count = a.id()?;
            let by = list(a.next())?
                .iter()
                .map(|x| {
                    let xs = list(x)?;
                    Ok((string(nth(xs, 0))?, int(nth(xs, 1))? as u64))
                })
                .collect::<R<Vec<_>>>()?;
            n(wb.set_attention(count, by).0)
        }
        "set_edges" => {
            let w = WinId(a.id()?);
            let ver = Version(a.id()?);
            let edges = list(a.next())?
                .iter()
                .map(|e| {
                    let xs = list(e)?;
                    Ok((edge_key(nth(xs, 0))?, rect(nth(xs, 1))?))
                })
                .collect::<R<Vec<_>>>()?;
            bool_val(wb.set_edges(w, ver, edges))
        }
        "begin_temp_layout" => {
            let g = GroupId(a.id()?);
            let tool = a.str()?;
            let title = a.str()?;
            match wb.begin_temp_layout(g, &tool, &title, a.origin()?) {
                Ok((v, t)) => Val::List(vec![n(v.0), n(t.0)]),
                Err(e) => refused(e),
            }
        }
        "end_temp_layout" => version(wb.end_temp_layout(GroupId(a.id()?))),
        "buffer_gone" => n(wb.buffer_gone(&a.str()?).0),
        "realisation" => realisation_val(wb, WinId(a.id()?)),
        // Task 17 fills the chrome description; until then a window has none
        "chrome" => {
            let w = a.id()?;
            match door.chrome.iter().find(|c| c.window == w) {
                None => Val::Nil,
                Some(c) => Val::List(
                    c.elements
                        .iter()
                        .map(|e| {
                            Val::List(vec![
                                Val::Int(e.id as i64),
                                Val::Sym(format!("{:?}", e.role)),
                                Val::Str(e.name.clone()),
                                Val::Int(e.rect.x.into()),
                                Val::Int(e.rect.y.into()),
                                Val::Int(e.rect.w.into()),
                                Val::Int(e.rect.h.into()),
                            ])
                        })
                        .collect(),
                ),
            }
        }
        "query" => {
            let w = WinId(a.id()?);
            match wb.query(w, &a.str()?) {
                Ok(t) => tokens_val(&t),
                Err(e) => refused(e),
            }
        }
        "snapshot" => {
            door.snapshots.push(door.wb.snapshot());
            n(door.snapshots.len() as u64 - 1)
        }
        "restore" => {
            let i = usize::try_from(a.int()?).or_else(|_| bad("a snapshot"))?;
            let Some(s) = door.snapshots.get(i).cloned() else {
                return bad("no such snapshot");
            };
            door.wb.restore(s);
            n(door.wb.version().0)
        }
        "save" => {
            let w = match a.next() {
                Val::Nil => None,
                x => Some(WinId(int(x)? as u64)),
            };
            Val::Str(wb.save(w))
        }
        "load" => {
            let text = a.str()?;
            match crate::persist::load(&text).and_then(|p| wb.restore_begin(p)) {
                Ok(ws) => Val::List(ws.iter().map(|w| n(w.0)).collect()),
                Err(e) => refused(e),
            }
        }
        "reset" => {
            *door = Door {
                wb: Workbench::new(),
                snapshots: Vec::new(),
                trace: door.trace.take(),
                chrome: Vec::new(),
            };
            Val::Nil
        }
        "trace" => {
            let on = truthy(a.next());
            let took = std::mem::replace(&mut door.trace, on.then(Vec::new)).unwrap_or_default();
            Val::List(
                took.iter()
                    .map(|(op, us)| Val::List(vec![sy(op), n(*us)]))
                    .collect(),
            )
        }
        "version" => n(wb.version().0),
        "pin_detail" => {
            let w = WinId(a.id()?);
            let pin = truthy(a.next());
            let sel = if pin { wb.selection(w).cloned() } else { None };
            version(wb.pin_detail(w, sel, a.origin()?))
        }
        "next_layout" => version(wb.next_layout(WinId(a.id()?), a.origin()?)),
        "save_project_layout" => {
            let w = WinId(a.id()?);
            let project = a.str()?;
            let lname = a.str()?;
            version(wb.save_project_layout(w, &project, &lname, a.origin()?))
        }
        "set_project" => {
            let w = WinId(a.id()?);
            version(wb.set_project(w, opt_string(a.next())?))
        }
        "set_place_state" => {
            let w = WinId(a.id()?);
            let place = a.str()?;
            let pl = list(a.next())?;
            let s = PlaceState {
                selection: opt_prop_string(pl, ":selection")?,
                scroll: prop(pl, ":scroll").map(int).transpose()?.unwrap_or(0) as u32,
            };
            version(wb.set_place_state(w, &place, s, a.origin()?))
        }
        "roles" => Val::List(
            wb.roles(WinId(a.id()?))
                .iter()
                .map(|r| {
                    Val::List(vec![
                        n(u64::from(r.depth)),
                        sy(r.role),
                        st(&r.name),
                        st(&r.key),
                        bool_val(r.pressed),
                    ])
                })
                .collect(),
        ),
        "fold" => opt(wb.fold(WinId(a.id()?)), |f| {
            Val::List(vec![fold_name(f.left), fold_name(f.right)])
        }),
        "resolve" => {
            let r = r#ref(a.next())?;
            let how = match sym(a.next())?.as_str() {
                "now" => Resolved::Now,
                "placeholder" => Resolved::Placeholder,
                "gone" => Resolved::Gone,
                x => return bad(format!("now, placeholder or gone: {x}")),
            };
            version(wb.resolve(&r, how))
        }
        "restore_tick" => n(wb.restore_tick().0),
        "pending_refs" => Val::List(wb.pending_refs().iter().map(ref_val).collect()),
        "take_notices" => Val::List(wb.take_notices().iter().map(|s| st(s)).collect()),
        _ => return Err(Bad::Op),
    })
}

/// One call on values (tests, and the C entry after it read its arguments).
pub fn call(op: i32, args: &[Val]) -> R<Val> {
    let op = usize::try_from(op).map_err(|_| Bad::Op)?;
    let name = *OPS.get(op).ok_or(Bad::Op)?;
    CALLS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    DOOR.with(|d| {
        let mut d = d.borrow_mut();
        let timed = d.trace.is_some().then(Instant::now);
        let r = run(&mut d, op, args);
        if let (Some(t0), Some(t)) = (timed, d.trace.as_mut()) {
            t.push((name, t0.elapsed().as_micros() as u64));
        }
        r
    })
}

// ---- the flat form

/// Read one value from the flat arguments at *AT.
///
/// # Safety
/// Each string token points to `len` readable bytes.
unsafe fn read_val(t: &[SmidjaVal], at: &mut usize) -> R<Val> {
    let Some(k) = t.get(*at) else {
        return bad("the arguments end inside a list");
    };
    *at += 1;
    let bytes = || -> R<String> {
        if k.len == 0 {
            return Ok(String::new());
        }
        if k.ptr.is_null() {
            return bad("a null string");
        }
        // SAFETY: by this function's contract.
        let b = unsafe { std::slice::from_raw_parts(k.ptr, k.len) };
        String::from_utf8(b.to_vec()).or_else(|_| bad("bytes that are not UTF-8"))
    };
    Ok(match k.tag {
        SMIDJA_NIL => Val::Nil,
        SMIDJA_INT => Val::Int(k.int_),
        SMIDJA_FLOAT => Val::Float(k.float_),
        SMIDJA_STR => Val::Str(bytes()?),
        SMIDJA_SYM => Val::Sym(bytes()?),
        SMIDJA_LIST => {
            let m = usize::try_from(k.int_).or_else(|_| bad("a negative list length"))?;
            if m > t.len() - *at {
                return bad("a list longer than the arguments");
            }
            let mut xs = Vec::with_capacity(m);
            for _ in 0..m {
                // SAFETY: by this function's contract.
                xs.push(unsafe { read_val(t, at) }?);
            }
            Val::List(xs)
        }
        x => return bad(format!("tag {x}")),
    })
}

fn flatten(v: &Val, toks: &mut Vec<SmidjaVal>, strs: &mut Vec<Box<[u8]>>) {
    let mut tok = |tag, int_, float_, s: Option<&str>| {
        let (ptr, len) = match s {
            Some(s) => {
                let b: Box<[u8]> = s.as_bytes().into();
                let p = (b.as_ptr(), b.len());
                strs.push(b);
                p
            }
            None => (std::ptr::null(), 0),
        };
        toks.push(SmidjaVal {
            tag,
            int_,
            float_,
            ptr,
            len,
        });
    };
    match v {
        Val::Nil => tok(SMIDJA_NIL, 0, 0.0, None),
        Val::Int(i) => tok(SMIDJA_INT, *i, 0.0, None),
        Val::Float(f) => tok(SMIDJA_FLOAT, 0, *f, None),
        Val::Str(s) => tok(SMIDJA_STR, 0, 0.0, Some(s)),
        Val::Sym(s) => tok(SMIDJA_SYM, 0, 0.0, Some(s)),
        Val::List(xs) => {
            tok(SMIDJA_LIST, xs.len() as i64, 0.0, None);
            for x in xs {
                flatten(x, toks, strs);
            }
        }
    }
}

/// The value of the flat answer T from *AT.
pub fn unflatten(t: &[SmidjaVal], at: &mut usize) -> Val {
    // SAFETY: an answer's string tokens point into the answer's own buffer.
    unsafe { read_val(t, at) }.unwrap_or(Val::Nil)
}

/// The number of the op named by the `len` bytes at `name` (`_` or `-` between words), or -1.
///
/// # Safety
/// `name` holds `len` readable bytes (null when `len` is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn smidja_op(name: *const u8, len: usize) -> i32 {
    if name.is_null() {
        return -1;
    }
    // SAFETY: by this entry point's contract.
    let b = unsafe { std::slice::from_raw_parts(name, len) };
    std::panic::catch_unwind(|| std::str::from_utf8(b).map_or(-1, op_number)).unwrap_or(-1)
}

/// One call: `op` on the `n` flat values at `args` (a list token's `int_` counts the values after it). On
/// `SMIDJA_OK` the answer's `*nout` values are at `*out`, valid until the next call on this thread; otherwise
/// `SMIDJA_E_ARG` (a bad argument), `SMIDJA_E_OP` (no such op) or `SMIDJA_E_PANIC`, with no answer.
///
/// # Safety
/// `args` points to `n` readable values (null when `n` is 0), each string or symbol `len` readable bytes; `out` and
/// `nout` are writable. Called on the thread that holds Emacs's global lock.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn smidja_call(
    op: i32,
    args: *const SmidjaVal,
    n: usize,
    out: *mut *const SmidjaVal,
    nout: *mut usize,
) -> i32 {
    if out.is_null() || nout.is_null() || (args.is_null() && n > 0) {
        return SMIDJA_E_ARG;
    }
    let toks: &[SmidjaVal] = if n == 0 {
        &[]
    } else {
        // SAFETY: by this entry point's contract.
        unsafe { std::slice::from_raw_parts(args, n) }
    };
    let answer = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut at = 0;
        let mut vals = Vec::new();
        while at < toks.len() {
            // SAFETY: by this entry point's contract.
            vals.push(unsafe { read_val(toks, &mut at) }?);
        }
        call(op, &vals)
    }));
    match answer {
        Ok(Ok(a)) => ANSWER.with(|b| {
            let mut b = b.borrow_mut();
            let (toks, strs) = &mut *b;
            toks.clear();
            strs.clear();
            flatten(&a, toks, strs);
            // SAFETY: `out` and `nout` are writable, by the contract; the tokens live until the next call.
            unsafe {
                *out = toks.as_ptr();
                *nout = toks.len();
            }
            SMIDJA_OK
        }),
        Ok(Err(Bad::Arg(_))) => SMIDJA_E_ARG,
        Ok(Err(Bad::Op)) => SMIDJA_E_OP,
        Err(_) => SMIDJA_E_PANIC,
    }
}

/// Run one call through the C entry from Rust (tests): the answer, or the code.
pub fn call_flat(op: i32, args: &[Val]) -> Result<Val, i32> {
    let mut toks = Vec::new();
    let mut strs = Vec::new();
    for a in args {
        flatten(a, &mut toks, &mut strs);
    }
    call_raw(op, &toks)
}

/// Run one call on raw flat values (tests: bad bytes).
pub fn call_raw(op: i32, toks: &[SmidjaVal]) -> Result<Val, i32> {
    let mut out: *const SmidjaVal = std::ptr::null();
    let mut nout = 0usize;
    // SAFETY: `toks` is a live slice whose strings are live; `out` and `nout` are writable locals.
    let rc = unsafe { smidja_call(op, toks.as_ptr(), toks.len(), &mut out, &mut nout) };
    if rc != SMIDJA_OK {
        return Err(rc);
    }
    // SAFETY: on SMIDJA_OK `out` holds `nout` values until the next call.
    let t = unsafe { std::slice::from_raw_parts(out, nout) };
    let mut at = 0;
    Ok(unflatten(t, &mut at))
}
