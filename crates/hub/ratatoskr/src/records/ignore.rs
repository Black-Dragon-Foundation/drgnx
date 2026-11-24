//! The importer's ignore list: `archive/` by default, then the `ignore = [...]` lines of the root's
//! `.drgnx/records.toml` (gitignore syntax: the last match wins, `!` re-includes, a file under an ignored folder
//! stays ignored).

use gix_ignore::Search;
use gix_ignore::search::Ignore as Parse;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

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

/// The root's git ignore rules: its `.gitignore` files and `.git/info/exclude`, read through `gix-ignore` (no `git`
/// process).  A folder's `.gitignore` is read the first time a path under it is asked about.
pub(crate) struct GitIgnore {
    root: PathBuf,
    /// `.git/info/exclude`: asked after every `.gitignore`.
    exclude: Search,
    /// A folder under the root (`""` for the root itself, `a/b` below it) and its `.gitignore`, when it has one.
    dirs: Mutex<HashMap<String, Option<Search>>>,
}

/// FILE's bytes, none when it is not there.
fn read_opt(file: &Path) -> villa::Result<Option<Vec<u8>>> {
    match std::fs::read(file) {
        Ok(b) => Ok(Some(b)),
        // `.git` is a file in a linked worktree: no `info/exclude` under it
        Err(e)
            if matches!(
                e.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
            ) =>
        {
            Ok(None)
        }
        Err(e) => Err(villa::Error::io(format!("{}: {e}", file.display()))),
    }
}

/// The patterns of FILE's BYTES, relative to FILE's folder under BASE (none: relative to the root).
fn search_of(bytes: &[u8], file: PathBuf, base: Option<&Path>) -> Search {
    let mut s = Search::default();
    // an in-memory buffer cannot fail to read
    crate::soft::done(
        s.add_patterns_buffer(bytes, file, base, Parse::default()),
        "git ignore patterns",
    );
    s
}

impl GitIgnore {
    /// The rules of ROOT: its `.git/info/exclude` and its own `.gitignore` are read now (one that cannot be read is an
    /// error naming it); the `.gitignore` files of folders below, when a path under them is asked about.
    pub(crate) fn load(root: &Path) -> villa::Result<GitIgnore> {
        let file = root.join(".git/info/exclude");
        let exclude = match read_opt(&file)? {
            Some(b) => search_of(&b, file, None),
            None => Search::default(),
        };
        let top = root.join(".gitignore");
        let own = read_opt(&top)?.map(|b| search_of(&b, top, Some(root)));
        Ok(GitIgnore {
            root: root.to_path_buf(),
            exclude,
            dirs: Mutex::new(HashMap::from([(String::new(), own)])),
        })
    }

    /// The `.gitignore` of the folder DIR (relative to the root); one that cannot be read counts as none.
    fn list_of(&self, dir: &str) -> Option<Search> {
        let file = self.root.join(dir).join(".gitignore");
        let bytes = read_opt(&file).ok().flatten()?;
        Some(search_of(&bytes, file, Some(&self.root)))
    }

    /// Whether REL (a path under the root) is git-ignored: itself, or any folder above it.
    pub(crate) fn ignored(&self, rel: &Path, is_dir: bool) -> bool {
        let parts: Vec<String> = rel
            .components()
            .map(|c| c.as_os_str().to_string_lossy().into_owned())
            .collect();
        // a folder that is ignored takes everything under it (git never looks inside); a file is judged last
        (1..=parts.len()).any(|n| {
            let dir = n < parts.len() || is_dir;
            self.verdict(&parts[..n - 1], &parts[..n].join("/"), dir) == Some(true)
        })
    }

    /// PATH (in the folders DIRS) by git's order: the nearest `.gitignore` with a matching line decides (its last
    /// matching line, so `!` re-includes), then `.git/info/exclude`.  None: no line matches.
    fn verdict(&self, dirs: &[String], path: &str, is_dir: bool) -> Option<bool> {
        use gix_ignore::glob::pattern::Case;
        let ask = |s: &Search| {
            s.pattern_matching_relative_path(path.into(), Some(is_dir), Case::Sensitive)
                .map(|m| !m.pattern.is_negative())
        };
        let mut lists = saman::lock(&self.dirs);
        for k in (0..=dirs.len()).rev() {
            let key = dirs[..k].join("/");
            let list = lists.entry(key).or_insert_with_key(|key| self.list_of(key));
            if let Some(hit) = list.as_ref().and_then(&ask) {
                return Some(hit);
            }
        }
        ask(&self.exclude)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn put(root: &Path, rel: &str, text: &str) {
        let p = root.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        crate::fsio::write(p, text).unwrap();
    }

    #[test]
    fn gitignore_files_apply_below_their_folder_and_exclude_everywhere() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        put(root, ".gitignore", "/drafts/\n*.tmp.md\n");
        put(root, "docs/specs/.gitignore", "secret.md\n!keep.tmp.md\n");
        put(root, ".git/info/exclude", "local.md\n");
        let g = GitIgnore::load(root).unwrap();
        let ig = |rel: &str| g.ignored(Path::new(rel), false);
        assert!(ig("drafts/a.md"));
        assert!(
            !ig("docs/drafts/a.md"),
            "an anchored line is the root's own"
        );
        assert!(ig("docs/specs/secret.md"));
        assert!(!ig("secret.md"), "a folder's line applies below it only");
        assert!(ig("docs/plans/x.tmp.md"));
        assert!(
            !ig("docs/specs/keep.tmp.md"),
            "the deeper file's negation wins"
        );
        assert!(ig("docs/local.md"));
        assert!(!ig("docs/specs/a.md"));
    }

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
