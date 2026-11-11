//! Text search in files, as the Search view runs it: ripgrep when installed, else `git grep` in a repository, else
//! `grep`, each a child process whose output is parsed here into matches, one batch per file. The matches carry
//! character columns (the searchers count bytes), and the ignore rules the index follows (`Ignore::Index`: no dot
//! paths, no secret-looking names) or only the ones the project's own files name (`Ignore::Real`).

use regex::RegexBuilder;
use serde_json::Value;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};

/// Characters of the line kept before and after a match.
pub const CONTEXT_CHARS: usize = 80;

/// Which files a search looks in.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Ignore {
    /// The index's filters: no dot paths and no secret-looking names.
    #[default]
    Index,
    /// Only what `.gitignore` files and the search's own globs name; dot paths and secret-looking names are searched.
    Real,
}

/// What to search for.
#[derive(Clone, Debug, Default)]
pub struct Query {
    pub root: PathBuf,
    /// Search this one file (globs then do not apply).
    pub file: Option<PathBuf>,
    /// Search only these files (absolute; a git scope's, or the open ones), narrowed by the globs.
    pub files: Option<Vec<PathBuf>>,
    pub text: String,
    /// Match case.
    pub case: bool,
    pub word: bool,
    pub regexp: bool,
    pub include: Vec<String>,
    pub exclude: Vec<String>,
    pub ignore: Ignore,
}

/// One match: FILE absolute, LINE from 1, COL and END characters of the line from 0.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Match {
    pub file: String,
    pub line: u32,
    pub col: u32,
    pub end: u32,
    pub text: String,
    pub before: String,
    pub after: String,
}

/// The searcher that runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    Rg,
    Git,
    Grep,
}

fn on_path(program: &str) -> bool {
    std::env::var_os("PATH")
        .is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(program).is_file()))
}

/// `rg` when installed, else `git` when ROOT is in a repository, else `grep`.
pub fn backend(root: &Path) -> Backend {
    if on_path("rg") {
        Backend::Rg
    } else if on_path("git") && root.ancestors().any(|d| d.join(".git").exists()) {
        Backend::Git
    } else {
        Backend::Grep
    }
}

fn globs(list: &[String]) -> Vec<&str> {
    list.iter()
        .flat_map(|g| g.split(','))
        .map(str::trim)
        .filter(|g| !g.is_empty())
        .collect()
}

/// A glob as a git pathspec glob: one without a slash matches at any depth, as in ripgrep.
fn git_glob(g: &str) -> String {
    if g.contains('/') {
        g.to_owned()
    } else {
        format!("**/{g}")
    }
}

/// GLOB as a regex over one name or a path: `*` and `?` stay within a name, `**` crosses folders, `[...]` and
/// `{a,b}` as written.
fn glob_regex(glob: &str) -> Option<regex::Regex> {
    let cs: Vec<char> = glob.chars().collect();
    let (mut re, mut i, mut braces) = (String::from("^"), 0, 0);
    while i < cs.len() {
        match cs[i] {
            '*' if cs.get(i + 1) == Some(&'*') => {
                let slash = cs.get(i + 2) == Some(&'/');
                re.push_str(if slash { "(?:.*/)?" } else { ".*" });
                i += if slash { 3 } else { 2 };
                continue;
            }
            '*' => re.push_str("[^/]*"),
            '?' => re.push_str("[^/]"),
            '[' => match cs[i + 1..].iter().position(|&c| c == ']') {
                Some(n) => {
                    let body: String = cs[i + 1..i + 1 + n].iter().collect();
                    let body = match body.strip_prefix('!') {
                        Some(b) => format!("^{b}"),
                        None => body,
                    };
                    re.push('[');
                    re.push_str(&body.replace('\\', r"\\").replace('[', r"\["));
                    re.push(']');
                    i += n + 2;
                    continue;
                }
                None => re.push_str(r"\["),
            },
            '{' => {
                re.push_str("(?:");
                braces += 1;
            }
            '}' if braces > 0 => {
                re.push(')');
                braces -= 1;
            }
            ',' if braces > 0 => re.push('|'),
            c => re.push_str(&regex::escape(c.encode_utf8(&mut [0; 4]))),
        }
        i += 1;
    }
    re.push('$');
    regex::Regex::new(&re).ok()
}

/// Whether GLOB names REL (a path relative to the root) as ripgrep reads it: one without a slash names any file or
/// folder of the path by its name, one with a slash the path from the root or one of its folders; a trailing slash
/// names folders only.
fn glob_names(glob: &str, rel: &str) -> bool {
    let folders = glob.ends_with('/');
    let glob = glob.trim_end_matches('/');
    let anchored = glob.contains('/');
    let Some(re) = glob_regex(glob.trim_start_matches('/')) else {
        return false;
    };
    let parts: Vec<&str> = rel.split('/').collect();
    let upto = if folders {
        parts.len() - 1
    } else {
        parts.len()
    };
    if anchored {
        (1..=upto).any(|k| re.is_match(&parts[..k].join("/")))
    } else {
        parts[..upto].iter().any(|p| re.is_match(p))
    }
}

/// Q's list of files (relative to its root) that its include and exclude globs keep; a file outside the root is not
/// searched. None when Q has no list.
fn listed(q: &Query) -> Option<Vec<String>> {
    let (inc, exc) = (globs(&q.include), globs(&q.exclude));
    let files = q.files.as_ref()?;
    Some(
        files
            .iter()
            .filter_map(|f| {
                let rel = f.strip_prefix(&q.root).ok()?.to_str()?;
                let keep = (inc.is_empty() || inc.iter().any(|g| glob_names(g, rel)))
                    && !exc.iter().any(|g| glob_names(g, rel));
                (keep && !rel.is_empty()).then(|| rel.to_owned())
            })
            .collect(),
    )
}

/// The command line (program first) searching Q with B, run in `q.root`.
pub fn command(b: Backend, q: &Query) -> Vec<String> {
    let file = q.file.as_ref().map(|f| f.to_string_lossy().into_owned());
    let listed = if file.is_none() { listed(q) } else { None };
    let (inc, exc) = if file.is_some() || listed.is_some() {
        (vec![], vec![])
    } else {
        (globs(&q.include), globs(&q.exclude))
    };
    let mut c: Vec<String> = Vec::new();
    let mut add = |xs: &[&str]| c.extend(xs.iter().map(|x| (*x).to_owned()));
    match b {
        Backend::Rg => {
            add(&["rg", "--json", "--no-config"]);
            if !q.regexp {
                add(&["-F"]);
            }
            add(&[if q.case { "-s" } else { "-i" }]);
            if q.word {
                add(&["-w"]);
            }
            if q.ignore == Ignore::Real {
                add(&["--hidden", "--glob=!.git/"]);
            }
            let gs: Vec<String> = inc
                .iter()
                .map(|g| format!("--glob={g}"))
                .chain(exc.iter().map(|g| format!("--glob=!{g}")))
                .collect();
            c.extend(gs);
            c.extend(["-e".into(), q.text.clone(), "--".into()]);
            match listed {
                Some(l) => c.extend(l),
                None => c.push(file.unwrap_or_else(|| ".".into())),
            }
        }
        Backend::Git => {
            add(&[
                "git",
                "-c",
                "core.quotePath=false",
                "grep",
                "-n",
                "-z",
                "-I",
            ]);
            add(&["--untracked", "--no-color"]);
            add(&[if q.regexp { "-E" } else { "-F" }]);
            if !q.case {
                add(&["-i"]);
            }
            if q.word {
                add(&["-w"]);
            }
            c.extend(["-e".into(), q.text.clone(), "--".into()]);
            match (file, listed) {
                (Some(f), _) => c.push(f),
                (None, Some(l)) => c.extend(l.iter().map(|r| format!(":(literal){r}"))),
                (None, None) => {
                    c.extend(inc.iter().map(|g| format!(":(glob){}", git_glob(g))));
                    c.extend(
                        exc.iter()
                            .map(|g| format!(":(exclude,glob){}", git_glob(g))),
                    );
                }
            }
        }
        Backend::Grep => {
            let one_by_one = file.is_some() || listed.is_some();
            add(&["grep", if one_by_one { "-H" } else { "-r" }]);
            add(&["-n", "--null", "-I", "--color=never"]);
            add(&[if q.regexp { "-E" } else { "-F" }]);
            if !q.case {
                add(&["-i"]);
            }
            if q.word {
                add(&["-w"]);
            }
            add(&["--exclude-dir=.git"]);
            c.extend(inc.iter().map(|g| format!("--include={g}")));
            c.extend(exc.iter().map(|g| format!("--exclude={g}")));
            c.extend(["-e".into(), q.text.clone(), "--".into()]);
            match listed {
                Some(l) => c.extend(l),
                None => c.push(file.unwrap_or_else(|| ".".into())),
            }
        }
    }
    c
}

/// Whether a file at REL (relative to the root) is searched under IGNORE.
pub fn searched(ignore: Ignore, rel: &str) -> bool {
    match ignore {
        Ignore::Real => true,
        Ignore::Index => {
            !rel.split('/')
                .any(|c| c.starts_with('.') && c != "." && c != "..")
                && !crate::files::sensitive_name(rel)
        }
    }
}

fn base64(s: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0u32);
    for ch in s.bytes() {
        let v = match ch {
            b'A'..=b'Z' => ch - b'A',
            b'a'..=b'z' => ch - b'a' + 26,
            b'0'..=b'9' => ch - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => continue,
        };
        acc = (acc << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    out
}

/// An `rg --json` text object (`{"text": s}` or `{"bytes": base64}`) as bytes.
fn rg_bytes(v: &Value) -> Vec<u8> {
    match (
        v.get("text").and_then(Value::as_str),
        v.get("bytes").and_then(Value::as_str),
    ) {
        (Some(t), _) => t.as_bytes().to_vec(),
        (_, Some(b)) => base64(b),
        _ => Vec::new(),
    }
}

/// The match at BYTES `[from, to)` of TEXT (a line without its newline), as characters with their context.
fn make(file: &str, line: u32, text: &str, from: usize, to: usize) -> Match {
    let col = text.char_indices().take_while(|(i, _)| *i < from).count();
    let end = col
        + text[text.floor_char_boundary(from)..text.floor_char_boundary(to.max(from))]
            .chars()
            .count();
    let chars: Vec<char> = text.chars().collect();
    let slice = |a: usize, b: usize| {
        chars[a.min(chars.len())..b.min(chars.len())]
            .iter()
            .collect()
    };
    Match {
        file: file.to_owned(),
        line,
        col: col as u32,
        end: end as u32,
        text: slice(col, end),
        before: slice(col.saturating_sub(CONTEXT_CHARS), col),
        after: slice(end, end + CONTEXT_CHARS),
    }
}

fn absolute(root: &Path, rel: &str) -> String {
    root.join(rel.strip_prefix("./").unwrap_or(rel))
        .to_string_lossy()
        .into_owned()
}

fn trim_eol(s: &str) -> &str {
    let s = s.strip_suffix('\n').unwrap_or(s);
    s.strip_suffix('\r').unwrap_or(s)
}

/// The matches in LINE of `rg --json` output (paths relative to ROOT).
pub fn parse_rg(line: &str, root: &Path) -> Vec<Match> {
    if !line.starts_with("{\"type\":\"match\"") {
        return Vec::new();
    }
    let Ok(v) = serde_json::from_str::<Value>(line) else {
        return Vec::new();
    };
    let d = &v["data"];
    let rel = String::from_utf8_lossy(&rg_bytes(&d["path"])).into_owned();
    let bytes = rg_bytes(&d["lines"]);
    let n = d["line_number"].as_u64().unwrap_or(0) as u32;
    let file = absolute(root, &rel);
    let text = String::from_utf8_lossy(&bytes).into_owned();
    let trimmed = trim_eol(&text);
    d["submatches"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|s| {
            // rg counts bytes of the original line; a lossy decode may change them, so map by the decoded prefix
            let b = |k: &str| s[k].as_u64().unwrap_or(0) as usize;
            let (from, to) = (b("start").min(bytes.len()), b("end").min(bytes.len()));
            let from_c = String::from_utf8_lossy(&bytes[..from]).len();
            let to_c = String::from_utf8_lossy(&bytes[..to]).len();
            make(&file, n, trimmed, from_c, to_c)
        })
        .collect()
}

/// The matches in LINE of `git grep -z -n` or `grep --null -n` output: each of RE in the line's text.
pub fn parse_grep(line: &str, root: &Path, re: &regex::Regex) -> Vec<Match> {
    let Some((rel, rest)) = line.split_once('\0') else {
        return Vec::new();
    };
    let Some(sep) = rest.find([':', '\0']) else {
        return Vec::new();
    };
    let Ok(n) = rest[..sep].parse::<u32>() else {
        return Vec::new();
    };
    let file = absolute(root, rel);
    let text = trim_eol(&rest[sep + 1..]);
    re.find_iter(text)
        .map(|m| make(&file, n, text, m.start(), m.end()))
        .collect()
}

/// Q's pattern as a regex for the fallbacks that print whole lines.
pub fn line_regex(q: &Query) -> Result<regex::Regex, String> {
    let body = if q.regexp {
        q.text.clone()
    } else {
        regex::escape(&q.text)
    };
    let body = if q.word {
        format!(r"\b(?:{body})\b")
    } else {
        body
    };
    RegexBuilder::new(&body)
        .case_insensitive(!q.case)
        .build()
        .map_err(|e| e.to_string())
}

/// What a match MATCHED becomes when replaced by TEMPLATE: the template itself, or after a regexp search its `\1`
/// (group), `\&` (the whole match) and `\\` expanded; `None` when the regexp no longer matches the text.
pub fn new_text(q: &Query, matched: &str, template: &str) -> Option<String> {
    if !q.regexp {
        return Some(template.to_owned());
    }
    let re = RegexBuilder::new(&format!(r"\A(?:{})\z", q.text))
        .case_insensitive(!q.case)
        .build()
        .ok()?;
    let caps = re.captures(matched)?;
    let mut out = String::new();
    let mut it = template.chars();
    while let Some(c) = it.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match it.next() {
            Some('&') => out.push_str(&caps[0]),
            Some(d @ '0'..='9') => {
                let g = d.to_digit(10).unwrap_or(0) as usize;
                out.push_str(caps.get(g).map_or("", |m| m.as_str()));
            }
            Some(o) => out.push(o),
            None => out.push('\\'),
        }
    }
    Some(out)
}

/// Search Q with B, handing each file's matches to ON_FILE as that file's lines are complete. Stops when CANCEL is
/// set (the child is killed). An empty text finds nothing. `Err` is the reason the search could not run or the
/// pattern was refused.
pub fn run_with(
    b: Backend,
    q: &Query,
    cancel: &AtomicBool,
    mut on_file: impl FnMut(Vec<Match>),
) -> Result<(), String> {
    // a list the globs left empty names no file (the searchers would take the root)
    if q.text.is_empty() || (q.file.is_none() && listed(q).is_some_and(|l| l.is_empty())) {
        return Ok(());
    }
    let re = (b != Backend::Rg).then(|| line_regex(q)).transpose()?;
    let argv = command(b, q);
    let mut child = Command::new(&argv[0])
        .args(&argv[1..])
        .current_dir(&q.root)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("{}: {e}", argv[0]))?;
    let stderr = child.stderr.take();
    let err = std::thread::spawn(move || {
        let mut s = String::new();
        if let Some(mut e) = stderr {
            let _ = std::io::Read::read_to_string(&mut e, &mut s);
        }
        s
    });
    let mut out = BufReader::new(child.stdout.take().expect("piped"));
    let (mut file, mut batch): (String, Vec<Match>) = (String::new(), Vec::new());
    let mut raw = Vec::new();
    let mut cancelled = false;
    loop {
        if cancel.load(Ordering::Relaxed) {
            cancelled = true;
            break;
        }
        raw.clear();
        match out.read_until(b'\n', &mut raw) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        let line = String::from_utf8_lossy(&raw);
        let line = trim_eol(&line);
        let found = match &re {
            None => parse_rg(line, &q.root),
            Some(re) => parse_grep(line, &q.root, re),
        };
        for m in found {
            let rel = m
                .file
                .strip_prefix(&*q.root.to_string_lossy())
                .unwrap_or(&m.file);
            if !searched(q.ignore, rel.trim_start_matches('/')) {
                continue;
            }
            if m.file != file && !batch.is_empty() {
                on_file(std::mem::take(&mut batch));
            }
            file.clone_from(&m.file);
            batch.push(m);
        }
    }
    if cancelled {
        let _ = child.kill();
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    let stderr_text = err.join().unwrap_or_default();
    if cancelled {
        return Ok(());
    }
    if !batch.is_empty() {
        on_file(batch);
    }
    // 1: no match (rg, grep, git grep); 2 and up: the search failed
    match status.code() {
        Some(0 | 1) => Ok(()),
        _ => Err(stderr_text
            .lines()
            .next()
            .unwrap_or("the search failed")
            .to_owned()),
    }
}

/// Q's matches in TEXT, the contents of FILE held elsewhere (an editor's buffer with unsaved edits): line by line, as
/// the fallbacks match a printed line. An empty text finds nothing.
pub fn search_text(q: &Query, file: &str, text: &str) -> Result<Vec<Match>, String> {
    if q.text.is_empty() {
        return Ok(Vec::new());
    }
    let re = line_regex(q)?;
    Ok(text
        .split('\n')
        .zip(1..)
        .flat_map(|(line, n)| line_matches(&re, file, n, line.strip_suffix('\r').unwrap_or(line)))
        .collect())
}

/// RE's matches in TEXT, line N of FILE (without its newline).
pub fn line_matches(re: &regex::Regex, file: &str, n: u32, text: &str) -> Vec<Match> {
    re.find_iter(text)
        .map(|m| make(file, n, text, m.start(), m.end()))
        .collect()
}

/// The match at bytes `[from, to)` of TEXT, line N of FILE, with its context.
pub fn match_at(file: &str, n: u32, text: &str, from: usize, to: usize) -> Match {
    make(file, n, text, from, to)
}

/// Search Q with the backend its root has.
pub fn run(q: &Query, cancel: &AtomicBool, on_file: impl FnMut(Vec<Match>)) -> Result<(), String> {
    run_on(backend(&q.root), q, cancel, on_file)
}

/// Search Q with B; a long list of files in parts of [`LIST_PART`], one after the other (a command line has a limit).
pub fn run_on(
    b: Backend,
    q: &Query,
    cancel: &AtomicBool,
    mut on_file: impl FnMut(Vec<Match>),
) -> Result<(), String> {
    let Some(files) = q.files.as_ref().filter(|_| q.file.is_none()) else {
        return run_with(b, q, cancel, on_file);
    };
    for part in files.chunks(LIST_PART) {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        let q = Query {
            files: Some(part.to_vec()),
            ..q.clone()
        };
        run_with(b, &q, cancel, &mut on_file)?;
    }
    Ok(())
}

/// The most files of a list one searcher's command line names.
const LIST_PART: usize = 1000;

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;

    fn q(root: &Path, text: &str) -> Query {
        Query {
            root: root.to_path_buf(),
            text: text.into(),
            ..Query::default()
        }
    }

    #[test]
    fn rg_lines_give_character_columns() {
        let line = r#"{"type":"match","data":{"path":{"text":"./a/é.txt"},"lines":{"text":"éé foo bar\n"},"line_number":7,"absolute_offset":0,"submatches":[{"match":{"text":"foo"},"start":5,"end":8}]}}"#;
        let m = parse_rg(line, Path::new("/r"));
        assert_eq!(m.len(), 1);
        assert_eq!(
            (m[0].file.as_str(), m[0].line, m[0].col, m[0].end),
            ("/r/a/é.txt", 7, 3, 6)
        );
        assert_eq!(
            (
                m[0].text.as_str(),
                m[0].before.as_str(),
                m[0].after.as_str()
            ),
            ("foo", "éé ", " bar")
        );
        assert!(parse_rg(r#"{"type":"begin","data":{}}"#, Path::new("/r")).is_empty());
    }

    #[test]
    fn grep_lines_find_each_match_in_the_line() {
        let re = line_regex(&Query {
            text: "ab".into(),
            ..q(Path::new("/r"), "ab")
        })
        .unwrap();
        let m = parse_grep("x.txt\u{0}3\u{0}ab AB ab", Path::new("/r"), &re);
        assert_eq!(
            m.iter().map(|m| (m.line, m.col)).collect::<Vec<_>>(),
            [(3, 0), (3, 3), (3, 6)]
        );
        let m = parse_grep("x.txt\u{0}3:ab", Path::new("/r"), &re);
        assert_eq!(m.len(), 1);
    }

    #[test]
    fn grep_follows_the_search_ignore_setting() {
        let mut query = q(Path::new("/r"), "t");
        assert!(!command(Backend::Rg, &query).contains(&"--hidden".to_owned()));
        assert!(!searched(Ignore::Index, ".github/ci.yml"));
        assert!(!searched(Ignore::Index, "a/.env"));
        assert!(!searched(Ignore::Index, "keys/server.pem"));
        assert!(searched(Ignore::Index, "src/main.rs"));
        query.ignore = Ignore::Real;
        assert!(command(Backend::Rg, &query).contains(&"--hidden".to_owned()));
        assert!(searched(Ignore::Real, ".github/ci.yml"));
        assert!(searched(Ignore::Real, "a/.env"));
    }

    /// The files B's run of QUERY found matches in, relative to its root, sorted.
    fn found(b: Backend, query: &Query) -> Vec<String> {
        let mut files = Vec::new();
        run_on(b, query, &AtomicBool::new(false), |ms| {
            let rel = Path::new(&ms[0].file).strip_prefix(&query.root).unwrap();
            files.push(rel.to_string_lossy().into_owned());
        })
        .unwrap();
        files.sort();
        files
    }

    #[test]
    fn a_file_list_is_searched_alone_and_the_globs_narrow_it() {
        let d = tempfile::tempdir().unwrap();
        let root = d.path();
        for f in ["a.rs", "b.txt", "d.rs", "sub/c.rs", "sub/e.txt"] {
            std::fs::create_dir_all(root.join(f).parent().unwrap()).unwrap();
            std::fs::write(root.join(f), "needle\n").unwrap();
        }
        let mut backends = vec![Backend::Grep];
        if on_path("rg") {
            backends.push(Backend::Rg);
        }
        if on_path("git") {
            let init = Command::new("git")
                .args(["init", "-q"])
                .current_dir(root)
                .status()
                .unwrap();
            assert!(init.success());
            backends.push(Backend::Git);
        }
        for b in backends {
            let mut query = q(root, "needle");
            query.files = Some(
                ["a.rs", "b.txt", "sub/c.rs", "sub/e.txt"]
                    .iter()
                    .map(|f| root.join(f))
                    .collect(),
            );
            assert_eq!(
                found(b, &query),
                ["a.rs", "b.txt", "sub/c.rs", "sub/e.txt"],
                "{b:?}"
            );
            query.include = vec!["*.rs".into()];
            assert_eq!(found(b, &query), ["a.rs", "sub/c.rs"], "{b:?}");
            query.exclude = vec!["sub".into()];
            assert_eq!(found(b, &query), ["a.rs"], "{b:?}");
            query.include = Vec::new();
            query.exclude = vec!["sub/*.txt, b.*".into()];
            assert_eq!(found(b, &query), ["a.rs", "sub/c.rs"], "{b:?}");
            query.files = Some(Vec::new());
            assert!(
                found(b, &query).is_empty(),
                "{b:?}: an empty list is no file, not the root"
            );
        }
    }

    #[test]
    fn a_long_file_list_is_searched_in_parts() {
        let d = tempfile::tempdir().unwrap();
        let files: Vec<PathBuf> = (0..2500)
            .map(|i| d.path().join(format!("f{i:04}.txt")))
            .collect();
        for f in &files {
            std::fs::write(f, "needle\n").unwrap();
        }
        let mut query = q(d.path(), "needle");
        query.files = Some(files[..2400].to_vec());
        assert_eq!(found(Backend::Grep, &query).len(), 2400);
    }

    #[test]
    fn a_run_batches_matches_per_file_and_honours_the_ignore_rules() {
        let d = tempfile::tempdir().unwrap();
        for (f, body) in [
            ("a.txt", "one needle\nneedle two needle\n"),
            ("b.txt", "none\n"),
            ("c.txt", "needle\n"),
            (".env", "needle\n"),
        ] {
            std::fs::write(d.path().join(f), body).unwrap();
        }
        let mut query = q(d.path(), "needle");
        let no = AtomicBool::new(false);
        let mut files = Vec::new();
        run_with(Backend::Grep, &query, &no, |ms| {
            files.push((ms[0].file.rsplit('/').next().unwrap().to_owned(), ms.len()));
        })
        .unwrap();
        files.sort();
        assert_eq!(files, [("a.txt".to_owned(), 3), ("c.txt".to_owned(), 1)]);
        query.ignore = Ignore::Real;
        let mut n = 0;
        run_with(Backend::Grep, &query, &no, |ms| n += ms.len()).unwrap();
        assert_eq!(n, 5);
    }

    #[test]
    fn a_cancelled_run_hands_over_nothing_more() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("a.txt"), "needle\n").unwrap();
        let stop = AtomicBool::new(true);
        let mut n = 0;
        run_with(Backend::Grep, &q(d.path(), "needle"), &stop, |_| n += 1).unwrap();
        assert_eq!(n, 0);
    }

    #[test]
    fn replace_templates_expand_groups() {
        let mut query = q(Path::new("/r"), r"(\w+)-(\d+)");
        assert_eq!(new_text(&query, "ab-12", r"\2-\1"), Some(r"\2-\1".into()));
        query.regexp = true;
        assert_eq!(
            new_text(&query, "ab-12", r"\2-\1 \& \\"),
            Some(r"12-ab ab-12 \".into())
        );
        assert_eq!(new_text(&query, "nope", "x"), None);
    }

    #[test]
    fn a_text_held_elsewhere_is_searched_line_by_line() {
        let mut query = q(Path::new("/r"), "needle");
        let text = "one needle\r\nNEEDLE é needle\nnone\nneedles";
        let ms = search_text(&query, "/r/a.txt", text).unwrap();
        assert_eq!(
            ms.iter()
                .map(|m| (m.file.as_str(), m.line, m.col, m.end))
                .collect::<Vec<_>>(),
            [
                ("/r/a.txt", 1, 4, 10),
                ("/r/a.txt", 2, 0, 6),
                ("/r/a.txt", 2, 9, 15),
                ("/r/a.txt", 4, 0, 6)
            ]
        );
        assert_eq!((ms[0].before.as_str(), ms[0].after.as_str()), ("one ", ""));
        assert_eq!(ms[2].before, "NEEDLE é ");
        query.case = true;
        query.word = true;
        let ms = search_text(&query, "/r/a.txt", text).unwrap();
        assert_eq!(
            ms.iter().map(|m| (m.line, m.col)).collect::<Vec<_>>(),
            [(1, 4), (2, 9)]
        );
        assert!(
            search_text(&q(Path::new("/r"), ""), "/r/a.txt", text)
                .unwrap()
                .is_empty()
        );
        let mut bad = q(Path::new("/r"), "(");
        bad.regexp = true;
        assert!(search_text(&bad, "/r/a.txt", text).is_err());
    }

    #[test]
    fn a_bad_pattern_is_an_error_not_a_hang() {
        let d = tempfile::tempdir().unwrap();
        let mut query = q(d.path(), "(");
        query.regexp = true;
        assert!(run_with(Backend::Grep, &query, &AtomicBool::new(false), |_| ()).is_err());
    }
}
