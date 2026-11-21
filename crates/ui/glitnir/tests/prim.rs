//! Task 15: the chrome primitives, the two glyph atlases, text runs.
use glitnir::atlas::*;
use glitnir::geom::Rect;
use glitnir::prim::*;
use glitnir::text::*;

const W: i32 = 64;
const H: i32 = 32;
const BG: u32 = 0xff20_2020;
const RED: u32 = 0xffff_0000;
const BLUE: u32 = 0xff00_00ff;

fn target(px: &mut [u32]) -> Target<'_> {
    Target {
        px,
        w: W,
        h: H,
        stride: W as usize,
        origin: (0, 0),
    }
}

fn canvas() -> Vec<u32> {
    vec![BG; (W * H) as usize]
}

fn at(px: &[u32], x: i32, y: i32) -> u32 {
    px[(y * W + x) as usize]
}

fn key(glyph: u32) -> GlyphKey {
    GlyphKey {
        font: 1,
        glyph,
        size_px: 13,
        scale120: 120,
    }
}

/// A solid 4×6 coverage mask, its top 6 px above the baseline.
fn block(cov: u8) -> Mask {
    Mask {
        w: 4,
        h: 6,
        bearing_x: 0,
        bearing_y: 6,
        data: MaskData::A8(vec![cov; 24]),
    }
}

fn colour_block(argb: u32) -> Mask {
    Mask {
        w: 4,
        h: 6,
        bearing_x: 0,
        bearing_y: 6,
        data: MaskData::Bgra(vec![argb; 24]),
    }
}

fn run(glyphs: Vec<PlacedGlyph>, color: u32, clip: Rect) -> Prim {
    Prim::Text {
        id: 7,
        run: TextRun {
            x: 2,
            baseline: 20,
            glyphs,
            color,
            clip,
            ellipsis: None,
        },
    }
}

fn g(glyph: u32, x: i32, kind: AtlasKind) -> PlacedGlyph {
    PlacedGlyph {
        key: key(glyph),
        x,
        adv: 5,
        kind,
    }
}

const ALL: Rect = Rect::new(0, 0, W, H);

#[test]
fn a_text_run_composes_from_atlas_masks_tinted() {
    let mut a = Atlases::default();
    a.a8.get_or_insert(key(1), || Some(block(255))).unwrap();
    a.a8.get_or_insert(key(2), || Some(block(128))).unwrap();
    let mut px = canvas();
    let p = run(
        vec![g(1, 0, AtlasKind::A8), g(2, 5, AtlasKind::A8)],
        RED,
        ALL,
    );
    compose(&[p], &mut a, ALL, &mut target(&mut px));
    // full coverage: the run's colour; half: half of it over the background
    assert_eq!(at(&px, 3, 16), RED);
    let half = at(&px, 8, 16);
    assert!(
        (half >> 16 & 0xff) > 0x80 && (half >> 8 & 0xff) < 0x20,
        "{half:08x}"
    );
    assert_eq!(at(&px, 3, 21), BG, "below the baseline: untouched");
}

#[test]
fn a_colour_glyph_composes_untinted_from_the_bgra_atlas() {
    let mut a = Atlases::default();
    a.bgra
        .get_or_insert(key(9), || Some(colour_block(BLUE)))
        .unwrap();
    let mut px = canvas();
    compose(
        &[run(vec![g(9, 0, AtlasKind::Bgra)], RED, ALL)],
        &mut a,
        ALL,
        &mut target(&mut px),
    );
    assert_eq!(at(&px, 3, 16), BLUE, "a red run leaves a blue glyph blue");
}

#[test]
fn a_run_mixes_a8_and_bgra_glyphs_in_order() {
    let mut a = Atlases::default();
    a.a8.get_or_insert(key(1), || Some(block(255))).unwrap();
    a.bgra
        .get_or_insert(key(9), || Some(colour_block(BLUE)))
        .unwrap();
    let mut px = canvas();
    let glyphs = vec![
        g(1, 0, AtlasKind::A8),
        g(9, 5, AtlasKind::Bgra),
        g(1, 10, AtlasKind::A8),
    ];
    compose(&[run(glyphs, RED, ALL)], &mut a, ALL, &mut target(&mut px));
    assert_eq!(at(&px, 3, 16), RED);
    assert_eq!(at(&px, 8, 16), BLUE);
    assert_eq!(at(&px, 13, 16), RED);
    // the gap between glyphs (pen 4) is background
    assert_eq!(at(&px, 6, 16), BG);
}

#[test]
fn bgra_is_premultiplied_over_the_background() {
    let mut a = Atlases::default();
    // half-alpha blue, premultiplied: 0x80 alpha, 0x80 blue
    a.bgra
        .get_or_insert(key(9), || Some(colour_block(0x8000_0080)))
        .unwrap();
    let card = 0xff40_4040u32;
    let mut px = vec![card; (W * H) as usize];
    compose(
        &[run(vec![g(9, 0, AtlasKind::Bgra)], RED, ALL)],
        &mut a,
        ALL,
        &mut target(&mut px),
    );
    let p = at(&px, 3, 16);
    // out = src + dst × (1 − 0.5): blue 0x80 + 0x40×0.5 ≈ 0xa0, red and green 0x40×0.5 ≈ 0x20, opaque
    assert_eq!(p >> 24, 0xff);
    assert!((0x9e..=0xa2).contains(&(p & 0xff)), "{p:08x}");
    assert!((0x1e..=0x22).contains(&(p >> 16 & 0xff)), "{p:08x}");
}

#[test]
fn ellipsis_clips_at_the_run_clip() {
    let mut a = Atlases::default();
    for k in [1, 2] {
        a.a8.get_or_insert(key(k), || Some(block(255))).unwrap();
    }
    let glyphs: Vec<_> = (0..8).map(|i| g(1, i * 5, AtlasKind::A8)).collect();
    let r = TextRun {
        x: 2,
        baseline: 20,
        glyphs,
        color: RED,
        clip: Rect::new(0, 0, 24, H),
        ellipsis: Some(Ellipsis {
            key: key(2),
            adv: 5,
            kind: AtlasKind::A8,
        }),
    };
    let v = r.visible();
    // room 24 − 5 = 19: glyphs ending at 2+5, 2+10, 2+15 fit, then the ellipsis at pen 15
    assert_eq!(v.len(), 4);
    assert_eq!(v[3].key, key(2));
    assert_eq!(v[3].x, 15);
    let mut px = canvas();
    compose(
        &[Prim::Text { id: 1, run: r }],
        &mut a,
        ALL,
        &mut target(&mut px),
    );
    for y in 0..H {
        for x in 24..W {
            assert_eq!(at(&px, x, y), BG, "drawn outside the clip at {x},{y}");
        }
    }
    assert_eq!(at(&px, 18, 16), RED, "the ellipsis is drawn");
}

#[test]
fn gradient_quad_two_stops() {
    let mut a = Atlases::default();
    let mut px = vec![0u32; (W * H) as usize];
    let p = Prim::GradQuad {
        id: 3,
        rect: Rect::new(0, 0, W, 8),
        radius: 0.0,
        axis: Axis::H,
        stops: [(0.0, 0xff00_0000), (1.0, 0x0000_0000)],
    };
    compose(&[p], &mut a, ALL, &mut target(&mut px));
    let alpha = |x| at(&px, x, 4) >> 24;
    assert!(alpha(0) > 0xf0, "{:x}", alpha(0));
    assert!(alpha(W - 1) < 0x08, "{:x}", alpha(W - 1));
    assert!((0x70..=0x90).contains(&alpha(W / 2)), "{:x}", alpha(W / 2));
    assert!((0..W - 1).all(|x| alpha(x) >= alpha(x + 1)), "monotone");
}

fn evict_case<T: Texel>(atlas: &mut Atlas<T>, mask: impl Fn() -> Mask) {
    // a mask that fills most of a page: one per page
    let big = |i| GlyphKey {
        font: 2,
        glyph: i,
        size_px: 600,
        scale120: 120,
    };
    for i in 0..PAGES as u32 {
        atlas.get_or_insert(big(i), || Some(mask())).unwrap();
    }
    assert_eq!(atlas.pages(), PAGES);
    assert_eq!(atlas.misses(), PAGES as u64);
    // use every page but the second, so it is the least recently used
    for i in (0..PAGES as u32).filter(|i| *i != 1) {
        assert!(atlas.get(&big(i)).is_some());
    }
    atlas.get_or_insert(big(99), || Some(mask())).unwrap();
    assert_eq!(atlas.evictions(), 1);
    assert_eq!(atlas.pages(), PAGES, "no fifth page");
    assert!(!atlas.contains(&big(1)), "the LRU page went");
    for i in (0..PAGES as u32).filter(|i| *i != 1) {
        assert!(atlas.contains(&big(i)), "page {i} kept");
    }
    // the evicted mask comes back on its next use (a miss)
    atlas.get_or_insert(big(1), || Some(mask())).unwrap();
    assert_eq!(atlas.misses(), PAGES as u64 + 2);
    // a hit makes no mask
    atlas
        .get_or_insert(big(1), || panic!("rasterised twice"))
        .unwrap();
}

#[test]
fn atlas_evicts_lru_and_reinserts() {
    let mut a = Atlases::default();
    evict_case(&mut a.a8, || Mask {
        w: 600,
        h: 600,
        bearing_x: 0,
        bearing_y: 0,
        data: MaskData::A8(vec![9; 600 * 600]),
    });
    evict_case(&mut a.bgra, || Mask {
        w: 600,
        h: 600,
        bearing_x: 0,
        bearing_y: 0,
        data: MaskData::Bgra(vec![0xff00_00ff; 600 * 600]),
    });
}

#[test]
fn every_prim_has_a_stable_id() {
    let r = Rect::new(1, 1, 10, 10);
    let k = key(1);
    let prims = vec![
        Prim::Quad {
            id: 1,
            rect: r,
            radius: 2.0,
            fill: RED,
        },
        Prim::GradQuad {
            id: 2,
            rect: r,
            radius: 0.0,
            axis: Axis::V,
            stops: [(0.0, RED), (1.0, 0)],
        },
        Prim::Ring {
            id: 3,
            rect: r,
            radius: 2.0,
            width: 1,
            argb: BLUE,
        },
        Prim::Shadow {
            id: 4,
            rect: r,
            radius: 2.0,
            blur: 8.0,
            offset: (0.0, 2.0),
            spread: 0.0,
            argb: 0x4000_0000,
        },
        Prim::Sprite {
            id: 5,
            at: (0, 0),
            key: k,
            tint: RED,
        },
        run(vec![], RED, r),
    ];
    let ids: Vec<u64> = prims.iter().map(Prim::id).collect();
    assert_eq!(ids, [1, 2, 3, 4, 5, 7]);
    // the same element rebuilt keeps its id
    assert_eq!(prims.clone().iter().map(Prim::id).collect::<Vec<_>>(), ids);
}

#[test]
fn a_scene_holds_only_allowed_prim_kinds() {
    assert_eq!(
        KINDS,
        ["quad", "grad-quad", "ring", "shadow", "sprite", "text"]
    );
    // no kind carries pixels: the source names no buffer field in the enum
    let src = include_str!("../src/prim.rs");
    let a = src.find("pub enum Prim {").unwrap();
    let b = a + src[a..].find("\n}\n").unwrap();
    for word in ["Vec<u32>", "Vec<u8>", "pixels", "&[u32]", "Arc<[u32]>"] {
        assert!(
            !src[a..b].contains(word),
            "a pixel-carrying primitive: {word}"
        );
    }
}

/// Manager's change 4: every kind clips to its strip or band.
#[test]
fn every_prim_clips_to_its_band() {
    let mut a = Atlases::default();
    a.a8.get_or_insert(key(1), || Some(block(255))).unwrap();
    let band = Rect::new(0, 10, W, 12);
    let half_out = Rect::new(4, 4, 20, 12);
    let prims = vec![
        Prim::Quad {
            id: 1,
            rect: half_out,
            radius: 0.0,
            fill: RED,
        },
        Prim::GradQuad {
            id: 2,
            rect: half_out,
            radius: 0.0,
            axis: Axis::H,
            stops: [(0.0, RED), (1.0, BLUE)],
        },
        Prim::Ring {
            id: 3,
            rect: half_out,
            radius: 0.0,
            width: 2,
            argb: BLUE,
        },
        Prim::Shadow {
            id: 4,
            rect: half_out,
            radius: 0.0,
            blur: 6.0,
            offset: (0.0, 0.0),
            spread: 2.0,
            argb: 0xff00_0000,
        },
        Prim::Sprite {
            id: 5,
            at: (30, 6),
            key: key(1),
            tint: RED,
        },
        run(vec![g(1, 40, AtlasKind::A8)], RED, ALL),
    ];
    let mut px = canvas();
    compose(&prims, &mut a, band, &mut target(&mut px));
    for y in (0..H).filter(|y| !(10..22).contains(y)) {
        for x in 0..W {
            assert_eq!(at(&px, x, y), BG, "drawn outside the band at {x},{y}");
        }
    }
    // the inside half is drawn (the quad alone: the later prims draw over it)
    let mut px = canvas();
    compose(&prims[..1], &mut a, band, &mut target(&mut px));
    assert_eq!(at(&px, 10, 12), RED, "the quad's inside half drawn");
}

#[test]
fn a_colour_strike_scales_once_to_the_run_size() {
    let m = Mask {
        w: 8,
        h: 8,
        bearing_x: 0,
        bearing_y: 8,
        data: MaskData::Bgra(vec![0xff00_00ff; 64]),
    };
    let s = scale_strike(&m, 8, 4);
    assert_eq!((s.w, s.h, s.bearing_y), (4, 4, 4));
    let MaskData::Bgra(d) = &s.data else { panic!() };
    assert!(d.iter().all(|p| *p == 0xff00_00ff));
}
