//! The definer table: the forms whose symbols Hrafn indexes, and the names each makes.
//!
//! The table is closed. It covers every form drgnx defines names with, because the eval's floor (exact-symbol
//! recall@1 = 1.0) needs them all. A form's head atoms are read by a small scanner over its text (spans come from
//! the grammar; no project code is evaluated).

/// What a definer's arguments look like.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Shape {
    /// `(head NAME ...)`.
    Plain,
    /// `(head 'NAME ...)`: the name is quoted.
    Quoted,
    Struct,
    Minor,
    Derived,
}

#[derive(Clone, Copy, Debug)]
pub struct Definer {
    pub name: &'static str,
    pub kind: &'static str,
    shape: Shape,
    /// The index of the docstring among the form's atoms (the head is 0), or none: then `:doc "..."` is looked for.
    doc_at: Option<usize>,
}

const fn d(name: &'static str, kind: &'static str, shape: Shape, doc_at: Option<usize>) -> Definer {
    Definer {
        name,
        kind,
        shape,
        doc_at,
    }
}

const TABLE: &[Definer] = &[
    d("defun", "function", Shape::Plain, Some(3)),
    d("defvar", "variable", Shape::Plain, Some(3)),
    d("defcustom", "custom", Shape::Plain, Some(3)),
    d("defmacro", "macro", Shape::Plain, Some(3)),
    d("cl-defun", "function", Shape::Plain, Some(3)),
    d("defconst", "constant", Shape::Plain, Some(3)),
    d("defvar-local", "variable", Shape::Plain, Some(3)),
    d("defface", "face", Shape::Plain, Some(3)),
    d("defgroup", "group", Shape::Plain, Some(3)),
    d("defsubst", "function", Shape::Plain, Some(3)),
    d("cl-defmacro", "macro", Shape::Plain, Some(3)),
    d("defvar-keymap", "keymap", Shape::Plain, None),
    d(
        "define-obsolete-function-alias",
        "alias",
        Shape::Quoted,
        None,
    ),
    d("drgnx-defsetting", "setting", Shape::Plain, None),
    d("drgnx-memo-define", "memo", Shape::Plain, None),
    d("defalias", "alias", Shape::Quoted, Some(3)),
    d("cl-defstruct", "struct", Shape::Struct, Some(2)),
    d("define-minor-mode", "mode", Shape::Minor, Some(2)),
    d("define-derived-mode", "mode", Shape::Derived, Some(4)),
    d("define-error", "error", Shape::Quoted, None),
    d("cl-defgeneric", "generic", Shape::Plain, Some(3)),
    d("cl-defmethod", "method", Shape::Plain, None),
    d("drgnx-module-define", "module", Shape::Quoted, None),
    d("drgnx-doctor-define", "check", Shape::Quoted, None),
    d("drgnx-config-define", "config", Shape::Quoted, None),
    d("drgnx-command-define", "command", Shape::Quoted, None),
];

pub fn definer(head: &str) -> Option<&'static Definer> {
    TABLE.iter().find(|d| d.name == head)
}

/// An atom of a form: a byte range in the file's text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Atom {
    pub start: usize,
    pub end: usize,
}

const MAX_DEPTH: usize = 200;

fn is_ws(b: u8) -> bool {
    matches!(b, 1..=32 | 0xA0)
}

/// The top-level atoms of the list that starts at `text[start]` (a `(`), at most `limit` of them. `end` bounds the
/// scan (the form's end). Offsets are absolute.
pub(crate) fn atoms(text: &str, start: usize, end: usize, limit: usize) -> Vec<Atom> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    if b.get(start) != Some(&b'(') {
        return out;
    }
    let mut i = start + 1;
    while out.len() < limit {
        i = skip_ws(b, i, end);
        if i >= end || b[i] == b')' {
            break;
        }
        let a = i;
        i = read_one(b, i, end, 0);
        if i <= a {
            break;
        }
        out.push(Atom { start: a, end: i });
    }
    out
}

fn skip_ws(b: &[u8], mut i: usize, end: usize) -> usize {
    while i < end {
        if is_ws(b[i]) {
            i += 1;
        } else if b[i] == b';' {
            while i < end && b[i] != b'\n' {
                i += 1;
            }
        } else {
            break;
        }
    }
    i
}

/// One datum starting at `i`; the index after it.
fn read_one(b: &[u8], mut i: usize, end: usize, depth: usize) -> usize {
    if i >= end {
        return i;
    }
    match b[i] {
        b'"' => {
            i += 1;
            while i < end && b[i] != b'"' {
                i += if b[i] == b'\\' { 2 } else { 1 };
            }
            (i + 1).min(end)
        }
        b'(' | b'[' if depth < MAX_DEPTH => {
            i += 1;
            loop {
                i = skip_ws(b, i, end);
                if i >= end {
                    return end;
                }
                if matches!(b[i], b')' | b']') {
                    return i + 1;
                }
                let next = read_one(b, i, end, depth + 1);
                i = if next > i { next } else { i + 1 };
            }
        }
        b'\'' | b'`' => read_one(b, skip_ws(b, i + 1, end), end, depth),
        b',' => {
            let j = if b.get(i + 1) == Some(&b'@') {
                i + 2
            } else {
                i + 1
            };
            read_one(b, skip_ws(b, j, end), end, depth)
        }
        b'#' if matches!(b.get(i + 1), Some(b'\'' | b'(' | b'[')) => read_one(b, i + 1, end, depth),
        b'#' if b.get(i + 1) == Some(&b's') && b.get(i + 2) == Some(&b'(') => {
            read_one(b, i + 2, end, depth)
        }
        b'?' => {
            // a character literal: `?(` is not a paren
            i += 1;
            if i < end && b[i] == b'\\' {
                i += 2;
                while i < end && b[i].is_ascii_alphanumeric() {
                    i += 1;
                }
            } else if i < end {
                i += 1;
                while i < end && (b[i] & 0xC0) == 0x80 {
                    i += 1;
                }
            }
            i.min(end)
        }
        _ => {
            let a = i;
            while i < end {
                match b[i] {
                    b'\\' => i += 2,
                    c if is_ws(c) || matches!(c, b'(' | b')' | b'[' | b']' | b'"' | b';') => break,
                    _ => i += 1,
                }
            }
            i.min(end).max(a + 1)
        }
    }
}

/// A name or symbol written as an atom: quote and function-quote prefixes dropped; `None` for a list.
fn symbol_of(s: &str) -> Option<String> {
    let s = s.trim_start_matches("#'").trim_start_matches('\'');
    if s.is_empty() || s.starts_with(['(', '[', '"', '`', ',', '?', ':']) {
        return None;
    }
    Some(s.to_string())
}

/// What a form defines.
pub(crate) struct Def {
    pub name: String,
    pub kind: &'static str,
}

fn def(name: impl Into<String>, kind: &'static str) -> Def {
    Def {
        name: name.into(),
        kind,
    }
}

/// The names the form makes. `atoms[0]` is the head.
pub(crate) fn defined(d: &Definer, text: &str, atoms: &[Atom]) -> Vec<Def> {
    let at = |i: usize| atoms.get(i).map(|a| &text[a.start..a.end]);
    let Some(first) = at(1) else {
        return Vec::new();
    };
    match d.shape {
        Shape::Plain | Shape::Quoted => symbol_of(first)
            .map(|n| vec![def(n, d.kind)])
            .unwrap_or_default(),
        Shape::Minor | Shape::Derived => {
            let Some(n) = symbol_of(first) else {
                return Vec::new();
            };
            vec![
                def(n.clone(), "mode"),
                def(format!("{n}-hook"), "hook"),
                def(format!("{n}-map"), "keymap"),
            ]
        }
        Shape::Struct => struct_defs(first, text, atoms),
    }
}

/// `(cl-defstruct NAME-OR-(NAME OPTIONS...) [DOC] SLOTS...)`.
fn struct_defs(first: &str, text: &str, atoms: &[Atom]) -> Vec<Def> {
    let mut parts: Vec<Atom> = Vec::new();
    let name = if first.starts_with('(') {
        let a = atoms[1];
        parts = atoms_in(text, a);
        parts.first().and_then(|p| symbol_of(&text[p.start..p.end]))
    } else {
        symbol_of(first)
    };
    let Some(name) = name else {
        return Vec::new();
    };
    let mut constructors: Vec<String> = Vec::new();
    let mut default_constructor = true;
    let mut predicate = Some(format!("{name}-p"));
    let mut conc = format!("{name}-");
    for opt in parts.iter().skip(1) {
        let inner = atoms_in(text, *opt);
        let word = |i: usize| inner.get(i).map(|a| &text[a.start..a.end]);
        match (word(0), word(1)) {
            (Some(":constructor"), Some("nil")) => default_constructor = false,
            (Some(":constructor"), Some(c)) => {
                if let Some(c) = symbol_of(c) {
                    constructors.push(c);
                }
            }
            (Some(":predicate"), Some("nil")) => predicate = None,
            (Some(":predicate"), Some(p)) => predicate = symbol_of(p),
            (Some(":conc-name"), Some("nil")) => conc.clear(),
            (Some(":conc-name"), Some(c)) => conc = c.trim_matches('"').to_string(),
            _ => {}
        }
    }
    let mut out = vec![def(name.clone(), "struct")];
    if default_constructor {
        out.push(def(format!("make-{name}"), "constructor"));
    }
    out.extend(constructors.into_iter().map(|c| def(c, "constructor")));
    out.extend(predicate.map(|p| def(p, "predicate")));
    for a in atoms.iter().skip(2) {
        let s = &text[a.start..a.end];
        if s.starts_with('"') {
            continue; // the docstring
        }
        let slot = if s.starts_with('(') {
            atoms_in(text, *a)
                .first()
                .and_then(|p| symbol_of(&text[p.start..p.end]))
        } else {
            symbol_of(s)
        };
        if let Some(slot) = slot {
            out.push(def(format!("{conc}{slot}"), "accessor"));
        }
    }
    out
}

/// The atoms of the list `a` covers.
fn atoms_in(text: &str, a: Atom) -> Vec<Atom> {
    atoms(text, a.start, a.end, usize::MAX)
}

/// The docstring of a form: `(first line, whole docstring)`.
pub(crate) fn doc_of(d: &Definer, text: &str, atoms: &[Atom]) -> Option<(String, String)> {
    let string_at = |i: usize| {
        atoms
            .get(i)
            .map(|a| &text[a.start..a.end])
            .filter(|s| s.starts_with('"'))
    };
    let raw = d.doc_at.and_then(string_at).or_else(|| {
        atoms
            .iter()
            .position(|a| &text[a.start..a.end] == ":doc")
            .and_then(|i| string_at(i + 1))
    })?;
    let inner = raw
        .strip_prefix('"')?
        .strip_suffix('"')
        .unwrap_or(&raw[1..]);
    let mut full = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('\n') | None => {}
                Some('=') => {}
                Some(n) => full.push(n),
            }
        } else {
            full.push(c);
        }
    }
    let first = full
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())?
        .to_string();
    Some((first, full))
}

/// Whether the form is a variable whose value is a literal table: such a form embeds only its head and docstring.
pub(crate) fn data_heavy(d: &Definer, text: &str, atoms: &[Atom]) -> bool {
    if !matches!(d.name, "defconst" | "defvar" | "defvar-local" | "defcustom") {
        return false;
    }
    let Some(v) = atoms.get(2).map(|a| &text[a.start..a.end]) else {
        return false;
    };
    [
        "'(", "`(", "'[", "[", "#s(", "(list ", "(vector ", "(list\n",
    ]
    .iter()
    .any(|p| v.starts_with(p))
}
