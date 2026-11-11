//! The Search view's modes past Text, as a run's batches of matches (one per file, in the order shown): Symbol, a
//! name's definitions and then the lines that use it (Hrafn's index, by name only: `search/usages`); Meaning, the
//! chunks a question finds (`search/query`), each with its symbol and score. Both are read-only: a run of either
//! refuses a replacement.

use crate::front::Front;
use hrafn::grep::{CONTEXT_CHARS, Match};
use runstav::methods::search::{QueryAnswer, UsagesAnswer, UsagesParams};
use runstav::types::AbsPath;
use std::collections::HashMap;
use std::path::Path;

/// What a run searches: text through the searcher (`hrafn::grep`), the others through Hrafn's index.
#[derive(Clone, Debug)]
pub(super) enum Mode {
    Text,
    Symbol { name: String, case: bool },
    Meaning { question: String },
}

/// How many uses and hits an index mode lists.
const INDEX_K: u32 = 100;

/// The batches MODE (Symbol or Meaning) finds in ROOT's view of the index; `Err` is why it could not run.
pub(super) async fn batches(
    f: &Front,
    root: &AbsPath,
    mode: &Mode,
) -> Result<Vec<(String, Vec<Match>)>, String> {
    let dir = Path::new(root.as_str());
    match mode {
        Mode::Text => Ok(Vec::new()),
        Mode::Symbol { name, case } => {
            let ans = f
                .search
                .usages(
                    f,
                    UsagesParams {
                        root: root.clone(),
                        name: name.clone(),
                        scope: None,
                        k: Some(INDEX_K),
                        base: None,
                    },
                )
                .await
                .map_err(|e| e.message)?;
            // each file read once, outside every lock
            let mut lines: HashMap<String, Option<Vec<String>>> = HashMap::new();
            Ok(symbol_batches(dir, &ans, name, *case, |file, n| {
                lines
                    .entry(file.to_owned())
                    .or_insert_with(|| {
                        std::fs::read_to_string(file)
                            .ok()
                            .map(|t| t.lines().map(String::from).collect())
                    })
                    .as_ref()?
                    .get(n.checked_sub(1)? as usize)
                    .cloned()
            }))
        }
        Mode::Meaning { question } => {
            let ans = f
                .search
                .query(f, dir, question, hrafn::Scope::Code, INDEX_K, false)
                .await
                .map_err(|e| e.message)?;
            Ok(meaning_batches(dir, &ans))
        }
    }
}

/// The batches of a Symbol search for NAME (CASE: match case) from ANS: the files that define it first, each
/// definition's line and then the file's uses, then the other files that use it in the index's rank. Each line gives
/// a match per whole-word occurrence of NAME in it, read by LINE_OF (a file's line, from 1); a definition whose line
/// does not hold NAME (a macro's) is a match of nothing at the line's start.
pub(super) fn symbol_batches(
    root: &Path,
    ans: &UsagesAnswer,
    name: &str,
    case: bool,
    mut line_of: impl FnMut(&str, u32) -> Option<String>,
) -> Vec<(String, Vec<Match>)> {
    let q = hrafn::grep::Query {
        root: root.to_path_buf(),
        text: name.to_owned(),
        case,
        word: true,
        ..hrafn::grep::Query::default()
    };
    let Ok(re) = hrafn::grep::line_regex(&q) else {
        return Vec::new();
    };
    // each file once, in order: the defining files, then the using ones; its lines in order (definitions first)
    let mut files: Vec<(String, Vec<(u32, bool)>)> = Vec::new();
    let mut add = |path: &str, line: u32, def: bool| {
        let file = root.join(path).to_string_lossy().into_owned();
        let at = match files.iter().position(|(f, _)| *f == file) {
            Some(i) => i,
            None => {
                files.push((file, Vec::new()));
                files.len() - 1
            }
        };
        if !files[at].1.iter().any(|(l, _)| *l == line) {
            files[at].1.push((line, def));
        }
    };
    for d in &ans.defined {
        add(&d.path, d.line_start, true);
    }
    for u in &ans.usages {
        for l in &u.lines {
            add(&u.path, *l, false);
        }
    }
    files
        .into_iter()
        .filter_map(|(file, lines)| {
            let mut ms = Vec::new();
            for (n, def) in lines {
                let Some(text) = line_of(&file, n) else {
                    continue;
                };
                let found = hrafn::grep::line_matches(&re, &file, n, &text);
                if found.is_empty() && def {
                    ms.push(hrafn::grep::match_at(&file, n, &text, 0, 0));
                }
                ms.extend(found);
            }
            (!ms.is_empty()).then_some((file, ms))
        })
        .collect()
}

/// The batches of a Meaning search from ANS: one match per hit, in the files' first hits' order, the hit's symbol as
/// the match and its first line and score after it.
pub(super) fn meaning_batches(root: &Path, ans: &QueryAnswer) -> Vec<(String, Vec<Match>)> {
    let mut files: Vec<(String, Vec<Match>)> = Vec::new();
    for h in &ans.hits {
        let file = root.join(&h.path).to_string_lossy().into_owned();
        let first = h.preview.lines().next().unwrap_or("").trim().to_owned();
        let score = format!("  {:.2}", h.score);
        let (text, after) = match &h.symbol {
            Some(s) => (s.clone(), format!("  {first}{score}")),
            None => (first, score),
        };
        let m = Match {
            file: file.clone(),
            line: h.line_start,
            col: 0,
            end: text.chars().count() as u32,
            text,
            before: String::new(),
            after: after.chars().take(CONTEXT_CHARS).collect(),
        };
        match files.iter_mut().find(|(f, _)| *f == file) {
            Some((_, ms)) => ms.push(m),
            None => files.push((file, vec![m])),
        }
    }
    files
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Each file and what the test reads of its matches.
    type Files<'a, T> = Vec<(&'a str, Vec<T>)>;
    use runstav::methods::search::{Fresh, Hit, Lag, QueryView, SymbolHit, Usage};

    fn view() -> QueryView {
        QueryView {
            worktree: None,
            differing_files: 0,
            state: "base".into(),
        }
    }

    fn def(path: &str, line: u32) -> SymbolHit {
        SymbolHit {
            path: path.into(),
            name: "parse".into(),
            kind: "function".into(),
            line_start: line,
            line_end: line + 3,
            sig: "fn parse(s: &str)".into(),
            doc1: None,
            container: None,
            class: "code".into(),
        }
    }

    fn usage(path: &str, lines: &[u32]) -> Usage {
        Usage {
            path: path.into(),
            line: lines[0],
            lines: lines.to_vec(),
            n: lines.len() as u32,
            enclosing: None,
            rank: 1.0,
        }
    }

    /// [D] Definitions first, then the uses: a file that defines the name lists its definition and then its uses;
    /// every whole-word occurrence on a line is a match (not `parser`), case as asked; a line the file no longer has
    /// is left out.
    #[test]
    fn a_symbol_search_lists_definitions_then_uses() {
        let ans = UsagesAnswer {
            defined: vec![def("src/p.rs", 3)],
            usages: vec![usage("src/main.rs", &[7, 9, 99]), usage("src/p.rs", &[10])],
            fresh: Fresh {
                files_pending: 0,
                view: view(),
            },
        };
        let line_of = |file: &str, n: u32| -> Option<String> {
            let lines: &[&str] = match file {
                "/r/src/p.rs" => &[
                    "",
                    "",
                    "fn parse(s: &str) {",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "    parse(t) + Parse(u)",
                ],
                "/r/src/main.rs" => &[
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "let a = parse(x); let b = parse(y);",
                    "",
                    "let p = parser();",
                ],
                _ => &[],
            };
            lines.get(n as usize - 1).map(|s| s.to_string())
        };
        let b = symbol_batches(Path::new("/r"), &ans, "parse", true, line_of);
        let got: Files<(u32, u32, &str)> = b
            .iter()
            .map(|(f, ms)| {
                (
                    f.as_str(),
                    ms.iter()
                        .map(|m| (m.line, m.col, m.text.as_str()))
                        .collect(),
                )
            })
            .collect();
        assert_eq!(
            got,
            [
                ("/r/src/p.rs", vec![(3, 3, "parse"), (10, 4, "parse")]),
                ("/r/src/main.rs", vec![(7, 8, "parse"), (7, 26, "parse")]),
            ]
        );
        assert_eq!(b[0].1[0].after, "(s: &str) {");
        // case ignored: `Parse` too
        let b = symbol_batches(Path::new("/r"), &ans, "parse", false, line_of);
        assert_eq!(b[0].1.len(), 3);
    }

    /// [D] A Meaning search: one match per hit under its file (files in the order of their first hit), the symbol as
    /// the match (else the hit's first line), its first line and score after it.
    #[test]
    fn a_meaning_search_lists_the_hits_by_file() {
        let hit = |path: &str, line: u32, symbol: Option<&str>, score: f64| Hit {
            path: path.into(),
            line_start: line,
            line_end: line + 5,
            symbol: symbol.map(String::from),
            score,
            preview: "  fn retry(op: Op) {\n    loop {".into(),
            routes: vec!["vector".into()],
            reanchored: false,
        };
        let ans = QueryAnswer {
            hits: vec![
                hit("a.rs", 4, Some("retry"), 0.91),
                hit("b.rs", 1, None, 0.5),
                hit("a.rs", 20, Some("backoff"), 0.42),
            ],
            lag: Lag::default(),
            model: None,
            notice: None,
            lag_line: String::new(),
            view: view(),
        };
        let b = meaning_batches(Path::new("/r"), &ans);
        let got: Files<(u32, &str, &str)> = b
            .iter()
            .map(|(f, ms)| {
                (
                    f.as_str(),
                    ms.iter()
                        .map(|m| (m.line, m.text.as_str(), m.after.as_str()))
                        .collect(),
                )
            })
            .collect();
        assert_eq!(
            got,
            [
                (
                    "/r/a.rs",
                    vec![
                        (4, "retry", "  fn retry(op: Op) {  0.91"),
                        (20, "backoff", "  fn retry(op: Op) {  0.42")
                    ]
                ),
                ("/r/b.rs", vec![(1, "fn retry(op: Op) {", "  0.50")]),
            ]
        );
    }
}
