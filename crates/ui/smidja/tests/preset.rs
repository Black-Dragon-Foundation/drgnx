//! Task 9: presets and per-project layouts (§8.2).
mod fixture;
use fixture::*;
use smidja::*;

fn active_ref(wb: &Workbench, g: GroupId) -> Option<Ref> {
    wb.group(g)?.active.map(|t| wb.tab(t).unwrap().r.clone())
}

fn apply(wb: &mut Workbench, w: WinId, name: &str) {
    wb.apply_preset(w, name, U).unwrap();
}

#[test]
fn work_preset_graph_tab_left_work_right_detail_bottom_hidden() {
    let (mut wb, w) = wb_1920();
    open(&mut wb, w, file("a"), How::Pin);
    wb.bottom(w, BottomRef::Kind("problems".into()), Vis::Show, U)
        .unwrap();
    wb.show_context(w, Target::Agents, false, U).unwrap();
    apply(&mut wb, w, "work");
    let gs = wb.groups(w);
    assert_eq!(gs.len(), 1);
    assert_eq!(active_ref(&wb, gs[0]), Some(page("graph")));
    let x = win(&wb, w);
    assert_eq!(
        (x.left.place.as_deref(), x.left.visible),
        (Some("work"), true)
    );
    assert_eq!((x.right.tab, x.right.visible), (RightTab::Detail, true));
    assert!(!x.bottom.visible);
    assert!(center_refs(&wb, w).contains(&file("a")));
}

#[test]
fn code_preset_recent_files_or_start_files_detail_bottom_as_it_was() {
    let (mut wb, w) = wb_1920();
    let a = open(&mut wb, w, file("a"), How::Pin);
    open(&mut wb, w, file("b"), How::Pin);
    open(&mut wb, w, page("graph"), How::Pin);
    wb.focus(w, FocusTarget::Tab(a), U).unwrap();
    open(&mut wb, w, page("notices"), How::Pin);
    wb.bottom(w, BottomRef::Kind("problems".into()), Vis::Show, U)
        .unwrap();
    apply(&mut wb, w, "code");
    assert_eq!(wb.active_tab(w), Some(a), "the most recent file tab");
    let x = win(&wb, w);
    assert_eq!(x.left.place.as_deref(), Some("files"));
    assert!(x.bottom.visible, "the bottom as it was");
    let (mut wb, w) = wb_1920();
    apply(&mut wb, w, "code");
    assert_eq!(wb.active_tab(w), None, "no file tab: Start");
    assert!(!win(&wb, w).bottom.visible);
}

#[test]
fn work_plus_code_is_one_os_window_center_split_graph_left_code_right() {
    let (mut wb, w) = wb_1920();
    open(&mut wb, w, file("a"), How::Pin);
    let b = open(&mut wb, w, file("b"), How::Pin);
    open(&mut wb, w, page("notices"), How::Pin);
    apply(&mut wb, w, "work+code");
    assert_eq!(wb.windows(), [w], "one OS window [D14]");
    let gs = wb.groups(w);
    assert_eq!(gs.len(), 2);
    assert!(matches!(
        win(&wb, w).center.tree,
        Node::Split {
            axis: Axis::Row,
            ..
        }
    ));
    assert_eq!(active_ref(&wb, gs[0]), Some(page("graph")));
    assert_eq!(wb.group(gs[1]).unwrap().active, Some(b));
    assert_eq!(titles(&wb, gs[1]), ["a", "b"]);
    assert_eq!(win(&wb, w).left.place.as_deref(), Some("work"));
    assert!(!win(&wb, w).bottom.visible);
}

#[test]
fn review_preset_review_page_and_diff_split_right_left_changes() {
    let (mut wb, w) = wb_1920();
    open(&mut wb, w, file("a"), How::Pin);
    apply(&mut wb, w, "review");
    let gs = wb.groups(w);
    assert_eq!(gs.len(), 2);
    assert_eq!(active_ref(&wb, gs[0]), Some(page("review")));
    assert_eq!(active_ref(&wb, gs[1]), Some(page("diff")));
    assert_eq!(win(&wb, w).left.place.as_deref(), Some("changes"));
    assert_eq!(win(&wb, w).right.tab, RightTab::Detail);
}

#[test]
fn zen_shows_the_active_group_full_size_all_hidden() {
    let (mut wb, w) = wb_1920();
    let (_, g2) = two_groups(&mut wb, w);
    wb.bottom(w, BottomRef::Kind("problems".into()), Vis::Show, U)
        .unwrap();
    apply(&mut wb, w, "zen");
    let r = wb.realisation(w).unwrap();
    assert_eq!(r.tree, Node::Leaf(g2));
    for x in &r.regions {
        assert_eq!(x.visible, x.region == Region::Center, "{:?}", x.region);
    }
    assert!(
        !wb.roles(w).iter().any(|r| r.role == "status"),
        "the status bar is hidden too"
    );
    assert_eq!(focus(&wb, w), Focus::Center(g2));
}

#[test]
fn a_preset_never_closes_a_buffer_unnamed_tabs_join_the_first_group() {
    let (mut wb, w) = wb_1920();
    let (g1, _) = two_groups(&mut wb, w);
    open_in(&mut wb, w, buf("scratch"), How::Pin, g1);
    open(&mut wb, w, page("extensions"), How::Pin);
    open(&mut wb, w, session("s1"), How::Pin);
    let before = center_refs(&wb, w);
    apply(&mut wb, w, "review");
    let after = center_refs(&wb, w);
    for r in &before {
        assert!(after.contains(r), "{r:?} kept");
    }
    let first = wb.groups(w)[0];
    let in_first: Vec<Ref> = wb
        .tabs_of(first)
        .iter()
        .map(|t| wb.tab(*t).unwrap().r.clone())
        .collect();
    for r in &before {
        assert!(in_first.contains(r), "{r:?} joined the first group");
    }
}

#[test]
fn a_preset_pushes_a_snapshot() {
    let (mut wb, w) = wb_1920();
    let (_, _) = two_groups(&mut wb, w);
    let tree_refs = |wb: &Workbench| {
        wb.groups(w)
            .into_iter()
            .map(|g| titles(wb, g))
            .collect::<Vec<_>>()
    };
    let before = tree_refs(&wb);
    let d = wb.undo_depth(w);
    apply(&mut wb, w, "work");
    assert_eq!(wb.undo_depth(w), d + 1);
    wb.restore_previous_layout(w, U).unwrap();
    let mut after = tree_refs(&wb);
    after[0].retain(|t| t != "Graph");
    assert_eq!(after, before);
}

#[test]
fn a_split_presets_half_closes_goes_full_size_and_resizes_like_any_group() {
    let (mut wb, w) = wb_1920();
    open(&mut wb, w, file("a"), How::Pin);
    apply(&mut wb, w, "work+code");
    let gs = wb.groups(w);
    wb.close_group(gs[1], U).unwrap();
    assert_eq!(wb.groups(w), [gs[0]], "the other half takes the center");
    wb.restore_previous_layout(w, U).unwrap();
    assert_eq!(wb.groups(w).len(), 2);
    wb.focus(w, FocusTarget::Group(wb.groups(w)[0]), U).unwrap();
    wb.full_size(w, U).unwrap();
    assert_eq!(wb.realisation(w).unwrap().tree.leaves().len(), 1);
    wb.full_size(w, U).unwrap();
    wb.resize_split(w, &[], &[1.0, 3.0], U).unwrap();
    let Node::Split { weights, .. } = &win(&wb, w).center.tree else {
        panic!("split")
    };
    assert_eq!(weights, &[0.25, 0.75]);
}

#[test]
fn hiding_the_left_never_changes_the_split() {
    let (mut wb, w) = wb_1920();
    apply(&mut wb, w, "work+code");
    let tree = win(&wb, w).center.tree.clone();
    wb.side(w, Region::Left, Vis::Hide, U).unwrap();
    assert_eq!(win(&wb, w).center.tree, tree);
    wb.side(w, Region::Left, Vis::Show, U).unwrap();
    assert_eq!(win(&wb, w).center.tree, tree);
}

#[test]
fn next_layout_cycles_presets_then_the_users() {
    let (mut wb, w) = wb_1920();
    wb.set_project(w, Some("p".into())).unwrap();
    open(&mut wb, w, file("a"), How::Pin);
    wb.save_project_layout(w, "p", "mine", U).unwrap();
    wb.save_project_layout(w, "other", "theirs", U).unwrap();
    let mut seen = Vec::new();
    for _ in 0..7 {
        wb.next_layout(w, U).unwrap();
        seen.push(wb.layout_name(w).unwrap().to_string());
    }
    assert_eq!(
        seen,
        ["work", "code", "work+code", "review", "zen", "mine", "work"]
    );
}

#[test]
fn agent_editor_browser_presets_do_not_exist() {
    let (mut wb, w) = wb_1920();
    for n in ["agent", "editor", "browser"] {
        assert!(wb.apply_preset(w, n, U).is_err(), "{n}");
    }
    let names: Vec<&str> = presets().iter().map(|p| p.name).collect();
    assert_eq!(names, ["work", "code", "work+code", "review", "zen"]);
}
