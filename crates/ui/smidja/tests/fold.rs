//! Task 6: folding at narrow widths (§4.6, §6.6): the table at every breakpoint ±1 px and ±1 column.
mod fixture;
use fixture::*;
use smidja::*;

use SideFold::{Folded, Open};

fn fold_at(width: u32) -> Fold {
    let (wb, w) = wb_at(width, 1000);
    wb.fold(w).unwrap()
}

fn tty_at(cols: u32) -> (Workbench, WinId) {
    let mut wb = Workbench::new();
    for d in decls() {
        wb.declare(d);
    }
    let w = wb.window_new("m0", WinSize::Cells { cols, lines: 40 }, 1.0, true);
    (wb, w)
}

#[test]
fn right_folds_when_center_drops_under_900() {
    // 44 rail + 272 left + 392 right + 4 gaps of 6: the center is 900 at 1632
    assert_eq!(fold_at(1631).right, Folded);
    assert_eq!(fold_at(1632).right, Open);
    assert_eq!(fold_at(1632).left, Open);
}

#[test]
fn left_folds_when_center_drops_under_800() {
    // with the right folded to its 44 px strip: the center is 800 at 1184
    assert_eq!(fold_at(1183).left, Folded);
    assert_eq!(fold_at(1184).left, Open);
    assert_eq!(fold_at(1184).right, Folded);
}

#[test]
fn right_folds_first() {
    for w in [1631, 1400, 1200, 1184] {
        let f = fold_at(w);
        assert_eq!((f.left, f.right), (Open, Folded), "{w}");
    }
    let f = fold_at(900);
    assert_eq!((f.left, f.right), (Folded, Folded));
}

#[test]
fn a_user_hidden_side_stays_hidden_at_any_width() {
    let (mut wb, w) = wb_1920();
    wb.side(w, Region::Left, Vis::Hide, U).unwrap();
    for width in (400..=3840).step_by(160) {
        wb.set_window_size(w, WinSize::Px { w: width, h: 1000 }, 1.0)
            .unwrap();
        let r = wb.realisation(w).unwrap();
        let left = r.regions.iter().find(|x| x.region == Region::Left).unwrap();
        assert!(!left.visible && !left.folded, "{width}");
        assert!(!win(&wb, w).left.visible);
    }
}

#[test]
fn a_folded_side_asked_for_opens_as_an_overlay_and_nothing_reflows() {
    let (mut wb, w) = wb_at(1000, 800);
    let before = wb.realisation(w).unwrap().regions;
    wb.navigate(w, "search", U).unwrap();
    assert_eq!(wb.side_overlay(w), Some(Region::Left));
    assert_eq!(
        wb.realisation(w).unwrap().regions,
        before,
        "no region moved"
    );
    assert_eq!(wb.fold(w).unwrap().left, Folded);
}

#[test]
fn esc_click_outside_or_a_pick_closes_and_focus_returns_to_center() {
    let (mut wb, w) = wb_at(1000, 800);
    wb.focus(w, FocusTarget::Region(Region::Right), U).unwrap();
    assert_eq!(wb.side_overlay(w), Some(Region::Right));
    wb.dismiss(w, None, U).unwrap();
    assert_eq!(wb.side_overlay(w), None);
    assert_eq!(focus(&wb, w), Focus::Center(ag(&wb, w)));
    // a pick: the realiser dismisses, then opens what was picked
    wb.navigate(w, "files", U).unwrap();
    wb.dismiss(w, None, U).unwrap();
    open(&mut wb, w, file("a"), How::Pin);
    assert_eq!(focus(&wb, w), Focus::Center(ag(&wb, w)));
}

#[test]
fn tty_right_folds_under_80_columns_left_under_60() {
    // 4 rail + 24 left + 32 right + 4 one-column gaps: the center is 80 at 144 columns
    let (wb, w) = tty_at(143);
    assert_eq!(wb.fold(w).unwrap().right, Folded);
    let (wb, w) = tty_at(144);
    assert_eq!(wb.fold(w).unwrap().right, Open);
    // under 100 columns no rail: 24 left + 2 gaps, the center is 60 at 86
    let (wb, w) = tty_at(85);
    assert_eq!(wb.fold(w).unwrap().left, Folded);
    let (wb, w) = tty_at(86);
    assert_eq!(wb.fold(w).unwrap().left, Open);
    let (wb, w) = tty_at(80);
    assert_eq!(
        wb.fold(w).unwrap(),
        Fold {
            left: Folded,
            right: Folded,
            overlay: None
        }
    );
}

#[test]
fn tty_rail_only_at_100_columns() {
    let rail = |cols| {
        let (wb, w) = tty_at(cols);
        let r = wb.realisation(w).unwrap();
        let x = r
            .regions
            .iter()
            .find(|x| x.region == Region::Rail)
            .unwrap()
            .clone();
        (x.visible, x.size)
    };
    assert_eq!(rail(99), (false, 0));
    assert_eq!(rail(100), (true, 4));
    assert_eq!(rail(120), (true, 4));
}

#[test]
fn folds_recompute_on_side_resize() {
    let (mut wb, w) = wb_at(1700, 1000);
    assert_eq!(wb.fold(w).unwrap().right, Open);
    wb.resize(w, Region::Right, 560, U).unwrap();
    assert_eq!(
        wb.fold(w).unwrap().right,
        Folded,
        "1700 - 44 - 272 - 560 - 24 < 900"
    );
    wb.resize(w, Region::Right, 392, U).unwrap();
    assert_eq!(wb.fold(w).unwrap().right, Open);
    wb.resize(w, Region::Left, 480, U).unwrap();
    assert_eq!(
        wb.fold(w).unwrap().right,
        Folded,
        "a wider left folds the right too"
    );
}

#[test]
fn every_breakpoint_plus_minus_one() {
    let (mut wb, w) = wb_1920();
    let px = |wb: &mut Workbench, width| {
        wb.set_window_size(w, WinSize::Px { w: width, h: 1000 }, 1.0)
            .unwrap();
        let f = wb.fold(w).unwrap();
        (f.left, f.right)
    };
    // down and back up through both breakpoints, on one window
    for _ in 0..2 {
        assert_eq!(px(&mut wb, 1633), (Open, Open));
        assert_eq!(px(&mut wb, 1632), (Open, Open));
        assert_eq!(px(&mut wb, 1631), (Open, Folded));
        assert_eq!(px(&mut wb, 1185), (Open, Folded));
        assert_eq!(px(&mut wb, 1184), (Open, Folded));
        assert_eq!(px(&mut wb, 1183), (Folded, Folded));
        assert_eq!(px(&mut wb, 1184), (Open, Folded));
        assert_eq!(px(&mut wb, 1632), (Open, Open));
    }
    // the same rule in columns, through the one function
    let c = |width, l: Option<u32>, r: Option<u32>| {
        smidja::fold::compute(&FOLD_CELLS, width, false, l, r)
    };
    assert_eq!(c(145, Some(24), Some(32)), (Open, Open));
    assert_eq!(c(144, Some(24), Some(32)), (Open, Open));
    assert_eq!(c(143, Some(24), Some(32)), (Open, Folded));
    assert_eq!(c(87, Some(24), Some(32)), (Open, Folded));
    assert_eq!(c(86, Some(24), Some(32)), (Open, Folded));
    assert_eq!(c(85, Some(24), Some(32)), (Folded, Folded));
    assert_eq!(
        c(85, None, Some(32)),
        (Open, Folded),
        "a hidden left never folds"
    );
    let p = |width| smidja::fold::compute(&FOLD_PX, width, false, Some(272), Some(392));
    assert_eq!(p(1632), (Open, Open));
    assert_eq!(p(1631), (Open, Folded));
}
