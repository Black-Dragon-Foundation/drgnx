//! Inline values (spec §8): while stopped, the selected frame's function shows values at line ends.
//!
//! - **Which names:** the frame's file is parsed with Hrafn's grammar for its language (none: no values), the innermost
//!   function holding the stopped line is found (none: the file's top level), and its identifiers are read from its
//!   first line to the stopped line, and to the end of the outermost loop around the stopped line, whose later lines
//!   ran on earlier passes. A called name, a function's own name and a field after a dot are not values.
//! - **Matched** against the frame's fetched scopes: Locals and Arguments, then Globals only for names no local
//!   scope has.
//! - **Where:** each name on the last line it appears on up to the stopped line (a name only in the loop's later lines:
//!   its last line there), in the order the line has them, at most [`PER_LINE`] a line; `name = value` with the value
//!   on one line and cut at [`VALUE_MAX`] characters, joined by two spaces, the line cut at [`LINE_MAX`].
//! - **Changed:** a value that differs from the same session's previous stop; the event gives each changed item's
//!   character range.
//! - **Cost:** one parse per file text, cached by its digest ([`CACHED`] trees); the walk covers the function only.
//!
//! The editor draws them (`drgnx-debug-gutter.el`), and shows none for a buffer modified since it was saved: the program
//! runs the saved file.

use super::session::Stop;
use hrafn::inline_scan::{Lists, scan};
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use tree_sitter::{Parser, Tree};

/// Values a line shows at most.
pub const PER_LINE: usize = 3;
/// A value's characters at most (the last one an ellipsis when cut).
pub const VALUE_MAX: usize = 60;
/// A line's text at most.
pub const LINE_MAX: usize = 120;
/// Parsed texts kept.
pub const CACHED: usize = 8;

/// A variable of the stopped frame.
#[derive(Clone, Debug)]
pub struct Var {
    pub name: String,
    pub value: String,
    /// From a Globals scope.
    pub global: bool,
}

/// One line's values: its text and the character ranges of the items that changed.
#[derive(Clone, Debug, PartialEq)]
pub struct Shown {
    pub line: u32,
    pub text: String,
    pub changed: Vec<(usize, usize)>,
}

/// The parse cache and each session's last values.
#[derive(Default)]
pub struct Inline {
    trees: Mutex<VecDeque<(u64, Tree)>>,
    parses: AtomicU64,
    last: Mutex<HashMap<String, HashMap<String, String>>>,
}

/// The node kinds inline values look for, over every built-in pack's grammar: each pack's `:inline` (docs/develop/packs.md).
fn lists() -> &'static Lists {
    static LISTS: std::sync::OnceLock<Lists> = std::sync::OnceLock::new();
    LISTS.get_or_init(|| {
        let mut l = Lists::default();
        let add = |to: &mut Vec<String>, from: &[String]| {
            for k in from {
                if !to.contains(k) {
                    to.push(k.clone());
                }
            }
        };
        for m in skald::builtin::manifests() {
            if let Some(i) = &m.inline {
                add(&mut l.functions, &i.functions);
                add(&mut l.loops, &i.loops);
                add(&mut l.names, &i.names);
            }
        }
        l
    })
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// TEXT cut to MAX characters, its last an ellipsis when cut.
fn cut(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_owned();
    }
    let mut s: String = text.chars().take(max.saturating_sub(1)).collect();
    s.push('…');
    s
}

impl Inline {
    pub fn new() -> Inline {
        Inline::default()
    }

    /// How many texts were parsed (not found in the cache).
    pub fn parses(&self) -> u64 {
        self.parses.load(Ordering::Relaxed)
    }

    /// TEXT's tree in LANG (its grammar LANGUAGE), from the cache when its digest is there.
    fn tree(&self, text: &str, lang: hrafn::Lang, language: tree_sitter::Language) -> Option<Tree> {
        let mut h = xxhash_rust::xxh3::Xxh3::new();
        h.update(text.as_bytes());
        h.update(format!("{lang:?}").as_bytes());
        let digest = h.digest();
        {
            let mut trees = lock(&self.trees);
            if let Some(i) = trees.iter().position(|(d, _)| *d == digest) {
                let hit = trees.remove(i)?;
                let tree = hit.1.clone();
                trees.push_front(hit);
                return Some(tree);
            }
        }
        let mut p = Parser::new();
        p.set_language(&language).ok()?;
        let tree = p.parse(text, None)?;
        self.parses.fetch_add(1, Ordering::Relaxed);
        let mut trees = lock(&self.trees);
        trees.push_front((digest, tree.clone()));
        trees.truncate(CACHED);
        Some(tree)
    }

    /// The values to show in PATH (its TEXT) stopped at LINE (1-based) with VARS; BEFORE: the session's values at its
    /// previous stop (none: nothing is marked changed).
    pub fn lines(
        &self,
        path: &str,
        text: &str,
        line: u32,
        vars: &[Var],
        before: Option<&HashMap<String, String>>,
    ) -> Vec<Shown> {
        let (lang, _) = hrafn::classify(path, text.as_bytes());
        let Some(language) = hrafn::structural::language(lang) else {
            return vec![];
        };
        let Some(tree) = self.tree(text, lang, language) else {
            return vec![];
        };
        let row = line.saturating_sub(1) as usize;
        let found = scan(&tree, text, row, lists());
        // the value of each name: a local scope's first, else a global's
        let value = |name: &str| {
            vars.iter()
                .find(|v| !v.global && v.name == name)
                .or_else(|| vars.iter().find(|v| v.global && v.name == name))
        };
        // each name's row: its last up to the stop, else its last
        let mut place: HashMap<&str, usize> = HashMap::new();
        for (r, _, n) in &found {
            if value(n).is_none() {
                continue;
            }
            let e = place.entry(n.as_str()).or_insert(*r);
            let up = |x: usize| x <= row;
            if (up(*r) && (!up(*e) || *r > *e)) || (!up(*r) && !up(*e) && *r > *e) {
                *e = *r;
            }
        }
        let mut by_row: Vec<(usize, Vec<&str>)> = vec![];
        let mut ordered: Vec<&(usize, usize, String)> = found.iter().collect();
        ordered.sort_by_key(|(r, c, _)| (*r, *c));
        for (r, _, n) in ordered {
            if place.get(n.as_str()) != Some(r) {
                continue;
            }
            match by_row.last_mut() {
                Some((lr, names)) if lr == r => {
                    if !names.contains(&n.as_str()) {
                        names.push(n);
                    }
                }
                _ => by_row.push((*r, vec![n])),
            }
        }
        by_row
            .into_iter()
            .map(|(r, names)| {
                let mut text = String::new();
                let mut changed = vec![];
                for n in names.into_iter().take(PER_LINE) {
                    let v = value(n).map(|v| v.value.as_str()).unwrap_or_default();
                    let one = v.replace(['\n', '\r'], " ");
                    let mut item = format!("{n} = {}", cut(&one, VALUE_MAX));
                    let sep = if text.is_empty() { 0 } else { 2 };
                    let room = LINE_MAX.saturating_sub(text.chars().count() + sep);
                    if room < 2 {
                        break;
                    }
                    let full = item.chars().count() <= room;
                    if !full {
                        item = cut(&item, room);
                    }
                    if sep > 0 {
                        text.push_str("  ");
                    }
                    let start = text.chars().count();
                    text.push_str(&item);
                    if before.is_some_and(|b| b.get(n).is_some_and(|old| old != v)) {
                        changed.push((start, start + item.chars().count()));
                    }
                    if !full {
                        break;
                    }
                }
                Shown {
                    line: u32::try_from(r + 1).unwrap_or(u32::MAX),
                    text,
                    changed,
                }
            })
            .collect()
    }

    /// The `debug-inline` event of SESSION's STOP: its selected frame's file read from disk, its values marked against
    /// the session's previous stop (which this stop then becomes). A frame with no file, or one that cannot be read:
    /// no lines.
    pub fn at_stop(&self, session: &str, stop: &Stop) -> Value {
        let frame = stop
            .frames
            .iter()
            .find(|f| f.get("id").and_then(Value::as_i64) == Some(stop.frame));
        let path = frame
            .and_then(|f| f.pointer("/source/path"))
            .and_then(Value::as_str);
        let line = frame
            .and_then(|f| f.get("line"))
            .and_then(Value::as_u64)
            .and_then(|l| u32::try_from(l).ok())
            .unwrap_or(0);
        let mut vars = vec![];
        for s in &stop.scopes {
            let Some(vs) = &s.variables else { continue };
            let name = s
                .scope
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let hint = s
                .scope
                .get("presentationHint")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if hint == "registers" || name.eq_ignore_ascii_case("registers") {
                continue;
            }
            let global = name.to_ascii_lowercase().contains("global");
            for v in vs {
                if let (Some(n), Some(val)) = (
                    v.get("name").and_then(Value::as_str),
                    v.get("value").and_then(Value::as_str),
                ) {
                    vars.push(Var {
                        name: n.to_owned(),
                        value: val.to_owned(),
                        global,
                    });
                }
            }
        }
        let mut last = lock(&self.last);
        let before = last.get(session).cloned();
        let now: HashMap<String, String> = vars
            .iter()
            .rev()
            .map(|v| (v.name.clone(), v.value.clone()))
            .collect();
        last.insert(session.to_owned(), now);
        drop(last);
        let shown = match path.map(|p| (p, std::fs::read_to_string(p))) {
            Some((p, Ok(text))) if line > 0 => self.lines(p, &text, line, &vars, before.as_ref()),
            _ => vec![],
        };
        let lines: Vec<Value> = shown
            .iter()
            .map(|s| json!({"line": s.line, "text": s.text, "changed": s.changed}))
            .collect();
        json!({"session": session, "epoch": stop.epoch, "path": path, "lines": lines})
    }

    /// SESSION has ended: its values go.
    pub fn forget(&self, session: &str) {
        lock(&self.last).remove(session);
    }
}

#[cfg(test)]
mod list_tests {
    use super::*;

    /// The lists the module held before the packs carried them (over every grammar Hrafn had).
    #[test]
    fn the_packs_lists_are_the_ones_inline_values_had() {
        fn strs(v: &[String]) -> Vec<&str> {
            v.iter().map(String::as_str).collect()
        }
        fn sorted<'a>(v: &[&'a str]) -> Vec<&'a str> {
            let mut v = v.to_vec();
            v.sort_unstable();
            v
        }
        assert_eq!(
            sorted(&strs(&lists().functions)),
            sorted(&[
                "function_definition",
                "function_declaration",
                "function_expression",
                "function_item",
                "function",
                "generator_function",
                "generator_function_declaration",
                "arrow_function",
                "method_definition",
                "method_declaration",
                "constructor_declaration",
                "func_literal",
                "closure_expression",
                "lambda",
                "lambda_expression",
                "local_function_statement", // C# (language packs Task 10b)
            ])
        );
        assert_eq!(
            sorted(&strs(&lists().loops)),
            sorted(&[
                "for_statement",
                "for_range_loop",    // C++ (language packs Task 9)
                "foreach_statement", // C# (language packs Task 10b)
                "for_in_statement",
                "enhanced_for_statement",
                "c_style_for_statement",
                "while_statement",
                "do_statement",
                "until_statement",
                "for_expression",
                "while_expression",
                "loop_expression",
            ])
        );
        assert_eq!(
            sorted(&strs(&lists().names)),
            sorted(&[
                "identifier",
                "variable_name",
                "shorthand_property_identifier"
            ])
        );
    }
}
