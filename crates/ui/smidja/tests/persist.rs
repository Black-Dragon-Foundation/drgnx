//! Task 12: the persistence text and the restore state machine (§4.9).
mod fixture;
use fixture::*;
use smidja::layout::SnapNode;
use smidja::*;

/// A session worth saving: a split, a preview, a page with a key, a session, the left on Search, the right on
/// Agents, a wider left, the bottom with Output.
fn session_wb() -> (Workbench, WinId) {
    let (mut wb, w) = wb_1920();
    open(&mut wb, w, file("a"), How::Pin);
    open(
        &mut wb,
        w,
        Ref::Page {
            page_kind: "extensions".into(),
            key: Some("magit".into()),
        },
        How::Pin,
    );
    let g1 = ag(&wb, w);
    open(&mut wb, w, file("b \"quoted\"\\x"), How::Pin);
    wb.split(g1, Side::Right, U).unwrap();
    open(&mut wb, w, file("p"), How::Preview);
    open(&mut wb, w, session("s1"), How::Pin);
    wb.navigate(w, "search", U).unwrap();
    wb.show_context(w, Target::Agents, false, U).unwrap();
    wb.resize(w, Region::Left, 300, U).unwrap();
    open(&mut wb, w, output("build"), How::Pin);
    (wb, w)
}

/// Load text into a fresh workbench and resolve every ref at once.
fn restore_all(text: &str) -> (Workbench, WinId) {
    let (mut wb, _) = wb_1920();
    let ids = wb.restore_begin(load(text).unwrap()).unwrap();
    for r in wb.pending_refs() {
        let _already_resolved = wb.resolve(&r, Resolved::Now);
    }
    wb.restore_tick();
    (wb, ids[0])
}

#[test]
fn saves_monitor_size_regions_place_right_tab_tree_refs_preview_order_bottom() {
    let (wb, _) = session_wb();
    let text = wb.save(None);
    assert!(text.starts_with("smidja-layout 1\n"));
    let p = load(&text).unwrap();
    let w = &p.windows[0];
    assert_eq!(w.monitor, "m0");
    assert_eq!(w.size, WinSize::Px { w: 1920, h: 1080 });
    assert_eq!(
        (w.left_visible, w.left_width, w.left_place.as_deref()),
        (true, 300, Some("search"))
    );
    assert_eq!((w.right_visible, w.right_tab), (true, RightTab::Agents));
    assert!(w.bottom_visible);
    assert_eq!(w.bottom_tabs.len(), 1);
    assert_eq!(w.bottom_tabs[0].r, output("build"));
    let SnapNode::Split {
        children, weights, ..
    } = &w.tree
    else {
        panic!("a split")
    };
    assert_eq!(weights, &[0.5, 0.5]);
    let SnapNode::Leaf(g1) = &children[0] else {
        panic!("a group")
    };
    let SnapNode::Leaf(g2) = &children[1] else {
        panic!("a group")
    };
    let refs1: Vec<&Ref> = g1.tabs.iter().map(|t| &t.r).collect();
    assert_eq!(
        refs1,
        [
            &file("a"),
            &Ref::Page {
                page_kind: "extensions".into(),
                key: Some("magit".into())
            }
        ]
    );
    let g2v: Vec<(&Ref, bool)> = g2.tabs.iter().map(|t| (&t.r, t.preview)).collect();
    assert_eq!(
        g2v,
        [
            (&file("b \"quoted\"\\x"), false),
            (&file("p"), true),
            (&session("s1"), false)
        ]
    );
    assert_eq!(g2.active, Some(2));
    assert_eq!(w.active, 1);
}

#[test]
fn never_saves_selection_focus_overlays_undo() {
    let (mut wb, w) = session_wb();
    let s1 = wb.save(None);
    wb.select(w, "file", "a", Source::Left, U).unwrap();
    wb.focus(w, FocusTarget::Region(Region::Left), U).unwrap();
    wb.overlay(w, OverlayKind::Palette, "", U).unwrap();
    wb.full_size(w, U).unwrap();
    wb.full_size(w, U).unwrap();
    let a = wb.selection(w).cloned();
    wb.pin_detail(w, a, U).unwrap();
    assert_eq!(wb.save(None), s1);
}

#[test]
fn round_trips_byte_for_byte() {
    let (wb, _) = session_wb();
    let text = wb.save(None);
    let (wb2, _) = restore_all(&text);
    assert_eq!(wb2.save(None), text);
    let mut tty = Workbench::new();
    for d in decls() {
        tty.declare(d);
    }
    let w = tty.window_new(
        "tty0",
        WinSize::Cells {
            cols: 120,
            lines: 40,
        },
        1.0,
        true,
    );
    open(&mut tty, w, file("x"), How::Preview);
    let t = tty.save(None);
    let mut back = Workbench::new();
    for d in decls() {
        back.declare(d);
    }
    back.window_new(
        "tty0",
        WinSize::Cells {
            cols: 80,
            lines: 24,
        },
        1.0,
        true,
    );
    back.restore_begin(load(&t).unwrap()).unwrap();
    back.resolve(&file("x"), Resolved::Now).unwrap();
    assert_eq!(back.save(None), t);
}

#[test]
fn an_unknown_version_is_refused() {
    let (wb, _) = session_wb();
    let text = wb
        .save(None)
        .replacen("smidja-layout 1", "smidja-layout 2", 1);
    assert!(load(&text).is_err());
    assert!(load("").is_err());
    assert!(load("smidja-layout 1\nwindow \"m0\" px 10\n").is_err());
}

#[test]
fn a_gone_file_is_dropped_with_one_notice() {
    let (wb, _) = session_wb();
    let (mut wb2, _) = wb_1920();
    let w = wb2.restore_begin(load(&wb.save(None)).unwrap()).unwrap()[0];
    for r in wb2.pending_refs() {
        let how = if r == file("a") {
            Resolved::Gone
        } else {
            Resolved::Now
        };
        wb2.resolve(&r, how).unwrap();
    }
    assert!(!center_refs(&wb2, w).contains(&file("a")));
    assert_eq!(center_refs(&wb2, w).len(), 4);
    let n = wb2.take_notices();
    assert_eq!(n.len(), 1);
    assert!(n[0].starts_with("a:"), "{n:?}");
}

#[test]
fn a_user_intent_during_restore_discards_the_pending_part() {
    let (wb, _) = session_wb();
    let (mut wb2, _) = wb_1920();
    let w = wb2.restore_begin(load(&wb.save(None)).unwrap()).unwrap()[0];
    wb2.resolve(&file("a"), Resolved::Now).unwrap();
    assert!(wb2.restoring());
    open(&mut wb2, w, file("mine"), How::Pin);
    assert!(!wb2.restoring(), "the user acted: the rest is dropped");
    assert!(wb2.resolve(&session("s1"), Resolved::Now).is_err());
    let refs = center_refs(&wb2, w);
    assert!(refs.contains(&file("a")) && refs.contains(&file("mine")));
    assert!(!refs.contains(&session("s1")));
}

#[test]
fn cold_hub_page_refs_open_at_once_with_placeholders() {
    let (mut wb, w) = wb_1920();
    wb.declare(Decl::PageKind {
        kind: "budgets".into(),
        title: "Budgets".into(),
        icon: "coins".into(),
        place: None,
        selects: None,
        view: Some("hub:budgets".into()),
    });
    let t = open(&mut wb, w, page("budgets"), How::Pin);
    wb.update_tab(
        t,
        TabFields {
            title: Some("Budgets › June".into()),
            ..TabFields::default()
        },
    )
    .unwrap();
    let (mut cold, _) = wb_1920();
    let w2 = cold.restore_begin(load(&wb.save(None)).unwrap()).unwrap()[0];
    cold.resolve(&page("budgets"), Resolved::Placeholder)
        .unwrap();
    let t2 = cold.active_tab(w2).unwrap();
    let tab = cold.tab(t2).unwrap();
    assert!(tab.placeholder);
    assert_eq!(tab.title, "Budgets › June", "the saved title is kept");
    cold.declare(Decl::PageKind {
        kind: "budgets".into(),
        title: "Budgets".into(),
        icon: "coins".into(),
        place: None,
        selects: None,
        view: Some("hub:budgets".into()),
    });
    assert!(
        !cold.tab(t2).unwrap().placeholder,
        "it fills when the hub declares its kind"
    );
}

#[test]
fn an_undeclared_kind_after_restore_shows_unavailable_and_one_notice() {
    let (mut wb, w) = wb_1920();
    wb.declare(Decl::PageKind {
        kind: "ext-page".into(),
        title: "Gone extension".into(),
        icon: "box".into(),
        place: None,
        selects: None,
        view: None,
    });
    open(&mut wb, w, page("ext-page"), How::Pin);
    open(&mut wb, w, file("a"), How::Pin);
    let (mut cold, _) = wb_1920();
    let w2 = cold.restore_begin(load(&wb.save(None)).unwrap()).unwrap()[0];
    cold.resolve(&file("a"), Resolved::Now).unwrap();
    cold.resolve(&page("ext-page"), Resolved::Placeholder)
        .unwrap();
    cold.restore_tick();
    assert!(!cold.restoring());
    let t = cold
        .tabs_of(ag(&cold, w2))
        .into_iter()
        .find(|t| cold.tab(*t).unwrap().r == page("ext-page"))
        .unwrap();
    assert!(cold.tab(t).unwrap().unavailable, "never a silent drop");
    assert_eq!(cold.notices().len(), 1);
}

#[test]
fn a_temp_layout_is_saved_as_its_return_to_tab() {
    let (mut wb, w) = wb_1920();
    open(&mut wb, w, file("a"), How::Pin);
    open(&mut wb, w, file("b"), How::Pin);
    let g = ag(&wb, w);
    wb.begin_temp_layout(g, "ediff", "Ediff: a ↔ b", U).unwrap();
    let p = load(&wb.save(None)).unwrap();
    let SnapNode::Leaf(sg) = &p.windows[0].tree else {
        panic!("one group")
    };
    assert_eq!(sg.tabs.len(), 2);
    assert_eq!(sg.active, Some(1), "b, the return tab, is the active one");
    assert!(sg.tabs.iter().all(|t| !t.title.contains("Ediff")));
}
