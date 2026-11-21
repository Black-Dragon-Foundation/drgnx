//! Task 1: the data and the declarations.
mod fixture;
use fixture::*;
use smidja::*;

#[test]
fn declare_is_idempotent_and_bumps_version() {
    let mut wb = Workbench::new();
    let v0 = wb.version();
    let d = Decl::PageKind {
        kind: "x".into(),
        title: "X".into(),
        icon: "box".into(),
        place: None,
        selects: None,
        view: None,
    };
    let v1 = wb.declare(d.clone());
    assert!(v1 > v0, "a new declaration bumps the version");
    let v2 = wb.declare(d);
    assert_eq!(v2, v1, "the same declaration again changes nothing");
    assert_eq!(wb.kinds().pages.len(), 1);
    let v3 = wb.declare(Decl::PageKind {
        kind: "x".into(),
        title: "X2".into(),
        icon: "box".into(),
        place: None,
        selects: None,
        view: None,
    });
    assert!(v3 > v2, "a changed declaration bumps it");
    assert_eq!(wb.kinds().pages.len(), 1);
    assert_eq!(wb.kinds().page("x").map(|p| p.title.as_str()), Some("X2"));
}

#[test]
fn a_page_kind_names_its_place() {
    let (mut wb, w) = wb_1920();
    assert_eq!(
        wb.kinds()
            .page("extensions")
            .and_then(|p| p.place.as_deref()),
        Some("extensions")
    );
    open(&mut wb, w, page("extensions"), How::Pin);
    assert_eq!(
        win(&wb, w).left.place.as_deref(),
        Some("extensions"),
        "the left follows the page's place"
    );
}

#[test]
fn places_keep_layout_a_order() {
    let mut wb = Workbench::new();
    // declared out of order: a foot place early, Work again later with a new icon
    let mut ds = decls();
    let settings = ds
        .iter()
        .position(|d| matches!(d, Decl::Place { place, .. } if place == "settings"))
        .unwrap();
    let s = ds.remove(settings);
    ds.insert(1, s);
    for d in ds {
        wb.declare(d);
    }
    wb.declare(Decl::Place {
        place: "work".into(),
        icon: "graph-2".into(),
        view: None,
        sections: Vec::new(),
        home: Some("graph".into()),
        foot: false,
    });
    let w = wb.window_new("m0", WinSize::Px { w: 1920, h: 1080 }, 1.0, false);
    let names: Vec<Token> = wb.query(w, "places").unwrap();
    let want: Vec<Token> = [
        "work",
        "files",
        "search",
        "changes",
        "run",
        "machines",
        "extensions",
        "settings",
        "keys",
    ]
    .iter()
    .map(|x| Token::Str(x.to_string()))
    .collect();
    assert_eq!(names, want);
    assert_eq!(
        win(&wb, w).left.place.as_deref(),
        Some("files"),
        "a window starts on the first place without a home"
    );
}

#[test]
fn defaults_match_the_spec() {
    let d = Defaults::default();
    assert_eq!(d.title_row, 38);
    assert_eq!(d.rail, 44);
    assert_eq!((d.left, d.left_min, d.left_max), (272, 200, 480));
    assert_eq!((d.right, d.right_min, d.right_max), (392, 320, 560));
    assert_eq!((d.bottom, d.bottom_min), (240, 120));
    assert_eq!(d.status_bar, 24);
    assert_eq!((d.tab_strip, d.breadcrumb), (34, 22));
    assert_eq!(d.section_header, 26);
    assert_eq!(d.folded_strip, 44);
    assert_eq!(
        (
            d.max_groups,
            d.split_min_w,
            d.split_min_h,
            d.undo_cap,
            d.closed_cap
        ),
        (8, 320, 160, 50, 20)
    );
    let (wb, w) = wb_1920();
    let r = wb.realisation(w).unwrap();
    let center = r
        .regions
        .iter()
        .find(|x| x.region == Region::Center)
        .unwrap();
    assert_eq!(center.size, 1188, "the center is the rest: 1188 at 1920");
}

#[test]
fn builds_for_android() {
    // check.sh --android builds the crate for aarch64-linux-android; this row pins what makes that possible: the model
    // is plain data with no OS handles, so it is Send + Sync and depends on std alone.
    fn plain<T: Send + Sync + Clone>() {}
    plain::<Workbench>();
}
