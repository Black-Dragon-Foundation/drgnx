//! The importer's ignore list: `archive/` by default, then the `ignore = [...]` lines of the root's
//! `.drgnx/records.toml` (gitignore syntax: the last match wins, `!` re-includes, a file under an ignored folder
//! stays ignored).

use gix_ignore::Search;
use gix_ignore::search::Ignore as Parse;
use std::path::Path;

/// The list's file, under the project root.
pub(crate) const RECORDS_TOML: &str = ".drgnx/records.toml";

/// What the importer skips before the file says anything.
pub(crate) const DEFAULT_IGNORE: &[&str] = &["archive/"];

/// The most the file may hold.
const MAX_BYTES: usize = 64 * 1024;

/// The patterns that keep files out of the import.
pub(crate) struct Ignore {
    search: Search,
}

impl Ignore {
    /// The list of ROOT: the default, then the file's lines.  A missing file is the default alone; a file over
    /// 64 KiB, bad TOML, an unknown key or a non-string entry is an error naming the file.
    pub(crate) fn load(root: &Path) -> villa::Result<Ignore> {
        let mut lines: Vec<String> = DEFAULT_IGNORE.iter().map(|s| (*s).to_owned()).collect();
        let file = root.join(RECORDS_TOML);
        match std::fs::read(&file) {
            Ok(bytes) => lines.extend(
                Self::file_lines(&bytes).map_err(|e| villa::Error::invalid(e.to_string()))?,
            ),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(villa::Error::io(format!("{RECORDS_TOML}: {e}"))),
        }
        Ok(Self::from_lines(&lines))
    }

    fn file_lines(bytes: &[u8]) -> villa::Result<Vec<String>> {
        if bytes.len() > MAX_BYTES {
            return Err(villa::Error::invalid(format!(
                "{RECORDS_TOML} is over 64 KiB"
            )));
        }
        let text = std::str::from_utf8(bytes)
            .map_err(|e| villa::Error::invalid(format!("{RECORDS_TOML}: {e}")))?;
        let doc: toml_edit::DocumentMut = text
            .parse()
            .map_err(|e| villa::Error::invalid(format!("{RECORDS_TOML}: {e}")))?;
        let mut out = Vec::new();
        for (key, item) in doc.as_table() {
            if key != "ignore" {
                return Err(villa::Error::invalid(format!(
                    "{RECORDS_TOML}: unknown key `{key}` (only `ignore`)"
                )));
            }
            let arr = item.as_array().ok_or_else(|| {
                villa::Error::invalid(format!(
                    "{RECORDS_TOML}: `ignore` must be an array of strings"
                ))
            })?;
            for v in arr {
                let s = v.as_str().ok_or_else(|| {
                    villa::Error::invalid(format!("{RECORDS_TOML}: `ignore` holds only strings"))
                })?;
                out.push(s.to_owned());
            }
        }
        Ok(out)
    }

    fn from_lines(lines: &[String]) -> Ignore {
        let mut search = Search::default();
        let text = lines.join("\n");
        // an in-memory buffer cannot fail to read
        crate::soft::done(
            search.add_patterns_buffer(text.as_bytes(), RECORDS_TOML, None, Parse::default()),
            "ignore patterns",
        );
        Ignore { search }
    }

    /// Whether REL (a path under the root) is ignored: itself, or any folder above it.
    pub(crate) fn ignored(&self, rel: &Path, is_dir: bool) -> bool {
        use gix_ignore::glob::pattern::Case;
        let parts: Vec<String> = rel
            .components()
            .map(|c| c.as_os_str().to_string_lossy().into_owned())
            .collect();
        // a folder that is ignored takes everything under it; a file is judged last
        for n in 1..=parts.len() {
            let path = parts[..n].join("/");
            let dir = n < parts.len() || is_dir;
            let hit = self.search.pattern_matching_relative_path(
                path.as_str().into(),
                Some(dir),
                Case::Sensitive,
            );
            if hit.is_some_and(|m| !m.pattern.is_negative()) {
                return true;
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with(lines: &[&str]) -> Ignore {
        let mut all: Vec<String> = DEFAULT_IGNORE.iter().map(|s| (*s).to_owned()).collect();
        all.extend(lines.iter().map(|s| (*s).to_owned()));
        Ignore::from_lines(&all)
    }

    #[test]
    fn the_default_skips_archive_at_any_depth_below_it() {
        let i = with(&[]);
        assert!(i.ignored(Path::new("archive"), true));
        assert!(i.ignored(Path::new("archive/docs/plans/x.md"), false));
        assert!(!i.ignored(Path::new("docs/plans/y.md"), false));
    }

    #[test]
    fn the_last_match_wins() {
        let i = with(&["docs/specs/old/**", "!docs/specs/old/keep.md"]);
        assert!(i.ignored(Path::new("docs/specs/old/a.md"), false));
        assert!(!i.ignored(Path::new("docs/specs/old/keep.md"), false));
        assert!(!with(&["!archive/"]).ignored(Path::new("archive/x.md"), false));
    }
}
