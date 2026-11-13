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
    Cpp,
    Shell,
    Python,
    JavaScript,
    TypeScript,
    Tsx,
    Go,
    Java,
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
            Lang::Cpp => "cpp",
            Lang::Shell => "shell",
            Lang::Python => "python",
            Lang::JavaScript => "javascript",
            Lang::TypeScript => "typescript",
            Lang::Tsx => "tsx",
            Lang::Go => "go",
            Lang::Java => "java",
            Lang::Org => "org",
            Lang::Markdown => "markdown",
            Lang::Text => "text",
        }
    }

    /// The language a stored name (`as_str`) names; anything else is text.
    pub fn parse(name: &str) -> Lang {
        const ALL: [Lang; 14] = [
            Lang::Elisp,
            Lang::Rust,
            Lang::C,
            Lang::Cpp,
            Lang::Shell,
            Lang::Python,
            Lang::JavaScript,
            Lang::TypeScript,
            Lang::Tsx,
            Lang::Go,
            Lang::Java,
            Lang::Org,
            Lang::Markdown,
            Lang::Text,
        ];
        ALL.into_iter()
            .find(|l| l.as_str() == name)
            .unwrap_or(Lang::Text)
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
pub use cli::{GitCli, ignored_dirs, is_ignored_dir};

#[cfg(feature = "host")]
pub(crate) mod cli {
    use super::Git;
    use std::io::{self, Write};
    use std::path::Path;
    use std::process::{Command, Stdio};

    /// The `git` executable.
    pub struct GitCli;

    /// `git` with no input whose exit 1 means "no answer" (`symbolic-ref -q`, `rev-parse -q --verify`, `config`).
    pub(crate) fn try_run(root: &Path, args: &[&str]) -> io::Result<Option<Vec<u8>>> {
        let out = Command::new("git")
            .arg("-C")
            .arg(root)
            .args(args)
            .env("GIT_OPTIONAL_LOCKS", "0")
            .stdin(Stdio::null())
            .output()?;
        match out.status.code() {
            Some(0) => Ok(Some(out.stdout)),
            Some(1) => Ok(None),
            _ => Err(io::Error::other(format!(
                "git {}: {}",
                args.join(" "),
                String::from_utf8_lossy(&out.stderr).trim()
            ))),
        }
    }

    pub(crate) fn run(root: &Path, args: &[&str], input: Vec<u8>) -> io::Result<Vec<u8>> {
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

    /// The directories of ROOT git ignores as a whole (`dir/`, root-relative): what a watcher leaves unwatched.
    pub fn ignored_dirs(root: &Path) -> io::Result<Vec<String>> {
        let out = run(
            root,
            &[
                "ls-files",
                "-z",
                "--others",
                "--ignored",
                "--exclude-standard",
                "--directory",
            ],
            vec![],
        )?;
        Ok(nul_list(&out)
            .into_iter()
            .filter(|p| p.ends_with('/'))
            .collect())
    }

    /// Whether git ignores the directory REL (root-relative) of ROOT.
    pub fn is_ignored_dir(root: &Path, rel: &Path) -> bool {
        let mut dir = rel.to_string_lossy().into_owned();
        dir.push('/');
        Command::new("git")
            .arg("-C")
            .arg(root)
            .args(["check-ignore", "-q", "--", &dir])
            .env("GIT_OPTIONAL_LOCKS", "0")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
    }

    pub(crate) fn nul_list(bytes: &[u8]) -> Vec<String> {
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
    tokens(&glob)
}

/// GLOB's tokens as written: no depth rule and no trailing-slash rule.
fn tokens(glob: &str) -> Vec<Tok> {
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

/// A compiled glob: a configuration glob (the depth rules above) or one taken as written (a `.gitignore` pattern,
/// placed by its reader).
pub(crate) struct Glob(Vec<Tok>);

impl Glob {
    pub(crate) fn config(glob: &str) -> Glob {
        Glob(glob_tokens(glob))
    }

    pub(crate) fn exact(glob: &str) -> Glob {
        Glob(tokens(glob))
    }

    pub(crate) fn matches(&self, path: &str) -> bool {
        let text: Vec<char> = path.chars().collect();
        tok_match(&self.0, &text)
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
        Some("cc" | "cpp" | "cxx" | "hpp" | "hh" | "h++") => Lang::Cpp,
        Some("sh" | "bash" | "zsh") => Lang::Shell,
        Some("py" | "pyi") => Lang::Python,
        Some("js" | "mjs" | "cjs" | "jsx") => Lang::JavaScript,
        Some("ts" | "mts" | "cts") => Lang::TypeScript,
        Some("tsx") => Lang::Tsx,
        Some("go") => Lang::Go,
        Some("java") => Lang::Java,
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
        return Lang::Elisp;
    }
    for w in line.split_whitespace() {
        let base = w.rsplit('/').next().unwrap_or(w);
        match base {
            "sh" | "bash" | "zsh" | "dash" | "ash" | "ksh" => return Lang::Shell,
            "node" | "nodejs" => return Lang::JavaScript,
            _ if base.starts_with("python")
                && base[6..].chars().all(|c| c.is_ascii_digit() || c == '.') =>
            {
                return Lang::Python;
            }
            _ => {}
        }
    }
    Lang::Text
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

/// What a path alone decides about indexing it: the configuration's globs, the hub's deny-list, dot paths, names of
/// secrets and nested repositories. The overlay applies the same rules to a worktree's paths (the base's `Config`).
pub(crate) struct Rules {
    off: bool,
    include: Vec<Vec<Tok>>,
    exclude: Vec<Vec<Tok>>,
    nested: Vec<String>,
}

impl Rules {
    /// The rules of CONFIG in a checkout whose nested repositories are NESTED (as `Git::nested` gives them).
    pub(crate) fn new(config: &Config, nested: &[String]) -> Rules {
        Rules {
            off: config.off,
            include: config.include.iter().map(|g| glob_tokens(g)).collect(),
            exclude: config.exclude.iter().map(|g| glob_tokens(g)).collect(),
            nested: nested.iter().map(|n| format!("{n}/")).collect(),
        }
    }

    pub(crate) fn admits(&self, path: &str, allow: &dyn Fn(&str) -> bool) -> bool {
        !(self.off
            || path.contains('\n') // `hash-object --stdin-paths` is line-based
            || dot_path(path)
            || sensitive_name(path)
            || self.nested.iter().any(|p| path.starts_with(p))
            || (!self.include.is_empty() && !glob_matches(&self.include, path))
            || glob_matches(&self.exclude, path)
            || !allow(path))
    }
}

/// PATH's bytes when its content can be indexed: a regular file (a link, a FIFO or a missing file is refused by the
/// read, which never follows a link), at most [`MAX_FILE_BYTES`], with no NUL among its first bytes.
pub(crate) fn read_admitted(root_fd: &eitri::Pinned, path: &str) -> Option<Vec<u8>> {
    let bytes = eitri::read_regular(root_fd.fd.as_fd(), Path::new(path), MAX_FILE_BYTES).ok()?;
    (!bytes[..bytes.len().min(BINARY_PROBE)].contains(&0)).then_some(bytes)
}

/// The listed row of an admitted file: its BLOB, BYTES and whether `.gitattributes` marks it generated (ATTR).
pub(crate) fn listed(path: String, blob: String, bytes: &[u8], attr: bool) -> Listed {
    Read::of(&path, blob, bytes).row(path, attr)
}

/// What a file's content gives its listed row: everything but the `.gitattributes` mark.
#[derive(Clone)]
struct Read {
    blob: String,
    lang: Lang,
    /// A generated-file marker among its first lines.
    marked: bool,
    size: u64,
}

impl Read {
    fn of(path: &str, blob: String, bytes: &[u8]) -> Read {
        Read {
            blob,
            lang: lang_of(path, &bytes[..bytes.len().min(256)]),
            marked: generated_by_marker(bytes),
            size: bytes.len() as u64,
        }
    }

    fn row(self, path: String, attr: bool) -> Listed {
        Listed {
            class: class_of(&path, self.lang),
            generated: self.marked || attr || generated_by_name(&path),
            lang: self.lang,
            size: self.size,
            blob: self.blob,
            path,
        }
    }
}

/// A file modified less than this before a listing began is read again by the next one: a write later in the same
/// timestamp tick would leave its status as it was (a 2-second tick on FAT, 1 on HFS+ and ext3, a jiffy on others).
const RACY: std::time::Duration = std::time::Duration::from_secs(2);

/// What one listing read, for the next to reuse: per path, the file's status when it was read and what the read gave
/// (`None`: not admitted, binary or too large), and the status of every `.gitattributes`. The next listing reads and
/// hashes again only the files whose status moved, and all of them when a `.gitattributes` did (its attributes and
/// clean filters go into every blob).
#[derive(Default)]
pub struct Snapshot {
    files: std::collections::HashMap<String, (eitri::Meta, Option<Read>)>,
    attributes: Vec<(String, Option<eitri::Meta>)>,
}

/// The files of the project at `root` that Hrafn indexes, sorted by path. `allow` is the hub's deny-list check on a
/// path relative to `root`; `config` can only narrow the list.
pub fn list(
    root: &Path,
    git: &dyn Git,
    config: &Config,
    allow: &dyn Fn(&str) -> bool,
) -> io::Result<Vec<Listed>> {
    list_with(root, git, config, allow, &mut Snapshot::default())
}

/// [`list`], reusing what SNAP holds of an earlier listing of the same `root` and leaving this one's there: a file
/// whose status (device, inode, size, both times) is what it was, and was modified at least [`RACY`] before that
/// listing began, is neither read nor hashed again. The paths, the rules, `.gitattributes`' marks and the nested
/// repositories are asked anew every time.
pub fn list_with(
    root: &Path,
    git: &dyn Git,
    config: &Config,
    allow: &dyn Fn(&str) -> bool,
    snap: &mut Snapshot,
) -> io::Result<Vec<Listed>> {
    let began = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .saturating_sub(RACY)
        .as_nanos() as i128;
    let root_fd = eitri::open_path(root, eitri::Kind::Dir)
        .map_err(|e| io::Error::other(format!("project root: {e}")))?;
    check_search_eld(&root_fd)?;
    if config.off {
        return Ok(vec![]);
    }
    let rules = Rules::new(config, &git.nested(root)?);
    let paths = git.ls_files(root)?;
    // a file's status: its directory pinned once for the files in it (ls-files lists them together), then one
    // `fstatat` each
    let mut dir: Option<(String, Option<eitri::Pinned>)> = None;
    let mut stat = |p: &str| -> Option<eitri::Meta> {
        let (parent, name) = p.rsplit_once('/').unwrap_or(("", p));
        if parent.is_empty() {
            return eitri::stat_in(root_fd.fd.as_fd(), Path::new(name)).ok();
        }
        if dir.as_ref().is_none_or(|d| d.0 != parent) {
            let pinned =
                eitri::open_beneath(root_fd.fd.as_fd(), Path::new(parent), eitri::Kind::Dir).ok();
            dir = Some((parent.to_string(), pinned));
        }
        let fd = dir.as_ref()?.1.as_ref()?.fd.as_fd();
        eitri::stat_in(fd, Path::new(name)).ok()
    };
    let attributes: Vec<(String, Option<eitri::Meta>)> = paths
        .iter()
        .filter(|p| p.rsplit('/').next() == Some(".gitattributes"))
        .map(|p| (p.clone(), stat(p)))
        .collect();
    let mut was = std::mem::take(&mut snap.files);
    if attributes != snap.attributes {
        was.clear();
    }
    snap.attributes = attributes;
    // per admitted path: its status when it is not racy, and what an earlier listing read or the bytes read now
    type Cand = (String, Option<eitri::Meta>, Result<Read, Vec<u8>>);
    let mut cands: Vec<Cand> = Vec::new();
    let mut seen = HashSet::new();
    for path in paths {
        if !seen.insert(path.clone()) || !rules.admits(&path, allow) {
            continue;
        }
        let meta = stat(&path);
        let kept = match (meta, was.remove(&path)) {
            (Some(m), Some((old, read))) if m == old => Some(read),
            _ => None,
        };
        let read = match kept {
            Some(read) => read.map(Ok),
            None => read_admitted(&root_fd, &path).map(Err),
        };
        let meta = meta.filter(|m| m.mtime_ns < began);
        match read {
            Some(read) => cands.push((path, meta, read)),
            None => {
                if let Some(m) = meta {
                    snap.files.insert(path, (m, None));
                }
            }
        }
    }
    let fresh: Vec<String> = cands
        .iter()
        .filter(|c| c.2.is_err())
        .map(|c| c.0.clone())
        .collect();
    let mut blobs = git.blobs(root, &fresh)?.into_iter();
    let all: Vec<String> = cands.iter().map(|c| c.0.clone()).collect();
    let attr: HashSet<String> = git.generated(root, &all)?.into_iter().collect();
    let mut out = Vec::with_capacity(cands.len());
    for (path, meta, read) in cands {
        let read = match read {
            Ok(r) => r,
            Err(bytes) => {
                let blob = blobs.next().ok_or_else(|| {
                    io::Error::other("git hash-object answered a different count")
                })?;
                Read::of(&path, blob, &bytes)
            }
        };
        if let Some(m) = meta {
            snap.files.insert(path.clone(), (m, Some(read.clone())));
        }
        let generated = attr.contains(&path);
        out.push(read.row(path, generated));
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(out)
}
