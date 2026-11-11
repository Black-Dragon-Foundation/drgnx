//! The Explorer's icons: drgnx's Lucide files (etc/icons) sized for a row, and the file-kind icon of a name from the
//! table Lisp reads too (etc/icons/files.eld), both built into the hub. An icon draws in `currentColor`: Emacs takes
//! it from the face of the text around the image, so no colour is named here.

use drgnx_rows::ImageId;
use std::collections::HashMap;
use std::sync::OnceLock;

/// The file-kind table: a plist of `:names` and `:extensions`, each a list of `(ICON "word" ...)`.
const FILES: &str = include_str!("../../../../../etc/icons/files.eld");

/// The icons a row can show, by name: the Explorer's, then the Work space's Flow (its columns and chips).
const SVGS: [(&str, &str); 20] = [
    (
        "list-checks",
        include_str!("../../../../../etc/icons/list-checks.svg"),
    ),
    (
        "flask-conical",
        include_str!("../../../../../etc/icons/flask-conical.svg"),
    ),
    (
        "pencil",
        include_str!("../../../../../etc/icons/pencil.svg"),
    ),
    (
        "shield",
        include_str!("../../../../../etc/icons/shield.svg"),
    ),
    (
        "git-merge",
        include_str!("../../../../../etc/icons/git-merge.svg"),
    ),
    ("eye", include_str!("../../../../../etc/icons/eye.svg")),
    ("lock", include_str!("../../../../../etc/icons/lock.svg")),
    ("check", include_str!("../../../../../etc/icons/check.svg")),
    (
        "circle",
        include_str!("../../../../../etc/icons/circle.svg"),
    ),
    ("flag", include_str!("../../../../../etc/icons/flag.svg")),
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

/// A datum of the table: a list, a symbol or keyword, or a string.
enum Sexp {
    List(Vec<Sexp>),
    Atom(String),
}

/// Read one datum of the table's text from I (comments skipped); the table is drgnx's own file, so a datum it
/// cannot read is a bug, caught by the tests.
fn read(text: &[u8], i: &mut usize) -> Option<Sexp> {
    loop {
        match text.get(*i)? {
            b';' => {
                while text.get(*i).is_some_and(|c| *c != b'\n') {
                    *i += 1;
                }
            }
            c if c.is_ascii_whitespace() => *i += 1,
            _ => break,
        }
    }
    match text[*i] {
        b'(' => {
            *i += 1;
            let mut items = Vec::new();
            loop {
                while text.get(*i).is_some_and(|c| c.is_ascii_whitespace()) {
                    *i += 1;
                }
                if text.get(*i) == Some(&b')') {
                    *i += 1;
                    return Some(Sexp::List(items));
                }
                items.push(read(text, i)?);
            }
        }
        b'"' => {
            let start = *i + 1;
            *i = start + text[start..].iter().position(|c| *c == b'"')?;
            let s = String::from_utf8_lossy(&text[start..*i]).into_owned();
            *i += 1;
            Some(Sexp::Atom(s))
        }
        _ => {
            let start = *i;
            while text
                .get(*i)
                .is_some_and(|c| !c.is_ascii_whitespace() && *c != b'(' && *c != b')')
            {
                *i += 1;
            }
            Some(Sexp::Atom(
                String::from_utf8_lossy(&text[start..*i]).into_owned(),
            ))
        }
    }
}

/// The table's sections: exact names and extensions, each word → its icon (the first line naming it).
struct Table {
    names: HashMap<String, String>,
    extensions: HashMap<String, String>,
}

fn table() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut t = Table {
            names: HashMap::new(),
            extensions: HashMap::new(),
        };
        let Some(Sexp::List(plist)) = read(FILES.as_bytes(), &mut 0) else {
            return t;
        };
        for pair in plist.chunks(2) {
            let [Sexp::Atom(key), Sexp::List(lines)] = pair else {
                continue;
            };
            let map = match key.as_str() {
                ":names" => &mut t.names,
                ":extensions" => &mut t.extensions,
                _ => continue,
            };
            for line in lines {
                let Sexp::List(words) = line else { continue };
                let mut words = words.iter().filter_map(|w| match w {
                    Sexp::Atom(s) => Some(s.as_str()),
                    Sexp::List(_) => None,
                });
                let Some(icon) = words.next() else { continue };
                for w in words {
                    map.entry(w.to_owned()).or_insert_with(|| icon.to_owned());
                }
            }
        }
        t
    })
}

/// The icon of the file called NAME (any case): its exact name's in the table, else the one of the text after its last
/// dot (a dotfile's name counts), else `file`.
pub fn file_icon(name: &str) -> &'static str {
    let lower = name.to_lowercase();
    let t = table();
    t.names
        .get(&lower)
        .or_else(|| {
            let (_, ext) = lower.rsplit_once('.')?;
            t.extensions.get(ext)
        })
        .map_or("file", String::as_str)
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

    /// [D] The table Lisp reads names the icons (icons-test.el `file-kinds-are-the-hub-s` asks the same names): an
    /// exact name first, then the last extension, any case, else `file`; every icon it names has a file.
    #[test]
    fn file_icons_follow_the_shared_table() {
        assert_eq!(file_icon("init.el"), "file-code");
        assert_eq!(file_icon("README.MD"), "file-text");
        assert_eq!(file_icon("ci.yaml"), "file-cog");
        assert_eq!(file_icon("dump.tar.gz"), "file-archive");
        assert_eq!(file_icon("shot.png"), "file-image");
        assert_eq!(file_icon("Makefile"), "file-code");
        assert_eq!(file_icon("Dockerfile"), "file-code");
        assert_eq!(file_icon("LICENSE"), "file-text");
        assert_eq!(file_icon("README"), "file-text");
        assert_eq!(file_icon(".gitignore"), "file-cog");
        assert_eq!(file_icon("CMakeLists.txt"), "file-code");
        assert_eq!(file_icon(".editorconfig"), "file-cog");
        assert_eq!(file_icon("md"), "file");
        assert_eq!(file_icon("blob.bin"), "file");
        let t = table();
        assert!(
            t.names.len() > 50 && t.extensions.len() > 150,
            "the table was read"
        );
        for icon in t.names.values().chain(t.extensions.values()) {
            assert!(svg(icon, 16).is_some(), "{icon} has a file");
        }
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
