//! Task 8: several OS windows, tear-out, monitors (§4.8, §8.1, §8.3).
mod fixture;
use fixture::*;
use smidja::*;

fn two_monitors() -> (Workbench, WinId, WinId) {
    let (mut wb, w1) = wb_1920();
    wb.set_monitors(vec!["m0".into(), "m1".into()]);
    let w2 = wb.window_new("m1", WinSize::Px { w: 2560, h: 1440 }, 1.0, false);
    (wb, w1, w2)
}

fn layout_of(wb: &Workbench) -> Vec<(WinId, Vec<Vec<Ref>>)> {
    wb.windows()
        .into_iter()
        .map(|w| {
            let gs = wb
                .groups(w)
                .into_iter()
                .map(|g| {
                    wb.tabs_of(g)
                        .iter()
                        .map(|t| wb.tab(*t).unwrap().r.clone())
                        .collect()
                })
                .collect();
            (w, gs)
        })
        .collect()
}

#[test]
fn every_os_window_has_its_own_regions_selection_and_focus() {
    let (mut wb, w1, w2) = two_monitors();
    wb.select(w1, "file", "a", Source::Left, U).unwrap();
    wb.side(w2, Region::Left, Vis::Hide, U).unwrap();
    wb.focus(w1, FocusTarget::Region(Region::Right), U).unwrap();
    wb.navigate(w2, "search", U).unwrap();
    assert!(wb.selection(w2).is_none());
    assert!(win(&wb, w1).left.visible);
    assert_eq!(focus(&wb, w1), Focus::Right);
    assert_eq!(focus(&wb, w2), Focus::Left);
    assert_eq!(win(&wb, w1).left.place.as_deref(), Some("files"));
    assert_eq!(win(&wb, w2).left.place.as_deref(), Some("search"));
    assert_ne!(ag(&wb, w1), ag(&wb, w2));
}

#[test]
fn a_page_kind_is_a_singleton_per_os_window() {
    let (mut wb, w1, w2) = two_monitors();
    let e1 = open(&mut wb, w1, page("extensions"), How::Pin);
    let e2 = open(&mut wb, w2, page("extensions"), How::Pin);
    assert_ne!(e1, e2, "two windows may each show Extensions");
    assert_eq!(open(&mut wb, w2, page("extensions"), How::Pin), e2);
    assert_eq!(center_refs(&wb, w1), [page("extensions")]);
    assert_eq!(center_refs(&wb, w2), [page("extensions")]);
}

#[test]
fn tear_out_makes_a_full_workbench_left_on_the_tabs_place_or_files_right_on_detail() {
    let (mut wb, w1) = wb_1920();
    let ext = open(&mut wb, w1, page("extensions"), How::Pin);
    let a = open(&mut wb, w1, file("a"), How::Pin);
    open(&mut wb, w1, file("b"), How::Pin);
    wb.show_context(w1, Target::Agents, false, U).unwrap();
    let (_, w2) = wb.tear_out(TearOut::Tab(ext), U).unwrap();
    assert_eq!(center_refs(&wb, w2), [page("extensions")]);
    assert_eq!(win(&wb, w2).left.place.as_deref(), Some("extensions"));
    assert!(win(&wb, w2).left.visible && win(&wb, w2).right.visible);
    assert_eq!(win(&wb, w2).right.tab, RightTab::Detail);
    assert_eq!(win(&wb, w2).size, win(&wb, w1).size);
    let (_, w3) = wb.tear_out(TearOut::Tab(a), U).unwrap();
    assert_eq!(win(&wb, w3).left.place.as_deref(), Some("files"));
    assert_eq!(center_refs(&wb, w1), [file("b")]);
    assert_eq!(wb.windows(), [w1, w2, w3]);
    assert_eq!(
        wb.undo_depth(w1),
        2,
        "each tear-out pushes a snapshot of the source"
    );
}

#[test]
fn a_lost_monitor_folds_its_windows_tabs_into_the_main_active_group_with_a_snapshot() {
    let (mut wb, w1, w2) = two_monitors();
    open(&mut wb, w1, file("main"), How::Pin);
    open(&mut wb, w2, file("x"), How::Pin);
    open(&mut wb, w2, file("y"), How::Pin);
    wb.set_monitors(vec!["m0".into()]);
    assert_eq!(wb.windows(), [w1]);
    assert_eq!(titles(&wb, ag(&wb, w1)), ["main", "x", "y"]);
    assert_eq!(
        wb.active_tab(w1)
            .map(|t| wb.tab(t).unwrap().title.clone())
            .as_deref(),
        Some("main")
    );
    assert_eq!(wb.undo_depth(w1), 1);
}

#[test]
fn the_returned_monitor_gets_its_windows_back_with_current_content() {
    let (mut wb, w1, w2) = two_monitors();
    open(&mut wb, w1, file("main"), How::Pin);
    let x = open(&mut wb, w2, file("x"), How::Pin);
    open(&mut wb, w2, file("y"), How::Pin);
    wb.set_monitors(vec!["m0".into()]);
    let f = TabFields {
        title: Some("x (edited)".into()),
        dirty: Some(true),
        ..TabFields::default()
    };
    wb.update_tab(x, f).unwrap();
    wb.set_monitors(vec!["m0".into(), "m1".into()]);
    assert_eq!(wb.windows(), [w1, w2]);
    assert_eq!(titles(&wb, ag(&wb, w1)), ["main"]);
    assert_eq!(titles(&wb, ag(&wb, w2)), ["x (edited)", "y"]);
    assert!(wb.tab(x).unwrap().dirty);
}

#[test]
fn nothing_moves_between_monitors_otherwise() {
    let (mut wb, w1, w2) = two_monitors();
    open(&mut wb, w1, file("a"), How::Pin);
    open(&mut wb, w2, file("b"), How::Pin);
    let before = layout_of(&wb);
    wb.set_monitors(vec!["m0".into(), "m1".into()]);
    wb.set_monitors(vec!["m1".into(), "m0".into(), "m2".into()]);
    wb.set_window_size(w2, WinSize::Px { w: 1280, h: 720 }, 2.0)
        .unwrap();
    assert_eq!(layout_of(&wb), before);
    assert_eq!(wb.undo_depth(w1), 0);
}
