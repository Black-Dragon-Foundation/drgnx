//! Task 20: hit targets (§6.4): every element a click acts on answers its command and the arguments that name it back.
mod fixture;
use fixture::*;
use smidja::abi::Val;
use smidja::hit::{HitTarget, element_key, hit, hover, kind_name, on_chrome, target};
use smidja::*;

fn measure(s: &str, _r: TextRole) -> u32 {
    8 * s.chars().count() as u32
}

/// Layout A at 1920 × 1080, the right open on Detail, two tabs in the center (one dirty), attention on the inbox.
fn scene(scale: f32) -> (ChromeDesc, TabId, TabId, GroupId) {
    let (mut wb, w) = wb_1920();
    wb.set_window_size(w, WinSize::Px { w: 1920, h: 1080 }, scale)
        .unwrap();
    wb.side(w, Region::Right, Vis::Show, U).unwrap();
    let a = open(&mut wb, w, file("a.rs"), How::Pin);
    let b = open(&mut wb, w, file("b.rs"), How::Pin);
    wb.update_tab(
        b,
        TabFields {
            dirty: Some(true),
            ..TabFields::default()
        },
    )
    .unwrap();
    wb.set_attention(2, vec![("inbox".into(), 2)]);
    let d = wb.chrome(w, &measure).expect("graphical");
    let g = GroupId(element_key(
        d.of_role(ChromeRole::TabStrip).next().expect("a strip").id,
    ));
    (d, a, b, g)
}

fn center(e: &Element) -> (i32, i32) {
    (e.rect.x + e.rect.w / 2, e.rect.y + e.rect.h / 2)
}

fn at(d: &ChromeDesc, e: &Element) -> Option<HitTarget> {
    let (x, y) = center(e);
    target(d, x, y)
}

fn first(d: &ChromeDesc, role: ChromeRole, pick: impl Fn(&Element) -> bool) -> &Element {
    d.of_role(role)
        .find(|e| pick(e))
        .unwrap_or_else(|| panic!("no {role:?}"))
}

#[test]
fn every_element_round_trips_to_its_command_id() {
    for scale in [1.0, 2.0, 1.25] {
        let (d, a, b, g) = scene(scale);
        let int = |v: u64| Val::Int(v as i64);
        // a tab and each of its parts but the ×: tab-activate, the tab's id back
        for t in [a, b] {
            let tab = first(&d, ChromeRole::Tab, |e| element_key(e.id) == t.0);
            for role in [
                ChromeRole::Tab,
                ChromeRole::TabIcon,
                ChromeRole::TabTitle,
                ChromeRole::TabClose,
            ] {
                let e = first(&d, role, |e| element_key(e.id) == t.0);
                let h = at(&d, e).unwrap_or_else(|| panic!("{role:?} at {scale}"));
                if role == ChromeRole::TabClose {
                    assert_eq!((h.command_id, h.id), ("tab-close", e.id), "{scale}");
                } else {
                    assert_eq!(
                        (h.command_id, h.id),
                        ("tab-activate", tab.id),
                        "{role:?} {scale}"
                    );
                }
                assert_eq!(h.args, vec![int(t.0)]);
            }
        }
        let dirty = first(&d, ChromeRole::TabDirty, |_| true);
        assert_eq!(at(&d, dirty).map(|h| h.args), Some(vec![int(b.0)]));
        // every rail item: place-go with its place
        let items: Vec<&Element> = d.of_role(ChromeRole::RailItem).collect();
        assert_eq!(items.len(), 9);
        for e in items {
            let h = at(&d, e).expect("a rail item");
            assert_eq!(h.command_id, "place-go");
            assert_eq!(h.args, vec![Val::Str(e.name.clone())]);
        }
        // the right's four tabs: right-show with the tab's name
        let names: Vec<Vec<Val>> = d
            .of_role(ChromeRole::RightTabItem)
            .map(|e| {
                let h = at(&d, e).expect("a right tab");
                assert_eq!(h.command_id, "right-show");
                h.args
            })
            .collect();
        let want: Vec<Vec<Val>> = ["detail", "agents", "inbox", "pull-requests"]
            .iter()
            .map(|n| vec![Val::Sym((*n).into())])
            .collect();
        assert_eq!(names, want);
        // status and title segments, the strip's buttons, the window controls
        for (role, cmd, args) in [
            (ChromeRole::StatusNeedsYou, "needs-you-show", vec![]),
            (ChromeRole::TitleNeedsYou, "needs-you-show", vec![]),
            (
                ChromeRole::TitleAgents,
                "right-show",
                vec![Val::Sym("agents".into())],
            ),
            (ChromeRole::TitleSearch, "quick-open", vec![]),
            (
                ChromeRole::StripSplit,
                "group-split",
                vec![int(g.0), Val::Sym("right".into())],
            ),
            (ChromeRole::StripMore, "group-more", vec![int(g.0)]),
            (ChromeRole::DetailPin, "detail-pin", vec![]),
            (ChromeRole::WinMinimize, "window-minimize", vec![]),
            (ChromeRole::WinMaximize, "window-maximize", vec![]),
            (ChromeRole::WinClose, "window-close", vec![]),
        ] {
            let e = first(&d, role, |_| true);
            let h = at(&d, e).unwrap_or_else(|| panic!("{role:?}"));
            assert_eq!(
                (h.element, h.command_id, h.args),
                (role, cmd, args),
                "{scale}"
            );
        }
        // backgrounds act on nothing
        for role in [
            ChromeRole::TitleRow,
            ChromeRole::StatusBar,
            ChromeRole::Breadcrumb,
            ChromeRole::RegionHeader,
        ] {
            let e = first(&d, role, |_| true);
            let (x, _) = center(e);
            // a corner of it no child covers
            assert_eq!(
                target(&d, e.rect.x + 1, e.rect.y + 1),
                None,
                "{role:?} at {x}"
            );
        }
    }
}

#[test]
fn hover_is_the_tab_for_its_parts_and_none_off_targets() {
    let (d, a, _, _) = scene(2.0);
    let tab = first(&d, ChromeRole::Tab, |e| element_key(e.id) == a.0);
    let title = first(&d, ChromeRole::TabTitle, |e| element_key(e.id) == a.0);
    let close = first(&d, ChromeRole::TabClose, |e| element_key(e.id) == a.0);
    let (x, y) = center(title);
    assert_eq!(hover(&d, x, y), Some(tab.id));
    let (x, y) = center(close);
    assert_eq!(hover(&d, x, y), Some(close.id));
    let crumb = first(&d, ChromeRole::Breadcrumb, |_| true);
    assert_eq!(hover(&d, crumb.rect.x + 1, crumb.rect.y + 1), None);
}

#[test]
fn hit_reads_the_chrome_on_screen() {
    let (d, a, _, _) = scene(1.0);
    let tab = first(&d, ChromeRole::Tab, |e| element_key(e.id) == a.0).clone();
    let w = d.window;
    assert_eq!(hit(w, 0, 0), None, "nothing on screen yet");
    abi::set_chrome(d);
    let (x, y) = center(&tab);
    assert_eq!(hit(w, x, y).map(|h| h.command_id), Some("tab-activate"));
    assert_eq!(hit(w + 1, x, y), None, "another window's chrome");
}

#[test]
fn a_card_alone_is_not_chrome_for_the_pointer() {
    let (d, _, _, _) = scene(1.0);
    let strip = first(&d, ChromeRole::TabStrip, |_| true).clone();
    let card = d
        .of_role(ChromeRole::Card)
        .find(|c| c.rect.x == strip.rect.x && c.rect.y == strip.rect.y)
        .expect("the group's card")
        .clone();
    let w = d.window;
    abi::set_chrome(d);
    assert!(on_chrome(w, strip.rect.x + 1, strip.rect.y + 1), "the band");
    let (x, y) = (card.rect.x + card.rect.w / 2, card.rect.y + card.rect.h / 2);
    assert!(
        !on_chrome(w, x, y),
        "the card's middle is the Emacs window's"
    );
}

#[test]
fn kind_names_are_lisp_names() {
    assert_eq!(kind_name(ChromeRole::Tab), "tab");
    assert_eq!(kind_name(ChromeRole::TabClose), "tab-close");
    assert_eq!(kind_name(ChromeRole::RightTabItem), "right-tab-item");
}
