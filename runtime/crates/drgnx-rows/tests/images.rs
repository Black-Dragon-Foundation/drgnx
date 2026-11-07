//! SVG images coloured from the editor's palette, and the image set a (view, class) sends them from.

use drgnx_rows::image::ImageSet;
use drgnx_rows::svg::{Palette, Svg};
use drgnx_rows::{ImageId, RowBuilder};

/// Every colour-looking token in SVG: `#…` values and `rgb(` calls.
fn colour_tokens(svg: &str) -> Vec<String> {
    let mut out = Vec::new();
    let b = svg.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'#' {
            let end = (i + 1..b.len())
                .find(|&j| !b[j].is_ascii_alphanumeric())
                .unwrap_or(b.len());
            out.push(svg[i..end].to_owned());
            i = end;
        } else if svg[i..].starts_with("rgb(") {
            out.push("rgb(".to_owned());
            i += 4;
        } else {
            i += 1;
        }
    }
    out
}

#[test]
fn svg_takes_colours_from_env_palette() {
    let palette = Palette(vec![
        ("lane".into(), "#a1b2c3".into()),
        ("chip".into(), "#0f0e0d".into()),
    ]);
    let mut svg = Svg::new(&palette, 40, 16);
    svg.rect(0.0, 0.0, 40.0, 16.0, 3.0, "chip")
        .line((2.0, 8.0), (38.0, 8.0), 1.0, "lane")
        .path("M0 0 L4 4", 1.0, "lane")
        .text(4.0, 12.0, 11.0, "missing-role", "a<b & \"c\"");
    let out = svg.finish();
    assert!(out.contains("#a1b2c3") && out.contains("#0f0e0d"), "{out}");
    for t in colour_tokens(&out) {
        assert!(
            t == "#a1b2c3" || t == "#0f0e0d",
            "colour literal {t} outside the palette: {out}"
        );
    }
    // a role the palette lacks takes the text's colour; text is escaped
    assert!(out.contains("fill=\"currentColor\""), "{out}");
    assert!(out.contains("a&lt;b &amp; &quot;c&quot;"), "{out}");
    // a palette value that is not a colour is never written
    let bad = Palette(vec![("lane".into(), "red\" onload=\"x".into())]);
    let mut svg = Svg::new(&bad, 4, 4);
    svg.line((0.0, 0.0), (4.0, 4.0), 1.0, "lane");
    assert!(!svg.finish().contains("onload"));
}

#[test]
fn image_id_is_content_hash_and_epoch() {
    let mut set = ImageSet::default();
    let a = set.add("<svg>a</svg>".into(), 3);
    assert_eq!(a, ImageId::of(b"<svg>a</svg>", 3));
    assert_eq!(
        set.add("<svg>a</svg>".into(), 3),
        a,
        "the same content and epoch is the same image"
    );
    let b = set.add("<svg>a</svg>".into(), 4);
    assert_ne!(a, b, "a new epoch never reuses a tile");
    assert_eq!(b.hash, a.hash);
    assert_ne!(set.add("<svg>b</svg>".into(), 3).hash, a.hash);
}

fn row(key: &str, img: ImageId) -> drgnx_rows::Row {
    let mut b = RowBuilder::new(key);
    b.push("x", None).image(img, "tile");
    b.finish()
}

#[test]
fn reset_carries_every_live_image() {
    let mut set = ImageSet::default();
    let a = set.add("<svg>a</svg>".into(), 1);
    let b = set.add("<svg>b</svg>".into(), 1);
    let unused = set.add("<svg>c</svg>".into(), 1);
    let rows = vec![row("1", a), row("2", b)];
    let first = set.for_patch(&rows, true);
    assert_eq!(first.iter().map(|i| i.0).collect::<Vec<_>>(), {
        let mut v = vec![a, b];
        v.sort();
        v
    });
    // the editor dropped its images at the reset: a second reset sends them all again
    let again = set.for_patch(&rows, true);
    assert_eq!(again.len(), 2);
    assert!(
        !again.iter().any(|i| i.0 == unused),
        "an image no row names is not sent"
    );
    assert_eq!(set.len(), 2, "an image no row names is dropped");
}

#[test]
fn insert_sends_only_new_images() {
    let mut set = ImageSet::default();
    let a = set.add("<svg>a</svg>".into(), 1);
    let rows = vec![row("1", a)];
    assert_eq!(set.for_patch(&rows, true).len(), 1);
    let b = set.add("<svg>b</svg>".into(), 1);
    let rows = vec![row("1", a), row("2", b)];
    let sent = set.for_patch(&rows, false);
    assert_eq!(sent, vec![(b, "<svg>b</svg>".to_owned())]);
    assert!(
        set.for_patch(&rows, false).is_empty(),
        "nothing new: nothing sent"
    );
}
