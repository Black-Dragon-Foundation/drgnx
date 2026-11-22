//! Task 7: the center's layout intents and layout undo (§4.3, §4.10, §8.1).
mod fixture;
use fixture::*;
use smidja::*;

#[test]
fn split_moves_the_active_tab_into_the_new_group() {
    let (mut wb, w) = wb_1920();
    let a = open(&mut wb, w, file("a"), How::Pin);
    let b = open(&mut wb, w, file("b"), How::Pin);
    let g1 = ag(&wb, w);
    let (_, g2) = wb.split(g1, Side::Right, U).unwrap();
    assert_eq!(wb.tabs_of(g1), [a]);
    assert_eq!(wb.tabs_of(g2), [b]);
    assert_eq!(focus(&wb, w), Focus::Center(g2));
    // a lone text tab is shown in both groups: never an empty group
    let (_, g3) = wb.split(g1, Side::Down, U).unwrap();
    assert_eq!(wb.tabs_of(g1), [a]);
    assert_eq!(titles(&wb, g3), ["a"]);
    // an empty group has nothing to split off
    let (mut wb, w) = wb_1920();
    assert!(wb.split(ag(&wb, w), Side::Right, U).is_err());
}

#[test]
fn a_ninth_group_is_refused_with_a_reason() {
    let (mut wb, w) = wb_1920();
    open(&mut wb, w, file("a"), How::Pin);
    let g1 = ag(&wb, w);
    let (_, g2) = wb.split(g1, Side::Right, U).unwrap();
    for g in [g1, g2] {
        let (_, low) = wb.split(g, Side::Down, U).unwrap();
        wb.split(g, Side::Down, U).unwrap();
        wb.split(low, Side::Down, U).unwrap();
    }
    assert_eq!(wb.groups(w).len(), 8);
    let e = wb.split(g1, Side::Right, U).unwrap_err();
    assert!(e.reason.contains('8'), "{}", e.reason);
    assert_eq!(wb.groups(w).len(), 8);
    assert_eq!(wb.undo_depth(w), 7, "a refused split pushes nothing");
}

#[test]
fn a_split_under_320x160_is_refused_with_a_reason() {
    let (mut wb, w) = wb_1920();
    open(&mut wb, w, file("a"), How::Pin);
    let g1 = ag(&wb, w);
    wb.split(g1, Side::Right, U).unwrap();
    let e = wb.split(g1, Side::Right, U).unwrap_err();
    assert!(e.reason.contains("320"), "594 / 2 < 320: {}", e.reason);
    wb.split(g1, Side::Down, U).unwrap();
    wb.split(g1, Side::Down, U).unwrap();
    let e = wb.split(g1, Side::Down, U).unwrap_err();
    assert!(e.reason.contains("160"), "254 / 2 < 160: {}", e.reason);
}

#[test]
fn swap_moves_the_groups_and_their_ids_hold() {
    // a group id is identity (W5, manager): a swap moves the groups with their tabs, it never renumbers them
    let (mut wb, w) = wb_1920();
    let (g1, g2) = two_groups(&mut wb, w);
    let (a, b) = (wb.tabs_of(g1), wb.tabs_of(g2));
    wb.swap(g1, Dir4::Right, U).unwrap();
    assert_eq!(wb.groups(w), [g2, g1], "the groups changed places");
    assert_eq!(wb.tabs_of(g1), a, "g1 keeps its tabs");
    assert_eq!(wb.tabs_of(g2), b, "g2 keeps its tabs");
    assert_eq!(
        wb.active_group(w),
        Some(g1),
        "the moved group keeps the focus"
    );
    assert!(
        wb.swap(g1, Dir4::Right, U).is_err(),
        "nothing to its right now"
    );
    wb.swap(g1, Dir4::Left, U).unwrap();
    assert_eq!(wb.groups(w), [g1, g2], "and back");
}

#[test]
fn stack_merges_two_groups_tabs() {
    let (mut wb, w) = wb_1920();
    let (g1, g2) = two_groups(&mut wb, w);
    wb.stack(g2, Dir4::Left, U).unwrap();
    assert_eq!(wb.groups(w), [g1]);
    assert_eq!(titles(&wb, g1), ["a", "b"]);
    assert_eq!(
        wb.active_tab(w)
            .map(|t| wb.tab(t).unwrap().title.clone())
            .as_deref(),
        Some("b")
    );
}

#[test]
fn focus_dir_crosses_from_the_edge_group_into_that_side_and_back_to_the_nearest_group() {
    let (mut wb, w) = wb_1920();
    let (g1, g2) = two_groups(&mut wb, w);
    wb.bottom(w, BottomRef::Kind("terminal".into()), Vis::Show, U)
        .unwrap();
    wb.focus(w, FocusTarget::Group(g1), U).unwrap();
    let steps = [
        (Dir4::Left, Focus::Left),
        (Dir4::Right, Focus::Center(g1)),
        (Dir4::Right, Focus::Center(g2)),
        (Dir4::Right, Focus::Right),
        (Dir4::Left, Focus::Center(g2)),
        (Dir4::Down, Focus::Bottom),
        (Dir4::Up, Focus::Center(g2)),
    ];
    for (d, f) in steps {
        wb.focus_dir(w, d, U).unwrap();
        assert_eq!(focus(&wb, w), f, "{d:?}");
    }
    assert_eq!(wb.undo_depth(w), 1, "only the split: focus is not undoable");
}

#[test]
fn full_size_shows_one_group_until_toggled() {
    let (mut wb, w) = wb_1920();
    let (_, g2) = two_groups(&mut wb, w);
    wb.full_size(w, U).unwrap();
    assert_eq!(wb.realisation(w).unwrap().tree, Node::Leaf(g2));
    assert_eq!(wb.groups(w).len(), 2, "the other group is kept, hidden");
    open(&mut wb, w, file("c"), How::Pin);
    assert_eq!(
        wb.realisation(w).unwrap().tree,
        Node::Leaf(g2),
        "until toggled back"
    );
    wb.full_size(w, U).unwrap();
    assert_eq!(wb.realisation(w).unwrap().tree.leaves().len(), 2);
}

#[test]
fn undo_cap_is_50() {
    let (mut wb, w) = wb_1920();
    for _ in 0..60 {
        wb.full_size(w, U).unwrap();
    }
    assert_eq!(wb.undo_depth(w), 50);
}

#[test]
fn undo_restores_refs_and_skips_a_missing_one() {
    let (mut wb, w) = wb_1920();
    open(&mut wb, w, file("a"), How::Pin);
    open(&mut wb, w, buf("b"), How::Pin);
    let g1 = ag(&wb, w);
    wb.split(g1, Side::Right, U).unwrap();
    let (g1b, g2) = (wb.groups(w)[0], wb.groups(w)[1]);
    let a = wb.tabs_of(g1b)[0];
    wb.close_group(g1b, U).unwrap();
    assert_eq!(wb.groups(w), [g2]);
    wb.buffer_gone("b");
    wb.restore_previous_layout(w, U).unwrap();
    assert_eq!(
        center_refs(&wb, w),
        [file("a")],
        "a closed tab comes back, the killed buffer does not"
    );
    assert!(wb.tab(a).is_none(), "made again from its ref");
    wb.restore_previous_layout(w, U).unwrap();
    assert_eq!(wb.groups(w).len(), 1);
    assert_eq!(center_refs(&wb, w), [file("a")]);
}

#[test]
fn tab_switch_selection_and_focus_are_not_undoable() {
    let (mut wb, w) = wb_1920();
    let a = open(&mut wb, w, file("a"), How::Pin);
    open(&mut wb, w, file("b"), How::Pin);
    wb.focus(w, FocusTarget::Tab(a), U).unwrap();
    wb.select(w, "file", "a", Source::Left, U).unwrap();
    wb.focus(w, FocusTarget::Region(Region::Left), U).unwrap();
    wb.cycle_region(w, Dir::Next, U).unwrap();
    assert_eq!(wb.undo_depth(w), 0);
    assert!(wb.restore_previous_layout(w, U).is_err());
}

#[test]
fn nothing_splits_the_center_but_a_user_layout_intent() {
    let (mut wb, w) = wb_1920();
    let g = ag(&wb, w);
    for i in 0..10 {
        let r = file(&format!("f{i}"));
        wb.open(w, r.clone(), How::Pin, OpenOpts::default(), P)
            .unwrap();
        open(&mut wb, w, r, How::Preview);
        wb.split(g, Side::Right, P).unwrap_err();
        wb.navigate(w, "work", U).unwrap();
        wb.show_context(w, Target::Agents, true, U).unwrap();
        wb.bottom(w, BottomRef::Kind("problems".into()), Vis::Toggle, U)
            .unwrap();
    }
    assert_eq!(wb.groups(w), [g]);
}

#[test]
fn a_terminal_moves_to_the_bottom_and_back() {
    let (mut wb, w) = wb_1920();
    let g = ag(&wb, w);
    let o = OpenOpts {
        kind: Some("terminal".into()),
        ..OpenOpts::default()
    };
    let t = wb.open(w, buf("vterm"), How::Pin, o, U).unwrap().1.unwrap();
    let a = open(&mut wb, w, file("a"), How::Pin);
    wb.move_tab(t, MoveTarget::Bottom, U).unwrap();
    assert_eq!(win(&wb, w).bottom.tabs, [t]);
    assert_eq!(win(&wb, w).bottom.active, Some(t));
    assert_eq!(wb.tabs_of(g), [a]);
    wb.move_tab(t, MoveTarget::Group(g), U).unwrap();
    assert!(win(&wb, w).bottom.tabs.is_empty());
    assert_eq!(wb.tabs_of(g), [a, t]);
    assert!(
        wb.move_tab(a, MoveTarget::Bottom, U).is_err(),
        "a file is no bottom kind"
    );
}

#[test]
fn no_layout_change_closes_a_tab_it_cannot_place() {
    let (mut wb, w) = wb_1920();
    let (_, _) = two_groups(&mut wb, w);
    wb.full_size(w, U).unwrap();
    let c = open(&mut wb, w, file("c"), How::Pin);
    wb.restore_previous_layout(w, U).unwrap();
    wb.restore_previous_layout(w, U).unwrap();
    assert_eq!(wb.groups(w).len(), 1);
    let first = wb.groups(w)[0];
    assert!(
        wb.tabs_of(first).contains(&c),
        "a tab the snapshot never saw joins the first group"
    );
    assert_eq!(titles(&wb, first), ["a", "b", "c"]);
}
