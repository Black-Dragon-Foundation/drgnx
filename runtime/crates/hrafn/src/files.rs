//! The strict file list: which files of a project Hrafn indexes, with their git blob, class and language.
//!
//! Git is behind the [`Git`] trait (`GitCli` under the `host` feature), file bytes are read through `eitri` (pinned
//! fds, bounded, never following a link), and the hub's deny-list check is the `allow` closure.

use std::collections::HashSet;
use std::io;
use std::os::fd::AsFd;
use std::path::Path;

/// Files over this size are not indexed.
pub const MAX_FILE_BYTES: u64 = 1 << 20;
/// A `.drgnx/search.eld` over this size cannot be read.
const SEARCH_ELD_MAX: u64 = 64 * 1024;
/// A file with a NUL byte among its first this-many bytes is binary.
const BINARY_PROBE: usize = 8000;
/// Generated-file markers are looked for in this many first lines.
const MARKER_LINES: usize = 5;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Class {
    Code,
    Test,
    Docs,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Lang {
    Elisp,
    Rust,
    C,
    Shell,
    Org,
    Markdown,
    Text,
}

impl Class {
    pub fn as_str(self) -> &'static str {
        match self {
            Class::Code => "code",
            Class::Test => "test",
            Class::Docs => "docs",
        }
    }
}

impl Lang {
    pub fn as_str(self) -> &'static str {
        match self {
            Lang::Elisp => "elisp",
            Lang::Rust => "rust",
            Lang::C => "c",
            Lang::Shell => "shell",
            Lang::Org => "org",
            Lang::Markdown => "markdown",
            Lang::Text => "text",
        }
    }
}

/// The project's `drgnx-search-*` settings and `.drgnx/search.eld`, as the hub resolved them. A config can only
/// narrow the list.
#[derive(Clone, Debug, Default)]
pub struct Config {
    pub include: Vec<String>,
    pub exclude: Vec<String>,
    pub off: bool,
}

/// One listed file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Listed {
    pub path: String,
    pub blob: String,
    pub class: Class,
    pub lang: Lang,
    pub generated: bool,
    pub size: u64,
}

/// What the file list needs of git. Paths are relative to `root`, with `/` separators.
pub trait Git {
    /// Tracked files and untracked files that are not ignored; never a nested repository (see `nested`).
    fn ls_files(&self, root: &Path) -> io::Result<Vec<String>>;
    /// The git blob id of each path's working-tree content (so an uncommitted edit changes it).
    fn blobs(&self, root: &Path, paths: &[String]) -> io::Result<Vec<String>>;
    fn head(&self, root: &Path) -> io::Result<String>;
    /// Directories that are repositories of their own (untracked clones and submodules), without a trailing `/`.
    fn nested(&self, root: &Path) -> io::Result<Vec<String>>;
    /// The subset of `paths` marked `linguist-generated` or `linguist-vendored` by `.gitattributes`.
    fn generated(&self, root: &Path, paths: &[String]) -> io::Result<Vec<String>>;
    /// The last `limit` commits reachable from HEAD that are not merges, newest first, with the lines each changed
    /// (the eval's source of questions).
    fn history(&self, root: &Path, limit: usize) -> io::Result<Vec<Commit>>;
    /// A file's bytes as of `rev`.
    fn show(&self, root: &Path, rev: &str, path: &str) -> io::Result<Vec<u8>>;
}

/// One commit of the history.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Commit {
    pub id: String,
    /// Committer time, seconds since the epoch.
    pub time: i64,
    pub subject: String,
    pub changes: Vec<Change>,
}

/// The lines one commit changed in one file (in the file as the commit left it).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub path: String,
    /// The commit created the file.
    pub added: bool,
    /// First and last line (1-based, inclusive) of each hunk that adds or changes lines; a pure deletion has none.
    pub hunks: Vec<(u32, u32)>,
}

/// The `-U0` log of `git log -p`, parsed. Commits start at a `\x01id\0time\0subject` line.
#[cfg(feature = "host")]
fn parse_history(text: &str) -> Vec<Commit> {
    let mut out: Vec<Commit> = Vec::new();
    let mut added = false;
    for line in text.lines() {
        if let Some(head) = line.strip_prefix('\u{1}') {
            let mut f = head.splitn(3, '\0');
            out.push(Commit {
                id: f.next().unwrap_or("").to_string(),
                time: f.next().and_then(|t| t.parse().ok()).unwrap_or(0),
                subject: f.next().unwrap_or("").to_string(),
                changes: Vec::new(),
            });
        } else if let Some(c) = out.last_mut() {
            if line.starts_with("--- ") {
                added = line == "--- /dev/null";
            } else if let Some(path) = line.strip_prefix("+++ b/") {
                c.changes.push(Change {
                    path: path.to_string(),
                    added,
                    hunks: Vec::new(),
                });
            } else if line.starts_with("+++ ") {
                // /dev/null: a deleted file
                c.changes.push(Change {
                    path: String::new(),
                    added: false,
                    hunks: Vec::new(),
                });
            } else if let Some(rest) = line.strip_prefix("@@ ")
                && let Some(new) = rest.split(' ').nth(1).and_then(|s| s.strip_prefix('+'))
                && let Some(ch) = c.changes.last_mut()
            {
                let (start, count) = new.split_once(',').unwrap_or((new, "1"));
                if let (Ok(s), Ok(n)) = (start.parse::<u32>(), count.parse::<u32>())
                    && n > 0
                {
                    ch.hunks.push((s, s + n - 1));
                }
            }
        }
    }
    for c in &mut out {
        c.changes.retain(|ch| !ch.path.is_empty());
    }
    out
}

#[cfg(feature = "host")]
pub use cli::GitCli;

#[cfg(feature = "host")]
mod cli {
    use super::Git;
    use std::io::{self, Write};
    use std::path::Path;
    use std::process::{Command, Stdio};

    /// The `git` executable.
    pub struct GitCli;

    fn run(root: &Path, args: &[&str], input: Vec<u8>) -> io::Result<Vec<u8>> {
        let mut child = Command::new("git")
            .arg("-C")
            .arg(root)
            .args(args)
            .env("GIT_OPTIONAL_LOCKS", "0")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        let mut stdin = child.stdin.take().expect("piped");
        // Written from a thread: git answers while it reads, and both pipes are finite.
        let writer = std::thread::spawn(move || {
            let _ = stdin.write_all(&input);
        });
        let out = child.wait_with_output()?;
        let _ = writer.join();
        if !out.status.success() {
            return Err(io::Error::other(format!(
                "git {}: {}",
                args.join(" "),
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
        Ok(out.stdout)
    }

    fn nul_list(bytes: &[u8]) -> Vec<String> {
        bytes
            .split(|b| *b == 0)
            .filter(|s| !s.is_empty())
            .map(|s| String::from_utf8_lossy(s).into_owned())
            .collect()
    }

    impl Git for GitCli {
        fn history(&self, root: &Path, limit: usize) -> io::Result<Vec<super::Commit>> {
            let n = format!("-n{limit}");
            let out = run(
                root,
                &[
                    "log",
                    "--no-merges",
                    "--no-color",
                    "--no-ext-diff",
                    "-M",
                    "-U0",
                    "-p",
                    &n,
                    "--format=%x01%H%x00%ct%x00%s",
                ],
                vec![],
            )?;
            Ok(super::parse_history(&String::from_utf8_lossy(&out)))
        }

        fn show(&self, root: &Path, rev: &str, path: &str) -> io::Result<Vec<u8>> {
            run(root, &["show", &format!("{rev}:{path}")], vec![])
        }

        fn ls_files(&self, root: &Path) -> io::Result<Vec<String>> {
            let tracked = run(root, &["ls-files", "-z"], vec![])?;
            let others = run(
                root,
                &["ls-files", "-z", "--others", "--exclude-standard"],
                vec![],
            )?;
            let mut all: Vec<String> = nul_list(&tracked)
                .into_iter()
                .chain(nul_list(&others))
                .filter(|p| !p.ends_with('/'))
                .collect();
            all.sort();
            all.dedup();
            Ok(all)
        }

        fn blobs(&self, root: &Path, paths: &[String]) -> io::Result<Vec<String>> {
            if paths.is_empty() {
                return Ok(vec![]);
            }
            let input = paths.join("\n") + "\n";
            let out = run(root, &["hash-object", "--stdin-paths"], input.into_bytes())?;
            let ids: Vec<String> = String::from_utf8_lossy(&out)
                .lines()
                .map(str::to_string)
                .collect();
            if ids.len() != paths.len() {
                return Err(io::Error::other(
                    "git hash-object answered a different count",
                ));
            }
            Ok(ids)
        }

        fn head(&self, root: &Path) -> io::Result<String> {
            let out = run(root, &["rev-parse", "HEAD"], vec![])?;
            Ok(String::from_utf8_lossy(&out).trim().to_string())
        }

        fn nested(&self, root: &Path) -> io::Result<Vec<String>> {
            // An untracked repository is listed as `dir/`; a submodule is a gitlink (mode 160000) in the index.
            let others = run(
                root,
                &["ls-files", "-z", "--others", "--exclude-standard"],
                vec![],
            )?;
            let mut out: Vec<String> = nul_list(&others)
                .into_iter()
                .filter(|p| p.ends_with('/'))
                .map(|p| p.trim_end_matches('/').to_string())
                .collect();
            let staged = run(root, &["ls-files", "-z", "-s"], vec![])?;
            for rec in nul_list(&staged) {
                // "<mode> <blob> <stage>\t<path>"
                if let Some((meta, path)) = rec.split_once('\t')
                    && meta.starts_with("160000")
                {
                    out.push(path.to_string());
                }
            }
            out.sort();
            out.dedup();
            Ok(out)
        }

        fn generated(&self, root: &Path, paths: &[String]) -> io::Result<Vec<String>> {
            if paths.is_empty() {
                return Ok(vec![]);
            }
            let mut input = Vec::new();
            for p in paths {
                input.extend_from_slice(p.as_bytes());
                input.push(0);
            }
            let out = run(
                root,
                &[
                    "check-attr",
                    "-z",
                    "--stdin",
                    "linguist-generated",
                    "linguist-vendored",
                ],
                input,
            )?;
            // path NUL attribute NUL value NUL, repeated
            let f = nul_list(&out);
            let mut hit = Vec::new();
            for rec in f.chunks(3) {
                if let [path, _attr, value] = rec
                    && (value == "set" || value == "true")
                {
                    hit.push(path.clone());
                }
            }
            hit.sort();
            hit.dedup();
            Ok(hit)
        }
    }
}

/// A `drgnx-search-config` glob as tokens: `*` and `?` stay within one path component, `**/` is any number of
/// directories, `**` anything; a glob without `/` matches at any depth, a trailing `/` means everything below.
#[derive(Clone, Copy, Debug)]
enum Tok {
    Lit(char),
    Star,
    One,
    Dirs,
    Any,
}

fn glob_tokens(glob: &str) -> Vec<Tok> {
    let glob = if glob.ends_with('/') {
        format!("{glob}**")
    } else if glob.contains('/') {
        glob.to_string()
    } else {
        format!("**/{glob}")
    };
    let cs: Vec<char> = glob.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < cs.len() {
        match cs[i] {
            '*' if cs.get(i + 1) == Some(&'*') => {
                if cs.get(i + 2) == Some(&'/') {
                    out.push(Tok::Dirs);
                    i += 3;
                } else {
                    out.push(Tok::Any);
                    i += 2;
                }
            }
            '*' => {
                out.push(Tok::Star);
                i += 1;
            }
            '?' => {
                out.push(Tok::One);
                i += 1;
            }
            c => {
                out.push(Tok::Lit(c));
                i += 1;
            }
        }
    }
    out
}

fn tok_match(toks: &[Tok], text: &[char]) -> bool {
    let Some((first, rest)) = toks.split_first() else {
        return text.is_empty();
    };
    match first {
        Tok::Lit(c) => text.first() == Some(c) && tok_match(rest, &text[1..]),
        Tok::One => text.first().is_some_and(|c| *c != '/') && tok_match(rest, &text[1..]),
        Tok::Any => (0..=text.len()).any(|n| tok_match(rest, &text[n..])),
        Tok::Star => {
            let run = text.iter().take_while(|c| **c != '/').count();
            (0..=run).any(|n| tok_match(rest, &text[n..]))
        }
        // zero directories, or any prefix that ends in a `/`
        Tok::Dirs => {
            tok_match(rest, text)
                || text
                    .iter()
                    .enumerate()
                    .any(|(i, c)| *c == '/' && tok_match(rest, &text[i + 1..]))
        }
    }
}

fn glob_matches(globs: &[Vec<Tok>], path: &str) -> bool {
    let text: Vec<char> = path.chars().collect();
    globs.iter().any(|g| tok_match(g, &text))
}

fn dot_path(path: &str) -> bool {
    path.split('/').any(|c| c.starts_with('.'))
}

const CREDENTIAL_CODE_EXTS: [&str; 12] = [
    ".el", ".elc", ".py", ".js", ".ts", ".rb", ".rs", ".go", ".c", ".h", ".md", ".org",
];

/// A basename that looks like a key, certificate or secret; never indexed, whatever the configuration says.
pub(crate) fn sensitive_name(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path).to_lowercase();
    const SUFFIXES: [&str; 10] = [
        ".pem",
        ".key",
        ".p12",
        ".pfx",
        ".kdbx",
        ".keystore",
        ".jks",
        ".asc",
        ".gpg",
        ".env",
    ];
    if SUFFIXES.iter().any(|s| name.ends_with(s))
        || ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
            .iter()
            .any(|p| name.starts_with(p))
        || name.contains("secret")
        || name.contains("credential")
    {
        return true;
    }
    for word in ["netrc", "authinfo"] {
        for (p, _) in name.match_indices(word) {
            let before_ok = p == 0 || matches!(name.as_bytes()[p - 1], b'.' | b'_' | b'-');
            let rest = &name[p + word.len()..];
            let rest_ok = rest.is_empty() || rest.starts_with('.') || rest.starts_with('~');
            if before_ok && rest_ok && !CREDENTIAL_CODE_EXTS.contains(&rest) {
                return true;
            }
        }
    }
    false
}

fn is_test(path: &str) -> bool {
    let mut comps: Vec<&str> = path.split('/').collect();
    let name = comps.pop().unwrap_or("");
    comps.iter().any(|c| *c == "test" || *c == "tests")
        || name.ends_with("-test.el")
        || name.ends_with("_test.rs")
}

fn lang_of(path: &str, head: &[u8]) -> Lang {
    let name = path.rsplit('/').next().unwrap_or(path);
    match name.rsplit_once('.').map(|(_, e)| e) {
        Some("el") => Lang::Elisp,
        Some("rs") => Lang::Rust,
        Some("c" | "h") => Lang::C,
        Some("sh" | "bash" | "zsh") => Lang::Shell,
        Some("org") => Lang::Org,
        Some("md" | "markdown") => Lang::Markdown,
        Some(_) => Lang::Text,
        None => shebang_lang(head),
    }
}

/// An extensionless file's language from its `#!` line.
fn shebang_lang(head: &[u8]) -> Lang {
    if !head.starts_with(b"#!") {
        return Lang::Text;
    }
    let line = head.split(|b| *b == b'\n').next().unwrap_or(&[]);
    let line = String::from_utf8_lossy(line);
    if line.contains("emacs") {
        Lang::Elisp
    } else if line.split_whitespace().any(|w| {
        let base = w.rsplit('/').next().unwrap_or(w);
        matches!(base, "sh" | "bash" | "zsh" | "dash" | "ash" | "ksh")
    }) {
        Lang::Shell
    } else {
        Lang::Text
    }
}

/// A path's language and class as the file list gives them; HEAD is the first bytes of the file (for a `#!` line).
pub fn classify(path: &str, head: &[u8]) -> (Lang, Class) {
    let lang = lang_of(path, head);
    (lang, class_of(path, lang))
}

fn class_of(path: &str, lang: Lang) -> Class {
    if is_test(path) {
        Class::Test
    } else if matches!(lang, Lang::Org | Lang::Markdown)
        || path.ends_with(".txt")
        || path.ends_with(".rst")
        || path.starts_with("docs/")
    {
        Class::Docs
    } else {
        Class::Code
    }
}

fn generated_by_name(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path);
    name.ends_with("-autoloads.el")
        || name == "loaddefs.el"
        || name.ends_with(".lock")
        || name.contains(".min.")
}

fn generated_by_marker(bytes: &[u8]) -> bool {
    let head = &bytes[..bytes.len().min(BINARY_PROBE)];
    String::from_utf8_lossy(head)
        .lines()
        .take(MARKER_LINES)
        .any(|l| {
            let l = l.to_lowercase();
            l.contains("generated") || l.contains("do not edit")
        })
}

/// `.drgnx/search.eld` is there but cannot be read: an error, never the defaults.
fn check_search_eld(root_fd: &eitri::Pinned) -> io::Result<()> {
    let dir = match eitri::open_beneath(root_fd.fd.as_fd(), Path::new(".drgnx"), eitri::Kind::Dir) {
        Ok(d) => d,
        Err(eitri::FsError::Io(e)) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(e) => {
            return Err(io::Error::other(format!(
                ".drgnx/search.eld cannot be read: {e}"
            )));
        }
    };
    match eitri::read_regular(dir.fd.as_fd(), Path::new("search.eld"), SEARCH_ELD_MAX) {
        Ok(b) if b.is_empty() => Err(io::Error::other(
            ".drgnx/search.eld cannot be read: it is empty",
        )),
        Ok(_) => Ok(()),
        Err(eitri::FsError::Io(e)) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(io::Error::other(format!(
            ".drgnx/search.eld cannot be read: {e}"
        ))),
    }
}

/// The files of the project at `root` that Hrafn indexes, sorted by path. `allow` is the hub's deny-list check on a
/// path relative to `root`; `config` can only narrow the list.
pub fn list(
    root: &Path,
    git: &dyn Git,
    config: &Config,
    allow: &dyn Fn(&str) -> bool,
) -> io::Result<Vec<Listed>> {
    let root_fd = eitri::open_path(root, eitri::Kind::Dir)
        .map_err(|e| io::Error::other(format!("project root: {e}")))?;
    check_search_eld(&root_fd)?;
    if config.off {
        return Ok(vec![]);
    }
    let include: Vec<_> = config.include.iter().map(|g| glob_tokens(g)).collect();
    let exclude: Vec<_> = config.exclude.iter().map(|g| glob_tokens(g)).collect();
    let nested = git.nested(root)?;
    let nested_prefixes: Vec<String> = nested.iter().map(|n| format!("{n}/")).collect();

    struct Cand {
        path: String,
        lang: Lang,
        size: u64,
        marker: bool,
    }
    let mut cands: Vec<Cand> = Vec::new();
    let mut seen = HashSet::new();
    for path in git.ls_files(root)? {
        if !seen.insert(path.clone())
            || path.contains('\n') // `hash-object --stdin-paths` is line-based
            || dot_path(&path)
            || sensitive_name(&path)
            || nested_prefixes.iter().any(|p| path.starts_with(p))
            || (!include.is_empty() && !glob_matches(&include, &path))
            || glob_matches(&exclude, &path)
            || !allow(&path)
        {
            continue;
        }
        // Links, FIFOs, missing files and over-size files are all refused by the bounded read.
        let Ok(bytes) = eitri::read_regular(root_fd.fd.as_fd(), Path::new(&path), MAX_FILE_BYTES)
        else {
            continue;
        };
        if bytes[..bytes.len().min(BINARY_PROBE)].contains(&0) {
            continue;
        }
        cands.push(Cand {
            lang: lang_of(&path, &bytes[..bytes.len().min(256)]),
            size: bytes.len() as u64,
            marker: generated_by_marker(&bytes),
            path,
        });
    }
    let paths: Vec<String> = cands.iter().map(|c| c.path.clone()).collect();
    let blobs = git.blobs(root, &paths)?;
    let attr: HashSet<String> = git.generated(root, &paths)?.into_iter().collect();
    let mut out: Vec<Listed> = cands
        .into_iter()
        .zip(blobs)
        .map(|(c, blob)| Listed {
            class: class_of(&c.path, c.lang),
            generated: c.marker || attr.contains(&c.path) || generated_by_name(&c.path),
            lang: c.lang,
            size: c.size,
            blob,
            path: c.path,
        })
        .collect();
    out.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(out)
}
