//! The Search view's Pattern toggle: a code pattern (`hrafn::structural`) over the files a search names. The files to
//! read come from the searcher: those holding the pattern's longest name (its first match each), else every file it
//! lists; each is parsed with its language's grammar and searched. A match is its first line's row; how many lines it
//! runs past that and its metavariables ride on the row as its mark ([`Mark::Span`]).

use super::run::Mark;
use hrafn::grep::{self, Match, Query};
use hrafn::structural::{self, Pattern};
use hrafn::{Lang, classify};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};

/// A Pattern search: what was typed, and the one language it is for (none: each file's own).
#[derive(Clone, Debug)]
pub(super) struct Find {
    pub pattern: String,
    pub lang: Option<Lang>,
}

/// LANG, a name of Hrafn's (`rust`, `elisp`, …) as a language with a grammar; `Err` says why not.
pub(super) fn lang_of(name: &str) -> Result<Lang, String> {
    let l = Lang::parse(name);
    if l.as_str() != name || structural::Grammar::of(l).is_none() {
        return Err(format!("no grammar for {name}"));
    }
    Ok(l)
}

/// One file's matches, each with its mark.
pub(super) type Batch = Vec<(Match, Mark)>;

/// The patterns a search made, one per language (`Err`: the language's refusal, said once).
struct Patterns<'a> {
    find: &'a Find,
    by_lang: HashMap<Lang, Result<Pattern, String>>,
}

impl Patterns<'_> {
    fn get(&mut self, lang: Lang) -> &Result<Pattern, String> {
        let pattern = &self.find.pattern;
        self.by_lang
            .entry(lang)
            .or_insert_with(|| Pattern::new(lang, pattern, None).map_err(|e| e.to_string()))
    }
}

/// Search Q's files for FIND, handing each file's matches to ON_FILE. Stops when CANCEL is set. `Err` is why the
/// search could not run, or each language the pattern is not valid in (those files are skipped).
pub(super) fn run(
    q: &Query,
    find: &Find,
    cancel: &AtomicBool,
    mut on_file: impl FnMut(Batch),
) -> Result<(), String> {
    let mut patterns = Patterns {
        find,
        by_lang: HashMap::new(),
    };
    // the one language's pattern refused: nothing to search
    let literal = match find.lang {
        Some(l) => {
            let p = patterns.get(l).as_ref().map_err(Clone::clone)?;
            p.literals().iter().max_by_key(|s| s.len()).cloned()
        }
        None => None,
    };
    let candidates = Query {
        text: literal.clone().unwrap_or_else(|| ".".into()),
        regexp: literal.is_none(),
        case: true,
        word: false,
        first: true,
        ..q.clone()
    };
    let result = grep::run(&candidates, cancel, |ms| {
        if cancel.load(Ordering::Relaxed) {
            return;
        }
        let file = &ms[0].file;
        let Ok(bytes) = std::fs::read(file) else {
            return;
        };
        let (lang, _) = classify(file, &bytes[..bytes.len().min(512)]);
        if find.lang.is_some_and(|l| l != lang) || structural::Grammar::of(lang).is_none() {
            return;
        }
        let Ok(p) = patterns.get(lang) else { return };
        let Ok(found) = p.find(&bytes) else { return };
        let batch = matches_of(file, &bytes, &found);
        if !batch.is_empty() {
            on_file(batch);
        }
    });
    result?;
    let refused: Vec<&String> = patterns
        .by_lang
        .values()
        .filter_map(|r| r.as_ref().err())
        .collect();
    match refused.as_slice() {
        [] => Ok(()),
        rs => Err(rs.iter().map(|s| s.as_str()).collect::<Vec<_>>().join("; ")),
    }
}

/// FOUND, the structural matches in FILE (whose bytes are BYTES, UTF-8), as rows' matches: each its first line's, lit
/// to the line's end when it runs on, with how many lines more and its metavariables.
fn matches_of(file: &str, bytes: &[u8], found: &[structural::Match]) -> Batch {
    let text = std::str::from_utf8(bytes).unwrap_or_default();
    found
        .iter()
        .map(|m| {
            let line_start = text[..m.start].rfind('\n').map_or(0, |i| i + 1);
            let line_end = text[m.start..]
                .find('\n')
                .map_or(text.len(), |i| m.start + i);
            let line = text[line_start..line_end]
                .strip_suffix('\r')
                .unwrap_or(&text[line_start..line_end]);
            let from = m.start - line_start;
            let to = (m.end.min(line_end) - line_start).min(line.len());
            let mark = Mark::Span {
                more: m.end_line - m.line,
                captures: m
                    .captures
                    .iter()
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect(),
            };
            (grep::match_at(file, m.line, line, from, to), mark)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn put(dir: &std::path::Path, name: &str, text: &str) -> String {
        let f = dir.join(name);
        std::fs::write(&f, text).unwrap();
        f.to_string_lossy().into_owned()
    }

    fn search(
        dir: &std::path::Path,
        pattern: &str,
        lang: Option<Lang>,
    ) -> (Vec<Batch>, Result<(), String>) {
        let q = Query {
            root: dir.to_path_buf(),
            ..Query::default()
        };
        let find = Find {
            pattern: pattern.into(),
            lang,
        };
        let mut out = Vec::new();
        let r = run(&q, &find, &AtomicBool::new(false), |b| out.push(b));
        out.sort_by(|a, b| a[0].0.file.cmp(&b[0].0.file));
        (out, r)
    }

    #[test]
    fn a_pattern_finds_its_matches_in_the_files_of_its_language() {
        let d = tempfile::tempdir().unwrap();
        let a = put(
            d.path(),
            "a.el",
            "(setq x (gethash k tbl))\n(gethash j\n  tbl)\n",
        );
        put(d.path(), "b.el", "(setq y 1)\n");
        put(d.path(), "c.rs", "fn f() { gethash(k, tbl); }\n");
        let (found, r) = search(d.path(), "(gethash $K tbl)", Some(Lang::Elisp));
        assert_eq!(r, Ok(()));
        assert_eq!(found.len(), 1);
        let rows: Vec<_> = found[0]
            .iter()
            .map(|(m, mark)| (m.file.clone(), m.line, m.col, m.text.clone(), mark.clone()))
            .collect();
        let span = |more, k: &str| Mark::Span {
            more,
            captures: vec![("K".into(), k.into())],
        };
        assert_eq!(
            rows,
            [
                (a.clone(), 1, 8, "(gethash k tbl)".into(), span(0, "k")),
                (a, 2, 0, "(gethash j".into(), span(1, "j")),
            ]
        );
    }

    #[test]
    fn without_a_language_each_file_is_its_own() {
        let d = tempfile::tempdir().unwrap();
        put(d.path(), "a.el", "(f 1)\n");
        put(d.path(), "b.py", "f(1)\n");
        put(d.path(), "notes.txt", "f(1)\n");
        let (found, r) = search(d.path(), "f($A)", None);
        // Lisp has no f($A) form: the pattern is not valid there, said once; Python's file matches
        assert!(r.is_err(), "{r:?}");
        assert_eq!(found.len(), 1);
        assert!(found[0][0].0.file.ends_with("b.py"));
    }

    #[test]
    fn a_pattern_not_valid_in_its_language_is_refused() {
        let d = tempfile::tempdir().unwrap();
        put(d.path(), "a.rs", "fn f() {}\n");
        let (found, r) = search(d.path(), "fn $F() { let = 1; }", Some(Lang::Rust));
        assert!(found.is_empty());
        assert_eq!(r, Err("pattern is not valid Rust at col 14".into()));
    }

    #[test]
    fn a_language_name_needs_a_grammar() {
        assert_eq!(lang_of("rust"), Ok(Lang::Rust));
        assert!(lang_of("org").is_err());
        assert!(lang_of("klingon").is_err());
    }
}
