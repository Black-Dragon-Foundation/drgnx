//! Task 11: `realisation`, `set_edges`, `query`, roles, `snapshot` / `restore` (§4.1, §5.1).
mod fixture;
use fixture::*;
use smidja::*;

fn size(r: &Realisation, reg: Region) -> u32 {
    r.regions.iter().find(|x| x.region == reg).unwrap().size
}

#[test]
fn realisation_scales_logical_to_device_px() {
    let (mut wb, w) = wb_1920();
    wb.set_window_size(w, WinSize::Px { w: 1920, h: 1080 }, 2.0)
        .unwrap();
    let r = wb.realisation(w).unwrap();
    assert_eq!(size(&r, Region::Left), 544);
    assert_eq!(size(&r, Region::Right), 784);
    assert_eq!(size(&r, Region::Rail), 88);
    assert_eq!(size(&r, Region::Center), 2376);
    assert_eq!(r.version, wb.version());
    assert_eq!(
        wb.rect(w, EdgeKey::Region(Region::Left)),
        Some(Rect {
            x: 100,
            y: 76,
            w: 544,
            h: 2036
        })
    );
}

#[test]
fn stale_edges_are_ignored() {
    let (mut wb, w) = wb_1920();
    let v = wb.realisation(w).unwrap().version;
    let e = vec![(
        EdgeKey::Region(Region::Left),
        Rect {
            x: 50,
            y: 38,
            w: 280,
            h: 1018,
        },
    )];
    assert!(wb.set_edges(w, v, e.clone()));
    open(&mut wb, w, file("a"), How::Pin);
    let stale = vec![(
        EdgeKey::Region(Region::Left),
        Rect {
            x: 0,
            y: 0,
            w: 1,
            h: 1,
        },
    )];
    assert!(!wb.set_edges(w, v, stale), "the model moved on");
    assert_eq!(win(&wb, w).edges, e);
}

#[test]
fn edges_override_requested_sizes_for_chrome_and_hit() {
    let (mut wb, w) = wb_1920();
    let g = ag(&wb, w);
    let asked = wb.rect(w, EdgeKey::Region(Region::Left)).unwrap();
    assert_eq!(
        asked,
        Rect {
            x: 50,
            y: 38,
            w: 272,
            h: 1018
        }
    );
    assert_eq!(
        wb.rect(w, EdgeKey::Group(g)).unwrap(),
        Rect {
            x: 328,
            y: 38,
            w: 1188,
            h: 1018
        }
    );
    let v = wb.version();
    let actual = Rect {
        x: 50,
        y: 38,
        w: 281,
        h: 1017,
    };
    let ga = Rect {
        x: 337,
        y: 38,
        w: 1179,
        h: 1017,
    };
    assert!(wb.set_edges(
        w,
        v,
        vec![
            (EdgeKey::Region(Region::Left), actual),
            (EdgeKey::Group(g), ga)
        ]
    ));
    assert_eq!(wb.rect(w, EdgeKey::Region(Region::Left)), Some(actual));
    assert_eq!(wb.rect(w, EdgeKey::Group(g)), Some(ga));
    assert_eq!(
        wb.rect(w, EdgeKey::Region(Region::Right)).unwrap().w,
        392,
        "a region not reported stays as asked"
    );
}

#[test]
fn roles_tree_names_every_region_group_tab_and_chrome_element() {
    let (mut wb, w) = wb_1920();
    let a = open(&mut wb, w, file("a"), How::Pin);
    let b = open(&mut wb, w, file("b"), How::Pin);
    let g = ag(&wb, w);
    wb.bottom(w, BottomRef::Kind("problems".into()), Vis::Show, U)
        .unwrap();
    let roles = wb.roles(w);
    let keys: Vec<&str> = roles.iter().map(|r| r.key.as_str()).collect();
    for k in [
        "region:rail",
        "region:left",
        "region:center",
        "region:right",
        "region:bottom",
        "status",
    ] {
        assert!(keys.contains(&k), "{k}");
    }
    for p in [
        "work",
        "files",
        "search",
        "changes",
        "run",
        "machines",
        "extensions",
        "settings",
        "keys",
    ] {
        let r = roles
            .iter()
            .find(|r| r.key == format!("place:{p}"))
            .unwrap();
        assert_eq!((r.role, r.name.as_str()), ("button", p));
    }
    for t in ["detail", "agents", "inbox", "pull-requests"] {
        assert!(
            roles
                .iter()
                .any(|r| r.role == "button" && r.key == format!("right:{t}"))
        );
    }
    let gl = roles
        .iter()
        .find(|r| r.key == format!("group:{}", g.0))
        .unwrap();
    assert_eq!(gl.role, "tablist");
    let ta = roles
        .iter()
        .find(|r| r.key == format!("tab:{}", a.0))
        .unwrap();
    assert_eq!((ta.role, ta.name.as_str()), ("tab", "a"));
    let roles_set: std::collections::BTreeSet<&str> = roles.iter().map(|r| r.role).collect();
    assert_eq!(
        roles_set.into_iter().collect::<Vec<_>>(),
        ["button", "region", "status", "tab", "tablist"]
    );
    // stable by id: another tab's rename leaves a's role as it was
    wb.update_tab(
        b,
        TabFields {
            title: Some("b2".into()),
            ..TabFields::default()
        },
    )
    .unwrap();
    let ta2 = wb
        .roles(w)
        .into_iter()
        .find(|r| r.key == format!("tab:{}", a.0))
        .unwrap();
    assert_eq!(&ta2, ta);
    assert_eq!(
        wb.query(w, "roles")
            .unwrap()
            .iter()
            .filter(|t| **t == Token::Open)
            .count(),
        wb.roles(w).len()
    );
}

#[test]
fn snapshot_restore_round_trips() {
    let (mut wb, w) = wb_1920();
    open(&mut wb, w, file("a"), How::Pin);
    wb.select(w, "file", "a", Source::Left, U).unwrap();
    let s = wb.snapshot();
    let copy = wb.clone();
    open(&mut wb, w, file("b"), How::Pin);
    wb.split(ag(&wb, w), Side::Right, U).unwrap();
    wb.overlay(w, OverlayKind::Palette, "", U).unwrap();
    assert_ne!(wb, copy);
    wb.restore(s.clone());
    assert_eq!(wb, copy);
    assert_eq!(wb.snapshot(), s);
}
