//! Task 2: `open`, `pin`, `close`, `reopen_closed` (§4.3 rules 1–4 as cases).
mod fixture;
use fixture::*;
use smidja::*;

#[test]
fn a_page_is_a_singleton_activated_in_its_own_group_with_its_key_updated() {
    let (mut wb, w) = wb_1920();
    let ext = open(&mut wb, w, page("extensions"), How::Pin);
    open(&mut wb, w, file("a"), How::Pin);
    let g1 = ag(&wb, w);
    let (_, g2) = wb.split(g1, Side::Right, U).unwrap();
    assert_eq!(ag(&wb, w), g2);
    let r = Ref::Page {
        page_kind: "extensions".into(),
        key: Some("magit".into()),
    };
    let t = open(&mut wb, w, r, How::Pin);
    assert_eq!(t, ext, "the existing tab, no new one");
    assert_eq!(center_refs(&wb, w).len(), 2);
    assert_eq!(
        wb.tab(ext).unwrap().r,
        Ref::Page {
            page_kind: "extensions".into(),
            key: Some("magit".into())
        }
    );
    assert_eq!(
        wb.group(g1).unwrap().active,
        Some(ext),
        "activated in its own group"
    );
    assert_eq!(ag(&wb, w), g1);
}

#[test]
fn a_page_preview_is_treated_as_pin() {
    let (mut wb, w) = wb_1920();
    let t = open(&mut wb, w, page("notices"), How::Preview);
    assert!(!wb.tab(t).unwrap().preview);
    assert_eq!(wb.group(ag(&wb, w)).unwrap().preview, None);
}

#[test]
fn text_reveal_if_open_activates_and_moves_to_at() {
    let (mut wb, w) = wb_1920();
    let a = open(&mut wb, w, file("a"), How::Pin);
    open(&mut wb, w, file("b"), How::Pin);
    let o = OpenOpts {
        at: Some("12:3".into()),
        ..OpenOpts::default()
    };
    let t = wb.open(w, file("a"), How::Reveal, o, U).unwrap().1.unwrap();
    assert_eq!(t, a);
    assert_eq!(wb.active_tab(w), Some(a));
    assert_eq!(
        wb.tab(a).unwrap().r,
        Ref::File {
            path: "/p/a".into(),
            at: Some("12:3".into())
        }
    );
    assert_eq!(center_refs(&wb, w).len(), 2);
}

#[test]
fn preview_replaces_the_groups_preview_reusing_the_tab_id() {
    let (mut wb, w) = wb_1920();
    let t1 = open(&mut wb, w, file("a"), How::Preview);
    let t2 = open(&mut wb, w, file("b"), How::Preview);
    assert_eq!(t1, t2, "the same tab id, content swapped");
    assert_eq!(wb.tab(t2).unwrap().r, file("b"));
    assert_eq!(wb.tabs_of(ag(&wb, w)).len(), 1);
    assert_eq!(wb.group(ag(&wb, w)).unwrap().preview, Some(t1));
}

#[test]
fn preview_with_none_adds_after_the_active_tab() {
    let (mut wb, w) = wb_1920();
    let x = open(&mut wb, w, file("x"), How::Pin);
    open(&mut wb, w, file("y"), How::Pin);
    wb.focus(w, FocusTarget::Tab(x), U).unwrap();
    open(&mut wb, w, file("a"), How::Preview);
    assert_eq!(titles(&wb, ag(&wb, w)), ["x", "a", "y"]);
}

#[test]
fn pin_adds_after_the_active_tab() {
    let (mut wb, w) = wb_1920();
    let x = open(&mut wb, w, file("x"), How::Pin);
    open(&mut wb, w, file("y"), How::Pin);
    wb.focus(w, FocusTarget::Tab(x), U).unwrap();
    let a = open(&mut wb, w, file("a"), How::Pin);
    assert_eq!(titles(&wb, ag(&wb, w)), ["x", "a", "y"]);
    assert!(!wb.tab(a).unwrap().preview);
}

#[test]
fn reveal_not_open_is_pin() {
    let (mut wb, w) = wb_1920();
    open(&mut wb, w, file("p"), How::Preview);
    let t = open(&mut wb, w, file("a"), How::Reveal);
    assert!(!wb.tab(t).unwrap().preview);
    assert_eq!(
        wb.tabs_of(ag(&wb, w)).len(),
        2,
        "a new tab; the preview stays"
    );
}

#[test]
fn pin_on_the_current_preview_of_the_same_ref_pins_in_place() {
    let (mut wb, w) = wb_1920();
    let t1 = open(&mut wb, w, file("a"), How::Preview);
    let t2 = open(&mut wb, w, file("a"), How::Pin);
    assert_eq!(t1, t2);
    assert!(!wb.tab(t1).unwrap().preview);
    assert_eq!(wb.group(ag(&wb, w)).unwrap().preview, None);
    let t3 = open(&mut wb, w, file("b"), How::Preview);
    let t4 = open(&mut wb, w, file("b"), How::Reveal);
    assert_eq!(t3, t4);
    assert!(!wb.tab(t3).unwrap().preview, "reveal pins it too");
}

#[test]
fn a_session_opens_pinned() {
    let (mut wb, w) = wb_1920();
    let t = open(&mut wb, w, session("s1"), How::Preview);
    assert!(!wb.tab(t).unwrap().preview);
    assert_eq!(wb.tab(t).unwrap().kind, "session");
}

#[test]
fn output_goes_to_the_bottom_unless_a_group_is_given() {
    let (mut wb, w) = wb_1920();
    let t = open(&mut wb, w, output("build"), How::Pin);
    assert_eq!(win(&wb, w).bottom.tabs, [t]);
    assert!(win(&wb, w).bottom.visible);
    assert!(center_refs(&wb, w).is_empty());
    let t2 = open(&mut wb, w, output("lsp"), How::Pin);
    assert_eq!(t2, t, "one Output tab: the channel switches in place");
    assert_eq!(wb.tab(t).unwrap().r, output("lsp"));
    let g = ag(&wb, w);
    let t3 = open_in(&mut wb, w, output("lsp"), How::Pin, g);
    assert_eq!(wb.tabs_of(g), [t3], "Open in Editor: a center tab");
}

#[test]
fn open_never_splits_or_touches_sides_or_selection() {
    let (mut wb, w) = wb_1920();
    wb.select(w, "file", "x", Source::Left, U).unwrap();
    wb.show_context(w, Target::Agents, false, U).unwrap();
    let before = win(&wb, w).clone();
    open(&mut wb, w, file("a"), How::Preview);
    open(&mut wb, w, file("b"), How::Pin);
    open(&mut wb, w, file("a"), How::Reveal);
    open(&mut wb, w, page("start"), How::Pin);
    open(&mut wb, w, session("s"), How::Pin);
    let after = win(&wb, w);
    assert_eq!(wb.groups(w).len(), 1);
    assert_eq!(after.left, before.left);
    assert_eq!(after.right, before.right);
    assert_eq!(after.bottom, before.bottom);
    assert_eq!(after.selection, before.selection);
    assert_eq!(wb.windows().len(), 1);
}

#[test]
fn preview_default_focus_false_pin_true() {
    let (mut wb, w) = wb_1920();
    wb.navigate(w, "search", U).unwrap();
    assert_eq!(focus(&wb, w), Focus::Left);
    open(&mut wb, w, file("a"), How::Preview);
    assert_eq!(
        focus(&wb, w),
        Focus::Left,
        "a preview leaves focus in the list"
    );
    open(&mut wb, w, file("b"), How::Pin);
    assert_eq!(focus(&wb, w), Focus::Center(ag(&wb, w)));
}

#[test]
fn close_activates_the_mru_tab() {
    let (mut wb, w) = wb_1920();
    let a = open(&mut wb, w, file("a"), How::Pin);
    open(&mut wb, w, file("b"), How::Pin);
    let c = open(&mut wb, w, file("c"), How::Pin);
    wb.focus(w, FocusTarget::Tab(a), U).unwrap();
    wb.focus(w, FocusTarget::Tab(c), U).unwrap();
    wb.close(c, U).unwrap();
    assert_eq!(
        wb.active_tab(w),
        Some(a),
        "the most recently used, not the neighbour"
    );
}

#[test]
fn an_emptied_group_is_removed_and_its_space_goes_to_its_sibling() {
    let (mut wb, w) = wb_1920();
    let (g1, g2) = two_groups(&mut wb, w);
    let b = wb.tabs_of(g2)[0];
    wb.close(b, U).unwrap();
    assert_eq!(wb.groups(w), [g1]);
    assert_eq!(win(&wb, w).center.tree, Node::Leaf(g1));
    assert_eq!(focus(&wb, w), Focus::Center(g1));
    // three in a row (2560 px: a third column fits 320): the middle one's weight goes to its left neighbour
    let (mut wb, w) = wb_at(2560, 1440);
    let (g1, g2) = two_groups(&mut wb, w);
    open_in(&mut wb, w, file("c"), How::Pin, g2);
    let (_, g3) = wb.split(g2, Side::Right, U).unwrap();
    let mid = wb.tabs_of(g2)[0];
    wb.close(mid, U).unwrap();
    assert_eq!(wb.groups(w), [g1, g3]);
    let Node::Split { weights, .. } = &win(&wb, w).center.tree else {
        panic!("a split")
    };
    assert_eq!(weights, &[0.75, 0.25]);
}

#[test]
fn the_last_group_stays_and_shows_start() {
    let (mut wb, w) = wb_1920();
    let a = open(&mut wb, w, file("a"), How::Pin);
    let g = ag(&wb, w);
    wb.close(a, U).unwrap();
    assert_eq!(wb.groups(w), [g]);
    assert!(wb.tabs_of(g).is_empty());
    assert_eq!(wb.active_tab(w), None, "empty: the realiser shows Start");
}

#[test]
fn reopen_closed_keeps_20() {
    let (mut wb, w) = wb_1920();
    let ts: Vec<TabId> = (0..21)
        .map(|i| open(&mut wb, w, file(&format!("f{i}")), How::Pin))
        .collect();
    for t in ts {
        wb.close(t, U).unwrap();
    }
    for _ in 0..20 {
        wb.reopen_closed(w, U).unwrap();
    }
    assert!(wb.reopen_closed(w, U).is_err(), "only 20 are kept");
    let t = titles(&wb, ag(&wb, w));
    assert_eq!(t.len(), 20);
    assert!(!t.contains(&"f0".to_string()), "the oldest is gone");
    assert!(t.contains(&"f20".to_string()));
}

#[test]
fn reveal_if_open_looks_only_in_the_target_os_window() {
    let (mut wb, w1) = wb_1920();
    let w2 = wb.window_new("m0", WinSize::Px { w: 1920, h: 1080 }, 1.0, false);
    let a1 = open(&mut wb, w1, file("a"), How::Pin);
    let a2 = open(&mut wb, w2, file("a"), How::Reveal);
    assert_ne!(a1, a2);
    assert_eq!(center_refs(&wb, w2), [file("a")]);
}
