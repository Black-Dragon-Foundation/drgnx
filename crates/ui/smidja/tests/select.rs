//! Task 3: `select`, `show_context`, `navigate`, the left following (§4.3, §4.7, §7.3).
mod fixture;
use fixture::*;
use smidja::*;

fn sel(wb: &Workbench, w: WinId) -> Option<String> {
    wb.detail(w).map(|s| s.id.clone())
}

#[test]
fn select_bumps_selection_gen() {
    let (mut wb, w) = wb_1920();
    assert_eq!(win(&wb, w).selection_gen, 0);
    wb.select(w, "file", "a", Source::Left, U).unwrap();
    assert_eq!(wb.selection(w).unwrap().generation, 1);
    wb.select(w, "file", "a", Source::Left, U).unwrap();
    assert_eq!(
        wb.selection(w).unwrap().generation,
        2,
        "the same item again is a new generation"
    );
    assert_eq!(wb.query(w, "selection").unwrap()[2], QueryItem::Int(2));
}

#[test]
fn detail_follows_unless_pinned() {
    let (mut wb, w) = wb_1920();
    wb.select(w, "task", "A", Source::Left, U).unwrap();
    assert_eq!(sel(&wb, w).as_deref(), Some("A"));
    let a = wb.selection(w).cloned();
    wb.pin_detail(w, a, U).unwrap();
    wb.select(w, "task", "B", Source::Left, U).unwrap();
    assert_eq!(sel(&wb, w).as_deref(), Some("A"), "pinned");
    wb.pin_detail(w, None, U).unwrap();
    assert_eq!(sel(&wb, w).as_deref(), Some("B"));
}

#[test]
fn a_non_detail_right_tab_gets_a_changed_dot_and_stays() {
    let (mut wb, w) = wb_1920();
    wb.show_context(w, Target::Agents, false, U).unwrap();
    wb.select(w, "file", "a", Source::Left, U).unwrap();
    assert_eq!(win(&wb, w).right.tab, RightTab::Agents);
    assert_eq!(win(&wb, w).right.changed, [RightTab::Detail]);
    wb.show_context(w, Target::Detail, false, U).unwrap();
    assert!(
        win(&wb, w).right.changed.is_empty(),
        "showing Detail clears its dot"
    );
}

#[test]
fn select_never_opens_focuses_or_folds() {
    let (mut wb, w) = wb_at(1500, 900);
    open(&mut wb, w, file("a"), How::Pin);
    let before = win(&wb, w).clone();
    let t = wb.active_tab(w).unwrap();
    wb.select(w, "file", "a", Source::Center(ag(&wb, w), t), U)
        .unwrap();
    let after = win(&wb, w);
    assert_eq!(after.focus, before.focus);
    assert_eq!(after.fold, before.fold);
    assert_eq!(after.overlays, before.overlays);
    assert_eq!(center_refs(&wb, w), [file("a")]);
    assert_eq!(after.right.visible, before.right.visible);
}

#[test]
fn the_left_follows_a_page_tab_with_a_place_only() {
    let (mut wb, w) = wb_1920();
    let ext = open(&mut wb, w, page("extensions"), How::Pin);
    assert_eq!(win(&wb, w).left.place.as_deref(), Some("extensions"));
    open(&mut wb, w, page("start"), How::Pin);
    assert_eq!(
        win(&wb, w).left.place.as_deref(),
        Some("extensions"),
        "a page without a place leaves it"
    );
    wb.navigate(w, "files", U).unwrap();
    wb.select(w, "extension", "magit", Source::Center(ag(&wb, w), ext), U)
        .unwrap();
    assert_eq!(
        win(&wb, w).left.place.as_deref(),
        Some("extensions"),
        "a selection from such a page tab too"
    );
}

#[test]
fn activating_a_text_tab_leaves_the_left() {
    let (mut wb, w) = wb_1920();
    let ext = open(&mut wb, w, page("extensions"), How::Pin);
    let a = open(&mut wb, w, file("a"), How::Pin);
    assert_eq!(win(&wb, w).left.place.as_deref(), Some("extensions"));
    wb.navigate(w, "search", U).unwrap();
    wb.focus(w, FocusTarget::Tab(a), U).unwrap();
    assert_eq!(win(&wb, w).left.place.as_deref(), Some("search"));
    wb.focus(w, FocusTarget::Tab(ext), U).unwrap();
    assert_eq!(win(&wb, w).left.place.as_deref(), Some("extensions"));
}

#[test]
fn show_context_shows_a_hidden_right_and_overlays_a_folded_one() {
    let (mut wb, w) = wb_1920();
    wb.side(w, Region::Right, Vis::Hide, U).unwrap();
    wb.show_context(w, Target::Inbox(Some("i1".into())), true, U)
        .unwrap();
    assert!(win(&wb, w).right.visible);
    assert_eq!(win(&wb, w).right.tab, RightTab::Inbox);
    assert_eq!(win(&wb, w).right.inbox_item.as_deref(), Some("i1"));
    assert_eq!(focus(&wb, w), Focus::Right);
    let (mut wb, w) = wb_at(1500, 900);
    assert_eq!(wb.fold(w).unwrap().right, SideFold::Folded);
    wb.show_context(w, Target::AgentsSession("s1".into()), true, U)
        .unwrap();
    assert_eq!(wb.side_overlay(w), Some(Region::Right));
    assert_eq!(
        wb.fold(w).unwrap().right,
        SideFold::Folded,
        "nothing reflows"
    );
    assert!(matches!(focus(&wb, w), Focus::Overlay(..)));
    assert_eq!(win(&wb, w).right.agents_conversation.as_deref(), Some("s1"));
}

#[test]
fn show_context_from_program_is_refused() {
    let (mut wb, w) = wb_1920();
    assert!(wb.show_context(w, Target::Agents, true, P).is_err());
    assert_eq!(win(&wb, w).right.tab, RightTab::Detail);
}

#[test]
fn navigate_opens_the_home_page_pinned_and_focuses_the_left() {
    let (mut wb, w) = wb_1920();
    let (_, t) = wb.navigate(w, "work", U).unwrap();
    let t = t.unwrap();
    assert_eq!(wb.tab(t).unwrap().r, page("graph"));
    assert!(!wb.tab(t).unwrap().preview);
    assert_eq!(wb.active_tab(w), Some(t));
    assert_eq!(win(&wb, w).left.place.as_deref(), Some("work"));
    assert_eq!(focus(&wb, w), Focus::Left);
    let (_, t2) = wb.navigate(w, "work", U).unwrap();
    assert_eq!(t2, Some(t), "opens or focuses the one Graph tab");
}

#[test]
fn rail_click_on_the_current_place_with_a_home_never_hides_the_left() {
    for place in ["work", "extensions", "machines", "settings", "keys"] {
        let (mut wb, w) = wb_1920();
        let (_, home) = wb.navigate(w, place, U).unwrap();
        open(&mut wb, w, file("a"), How::Pin);
        for _ in 0..3 {
            wb.navigate(w, place, U).unwrap();
            assert!(win(&wb, w).left.visible, "{place}: the left stays");
            assert_eq!(
                wb.active_tab(w),
                home,
                "{place}: its home page is active again"
            );
            assert_eq!(focus(&wb, w), Focus::Left);
        }
    }
}

#[test]
fn rail_click_on_the_current_place_without_a_home_toggles() {
    for place in ["files", "search", "changes", "run"] {
        let (mut wb, w) = wb_1920();
        wb.navigate(w, "work", U).unwrap();
        wb.navigate(w, place, U).unwrap();
        assert!(win(&wb, w).left.visible);
        wb.navigate(w, place, U).unwrap();
        assert!(
            !win(&wb, w).left.visible,
            "{place}: a second click hides the left"
        );
        assert_eq!(focus(&wb, w), Focus::Center(ag(&wb, w)));
        wb.navigate(w, place, U).unwrap();
        assert!(win(&wb, w).left.visible, "{place}: a third shows it");
    }
}

#[test]
fn each_place_restores_its_own_selection_and_scroll() {
    let (mut wb, w) = wb_1920();
    let f = PlaceState {
        selection: Some("src/a.rs".into()),
        scroll: 40,
    };
    let s = PlaceState {
        selection: Some("hit 3".into()),
        scroll: 7,
    };
    wb.navigate(w, "files", U).unwrap();
    wb.set_place_state(w, "files", f.clone(), U).unwrap();
    wb.navigate(w, "search", U).unwrap();
    wb.set_place_state(w, "search", s.clone(), U).unwrap();
    wb.navigate(w, "files", U).unwrap();
    assert_eq!(wb.place_state(w), Some(&f));
    wb.navigate(w, "search", U).unwrap();
    assert_eq!(wb.place_state(w), Some(&s));
}

#[test]
fn rail_lit_place_equals_the_left_place() {
    let (mut wb, w) = wb_1920();
    let lit = |wb: &Workbench| {
        let r = wb
            .roles(w)
            .into_iter()
            .find(|r| r.key.starts_with("place:") && r.pressed)
            .map(|r| r.name);
        (
            r,
            wb.rail_lit(w).map(str::to_string),
            win(wb, w).left.place.clone(),
        )
    };
    let ext = open(&mut wb, w, page("extensions"), How::Pin);
    wb.navigate(w, "search", U).unwrap();
    wb.focus(w, FocusTarget::Tab(ext), U).unwrap();
    wb.navigate(w, "work", U).unwrap();
    for _ in 0..2 {
        let (a, b, c) = lit(&wb);
        assert_eq!(a, c);
        assert_eq!(b, c);
        wb.navigate(w, "files", U).unwrap();
    }
}
