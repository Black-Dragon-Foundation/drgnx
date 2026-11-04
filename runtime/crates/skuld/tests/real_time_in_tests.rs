//! No real time in Rust test code.
//!
//! Test code (a crate's `tests/` files, `tests.rs` files and `#[cfg(test)]` items) never sleeps or reads a clock:
//! `tokio::time::sleep`, `std::thread::sleep`, `Instant::now` and `SystemTime::now` are the waits and deadlines that
//! make a test depend on how fast the machine is. A test waits for what it needs with [`skuld::wait_until`], or runs
//! on paused tokio time, or is a timing test.
//!
//! Exempt:
//! - a test that is `#[ignore = "timing: …"]` (a timing test, run by the timing lane) and `tests/timing.rs`;
//! - `skuld`'s own `wait_until` (`skuld/src/wait.rs`) and the hub clock's module (`drgnx-ratatoskr/src/clock*`);
//! - `tokio::time::sleep` inside a paused tokio test (`#[tokio::test(start_paused = true)]`, or a body that calls
//!   `tokio::time::pause()`): the sleep is virtual there;
//! - `Instant::now` inside a paused test, in a file that imports tokio's `Instant`, unless written
//!   `std::time::Instant::now`. A paused test is `start_paused = true` (not `false`) or a body that calls
//!   `tokio::time::pause()`; the exemption covers that function only, never the rest of its file. A helper that only
//!   paused tests call is marked `#[doc = "paused clock: …"]` and counts as paused.
//!
//! Test code is any `cfg(...)` predicate naming `test` (`cfg(all(test, …))` too). The scan covers `crates/*` and
//! `conformance`. A bare `sleep(` is classed by the file's `use` line (`std::thread::sleep` or tokio's), and
//! `X as Y` imports of `Instant`, `SystemTime`, `sleep` and `thread` are followed.
//!
//! The check reads the sources as text (comments and string literals blanked); `cargo test --workspace` runs it.

use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    TokioSleep,
    ThreadSleep,
    InstantNow,
    SystemTimeNow,
}

impl Kind {
    fn name(self) -> &'static str {
        match self {
            Kind::TokioSleep => "tokio sleep",
            Kind::ThreadSleep => "thread::sleep",
            Kind::InstantNow => "Instant::now",
            Kind::SystemTimeNow => "SystemTime::now",
        }
    }
}

/// `src` with comments, string literals and char literals blanked to spaces (newlines kept), so that braces and
/// banned names inside them are not seen.
fn blank(src: &str) -> String {
    let c: Vec<char> = src.chars().collect();
    let mut out = String::with_capacity(src.len());
    let mut i = 0;
    let keep = |ch: char| if ch == '\n' { '\n' } else { ' ' };
    while i < c.len() {
        let ch = c[i];
        let prev_ident = i > 0 && (c[i - 1].is_alphanumeric() || c[i - 1] == '_');
        if ch == '/' && c.get(i + 1) == Some(&'/') {
            while i < c.len() && c[i] != '\n' {
                out.push(' ');
                i += 1;
            }
        } else if ch == '/' && c.get(i + 1) == Some(&'*') {
            let mut depth = 0;
            while i < c.len() {
                if c[i] == '/' && c.get(i + 1) == Some(&'*') {
                    depth += 1;
                    out.push_str("  ");
                    i += 2;
                } else if c[i] == '*' && c.get(i + 1) == Some(&'/') {
                    depth -= 1;
                    out.push_str("  ");
                    i += 2;
                    if depth == 0 {
                        break;
                    }
                } else {
                    out.push(keep(c[i]));
                    i += 1;
                }
            }
        } else if (ch == 'r' && !prev_ident) && matches!(c.get(i + 1), Some('"' | '#')) {
            // a raw string r"…" or r#"…"#
            let mut j = i + 1;
            let mut hashes = 0;
            while c.get(j) == Some(&'#') {
                hashes += 1;
                j += 1;
            }
            if c.get(j) != Some(&'"') {
                out.push(ch);
                i += 1;
                continue;
            }
            j += 1;
            loop {
                if j >= c.len() {
                    break;
                }
                if c[j] == '"' && (0..hashes).all(|k| c.get(j + 1 + k) == Some(&'#')) {
                    j += 1 + hashes;
                    break;
                }
                j += 1;
            }
            for &x in &c[i..j.min(c.len())] {
                out.push(keep(x));
            }
            i = j;
        } else if ch == '"' {
            out.push(' ');
            i += 1;
            while i < c.len() && c[i] != '"' {
                if c[i] == '\\' && i + 1 < c.len() {
                    out.push(' ');
                    i += 1;
                }
                out.push(keep(c[i]));
                i += 1;
            }
            out.push(' ');
            i += 1;
        } else if ch == '\'' {
            // a char literal ('x', '\n', '\u{..}'); a lifetime has no closing quote right after
            let close = if c.get(i + 1) == Some(&'\\') {
                (i + 2..(i + 12).min(c.len())).find(|&k| c[k] == '\'')
            } else if c.get(i + 2) == Some(&'\'') {
                Some(i + 2)
            } else {
                None
            };
            match close {
                Some(k) => {
                    for _ in i..=k {
                        out.push(' ');
                    }
                    i = k + 1;
                }
                None => {
                    out.push(ch);
                    i += 1;
                }
            }
        } else {
            out.push(ch);
            i += 1;
        }
    }
    out
}

fn bare_sleep(line: &str) -> bool {
    if line.contains("fn sleep") {
        return false;
    }
    line.match_indices("sleep(").any(|(at, _)| {
        line[..at]
            .chars()
            .next_back()
            .is_none_or(|p| !(p.is_alphanumeric() || p == '_' || p == '.' || p == ':'))
    })
}

/// What the file's `use` statements say: whether a bare `sleep(` is `std::thread::sleep`, whether tokio's `Instant` is
/// imported, and the aliases (`X as Y`) of `Instant`, `SystemTime`, `sleep` and `thread`, as (alias, what it names).
#[derive(Default)]
struct Imports {
    bare_thread_sleep: bool,
    tokio_instant: bool,
    aliases: Vec<(String, String)>,
}

fn is_ident(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// `line` with each whole word `from` (not part of a path or a method call) replaced by `to`.
fn replace_word(line: &str, from: &str, to: &str) -> String {
    let mut out = String::new();
    let mut last = 0;
    for (at, _) in line.match_indices(from) {
        let before = line[..at].chars().next_back();
        let after = line[at + from.len()..].chars().next();
        if at >= last
            && before.is_none_or(|c| !(is_ident(c) || c == ':' || c == '.'))
            && after.is_none_or(|c| !is_ident(c))
        {
            out.push_str(&line[last..at]);
            out.push_str(to);
            last = at + from.len();
        }
    }
    out.push_str(&line[last..]);
    out
}

fn imports(blanked: &str) -> Imports {
    let mut im = Imports::default();
    for stmt in blanked.split(';') {
        let Some(at) = stmt.rfind("use ") else {
            continue;
        };
        if stmt[..at].chars().next_back().is_some_and(is_ident) {
            continue;
        }
        let stmt = &stmt[at + 4..];
        let spaced = stmt.replace(['{', '}', ','], " ");
        let words: Vec<&str> = spaced.split_whitespace().collect();
        let has_word = |w: &str| {
            words
                .iter()
                .any(|x| *x == w || x.ends_with(&format!("::{w}")))
        };
        let tokio = stmt.contains("tokio");
        let thread = stmt.contains("thread") && !tokio;
        if has_word("Instant") && tokio {
            im.tokio_instant = true;
        }
        if has_word("sleep") && thread {
            im.bare_thread_sleep = true;
        }
        for w in words.windows(3) {
            if w[1] != "as" {
                continue;
            }
            let orig = w[0].rsplit("::").next().unwrap_or(w[0]);
            let target = match orig {
                "Instant" if tokio => "tokio::time::Instant",
                "Instant" => "std::time::Instant",
                "SystemTime" => "SystemTime",
                "sleep" if thread => "thread::sleep",
                "sleep" => "tokio::time::sleep",
                "thread" => "thread",
                _ => continue,
            };
            if w[2] != "_" {
                im.aliases.push((w[2].to_string(), target.to_string()));
            }
        }
    }
    im
}

fn kinds(line: &str, bare_thread_sleep: bool) -> Vec<Kind> {
    let mut out = Vec::new();
    if bare_sleep(line) && bare_thread_sleep {
        out.push(Kind::ThreadSleep);
    } else if line.contains("tokio::time::sleep")
        || line.contains("time::sleep(")
        || bare_sleep(line)
    {
        out.push(Kind::TokioSleep);
    }
    if line.contains("thread::sleep") {
        out.push(Kind::ThreadSleep);
    }
    if line.contains("Instant::now") {
        out.push(Kind::InstantNow);
    }
    if line.contains("SystemTime::now") {
        out.push(Kind::SystemTimeNow);
    }
    out
}

fn depth_change(line: &str) -> i64 {
    line.chars()
        .map(|c| i64::from(c == '{') - i64::from(c == '}'))
        .sum()
}

/// A test-code region: it began at brace depth `base` and is over once the depth is back there after opening.
struct Region {
    base: i64,
    opened: bool,
    timing: bool,
    paused: bool,
}

impl Region {
    fn new(base: i64) -> Self {
        Region {
            base,
            opened: false,
            timing: false,
            paused: false,
        }
    }

    /// Update after `line` left the depth at `depth`; true while the region goes on. A declaration with no body
    /// (`fn f();`, `mod m;`) ends where it is.
    fn live(&mut self, depth: i64, line: &str) -> bool {
        if line.contains('{') {
            self.opened = true;
        }
        if !self.opened && line.trim_end().ends_with(';') {
            return false;
        }
        !(self.opened && depth <= self.base)
    }
}

/// Whether an attribute is a `cfg(...)` whose predicate names `test` (`cfg(test)`, `cfg(all(test, ...))`, ...), but
/// not as `not(test)`.
fn cfg_selects_test(attr: &str) -> bool {
    let Some(pred) = attr.strip_prefix("#[cfg(") else {
        return false;
    };
    let pred: String = pred.split_whitespace().collect();
    pred.match_indices("test").any(|(at, _)| {
        let before = pred[..at].chars().next_back();
        let after = pred[at + 4..].chars().next();
        before.is_none_or(|c| !is_ident(c) && c != ':' && c != '"')
            && after.is_none_or(|c| !is_ident(c) && c != '"')
            && !pred[..at].ends_with("not(")
    })
}

/// The banned sites of one file as (line, kind). `whole` says every line is test code; `mods` collects the names of
/// the `#[cfg(test)] mod NAME;` files this file declares.
fn scan(src: &str, whole: bool, mods: &mut Vec<String>) -> Vec<(usize, Kind)> {
    let mut blanked = blank(src);
    let im = imports(&blanked);
    for (alias, target) in &im.aliases {
        blanked = replace_word(&blanked, alias, target);
    }
    // tokio's `Instant` reads the paused clock, which is virtual, inside a paused test
    let tokio_clock = im.tokio_instant || blanked.contains("tokio::time::Instant");
    let mut sites = Vec::new();
    let (mut depth, mut attrs) = (0i64, Vec::<String>::new());
    let (mut test, mut func): (Option<Region>, Option<Region>) = (None, None);
    for (n, (raw, line)) in src.lines().zip(blanked.lines()).enumerate() {
        let trimmed = line.trim();
        let raw_trim = raw.trim();
        let start = depth;
        if trimmed.is_empty() {
            continue;
        }
        if raw_trim.starts_with("#[") {
            attrs.push(raw_trim.to_string());
            depth += depth_change(line);
            continue;
        }
        let cfg_test = attrs.iter().any(|a| cfg_selects_test(a));
        let is_fn = trimmed.contains("fn ");
        if cfg_test && test.is_none() {
            let decl = trimmed
                .trim_start_matches("pub ")
                .trim_start_matches("pub(crate) ");
            if let Some(rest) = decl.strip_prefix("mod ") {
                if rest.trim_end().ends_with(';') {
                    mods.push(rest.trim_end().trim_end_matches(';').trim().to_string());
                } else {
                    test = Some(Region::new(start));
                }
            } else if !trimmed.ends_with(';') {
                test = Some(Region::new(start));
            }
        }
        if is_fn && func.is_none() {
            let mut r = Region::new(start);
            r.timing = attrs
                .iter()
                .any(|a| a.starts_with("#[ignore") && a.contains("timing"));
            r.paused = attrs.iter().any(|a| {
                let a: String = a.split_whitespace().collect();
                (a.contains("start_paused") && !a.contains("start_paused=false"))
                    || a.starts_with("#[doc=\"pausedclock")
            });
            func = Some(r);
        }
        attrs.clear();
        if trimmed.starts_with("use ") || trimmed.starts_with("pub use ") {
            depth += depth_change(line);
            continue;
        }
        let in_test = whole || test.is_some();
        if in_test {
            let paused_body = trimmed.contains("time::pause()");
            if paused_body && let Some(f) = func.as_mut() {
                f.paused = true;
            }
            for k in kinds(trimmed, im.bare_thread_sleep) {
                let timing = func.as_ref().is_some_and(|f| f.timing);
                let paused = func.as_ref().is_some_and(|f| f.paused);
                let virtual_clock = paused
                    && k == Kind::InstantNow
                    && tokio_clock
                    && !trimmed.contains("std::time::Instant");
                if !(timing || virtual_clock || (paused && k == Kind::TokioSleep)) {
                    sites.push((n + 1, k));
                }
            }
        }
        depth += depth_change(line);
        if let Some(r) = test.as_mut()
            && !r.live(depth, line)
        {
            test = None;
        }
        if let Some(r) = func.as_mut()
            && !r.live(depth, line)
        {
            func = None;
        }
    }
    sites
}

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            rust_files(&p, out);
        } else if p.extension().is_some_and(|x| x == "rs") {
            out.push(p);
        }
    }
}

fn exempt(rel: &str) -> bool {
    rel.ends_with("skuld/src/wait.rs")
        || rel.ends_with("/tests/timing.rs")
        || rel.contains("drgnx-ratatoskr/src/clock")
}

/// Every banned call in test code across `crates/*/{src,tests}` and `conformance/{src,tests}` of the workspace at
/// `runtime`, as `file:line: kind`.
fn find(runtime: &Path) -> Vec<String> {
    let crates = runtime;
    let mut files = Vec::new();
    let mut members: Vec<PathBuf> = fs::read_dir(runtime.join("crates"))
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .collect();
    members.push(runtime.join("conformance"));
    for member in members {
        for sub in ["src", "tests"] {
            rust_files(&member.join(sub), &mut files);
        }
    }
    files.sort();
    // files a `#[cfg(test)] mod NAME;` names are test code as a whole
    let mut test_files: Vec<PathBuf> = Vec::new();
    for f in &files {
        let mut mods = Vec::new();
        scan(&fs::read_to_string(f).unwrap(), false, &mut mods);
        let dir = f.parent().unwrap();
        let own = f.file_stem().unwrap().to_string_lossy().into_owned();
        let base = if own == "mod" || own == "lib" || own == "main" {
            dir.to_path_buf()
        } else {
            dir.join(&own)
        };
        for m in mods {
            test_files.push(dir.join(format!("{m}.rs")));
            test_files.push(dir.join(&m).join("mod.rs"));
            test_files.push(base.join(format!("{m}.rs")));
            test_files.push(base.join(&m).join("mod.rs"));
        }
    }
    let mut out = Vec::new();
    for f in &files {
        let rel = f
            .strip_prefix(crates)
            .unwrap()
            .to_string_lossy()
            .replace('\\', "/");
        if exempt(&rel) {
            continue;
        }
        let whole = rel.contains("/tests/") || rel.ends_with("/tests.rs") || test_files.contains(f);
        for (line, kind) in scan(&fs::read_to_string(f).unwrap(), whole, &mut Vec::new()) {
            out.push(format!("{rel}:{line}: {}", kind.name()));
        }
    }
    out
}

#[test]
fn no_real_time_in_test_code() {
    let runtime = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap();
    let sites = find(runtime);
    assert!(
        sites.is_empty(),
        "real time in test code (wait with skuld::wait_until, pause tokio time, or make it a timing test):\n{}",
        sites.join("\n")
    );
}

fn sites_of(src: &str, whole: bool) -> Vec<(usize, Kind)> {
    scan(src, whole, &mut Vec::new())
}

#[test]
fn the_check_bites_test_code_and_only_test_code() {
    let src = "fn real() { std::thread::sleep(d); let t = Instant::now(); }\n\
               #[cfg(test)]\nmod tests {\n    use super::*;\n    #[test]\n    fn a() {\n        let t = Instant::now();\n        \
               tokio::time::sleep(d).await;\n        std::thread::sleep(d);\n        let s = SystemTime::now();\n    }\n}\n\
               fn after() { Instant::now(); }\n";
    let kinds = sites_of(src, false);
    assert_eq!(
        kinds,
        vec![
            (7, Kind::InstantNow),
            (8, Kind::TokioSleep),
            (9, Kind::ThreadSleep),
            (10, Kind::SystemTimeNow)
        ]
    );
    // a file of test code as a whole
    assert_eq!(
        sites_of("fn a() { sleep(d); }\n", true),
        vec![(1, Kind::TokioSleep)]
    );
    assert!(sites_of("fn a() { sleep(d); }\n", false).is_empty());
}

#[test]
fn timing_tests_and_paused_tests_are_exempt() {
    let timing = "#[test]\n#[ignore = \"timing: measures the grace\"]\nfn t() {\n    let t = Instant::now();\n    std::thread::sleep(d);\n}\n\
                  #[test]\nfn plain() {\n    let t = Instant::now();\n}\n";
    assert_eq!(sites_of(timing, true), vec![(9, Kind::InstantNow)]);
    let paused = "#[tokio::test(start_paused = true)]\nasync fn p() {\n    tokio::time::sleep(d).await;\n    std::thread::sleep(d);\n}\n\
                  #[tokio::test]\nasync fn q() {\n    tokio::time::pause();\n    tokio::time::sleep(d).await;\n}\n\
                  #[tokio::test]\nasync fn r() {\n    tokio::time::sleep(d).await;\n}\n";
    assert_eq!(
        sites_of(paused, true),
        vec![(4, Kind::ThreadSleep), (13, Kind::TokioSleep)]
    );
}

#[test]
fn the_virtual_clock_exemption_is_per_paused_test() {
    // a real sleep and a std clock read in a plain test next to a paused one are still flagged
    let src = "use tokio::time::Instant;\n\
               #[tokio::test(start_paused = true)]\nasync fn p() {\n    let t = Instant::now();\n    tokio::time::sleep(d).await;\n}\n\
               #[tokio::test]\nasync fn plain() {\n    tokio::time::sleep(d).await;\n    let t = Instant::now();\n}\n\
               #[tokio::test(start_paused = false)]\nasync fn not_paused() {\n    tokio::time::sleep(d).await;\n}\n";
    assert_eq!(
        sites_of(src, true),
        vec![
            (9, Kind::TokioSleep),
            (10, Kind::InstantNow),
            (14, Kind::TokioSleep)
        ]
    );
    // a helper marked as paused is exempt, an unmarked one is not
    let helper = "use tokio::time::Instant;\n#[doc = \"paused clock: called by paused tests\"]\nfn marked() {\n    Instant::now();\n}\n\
                  fn unmarked() {\n    Instant::now();\n}\n";
    assert_eq!(sites_of(helper, true), vec![(7, Kind::InstantNow)]);
}

#[test]
fn any_cfg_predicate_naming_test_makes_test_code() {
    for attr in [
        "#[cfg(test)]",
        "#[cfg(all(test, target_os = \"linux\"))]",
        "#[cfg(any(feature = \"x\", test))]",
    ] {
        assert!(cfg_selects_test(attr), "{attr}");
        let src = format!("{attr}\nmod tests {{\n    fn a() {{ std::thread::sleep(d); }}\n}}\n");
        assert_eq!(
            sites_of(&src, false),
            vec![(3, Kind::ThreadSleep)],
            "{attr}"
        );
    }
    for attr in [
        "#[cfg(not(test))]",
        "#[cfg(feature = \"test-hooks\")]",
        "#[cfg(target_os = \"test\")]",
        "#[cfg(unix)]",
    ] {
        assert!(!cfg_selects_test(attr), "{attr}");
    }
}

#[test]
fn imported_names_are_classified_by_their_use_line() {
    // a bare sleep imported from std::thread is a thread sleep, so a paused test does not excuse it
    let thread = "use std::thread::sleep;\n#[tokio::test(start_paused = true)]\nasync fn p() {\n    sleep(d);\n}\n";
    assert_eq!(sites_of(thread, true), vec![(4, Kind::ThreadSleep)]);
    let grouped = "use std::thread::{self, sleep};\nfn a() { sleep(d); }\n";
    assert_eq!(sites_of(grouped, true), vec![(2, Kind::ThreadSleep)]);
    let tokio = "use tokio::time::sleep;\n#[tokio::test(start_paused = true)]\nasync fn p() {\n    sleep(d).await;\n}\n";
    assert!(sites_of(tokio, true).is_empty());
    // aliases
    let clock = "use std::time::Instant as Clock;\nuse std::time::SystemTime as Wall;\nuse std::thread::sleep as nap;\n\
                 fn a() {\n    Clock::now();\n    Wall::now();\n    nap(d);\n}\n";
    assert_eq!(
        sites_of(clock, true),
        vec![
            (5, Kind::InstantNow),
            (6, Kind::SystemTimeNow),
            (7, Kind::ThreadSleep)
        ]
    );
    let tokio_alias = "use tokio::time::Instant as Clock;\n#[tokio::test(start_paused = true)]\nasync fn p() {\n    Clock::now();\n}\n\
                       #[tokio::test]\nasync fn q() {\n    Clock::now();\n}\n";
    assert_eq!(sites_of(tokio_alias, true), vec![(8, Kind::InstantNow)]);
}

#[test]
fn comments_strings_and_other_names_are_not_calls() {
    let src = "// tokio::time::sleep(d)\nfn a() {\n    let s = \"Instant::now()\";\n    let r = r#\"thread::sleep { \"#;\n    \
               let c = '{';\n    /* SystemTime::now() */\n    fn sleep_for() {}\n    x.sleep(d);\n    fn sleep(d: u8) {}\n}\n";
    assert!(sites_of(src, true).is_empty());
}
