//! Task 4: the origin rule (W6), tab fields, attention, buffer death.
mod fixture;
use fixture::*;
use smidja::*;

/// What a program must never change: visibility, the right's tab, focus, the tree, the windows.
fn shown(wb: &Workbench) -> Vec<String> {
    wb.windows()
        .into_iter()
        .map(|w| {
            let x = win(wb, w);
            format!(
                "{:?} {} {} {} {:?} {:?} {:?} {:?} {:?}",
                w,
                x.left.visible,
                x.right.visible,
                x.bottom.visible,
                x.right.tab,
                x.focus,
                x.center.tree,
                x.center.full_size,
                x.fold.overlay
            )
        })
        .collect()
}

#[test]
fn a_program_open_of_a_new_ref_only_marks() {
    let (mut wb, w) = wb_1920();
    let a = open(&mut wb, w, file("a"), How::Pin);
    let (_, t) = wb
        .open(w, file("b"), How::Pin, OpenOpts::default(), P)
        .unwrap();
    assert_eq!(t, None, "no tab");
    assert_eq!(center_refs(&wb, w), [file("a")]);
    assert_eq!(wb.program_marks(w), [file("b")]);
    open(&mut wb, w, file("c"), How::Pin);
    let (_, t) = wb
        .open(w, file("a"), How::Reveal, OpenOpts::default(), P)
        .unwrap();
    assert_eq!(t, Some(a));
    assert!(
        wb.tab(a).unwrap().changed,
        "an existing tab gets the changed dot"
    );
    assert_ne!(wb.active_tab(w), Some(a), "and is not activated");
    wb.open(w, output("build"), How::Pin, OpenOpts::default(), P)
        .unwrap();
    assert_eq!(wb.output_count(w, "build"), 1);
    assert!(!win(&wb, w).bottom.visible);
}

#[test]
fn a_program_preview_is_allowed_only_for_a_debugger_stop() {
    let (mut wb, w) = wb_1920();
    let (g1, _g2) = two_groups(&mut wb, w);
    let g = ag(&wb, w);
    let f = focus(&wb, w);
    let stop = OpenOpts {
        debug_stop: true,
        ..OpenOpts::default()
    };
    let (_, t) = wb
        .open(w, file("main.c"), How::Preview, stop.clone(), P)
        .unwrap();
    let t = t.expect("a debugger stop previews");
    assert!(wb.tab(t).unwrap().preview);
    assert_eq!(wb.group(g).unwrap().active, Some(t));
    assert_eq!(focus(&wb, w), f, "focus stays");
    let (_, t) = wb
        .open(w, file("x.c"), How::Preview, OpenOpts::default(), P)
        .unwrap();
    assert_eq!(t, None, "without a stop it only marks");
    let (_, t) = wb.open(w, file("y.c"), How::Pin, stop.clone(), P).unwrap();
    assert_eq!(t, None, "a stop pins nothing");
    let other = OpenOpts {
        group: Some(g1),
        ..stop
    };
    let (_, t) = wb.open(w, file("z.c"), How::Preview, other, P).unwrap();
    assert_eq!(t, None, "only in the active group");
}

#[test]
fn a_program_never_changes_focus_visibility_right_tab_or_splits() {
    let (mut wb, w) = wb_1920();
    let (g1, g2) = two_groups(&mut wb, w);
    let t = wb.tabs_of(g1)[0];
    open(&mut wb, w, buf("term"), How::Pin);
    wb.bottom(w, BottomRef::Kind("problems".into()), Vis::Show, U)
        .unwrap();
    wb.navigate(w, "search", U).unwrap();
    wb.full_size(w, U).unwrap();
    wb.full_size(w, U).unwrap();
    let before = shown(&wb);
    let mut results: Vec<(&str, bool)> = Vec::new();
    let mut r = |name, ok: bool| results.push((name, ok));
    r(
        "open",
        wb.open(w, page("extensions"), How::Pin, OpenOpts::default(), P)
            .is_ok(),
    );
    r("pin", wb.pin(t, P).is_ok());
    r("close", wb.close(t, P).is_ok());
    r("reopen", wb.reopen_closed(w, P).is_ok());
    r("select", wb.select(w, "file", "a", Source::Left, P).is_ok());
    r("pin_detail", wb.pin_detail(w, None, P).is_ok());
    r(
        "show_context",
        wb.show_context(w, Target::Inbox(None), true, P).is_ok(),
    );
    r("navigate", wb.navigate(w, "work", P).is_ok());
    r(
        "focus",
        wb.focus(w, FocusTarget::Region(Region::Right), P).is_ok(),
    );
    r("cycle", wb.cycle_region(w, Dir::Next, P).is_ok());
    r("side", wb.side(w, Region::Left, Vis::Toggle, P).is_ok());
    r("resize", wb.resize(w, Region::Left, 300, P).is_ok());
    r(
        "bottom",
        wb.bottom(w, BottomRef::Kind("output".into()), Vis::Toggle, P)
            .is_ok(),
    );
    r(
        "overlay",
        wb.overlay(w, OverlayKind::Palette, "", P).is_ok(),
    );
    r("dismiss", wb.dismiss(w, None, P).is_ok());
    r("split", wb.split(g1, Side::Down, P).is_ok());
    r(
        "move_tab",
        wb.move_tab(t, MoveTarget::NewGroup(g2, Side::Down), P)
            .is_ok(),
    );
    r("swap", wb.swap(g1, Dir4::Right, P).is_ok());
    r("stack", wb.stack(g1, Dir4::Right, P).is_ok());
    r("focus_dir", wb.focus_dir(w, Dir4::Left, P).is_ok());
    r("full_size", wb.full_size(w, P).is_ok());
    r(
        "resize_split",
        wb.resize_split(w, &[], &[1.0, 3.0], P).is_ok(),
    );
    r("close_group", wb.close_group(g2, P).is_ok());
    r("restore", wb.restore_previous_layout(w, P).is_ok());
    r("preset", wb.apply_preset(w, "zen", P).is_ok());
    r("next_layout", wb.next_layout(w, P).is_ok());
    r("tear_out", wb.tear_out(TearOut::Tab(t), P).is_ok());
    r("window_close", wb.window_close(w, P).is_ok());
    r(
        "temp",
        wb.begin_temp_layout(g1, "ediff", "Ediff", P).is_ok(),
    );
    r(
        "save_layout",
        wb.save_project_layout(w, "p", "mine", P).is_ok(),
    );
    r(
        "place_state",
        wb.set_place_state(w, "files", PlaceState::default(), P)
            .is_ok(),
    );
    assert_eq!(
        shown(&wb),
        before,
        "nothing a program did changed what shows"
    );
    let done: Vec<&str> = results.iter().filter(|x| x.1).map(|x| x.0).collect();
    assert_eq!(done, ["open"], "only open went through, as a mark");
    assert_eq!(wb.tab(t).unwrap().r, file("a"));
}

#[test]
fn buffer_gone_closes_every_tab_of_that_buffer_in_every_group() {
    let (mut wb, w) = wb_1920();
    open(&mut wb, w, buf("b"), How::Pin);
    let g1 = ag(&wb, w);
    let (_, g2) = wb.split(g1, Side::Right, U).unwrap();
    assert_eq!(
        center_refs(&wb, w),
        [buf("b"), buf("b")],
        "one buffer, a tab in two groups"
    );
    let w2 = wb.window_new("m0", WinSize::Px { w: 1920, h: 1080 }, 1.0, false);
    open(&mut wb, w2, buf("b"), How::Pin);
    open(&mut wb, w2, file("keep"), How::Pin);
    wb.buffer_gone("b");
    assert!(center_refs(&wb, w).is_empty());
    assert_eq!(center_refs(&wb, w2), [file("keep")]);
    assert_eq!(
        wb.groups(w).len(),
        1,
        "an emptied group goes, the last stays"
    );
    assert!(wb.groups(w).iter().all(|g| *g == g1 || *g == g2));
}

#[test]
fn buffer_gone_follows_closes_rule_for_an_emptied_group() {
    let (mut wb, w) = wb_1920();
    let g1 = ag(&wb, w);
    open(&mut wb, w, file("a"), How::Pin);
    open(&mut wb, w, buf("log"), How::Pin);
    let (_, g2) = wb.split(g1, Side::Right, U).unwrap();
    assert_eq!(focus(&wb, w), Focus::Center(g2));
    wb.buffer_gone("log");
    assert_eq!(wb.groups(w), [g1]);
    assert_eq!(
        focus(&wb, w),
        Focus::Center(g1),
        "focus moves to the group that took the space"
    );
}

#[test]
fn reopen_closed_skips_a_gone_buffer() {
    let (mut wb, w) = wb_1920();
    let b = open(&mut wb, w, buf("b"), How::Pin);
    let a = open(&mut wb, w, file("a"), How::Pin);
    wb.close(b, U).unwrap();
    wb.close(a, U).unwrap();
    wb.buffer_gone("b");
    wb.reopen_closed(w, U).unwrap();
    assert_eq!(center_refs(&wb, w), [file("a")]);
    assert!(
        wb.reopen_closed(w, U).is_err(),
        "the killed buffer is skipped"
    );
    assert_eq!(center_refs(&wb, w), [file("a")]);
}

#[test]
fn update_tab_never_moves_anything() {
    let (mut wb, w) = wb_1920();
    let (g1, _) = two_groups(&mut wb, w);
    let a = wb.tabs_of(g1)[0];
    let before = win(&wb, w).clone();
    let tabs_before: Vec<Vec<TabId>> = wb.groups(w).into_iter().map(|g| wb.tabs_of(g)).collect();
    let f = TabFields {
        title: Some("a.rs (renamed)".into()),
        icon: Some("rust".into()),
        marks: Some(vec!["agent".into()]),
        dirty: Some(true),
        ref_path: Some("/p/a.rs".into()),
    };
    wb.update_tab(a, f).unwrap();
    let after = win(&wb, w);
    assert_eq!(after.center, before.center);
    assert_eq!(after.focus, before.focus);
    assert_eq!(after.left, before.left);
    let tabs_after: Vec<Vec<TabId>> = wb.groups(w).into_iter().map(|g| wb.tabs_of(g)).collect();
    assert_eq!(tabs_after, tabs_before);
    let t = wb.tab(a).unwrap();
    assert_eq!(
        (t.title.as_str(), t.dirty, t.marks.len()),
        ("a.rs (renamed)", true, 1)
    );
    assert_eq!(
        t.r,
        Ref::File {
            path: "/p/a.rs".into(),
            at: None
        }
    );
}

#[test]
fn attention_count_is_shared_by_every_os_window() {
    let (mut wb, w1) = wb_1920();
    let w2 = wb.window_new("m0", WinSize::Px { w: 1280, h: 800 }, 1.0, false);
    wb.set_attention(3, vec![("approve".into(), 2), ("answer".into(), 1)]);
    assert_eq!(wb.attention().count, 3);
    let q1 = wb.query(w1, "attention").unwrap();
    assert_eq!(q1, wb.query(w2, "attention").unwrap());
    assert_eq!(q1[0], QueryItem::Int(3));
}
