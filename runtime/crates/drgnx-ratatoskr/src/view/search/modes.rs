//! The Search view's modes past Text, as a run's batches of matches (one per file, in the order shown): Symbol, a
//! name's definitions and then the lines that use it (Hrafn's index, by name only: `search/usages`); Meaning, the
//! chunks a question finds (`search/query`), each with its symbol and score. Both are read-only: a run of either
//! refuses a replacement.

use super::run::{self, Mark, Read};
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

/// One file's matches from an index mode, each with its mark (a definition's, a hit's score).
pub(super) type Batch = (String, Vec<Match>, Vec<Option<Mark>>);

/// The files MODE (Symbol or Meaning) finds in ROOT's view of the index, each read for its snapshot and marks; with
/// CONTEXT, a Symbol search's uses are grouped under the definitions that hold them (label rows, as Text's), its
/// definitions' own rows standing for theirs. `Err` is why it could not run.
pub(super) async fn found(
    f: &Front,
    root: &AbsPath,
    mode: &Mode,
    context: bool,
) -> Result<Vec<(String, Vec<Match>, Option<Read>)>, String> {
    let symbol = matches!(mode, Mode::Symbol { .. });
    Ok(batches(f, root, mode)
        .await?
        .into_iter()
        .map(|(file, ms, marks)| {
            let read =
                run::read(Path::new(&file), &ms, context && symbol).map(|r| marked(r, marks));
            (file, ms, read)
        })
        .collect())
}

/// R with MARKS: a definition's row stands for its own label (its context is dropped), so the uses in it get one
/// under it.
fn marked(mut r: Read, marks: Vec<Option<Mark>>) -> Read {
    for (c, m) in r.ctx.iter_mut().zip(&marks) {
        if matches!(m, Some(Mark::Def { .. })) {
            *c = None;
        }
    }
    r.marks = marks;
    r
}

/// The batches MODE (Symbol or Meaning) finds in ROOT's view of the index; `Err` is why it could not run.
async fn batches(f: &Front, root: &AbsPath, mode: &Mode) -> Result<Vec<Batch>, String> {
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
/// definition's line and then the file's uses in line order, then the other files that use it in the index's rank.
/// Each line gives a match per whole-word occurrence of NAME in it, read by LINE_OF (a file's line, from 1); a
/// definition whose line does not hold NAME (a macro's) is a match of nothing at the line's start. A definition's
/// first match is marked with its kind and signature.
pub(super) fn symbol_batches(
    root: &Path,
    ans: &UsagesAnswer,
    name: &str,
    case: bool,
    mut line_of: impl FnMut(&str, u32) -> Option<String>,
) -> Vec<Batch> {
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
    // each file once, in order: the defining files, then the using ones; its lines (definitions first, then the uses
    // in line order, so the uses in one definition follow each other under its label)
    type Line = (u32, Option<Mark>);
    let mut files: Vec<(String, Vec<Line>)> = Vec::new();
    let mut add = |path: &str, line: u32, def: Option<Mark>| {
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
        add(&d.path, d.line_start, Some(def_mark(d)));
    }
    let mut uses: Vec<(&str, u32)> = ans
        .usages
        .iter()
        .flat_map(|u| u.lines.iter().map(|l| (u.path.as_str(), *l)))
        .collect();
    // a file's uses in line order, the files in the index's rank (a stable sort by each file's first place)
    let first: HashMap<&str, usize> = ans
        .usages
        .iter()
        .enumerate()
        .rev()
        .map(|(i, u)| (u.path.as_str(), i))
        .collect();
    uses.sort_by_key(|(p, l)| (first[p], *l));
    for (p, l) in uses {
        add(p, l, None);
    }
    files
        .into_iter()
        .filter_map(|(file, lines)| {
            let (mut ms, mut marks) = (Vec::new(), Vec::new());
            for (n, def) in lines {
                let Some(text) = line_of(&file, n) else {
                    continue;
                };
                let mut found = hrafn::grep::line_matches(&re, &file, n, &text);
                if found.is_empty() && def.is_some() {
                    found.push(hrafn::grep::match_at(&file, n, &text, 0, 0));
                }
                for (i, m) in found.into_iter().enumerate() {
                    ms.push(m);
                    marks.push(if i == 0 { def.clone() } else { None });
                }
            }
            (!ms.is_empty()).then_some((file, ms, marks))
        })
        .collect()
}

/// Definition D's mark: its kind and signature.
fn def_mark(d: &runstav::methods::search::SymbolHit) -> Mark {
    Mark::Def {
        kind: d.kind.clone(),
        sig: d.sig.clone(),
    }
}

/// The batches of a Meaning search from ANS: one match per hit, in the files' first hits' order, the hit's symbol as
/// the match (its first line after it), else its first line; each marked with its score and its share of the best
/// hit's. The hits' lines are where `search/query` found them again in the files as they are now.
pub(super) fn meaning_batches(root: &Path, ans: &QueryAnswer) -> Vec<Batch> {
    let mut files: Vec<Batch> = Vec::new();
    let best = ans.hits.iter().map(|h| h.score).fold(0.0, f64::max);
    for h in &ans.hits {
        let file = root.join(&h.path).to_string_lossy().into_owned();
        let first = h.preview.lines().next().unwrap_or("").trim().to_owned();
        let (text, after) = match &h.symbol {
            Some(s) => (s.clone(), format!("  {first}")),
            None => (first, String::new()),
        };
        let mark = Some(Mark::Score {
            score: h.score,
            share: if best > 0.0 { h.score / best } else { 0.0 },
            moved: h.reanchored,
        });
        let m = Match {
            file: file.clone(),
            line: h.line_start,
            col: 0,
            end: text.chars().count() as u32,
            text,
            before: String::new(),
            after: after.chars().take(CONTEXT_CHARS).collect(),
        };
        match files.iter_mut().find(|(f, _, _)| *f == file) {
            Some((_, ms, marks)) => {
                ms.push(m);
                marks.push(mark);
            }
            None => files.push((file, vec![m], vec![mark])),
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
            .map(|(f, ms, _)| {
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
        // the definition's match carries its kind and signature; the uses carry nothing
        assert_eq!(
            b[0].2,
            [
                Some(Mark::Def {
                    kind: "function".into(),
                    sig: "fn parse(s: &str)".into()
                }),
                None
            ]
        );
        assert_eq!(b[1].2, [None, None]);
        // case ignored: `Parse` too
        let b = symbol_batches(Path::new("/r"), &ans, "parse", false, line_of);
        assert_eq!(b[0].1.len(), 3);
    }

    /// [D] Symbol's grouping: a definition's row has no label (it stands for its own), the uses in it get one label
    /// under it, a use at the top level none.
    #[test]
    fn a_symbol_searchs_uses_are_grouped_under_their_definition() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("p.rs");
        let text = "fn parse(s: &str) {\n    parse(s);\n    parse(s);\n}\nuse parse;\n";
        std::fs::write(&path, text).unwrap();
        let file = path.to_string_lossy().into_owned();
        let at = |line: u32, col: u32| Match {
            file: file.clone(),
            line,
            col,
            end: col + 5,
            text: "parse".into(),
            before: String::new(),
            after: String::new(),
        };
        let ms = vec![at(1, 3), at(2, 4), at(3, 4), at(5, 4)];
        let def = Some(Mark::Def {
            kind: "function".into(),
            sig: "fn parse(s: &str)".into(),
        });
        let r = marked(
            run::read(&path, &ms, true).unwrap(),
            vec![def, None, None, None],
        );
        let f = run::Found::new(file.clone(), ms, vec![0, 1, 2, 3], Some(r));
        let labels: Vec<Option<&str>> = (0..4)
            .map(|i| f.labelled(i).map(|d| d.name.as_str()))
            .collect();
        assert_eq!(labels, [None, Some("parse"), None, None]);
    }

    /// [D] A file's uses come in line order (the index lists them by rank), so the uses in one definition follow each
    /// other under its label; the files keep the index's order.
    #[test]
    fn a_symbol_search_lists_a_files_uses_in_line_order() {
        let ans = UsagesAnswer {
            defined: vec![],
            usages: vec![
                usage("b.rs", &[9, 2]),
                usage("a.rs", &[4]),
                usage("b.rs", &[5]),
            ],
            fresh: Fresh {
                files_pending: 0,
                view: view(),
            },
        };
        let b = symbol_batches(Path::new("/r"), &ans, "parse", true, |_, _| {
            Some("parse".into())
        });
        let got: Files<u32> = b
            .iter()
            .map(|(f, ms, _)| (f.as_str(), ms.iter().map(|m| m.line).collect()))
            .collect();
        assert_eq!(got, [("/r/b.rs", vec![2, 5, 9]), ("/r/a.rs", vec![4])]);
    }

    /// [D] A Meaning search: one match per hit under its file (files in the order of their first hit), the symbol as
    /// the match (else the hit's first line) with its first line after it; each marked with its score, its share of
    /// the best hit's and whether it moved since it was indexed.
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
            reanchored: line == 20,
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
            .map(|(f, ms, _)| {
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
                        (4, "retry", "  fn retry(op: Op) {"),
                        (20, "backoff", "  fn retry(op: Op) {")
                    ]
                ),
                ("/r/b.rs", vec![(1, "fn retry(op: Op) {", "")]),
            ]
        );
        let score = |score: f64, share: f64, moved: bool| {
            Some(Mark::Score {
                score,
                share,
                moved,
            })
        };
        assert_eq!(
            b[0].2,
            [score(0.91, 1.0, false), score(0.42, 0.42 / 0.91, true)]
        );
        assert_eq!(b[1].2, [score(0.5, 0.5 / 0.91, false)]);
    }
}
