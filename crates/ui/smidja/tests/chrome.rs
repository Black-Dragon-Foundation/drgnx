//! Task 17: the chrome description (§6.1, §6.3 rules 2–3): golden data, not pixels.
mod fixture;
use fixture::*;
use smidja::*;

/// Every text 8 device px a character: the tests' stand-in for the glue's shaping.
fn measure(s: &str, _r: TextRole) -> u32 {
    8 * s.chars().count() as u32
}

fn rect(x: i32, y: i32, w: i32, h: i32) -> Rect {
    Rect { x, y, w, h }
}

/// Layout A at 1920 × 1080: Files with two sections on the left, two tabs in the center, the right open on Detail.
fn f0(scale: f32) -> (Workbench, WinId, TabId, TabId) {
    let (mut wb, w) = wb_1920();
    wb.declare(Decl::Place {
        place: "files".into(),
        icon: "files".into(),
        view: None,
        sections: vec!["Explorer".into(), "Outline".into()],
        home: None,
        foot: false,
    });
    wb.set_window_size(w, WinSize::Px { w: 1920, h: 1080 }, scale)
        .unwrap();
    wb.side(w, Region::Right, Vis::Show, U).unwrap();
    let a = open(&mut wb, w, file("a.rs"), How::Pin);
    let b = open(&mut wb, w, file("b.rs"), How::Pin);
    (wb, w, a, b)
}

fn one(d: &ChromeDesc, role: ChromeRole) -> &Element {
    let v: Vec<&Element> = d.of_role(role).collect();
    assert_eq!(v.len(), 1, "{role:?}: {v:?}");
    v[0]
}

#[test]
fn chrome_scene_for_flow_f0_at_1920() {
    let (wb, w, a, b) = f0(1.0);
    let d = wb.chrome(w, &measure).expect("a graphical window");
    assert_eq!((d.width, d.height), (1920, 1080));
    // the frame strips
    assert_eq!(one(&d, ChromeRole::TitleRow).rect, rect(0, 0, 1920, 38));
    assert_eq!(one(&d, ChromeRole::StatusBar).rect, rect(0, 1056, 1920, 24));
    assert_eq!(one(&d, ChromeRole::Rail).rect, rect(0, 38, 44, 1018));
    assert_eq!(d.of_role(ChromeRole::RailItem).count(), 9);
    // the cards: left after the rail and a 6 px gap, the center after the left and a gap, the right after the center
    let cards: Vec<Rect> = d.of_role(ChromeRole::Card).map(|e| e.rect).collect();
    assert_eq!(cards[0], rect(50, 38, 272, 1018), "left");
    assert_eq!(cards[1], rect(328, 38, 1188, 1018), "center group");
    assert_eq!(cards[2], rect(1522, 38, 392, 1018), "right");
    // the bands: tab strip 34 + breadcrumb 22 on the group, region headers 34, section headers 26
    assert_eq!(one(&d, ChromeRole::TabStrip).rect, rect(328, 38, 1188, 34));
    assert_eq!(
        one(&d, ChromeRole::Breadcrumb).rect,
        rect(328, 72, 1188, 22)
    );
    let heads: Vec<Rect> = d
        .of_role(ChromeRole::RegionHeader)
        .map(|e| e.rect)
        .collect();
    assert_eq!(heads, vec![rect(50, 38, 272, 34), rect(1522, 38, 392, 34)]);
    let secs: Vec<(String, Rect)> = d
        .of_role(ChromeRole::SectionHeader)
        .map(|e| (e.name.clone(), e.rect))
        .collect();
    assert_eq!(
        secs[0],
        ("Explorer".into(), rect(50, 72, 272, 26)),
        "under the region header"
    );
    assert_eq!(secs[1].0, "Outline");
    assert_eq!(secs[1].1.h, 26);
    // the tabs, in order, with stable ids: the same description twice has the same ids
    let tabs: Vec<u64> = d.of_role(ChromeRole::Tab).map(|e| e.id).collect();
    assert_eq!(
        tabs,
        vec![
            element_id(ChromeRole::Tab, a.0),
            element_id(ChromeRole::Tab, b.0)
        ]
    );
    assert!(
        d.get(element_id(ChromeRole::Tab, b.0))
            .unwrap()
            .state
            .active
    );
    assert_eq!(wb.chrome(w, &measure).unwrap(), d);
    // the right's four tabs, Detail lit, and Detail's pin
    let rt: Vec<&Element> = d.of_role(ChromeRole::RightTabItem).collect();
    assert_eq!(rt.len(), 4);
    assert!(rt[0].state.lit);
    one(&d, ChromeRole::DetailPin);
    // the focus ring is on the focused group's card
    let ring = one(&d, ChromeRole::FocusRing);
    assert_eq!(ring.rect, cards[1]);
    // ids are unique
    let mut ids: Vec<u64> = d.elements.iter().map(|e| e.id).collect();
    ids.sort_unstable();
    ids.dedup();
    assert_eq!(ids.len(), d.elements.len());
}

#[test]
fn chrome_scales_to_device_px() {
    let (wb, w, _, _) = f0(2.0);
    let d = wb.chrome(w, &measure).unwrap();
    assert_eq!(one(&d, ChromeRole::TitleRow).rect, rect(0, 0, 3840, 76));
    assert_eq!(one(&d, ChromeRole::TabStrip).rect.h, 68);
    assert_eq!(one(&d, ChromeRole::Breadcrumb).rect.h, 44);
}

#[test]
fn preview_tab_title_is_italic() {
    let (mut wb, w, a, _) = f0(1.0);
    let p = open(&mut wb, w, file("p.rs"), How::Preview);
    let d = wb.chrome(w, &measure).unwrap();
    let title = |t: TabId| d.get(element_id(ChromeRole::TabTitle, t.0)).unwrap();
    assert_eq!(title(p).text, Some(TextRole::UiItalic));
    assert!(
        d.get(element_id(ChromeRole::Tab, p.0))
            .unwrap()
            .state
            .preview
    );
    assert_eq!(title(a).text, Some(TextRole::Ui));
}

#[test]
fn dirty_dot_and_agent_mark_on_tabs() {
    let (mut wb, w, a, b) = f0(1.0);
    wb.update_tab(
        a,
        TabFields {
            dirty: Some(true),
            ..Default::default()
        },
    )
    .unwrap();
    wb.update_tab(
        b,
        TabFields {
            marks: Some(vec!["agent".into()]),
            ..Default::default()
        },
    )
    .unwrap();
    let d = wb.chrome(w, &measure).unwrap();
    let dot = d
        .get(element_id(ChromeRole::TabDirty, a.0))
        .expect("a's dirty dot");
    assert_eq!(dot.parent, Some(element_id(ChromeRole::Tab, a.0)));
    assert!(d.get(element_id(ChromeRole::TabAgent, a.0)).is_none());
    assert!(
        d.get(element_id(ChromeRole::TabAgent, b.0)).is_some(),
        "b's agent mark"
    );
    assert!(d.get(element_id(ChromeRole::TabDirty, b.0)).is_none());
    // the marks sit between the title and the ×, inside the tab
    let tab = d.get(element_id(ChromeRole::Tab, a.0)).unwrap().rect;
    let close = d.get(element_id(ChromeRole::TabClose, a.0)).unwrap().rect;
    let title = d.get(element_id(ChromeRole::TabTitle, a.0)).unwrap().rect;
    assert!(dot.rect.x >= title.x + title.w && dot.rect.x + dot.rect.w <= close.x);
    assert!(close.x + close.w <= tab.x + tab.w);
}

#[test]
fn folded_right_strip_icons_and_counts_ember_when_needs_you() {
    let (mut wb, w) = wb_at(1500, 900);
    wb.side(w, Region::Right, Vis::Show, U).unwrap();
    assert_eq!(win(&wb, w).fold.right, SideFold::Folded);
    wb.set_attention(3, vec![("agents".into(), 2), ("pull-requests".into(), 1)]);
    let d = wb.chrome(w, &measure).unwrap();
    assert!(
        d.of_role(ChromeRole::RegionHeader).all(|e| e.rect.x < 1400),
        "no right header when folded"
    );
    let strip = one(&d, ChromeRole::FoldStrip);
    assert_eq!(strip.rect.w, 44);
    let items: Vec<(String, String, u64, bool)> = d
        .of_role(ChromeRole::FoldItem)
        .map(|e| {
            (
                e.name.clone(),
                e.icon.clone(),
                e.state.count,
                e.state.needs_you,
            )
        })
        .collect();
    assert_eq!(
        items,
        vec![
            ("detail".into(), "info".into(), 0, false),
            ("agents".into(), "bot".into(), 2, true),
            ("inbox".into(), "inbox".into(), 0, false),
            ("pull-requests".into(), "git-pull-request".into(), 1, false),
        ]
    );
    let chip = one(&d, ChromeRole::TitleNeedsYou);
    assert_eq!((chip.state.count, chip.state.needs_you), (3, true));
}

#[test]
fn band_rects_equal_the_edges_sent() {
    let (mut wb, w, _, _) = f0(1.0);
    let g = ag(&wb, w);
    let v = wb.realisation(w).unwrap().version;
    // Emacs laid the group out 3 px lower and 2 px narrower than asked, the left 4 px wider, its second section at 500
    let edges = vec![
        (EdgeKey::Group(g), rect(328, 41, 1186, 1000)),
        (EdgeKey::Region(Region::Left), rect(50, 38, 276, 1018)),
        (EdgeKey::Section(1), rect(50, 500, 276, 556)),
    ];
    assert!(wb.set_edges(w, v, edges));
    let d = wb.chrome(w, &measure).unwrap();
    assert_eq!(one(&d, ChromeRole::TabStrip).rect, rect(328, 41, 1186, 34));
    assert_eq!(
        one(&d, ChromeRole::Breadcrumb).rect,
        rect(328, 75, 1186, 22)
    );
    assert_eq!(
        d.get(element_id(ChromeRole::Card, 0x100 + g.0))
            .unwrap()
            .rect,
        rect(328, 41, 1186, 1000)
    );
    let heads: Vec<Rect> = d
        .of_role(ChromeRole::RegionHeader)
        .map(|e| e.rect)
        .collect();
    assert_eq!(heads[0], rect(50, 38, 276, 34));
    let secs: Vec<Rect> = d
        .of_role(ChromeRole::SectionHeader)
        .map(|e| e.rect)
        .collect();
    assert_eq!(secs[1], rect(50, 500, 276, 26));
}

#[test]
fn a_terminal_window_has_no_graphical_chrome() {
    let mut wb = Workbench::new();
    let w = wb.window_new(
        "m0",
        WinSize::Cells {
            cols: 120,
            lines: 40,
        },
        1.0,
        true,
    );
    assert!(wb.chrome(w, &measure).is_none());
}

#[test]
fn element_at_answers_the_deepest_element() {
    let (wb, w, a, _) = f0(1.0);
    let d = wb.chrome(w, &measure).unwrap();
    let close = d.get(element_id(ChromeRole::TabClose, a.0)).unwrap().rect;
    let hit = element_at(&d, close.x + 2, close.y + 2).unwrap();
    assert_eq!(hit.id, element_id(ChromeRole::TabClose, a.0));
    let tab = d.get(element_id(ChromeRole::Tab, a.0)).unwrap().rect;
    // the tab's own padding, left of its icon
    assert_eq!(
        element_at(&d, tab.x + 2, tab.y + 2).unwrap().id,
        element_id(ChromeRole::Tab, a.0)
    );
}
