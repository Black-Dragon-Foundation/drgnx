//! Task 22: drags (§6.4): a tab dropped on a zone, a divider dragged, and tab strips that do not fit.
mod fixture;
use fixture::*;
use smidja::abi::Val;
use smidja::drag::DropCommand;
use smidja::hit::element_key;
use smidja::*;

fn measure(s: &str, _r: TextRole) -> u32 {
    8 * s.chars().count() as u32
}

fn card(d: &ChromeDesc, key: u64) -> Rect {
    d.of_role(ChromeRole::Card)
        .find(|e| element_key(e.id) == key)
        .unwrap_or_else(|| panic!("no card {key:#x}"))
        .rect
}

fn tab(d: &ChromeDesc, t: TabId) -> Option<&Element> {
    d.of_role(ChromeRole::Tab)
        .find(|e| element_key(e.id) == t.0)
}

fn mid(r: Rect) -> (i32, i32) {
    (r.x + r.w / 2, r.y + r.h / 2)
}

/// LP logical pixels at SCALE, through the one conversion (the scale-zoom standard).
fn px(lp: f32, scale: f32) -> i32 {
    kvardi::Lp(lp)
        .to_px(&kvardi::Scale {
            output: scale,
            ..kvardi::Scale::default()
        })
        .0
}

/// Two groups side by side (a.rs, b.rs in the first; c.rs in the second) and the bottom shown, at SCALE.
fn scene(scale: f32) -> (Workbench, WinId, GroupId, GroupId, TabId) {
    let (mut wb, w) = wb_1920();
    wb.set_window_size(w, WinSize::Px { w: 1920, h: 1080 }, scale)
        .unwrap();
    let a = open(&mut wb, w, file("a.rs"), How::Pin);
    open(&mut wb, w, file("b.rs"), How::Pin);
    let g1 = ag(&wb, w);
    let (_, g2) = wb.split(g1, Side::Right, U).expect("split");
    open_in(&mut wb, w, file("c.rs"), How::Pin, g2);
    wb.bottom(w, BottomRef::Kind("terminal".into()), Vis::Show, U)
        .unwrap();
    (wb, w, g1, g2, a)
}

/// Drag tab T of DESC from its middle to (X, Y): what the drop zone lights, and the drop's command.
fn drop_at(
    wb: &Workbench,
    w: WinId,
    d: &ChromeDesc,
    t: TabId,
    (x, y): (i32, i32),
) -> (Option<(MoveTarget, Option<Rect>)>, Option<DropCommand>) {
    let (px, py) = mid(tab(d, t).expect("the tab").rect);
    let mut g = wb.drag_begin(w, d, px, py).expect("a drag on a tab");
    g.motion(wb, d, x, y);
    let zone = g.zone(d);
    (zone, g.end(wb, d, x, y))
}

#[test]
fn a_press_moves_a_scaled_threshold_before_it_is_a_drag() {
    let (wb, w, _g1, _g2, a) = scene(2.0);
    let d = wb.chrome(w, &measure).expect("graphical");
    let (px, py) = mid(tab(&d, a).expect("the tab").rect);
    let mut g = wb.drag_begin(w, &d, px, py).expect("a drag on a tab");
    // 5 device px is 2.5 logical: under the 4 lp threshold at scale 2 (8 px), over it at scale 1
    g.motion(&wb, &d, px + 5, py);
    assert!(!g.started());
    g.motion(&wb, &d, px + 8, py);
    assert!(g.started());
}

#[test]
fn drop_targets_group_new_split_bottom_outside_tear_out() {
    for scale in [1.0, 2.0] {
        let (wb, w, g1, g2, a) = scene(scale);
        let d = wb.chrome(w, &measure).expect("graphical");
        let c2 = card(&d, 0x100 + g2.0);
        let c1 = card(&d, 0x100 + g1.0);
        let bottom = card(&d, Region::Bottom as u64);
        let mv = |target| Some(DropCommand::TabMove { tab: a, target });
        // the other group's middle: into it, the whole card lit
        let (zone, cmd) = drop_at(&wb, w, &d, a, mid(c2));
        assert_eq!(zone, Some((MoveTarget::Group(g2), Some(c2))), "s{scale}");
        assert_eq!(cmd, mv(MoveTarget::Group(g2)), "s{scale}");
        // its right quarter: a new group to its right, the right half lit
        let (zone, cmd) = drop_at(&wb, w, &d, a, (c2.x + c2.w - 4, c2.y + c2.h / 2));
        let half = Rect {
            x: c2.x + c2.w / 2,
            w: c2.w - c2.w / 2,
            ..c2
        };
        assert_eq!(
            zone,
            Some((MoveTarget::NewGroup(g2, Side::Right), Some(half)))
        );
        assert_eq!(cmd, mv(MoveTarget::NewGroup(g2, Side::Right)));
        // its bottom quarter: a new group below
        let (_, cmd) = drop_at(&wb, w, &d, a, (c2.x + c2.w / 2, c2.y + c2.h - 4));
        assert_eq!(cmd, mv(MoveTarget::NewGroup(g2, Side::Down)));
        // the bottom panel's card
        let (zone, cmd) = drop_at(&wb, w, &d, a, mid(bottom));
        assert_eq!(zone, Some((MoveTarget::Bottom, Some(bottom))));
        assert_eq!(cmd, mv(MoveTarget::Bottom));
        // outside the OS window: torn out, nothing lit
        let (zone, cmd) = drop_at(&wb, w, &d, a, (-40, c1.y));
        assert_eq!(zone, Some((MoveTarget::NewOsWindow, None)));
        assert_eq!(cmd, mv(MoveTarget::NewOsWindow));
        // its own group's middle, or no move past the threshold: nothing
        assert_eq!(drop_at(&wb, w, &d, a, mid(c1)).1, None);
        let (px, py) = mid(tab(&d, a).unwrap().rect);
        assert_eq!(drop_at(&wb, w, &d, a, (px + 1, py + 1)).1, None);
        // the command as Lisp gets it: the move_tab op's arguments
        assert_eq!(
            mv(MoveTarget::NewGroup(g2, Side::Right))
                .unwrap()
                .command(w),
            (
                "tab-move",
                vec![
                    Val::Int(a.0 as i64),
                    Val::List(vec![
                        Val::Sym("new-group".into()),
                        Val::Int(g2.0 as i64),
                        Val::Sym("right".into())
                    ])
                ]
            )
        );
    }
}

#[test]
fn live_resize_is_one_realisation_per_frame_at_most() {
    for scale in [1.0, 2.0] {
        let (wb, w, g1, g2, _) = scene(scale);
        let d = wb.chrome(w, &measure).expect("graphical");
        let (c1, c2) = (card(&d, 0x100 + g1.0), card(&d, 0x100 + g2.0));
        // the divider: the gap between the two groups' cards
        let gx = (c1.x + c1.w + c2.x) / 2;
        let gy = c1.y + c1.h / 2;
        let mut g = wb.drag_begin(w, &d, gx, gy).expect("a divider");
        assert_eq!(g.divider(), Some(Axis::Row));
        assert_eq!(g.take_live(), None, "nothing before a move");
        // many motions in one frame: one resize handed on, the newest
        for dx in 1..=20 {
            g.motion(&wb, &d, gx - dx * 10, gy);
        }
        let Some(DropCommand::SplitResize { path, weights }) = g.take_live() else {
            panic!("a live split resize")
        };
        assert_eq!(path, Vec::<usize>::new());
        assert!(
            (weights.iter().sum::<f32>() - 1.0).abs() < 1e-3,
            "{weights:?}"
        );
        assert!(weights[0] < weights[1], "{weights:?}");
        assert_eq!(g.take_live(), None, "at most one per frame");
        g.motion(&wb, &d, gx - 150, gy);
        assert!(g.take_live().is_some(), "the next frame's");
        let end = g.end(&wb, &d, gx - 150, gy);
        assert!(
            matches!(end, Some(DropCommand::SplitResize { .. })),
            "{end:?}"
        );
        // the bottom's top edge: the region's size, logical px
        let b = card(&d, Region::Bottom as u64);
        let by = b.y - px(3.0, scale);
        let g = wb
            .drag_begin(w, &d, b.x + b.w / 2, by)
            .expect("the bottom's divider");
        assert_eq!(g.divider(), Some(Axis::Column));
        let to = b.y - px(100.0, scale);
        assert_eq!(
            g.end(&wb, &d, b.x + b.w / 2, to),
            Some(DropCommand::RegionResize {
                region: Region::Bottom,
                size: ((b.y + b.h - to) as f32 / scale).round() as u32
            })
        );
        // a press on a card's inside is no drag
        assert!(wb.drag_begin(w, &d, mid(c2).0, mid(c2).1).is_none());
    }
}

/// One group in a 900 px wide window with tabs t0..t11, the last active.
fn crowded(scale: f32) -> (Workbench, WinId, GroupId, Vec<TabId>) {
    let (mut wb, w) = wb_at(900, 700);
    wb.set_window_size(w, WinSize::Px { w: 900, h: 700 }, scale)
        .unwrap();
    let tabs: Vec<TabId> = (0..12)
        .map(|i| open(&mut wb, w, file(&format!("tab-{i:02}.rs")), How::Pin))
        .collect();
    let g = ag(&wb, w);
    (wb, w, g, tabs)
}

fn strip(d: &ChromeDesc) -> Rect {
    d.of_role(ChromeRole::TabStrip)
        .next()
        .expect("a strip")
        .rect
}

fn inside(e: &Element, r: Rect) -> bool {
    e.rect.x >= r.x && e.rect.x + e.rect.w <= r.x + r.w
}

#[test]
fn strip_keeps_the_active_tab_in_view() {
    for scale in [1.0, 2.0] {
        let (mut wb, w, g, tabs) = crowded(scale);
        let d = wb.chrome(w, &measure).unwrap();
        let s = strip(&d);
        let last = tab(&d, tabs[11]).expect("the active tab is shown");
        assert!(inside(last, s), "s{scale}: {:?} in {s:?}", last.rect);
        assert!(tab(&d, tabs[0]).is_none(), "the first is scrolled away");
        // no tab is under the strip's arrows or buttons
        let arrows = d
            .of_role(ChromeRole::StripScrollLeft)
            .next()
            .expect("arrows when tabs are hidden")
            .rect;
        for e in d.of_role(ChromeRole::Tab) {
            assert!(
                e.rect.x + e.rect.w <= arrows.x,
                "{:?} over {arrows:?}",
                e.rect
            );
        }
        // the wheel scrolls to the start, past the active tab; the chrome is new, the model's version is not
        let (v, n) = (wb.version(), wb.chrome_generation());
        assert!(wb.tab_strip_scroll(g, -20));
        assert_eq!(wb.version(), v);
        assert!(wb.chrome_generation() > n);
        let d = wb.chrome(w, &measure).unwrap();
        assert!(tab(&d, tabs[0]).is_some_and(|e| inside(e, s)));
        assert!(tab(&d, tabs[11]).is_none());
        assert!(!wb.tab_strip_scroll(g, -1), "already at the start");
        // activating a hidden tab brings it into view again
        open(&mut wb, w, file("tab-10.rs"), How::Pin);
        let d = wb.chrome(w, &measure).unwrap();
        assert!(tab(&d, tabs[10]).is_some_and(|e| inside(e, s)));
    }
}

#[test]
fn plus_n_counts_hidden_tabs() {
    for scale in [1.0, 2.0] {
        let (wb, w, _, _) = crowded(scale);
        let d = wb.chrome(w, &measure).unwrap();
        let shown = d.of_role(ChromeRole::Tab).count();
        assert!(shown < 12);
        let count = d.of_role(ChromeRole::StripCount).next().expect("+N");
        assert_eq!(count.name, format!("+{}", 12 - shown));
        assert!(d.of_role(ChromeRole::StripFade).next().is_some());
        // all of them fitting: no count, no arrows, no fade
        let (mut wb, w) = wb_1920();
        open(&mut wb, w, file("a.rs"), How::Pin);
        let d = wb.chrome(w, &measure).unwrap();
        for role in [
            ChromeRole::StripCount,
            ChromeRole::StripScrollLeft,
            ChromeRole::StripScrollRight,
            ChromeRole::StripFade,
        ] {
            assert!(d.of_role(role).next().is_none(), "{role:?}");
        }
    }
}
