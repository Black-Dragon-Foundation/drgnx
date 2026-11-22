//! Task 5: focus, overlays, region intents (§4.3, §9.1).
mod fixture;
use fixture::*;
use smidja::*;

fn ov(wb: &mut Workbench, w: WinId, k: OverlayKind) -> OverlayId {
    wb.overlay(w, k, "", U).unwrap().1
}

#[test]
fn f6_cycles_left_center_groups_right_bottom_skipping_hidden() {
    let (mut wb, w) = wb_1920();
    let (g1, g2) = two_groups(&mut wb, w);
    wb.bottom(w, BottomRef::Kind("problems".into()), Vis::Show, U)
        .unwrap();
    wb.focus(w, FocusTarget::Region(Region::Left), U).unwrap();
    let ring = [
        Focus::Center(g1),
        Focus::Center(g2),
        Focus::Right,
        Focus::Bottom,
        Focus::Left,
    ];
    for f in &ring {
        wb.cycle_region(w, Dir::Next, U).unwrap();
        assert_eq!(&focus(&wb, w), f);
    }
    wb.cycle_region(w, Dir::Prev, U).unwrap();
    assert_eq!(focus(&wb, w), Focus::Bottom);
    wb.side(w, Region::Right, Vis::Hide, U).unwrap();
    wb.focus(w, FocusTarget::Group(g2), U).unwrap();
    wb.cycle_region(w, Dir::Next, U).unwrap();
    assert_eq!(focus(&wb, w), Focus::Bottom, "the hidden right is skipped");
}

#[test]
fn f6_on_a_folded_side_opens_its_overlay() {
    let (mut wb, w) = wb_at(1500, 900);
    let g = ag(&wb, w);
    wb.focus(w, FocusTarget::Group(g), U).unwrap();
    wb.cycle_region(w, Dir::Next, U).unwrap();
    assert_eq!(wb.side_overlay(w), Some(Region::Right));
    let Focus::Overlay(_, ret) = focus(&wb, w) else {
        panic!("an overlay holds focus")
    };
    assert_eq!(*ret, Focus::Center(g));
    wb.cycle_region(w, Dir::Next, U).unwrap();
    assert_eq!(wb.side_overlay(w), None, "moving on closes it");
    assert_eq!(focus(&wb, w), Focus::Left);
}

#[test]
fn the_rail_and_strips_are_never_focus() {
    let (mut wb, w) = wb_at(1500, 900);
    assert!(wb.focus(w, FocusTarget::Region(Region::Rail), U).is_err());
    wb.focus(w, FocusTarget::Region(Region::Right), U).unwrap();
    assert!(
        matches!(focus(&wb, w), Focus::Overlay(..)),
        "the folded right's strip is not a stop: its overlay is"
    );
    for _ in 0..12 {
        wb.cycle_region(w, Dir::Next, U).unwrap();
        assert_ne!(focus(&wb, w), Focus::Right);
    }
}

#[test]
fn hiding_the_focused_region_moves_focus_to_the_active_group() {
    for r in [Region::Left, Region::Right, Region::Bottom] {
        let (mut wb, w) = wb_1920();
        wb.bottom(w, BottomRef::Kind("output".into()), Vis::Show, U)
            .unwrap();
        wb.focus(w, FocusTarget::Region(r), U).unwrap();
        wb.side(w, r, Vis::Hide, U).unwrap();
        assert_eq!(focus(&wb, w), Focus::Center(ag(&wb, w)), "{r:?}");
    }
}

#[test]
fn an_overlay_records_its_return_focus() {
    let (mut wb, w) = wb_1920();
    wb.focus(w, FocusTarget::Region(Region::Left), U).unwrap();
    let id = ov(&mut wb, w, OverlayKind::Palette);
    assert_eq!(focus(&wb, w), Focus::Overlay(id, Box::new(Focus::Left)));
}

#[test]
fn dismiss_restores_the_return_focus() {
    let (mut wb, w) = wb_1920();
    wb.focus(w, FocusTarget::Region(Region::Left), U).unwrap();
    let id = ov(&mut wb, w, OverlayKind::QuickOpen);
    wb.dismiss(w, Some(id), U).unwrap();
    assert_eq!(focus(&wb, w), Focus::Left);
    assert!(wb.overlays(w).is_empty());
}

#[test]
fn at_most_one_modal_overlay() {
    let (mut wb, w) = wb_1920();
    wb.focus(w, FocusTarget::Region(Region::Right), U).unwrap();
    ov(&mut wb, w, OverlayKind::Palette);
    let s = ov(&mut wb, w, OverlayKind::Switcher);
    let kinds: Vec<OverlayKind> = wb.overlays(w).iter().map(|o| o.kind).collect();
    assert_eq!(
        kinds,
        [OverlayKind::Switcher],
        "the switcher replaces the palette"
    );
    assert_eq!(focus(&wb, w), Focus::Overlay(s, Box::new(Focus::Right)));
    wb.dismiss(w, None, U).unwrap();
    assert_eq!(focus(&wb, w), Focus::Right);
}

#[test]
fn minibuffer_and_completion_stack_above_a_modal() {
    let (mut wb, w) = wb_1920();
    let g = ag(&wb, w);
    let p = ov(&mut wb, w, OverlayKind::Palette);
    let m = ov(&mut wb, w, OverlayKind::Minibuffer);
    let c = ov(&mut wb, w, OverlayKind::Completion);
    let kinds: Vec<OverlayKind> = wb.overlays(w).iter().map(|o| o.kind).collect();
    assert_eq!(
        kinds,
        [
            OverlayKind::Palette,
            OverlayKind::Minibuffer,
            OverlayKind::Completion
        ]
    );
    let chain = Focus::Overlay(
        c,
        Box::new(Focus::Overlay(
            m,
            Box::new(Focus::Overlay(p, Box::new(Focus::Center(g)))),
        )),
    );
    assert_eq!(focus(&wb, w), chain);
    wb.dismiss(w, None, U).unwrap();
    assert_eq!(
        focus(&wb, w),
        Focus::Overlay(m, Box::new(Focus::Overlay(p, Box::new(Focus::Center(g)))))
    );
}

#[test]
fn toasts_are_their_own_lane_one_visible() {
    let (mut wb, w) = wb_1920();
    let f = focus(&wb, w);
    let t1 = wb.overlay(w, OverlayKind::Toast, "saved", P).unwrap().1;
    let t2 = wb.overlay(w, OverlayKind::Toast, "pushed", P).unwrap().1;
    assert_eq!(wb.toast(w).map(|o| o.id), Some(t1), "one shown at a time");
    assert!(wb.overlays(w).is_empty(), "not in the overlay stack");
    assert_eq!(focus(&wb, w), f, "a toast never takes focus");
    wb.dismiss(w, Some(t1), P).unwrap();
    assert_eq!(wb.toast(w).map(|o| o.id), Some(t2));
}

#[test]
fn overlays_never_take_region_space_or_enter_undo() {
    let (mut wb, w) = wb_at(1500, 900);
    let before = wb.realisation(w).unwrap();
    ov(&mut wb, w, OverlayKind::Palette);
    ov(&mut wb, w, OverlayKind::Card);
    wb.show_context(w, Target::Detail, true, U).unwrap();
    let after = wb.realisation(w).unwrap();
    assert_eq!(after.regions, before.regions);
    assert_eq!(after.tree, before.tree);
    assert_eq!(wb.undo_depth(w), 0);
}

#[test]
fn resize_clamps_left_200_480_right_320_560_bottom_120_to_half() {
    let (mut wb, w) = wb_1920();
    let cases = [
        (Region::Left, 100, 200),
        (Region::Left, 900, 480),
        (Region::Left, 300, 300),
        (Region::Right, 100, 320),
        (Region::Right, 9999, 560),
        (Region::Bottom, 10, 120),
        (Region::Bottom, 9999, 509),
    ];
    for (r, ask, got) in cases {
        wb.resize(w, r, ask, U).unwrap();
        let x = win(&wb, w);
        let now = match r {
            Region::Left => x.left.width,
            Region::Right => x.right.width,
            _ => x.bottom.height,
        };
        assert_eq!(now, got, "{r:?} {ask}");
    }
}
