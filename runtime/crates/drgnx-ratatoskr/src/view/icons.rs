//! The Explorer's icons: drgnx's Lucide files (etc/icons) sized for a row, and the file-kind icon of a name from the
//! table Lisp reads too (etc/icons/files.eld), both built into the hub. An icon draws in `currentColor`: Emacs takes
//! it from the face of the text around the image, so no colour is named here.

use drgnx_rows::ImageId;

/// The file-kind table: one list of `(ICON "ext" ...)`, a kind per line (the outer list's parens ride on the first and
/// last), the first line naming an extension wins.
const FILES: &str = include_str!("../../../../../etc/icons/files.eld");

/// The icons a row can show, by name.
const SVGS: [(&str, &str); 10] = [
    (
        "chevron-down",
        include_str!("../../../../../etc/icons/chevron-down.svg"),
    ),
    (
        "chevron-right",
        include_str!("../../../../../etc/icons/chevron-right.svg"),
    ),
    (
        "folder",
        include_str!("../../../../../etc/icons/folder.svg"),
    ),
    (
        "folder-open",
        include_str!("../../../../../etc/icons/folder-open.svg"),
    ),
    ("file", include_str!("../../../../../etc/icons/file.svg")),
    (
        "file-code",
        include_str!("../../../../../etc/icons/file-code.svg"),
    ),
    (
        "file-text",
        include_str!("../../../../../etc/icons/file-text.svg"),
    ),
    (
        "file-cog",
        include_str!("../../../../../etc/icons/file-cog.svg"),
    ),
    (
        "file-image",
        include_str!("../../../../../etc/icons/file-image.svg"),
    ),
    (
        "file-archive",
        include_str!("../../../../../etc/icons/file-archive.svg"),
    ),
];

/// An icon's size in logical px (`drgnx-icons-size`).
pub const SIZE: f32 = 16.0;

/// The stroke in the icon's 24-unit box at any size (`drgnx-icons-stroke`, the design's `svg.i`).
const STROKE: &str = "1.6";

/// The table's lines as (icon, extensions).
fn table() -> impl Iterator<Item = (&'static str, Vec<&'static str>)> {
    FILES
        .lines()
        .map(str::trim)
        .filter(|l| l.starts_with('(') && !l.starts_with(";;"))
        .filter_map(|l| {
            let inner = l.trim_start_matches('(').trim_end_matches(')');
            let mut words = inner.split_whitespace();
            let icon = words.next()?;
            Some((icon, words.map(|w| w.trim_matches('"')).collect()))
        })
}

/// The icon of the file called NAME: the first table line with an extension NAME ends in (`.EXT`, any case), else
/// `file`.
pub fn file_icon(name: &str) -> &'static str {
    let lower = name.to_lowercase();
    table()
        .find(|(_, exts)| {
            exts.iter().any(|e| {
                lower.len() > e.len()
                    && lower.ends_with(e)
                    && lower[..lower.len() - e.len()].ends_with('.')
            })
        })
        .map_or("file", |(icon, _)| icon)
}

/// Icon NAME as an SVG PX device pixels square with the design's stroke, and its id; none for a name with no file.
pub fn svg(name: &str, px: u32) -> Option<(ImageId, String)> {
    let (_, text) = SVGS.iter().find(|(n, _)| *n == name)?;
    let text = text
        .replace(
            "width=\"24\" height=\"24\"",
            &format!("width=\"{px}\" height=\"{px}\""),
        )
        .replace("stroke-width=\"2\"", &format!("stroke-width=\"{STROKE}\""));
    Some((ImageId::of(text.as_bytes(), 0), text))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [D] The table Lisp reads names the icons: the first line naming an extension, any case, else `file`.
    #[test]
    fn file_icons_follow_the_shared_table() {
        assert_eq!(file_icon("init.el"), "file-code");
        assert_eq!(file_icon("README.MD"), "file-text");
        assert_eq!(file_icon("ci.yaml"), "file-cog");
        assert_eq!(file_icon("dump.tar.gz"), "file-archive");
        assert_eq!(file_icon("shot.png"), "file-image");
        assert_eq!(file_icon("Makefile"), "file");
        assert_eq!(file_icon("md"), "file");
        assert_eq!(file_icon(".editorconfig"), "file-cog");
    }

    /// [D] An icon is sized and stroked as `drgnx-icons--make` does, in `currentColor`; the same icon at the same size
    /// is the same image.
    #[test]
    fn an_icon_is_sized_and_stroked() {
        let (id, s) = svg("folder", 20).unwrap();
        assert!(s.contains("width=\"20\" height=\"20\""), "{s}");
        assert!(s.contains("stroke-width=\"1.6\""), "{s}");
        assert!(s.contains("currentColor"), "{s}");
        assert_eq!(svg("folder", 20).unwrap().0, id);
        assert_ne!(svg("folder", 32).unwrap().0, id);
        assert!(svg("no-such", 16).is_none());
    }
}
