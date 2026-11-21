//! The tests' workbench: layout A's places and kinds (§4.4) declared as drgnx declares them, one OS window.
#![allow(dead_code)]

use smidja::*;

pub const U: Origin = Origin::User;
pub const P: Origin = Origin::Program;

fn s(x: &str) -> String {
    x.to_string()
}

/// Places in layout A's order (Settings and Keys at the foot), page kinds, selection and bottom kinds.
pub fn decls() -> Vec<Decl> {
    let mut v = Vec::new();
    for (place, home, foot) in [
        ("work", Some("graph"), false),
        ("files", None, false),
        ("search", None, false),
        ("changes", None, false),
        ("run", None, false),
        ("machines", Some("machines"), false),
        ("extensions", Some("extensions"), false),
        ("settings", Some("settings"), true),
        ("keys", Some("keys"), true),
    ] {
        v.push(Decl::Place {
            place: s(place),
            icon: s(place),
            view: None,
            sections: Vec::new(),
            home: home.map(s),
            foot,
        });
    }
    for (kind, title, place) in [
        ("graph", "Graph", Some("work")),
        ("machines", "Machines", Some("machines")),
        ("extensions", "Extensions", Some("extensions")),
        ("settings", "Settings", Some("settings")),
        ("keys", "Keys", Some("keys")),
        ("review", "Review", Some("changes")),
        ("diff", "Diff", None),
        ("start", "Start", None),
        ("notices", "Notices", None),
    ] {
        v.push(Decl::PageKind {
            kind: s(kind),
            title: s(title),
            icon: s(kind),
            place: place.map(s),
            selects: None,
            view: None,
        });
    }
    for k in ["file", "task", "extension"] {
        v.push(Decl::SelectionKind {
            kind: s(k),
            detail: None,
        });
    }
    for k in ["problems", "output", "terminal", "debug-console", "results"] {
        v.push(Decl::BottomKind { kind: s(k) });
    }
    v.push(Decl::TabKind {
        kind: s("terminal"),
    });
    v.extend(preset_decls());
    v
}

/// Layout A's five presets [D14] (Work, Code, Work + code, Review, Zen), as drgnx declares them.
pub fn preset_decls() -> Vec<Decl> {
    use smidja::{CenterSpec as C, Preset, SideSpec as S};
    let show = |p: &str| S::Show(Some(p.to_string()));
    let page = |k: &str| C::Page(k.to_string());
    let p = |name: &str, center, left, right, bottom, hide_chrome| {
        Decl::Preset(Preset {
            name: name.to_string(),
            center,
            left,
            right,
            bottom,
            hide_chrome,
        })
    };
    vec![
        p(
            "work",
            page("graph"),
            show("work"),
            S::Show(None),
            S::Hide,
            false,
        ),
        p(
            "code",
            C::Recent,
            show("files"),
            S::Show(None),
            S::AsItWas,
            false,
        ),
        p(
            "work+code",
            C::Split(Box::new(page("graph")), Box::new(C::Recent)),
            show("work"),
            S::Show(None),
            S::Hide,
            false,
        ),
        p(
            "review",
            C::Split(Box::new(page("review")), Box::new(page("diff"))),
            show("changes"),
            S::Show(None),
            S::Hide,
            false,
        ),
        p("zen", C::Zen, S::Hide, S::Hide, S::Hide, true),
    ]
}

pub fn wb_at(w: u32, h: u32) -> (Workbench, WinId) {
    let mut wb = Workbench::new();
    for d in decls() {
        wb.declare(d);
    }
    let id = wb.window_new("m0", WinSize::Px { w, h }, 1.0, false);
    (wb, id)
}

/// One OS window 1920×1080 at scale 1.
pub fn wb_1920() -> (Workbench, WinId) {
    wb_at(1920, 1080)
}

pub fn file(p: &str) -> Ref {
    Ref::File {
        path: format!("/p/{p}"),
        at: None,
    }
}

pub fn buf(id: &str) -> Ref {
    Ref::Buffer {
        id: s(id),
        name: format!("*{id}*"),
    }
}

pub fn page(k: &str) -> Ref {
    Ref::Page {
        page_kind: s(k),
        key: None,
    }
}

pub fn session(id: &str) -> Ref {
    Ref::Session { id: s(id) }
}

pub fn output(ch: &str) -> Ref {
    Ref::Output { channel: s(ch) }
}

/// A user open with default options.
pub fn open(wb: &mut Workbench, w: WinId, r: Ref, how: How) -> TabId {
    wb.open(w, r, how, OpenOpts::default(), U)
        .expect("open")
        .1
        .expect("a tab")
}

pub fn open_in(wb: &mut Workbench, w: WinId, r: Ref, how: How, g: GroupId) -> TabId {
    let o = OpenOpts {
        group: Some(g),
        ..OpenOpts::default()
    };
    wb.open(w, r, how, o, U).expect("open").1.expect("a tab")
}

pub fn ag(wb: &Workbench, w: WinId) -> GroupId {
    wb.active_group(w).expect("an active group")
}

pub fn win(wb: &Workbench, w: WinId) -> &OsWindow {
    wb.window(w).expect("the window")
}

pub fn focus(wb: &Workbench, w: WinId) -> Focus {
    wb.focus_of(w).expect("focus").clone()
}

/// The titles of a group's tabs, in order.
pub fn titles(wb: &Workbench, g: GroupId) -> Vec<String> {
    wb.tabs_of(g)
        .iter()
        .map(|t| wb.tab(*t).expect("tab").title.clone())
        .collect()
}

/// Every tab's ref in a window's center.
pub fn center_refs(wb: &Workbench, w: WinId) -> Vec<Ref> {
    wb.groups(w)
        .into_iter()
        .flat_map(|g| wb.tabs_of(g))
        .map(|t| wb.tab(t).expect("tab").r.clone())
        .collect()
}

/// Two groups side by side: g1 [a], g2 [b] (b active, focus in g2).
pub fn two_groups(wb: &mut Workbench, w: WinId) -> (GroupId, GroupId) {
    open(wb, w, file("a"), How::Pin);
    open(wb, w, file("b"), How::Pin);
    let g1 = ag(wb, w);
    let (_, g2) = wb.split(g1, Side::Right, U).expect("split");
    (g1, g2)
}
