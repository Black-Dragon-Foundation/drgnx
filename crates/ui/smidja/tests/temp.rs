//! Task 10: temporary layouts (§5.3.3).
mod fixture;
use fixture::*;
use smidja::*;

fn ediff(wb: &mut Workbench, g: GroupId) -> TabId {
    wb.begin_temp_layout(g, "ediff", "Ediff: a.el ↔ b.el", U)
        .unwrap()
        .1
}

#[test]
fn a_temp_layout_makes_the_tools_tab_active() {
    let (mut wb, w) = wb_1920();
    open(&mut wb, w, file("a"), How::Pin);
    let g = ag(&wb, w);
    let t = ediff(&mut wb, g);
    assert_eq!(wb.active_tab(w), Some(t));
    let tab = wb.tab(t).unwrap();
    assert_eq!(
        (tab.kind.as_str(), tab.title.as_str()),
        ("text", "Ediff: a.el ↔ b.el")
    );
    assert_eq!(wb.temp_of(g).map(|x| x.tool.as_str()), Some("ediff"));
    assert_eq!(wb.realisation(w).unwrap().temp, [(g, t)]);
}

#[test]
fn opens_aimed_at_a_locked_group_go_to_the_next_group() {
    let (mut wb, w) = wb_1920();
    let (g1, g2) = two_groups(&mut wb, w);
    wb.focus(w, FocusTarget::Group(g1), U).unwrap();
    let t = ediff(&mut wb, g1);
    let c = open(&mut wb, w, file("c"), How::Pin);
    assert!(wb.tabs_of(g2).contains(&c));
    assert_eq!(
        wb.group(g1).unwrap().active,
        Some(t),
        "the tool keeps its group"
    );
    let c2 = open_in(&mut wb, w, file("d"), How::Preview, g1);
    assert!(wb.tabs_of(g2).contains(&c2));
}

#[test]
fn with_one_group_opens_go_behind_the_tools_tab_unactivated() {
    let (mut wb, w) = wb_1920();
    open(&mut wb, w, file("a"), How::Pin);
    let g = ag(&wb, w);
    let t = ediff(&mut wb, g);
    let c = open(&mut wb, w, file("c"), How::Pin);
    let tabs = wb.tabs_of(g);
    let i = tabs.iter().position(|x| *x == t).unwrap();
    assert_eq!(tabs.get(i + 1), Some(&c), "behind the tool's tab");
    assert_eq!(wb.active_tab(w), Some(t), "not activated");
}

#[test]
fn activating_another_tab_of_a_locked_group_is_refused_with_the_reason() {
    let (mut wb, w) = wb_1920();
    let a = open(&mut wb, w, file("a"), How::Pin);
    let g = ag(&wb, w);
    ediff(&mut wb, g);
    let e = wb.focus(w, FocusTarget::Tab(a), U).unwrap_err();
    assert_eq!(e.reason, "Ediff is running here; q quits it");
    assert!(wb.split(g, Side::Right, U).is_err());
}

#[test]
fn a_temp_layout_is_never_saved_or_in_undo() {
    let (mut wb, w) = wb_1920();
    let (g1, g2) = two_groups(&mut wb, w);
    let d = wb.undo_depth(w);
    ediff(&mut wb, g1);
    assert_eq!(wb.undo_depth(w), d, "beginning pushes nothing");
    assert!(!wb.save(None).contains("Ediff"));
    open_in(&mut wb, w, file("c"), How::Pin, g2);
    wb.split(g2, Side::Down, U).unwrap();
    wb.restore_previous_layout(w, U).unwrap_err();
    wb.end_temp_layout(g1).unwrap();
    assert_eq!(wb.undo_depth(w), d + 1, "only the split");
    wb.restore_previous_layout(w, U).unwrap();
    assert!(
        center_refs(&wb, w)
            .iter()
            .all(|r| !matches!(r, Ref::Buffer { name, .. } if name.contains("Ediff")))
    );
}

#[test]
fn end_reactivates_return_to() {
    let (mut wb, w) = wb_1920();
    let a = open(&mut wb, w, file("a"), How::Pin);
    let b = open(&mut wb, w, file("b"), How::Pin);
    let g = ag(&wb, w);
    wb.focus(w, FocusTarget::Tab(a), U).unwrap();
    let t = ediff(&mut wb, g);
    wb.end_temp_layout(g).unwrap();
    assert_eq!(wb.active_tab(w), Some(a));
    assert!(wb.tab(t).is_none());
    assert_eq!(wb.tabs_of(g), [a, b]);
    assert!(wb.temp_of(g).is_none());
}

#[test]
fn a_program_cannot_begin_one() {
    let (mut wb, w) = wb_1920();
    open(&mut wb, w, file("a"), How::Pin);
    let g = ag(&wb, w);
    assert!(wb.begin_temp_layout(g, "gdb", "gdb", P).is_err());
    assert!(wb.temp_of(g).is_none());
}
