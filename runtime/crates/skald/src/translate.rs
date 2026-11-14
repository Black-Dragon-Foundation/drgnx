//! The generic mode's query translation (design §3.4, Task 3g): a pack's `highlights.scm`, written in the portable
//! subset (`highlights::check`), becomes the queries Emacs's `treesit-font-lock-rules` takes.
//!
//! Emacs names a capture by the face (or function) it applies, and accepts only `#eq?`, `#match?` and `#pred?`. So:
//! - a capture `@keyword.return` becomes `@font-lock-keyword-face` (a fixed table; a capture the table does not know
//!   becomes `@_NAME`, which Emacs ignores, so a predicate may still refer to it);
//! - `#match?` keeps its regexp, rewritten from the portable subset into Emacs's syntax;
//! - `#any-of?` becomes a `#match?` on an anchored alternation;
//! - `#not-eq?` and `#not-match?` become `#pred?` on a named function, which the editor defines (`Pred`).
//!
//! Each top-level pattern goes to the feature of its first known capture, so a level (`treesit-font-lock-feature-list`)
//! turns whole kinds of highlighting on and off. The rules stay in the file's order (consecutive patterns of one feature
//! share a rule) and the editor lets a later rule override an earlier one: highlight queries written for Neovim let a
//! later, more specific pattern win over a general one (`(identifier) @variable`, then `(function_declaration name:
//! (identifier) @function)`), and grouping by feature would turn that around.

use std::fmt::Write as _;

/// A highlighting rule: the Emacs feature it belongs to and the query text (Emacs syntax).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rule {
    pub feature: String,
    pub query: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PredKind {
    /// true when the node's text is not ARG
    NotEq,
    /// true when the node's text does not match ARG (an Emacs regexp)
    NotMatch,
    /// true when the two nodes' texts differ (`#not-eq?` on two captures)
    NotEqNodes,
}

/// A function the editor defines for a `#pred?` in a rule: `(NAME NODE…)`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pred {
    pub name: String,
    pub kind: PredKind,
    pub arg: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Translated {
    pub rules: Vec<Rule>,
    pub preds: Vec<Pred>,
    /// Capture names the table does not know (turned into ignored `@_NAME` captures), each once.
    pub unmapped: Vec<String>,
}

/// (feature, face) of a capture name, or `None`. A name that is not listed falls back to its part before the first dot.
fn capture(name: &str) -> Option<(&'static str, &'static str)> {
    let exact = match name {
        "comment.documentation" => ("comment", "font-lock-doc-face"),
        "string.escape" | "escape" => ("escape-sequence", "font-lock-escape-face"),
        "function.builtin" | "function.macro" => ("function", "font-lock-builtin-face"),
        "function"
        | "function.call"
        | "function.method"
        | "function.method.call"
        | "method"
        | "method.call" => ("function", "font-lock-function-name-face"),
        "type" | "type.builtin" | "type.definition" | "constructor" | "namespace" | "module" => {
            ("type", "font-lock-type-face")
        }
        "variable.builtin" => ("variable", "font-lock-builtin-face"),
        "variable.parameter" | "parameter" => ("variable", "font-lock-variable-name-face"),
        "variable.member" | "property" | "field" => ("property", "font-lock-property-use-face"),
        "punctuation.bracket" => ("bracket", "font-lock-bracket-face"),
        "punctuation.delimiter" | "punctuation.special" => {
            ("delimiter", "font-lock-delimiter-face")
        }
        "attribute" | "annotation" | "decorator" | "preproc" | "preprocessor" => {
            ("attribute", "font-lock-preprocessor-face")
        }
        "constant" | "constant.builtin" | "boolean" => ("constant", "font-lock-constant-face"),
        "number" | "float" | "number.float" => ("number", "font-lock-number-face"),
        "comment" => ("comment", "font-lock-comment-face"),
        "string" | "character" | "string.special" | "string.regexp" | "string.documentation" => {
            ("string", "font-lock-string-face")
        }
        "keyword" | "conditional" | "repeat" | "include" | "exception" | "define" => {
            ("keyword", "font-lock-keyword-face")
        }
        "operator" => ("operator", "font-lock-operator-face"),
        "variable" => ("variable", "font-lock-variable-use-face"),
        "label" => ("variable", "font-lock-constant-face"),
        "tag" => ("keyword", "font-lock-keyword-face"),
        _ => return name.split_once('.').and_then(|(base, _)| capture(base)),
    };
    Some(exact)
}

/// A portable regexp (literals, `.`, classes, `^ $ * + ? |`, groups) in Emacs syntax.
pub fn emacs_regexp(re: &str) -> String {
    let cs: Vec<char> = re.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    let mut in_class = false;
    while i < cs.len() {
        let c = cs[i];
        if in_class {
            out.push(c);
            if c == ']' {
                in_class = false;
            }
            i += 1;
            continue;
        }
        match c {
            '[' => {
                in_class = true;
                out.push(c);
                if cs.get(i + 1) == Some(&'^') {
                    out.push('^');
                    i += 1;
                }
                if cs.get(i + 1) == Some(&']') {
                    out.push(']');
                    i += 1;
                }
            }
            '(' => out.push_str("\\("),
            ')' => out.push_str("\\)"),
            '|' => out.push_str("\\|"),
            '\\' => match cs.get(i + 1) {
                // an escaped punctuation mark: literal. Emacs's own specials keep their backslash, the rest is plain
                Some(&n) if matches!(n, '.' | '*' | '+' | '?' | '[' | ']' | '^' | '$' | '\\') => {
                    out.push('\\');
                    out.push(n);
                    i += 1;
                }
                Some(&n) => {
                    out.push(n);
                    i += 1;
                }
                None => out.push_str("\\\\"),
            },
            c => out.push(c),
        }
        i += 1;
    }
    out
}

/// `s` escaped as a string literal of a query.
fn scm_string(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// A token of a query: the text and its kind.
#[derive(Debug, PartialEq)]
enum Tok<'a> {
    Open(&'a str),
    Close(&'a str),
    Str(String),
    Capture(&'a str),
    Pred(&'a str),
    Other(&'a str),
}

fn lex(text: &str) -> Vec<Tok<'_>> {
    let b = text.as_bytes();
    let (mut i, mut out) = (0, Vec::new());
    while i < b.len() {
        let c = b[i];
        match c {
            b' ' | b'\t' | b'\r' | b'\n' => i += 1,
            b';' => {
                while i < b.len() && b[i] != b'\n' {
                    i += 1;
                }
            }
            b'(' | b'[' => {
                out.push(Tok::Open(&text[i..=i]));
                i += 1;
            }
            b')' | b']' => {
                out.push(Tok::Close(&text[i..=i]));
                i += 1;
            }
            b'"' => {
                let mut s = String::new();
                i += 1;
                while i < b.len() && b[i] != b'"' {
                    if b[i] == b'\\' && i + 1 < b.len() {
                        i += 1;
                        match b[i] {
                            b'n' => s.push('\n'),
                            b't' => s.push('\t'),
                            _ => {
                                let ch = text[i..].chars().next().expect("a char");
                                s.push(ch);
                                i += ch.len_utf8() - 1;
                            }
                        }
                    } else {
                        let ch = text[i..].chars().next().expect("a char");
                        s.push(ch);
                        i += ch.len_utf8() - 1;
                    }
                    i += 1;
                }
                i += 1;
                out.push(Tok::Str(s));
            }
            b'@' | b'#' => {
                let start = i;
                i += 1;
                while i < b.len() && !b" \t\r\n()[]\";".contains(&b[i]) {
                    i += 1;
                }
                let word = &text[start..i];
                out.push(if c == b'@' {
                    Tok::Capture(&word[1..])
                } else {
                    Tok::Pred(word)
                });
            }
            _ => {
                let start = i;
                while i < b.len() && !b" \t\r\n()[]\";".contains(&b[i]) {
                    i += 1;
                }
                out.push(Tok::Other(&text[start..i]));
            }
        }
    }
    out
}

/// The tokens of one top-level pattern per entry: a pattern starts at any depth-0 token that is not a trailing capture
/// or quantifier.
fn patterns<'a>(toks: Vec<Tok<'a>>) -> Vec<Vec<Tok<'a>>> {
    let (mut out, mut depth): (Vec<Vec<Tok<'a>>>, i32) = (Vec::new(), 0);
    for t in toks {
        let starts = depth == 0
            && !matches!(&t, Tok::Capture(_) | Tok::Close(_))
            && !matches!(&t, Tok::Other(w) if matches!(*w, "*" | "+" | "?" | "!"));
        match &t {
            Tok::Open(_) => depth += 1,
            Tok::Close(_) => depth -= 1,
            _ => {}
        }
        if starts || out.is_empty() {
            out.push(Vec::new());
        }
        out.last_mut().expect("a pattern").push(t);
    }
    out
}

struct Ctx<'a> {
    pack: &'a str,
    preds: Vec<Pred>,
    unmapped: Vec<String>,
    refused: Vec<String>,
}

impl Ctx<'_> {
    fn cap(&mut self, name: &str) -> String {
        if name.starts_with('_') {
            return name.to_string();
        }
        match capture(name) {
            Some((_, face)) => face.to_string(),
            None => {
                if !self.unmapped.iter().any(|u| u == name) {
                    self.unmapped.push(name.to_string());
                }
                format!("_{}", name.replace('.', "_"))
            }
        }
    }

    fn pred_fn(&mut self, kind: PredKind, arg: String) -> String {
        let name = format!("drgnx-pack-pred--{}-{}", self.pack, self.preds.len() + 1);
        self.preds.push(Pred {
            name: name.clone(),
            kind,
            arg,
        });
        name
    }

    /// The tokens of one predicate `( #name args… )` (the parens included) as query text.
    fn predicate(&mut self, toks: &[Tok<'_>]) -> String {
        let (name, args) = match &toks[1] {
            Tok::Pred(n) => (*n, &toks[2..toks.len() - 1]),
            _ => unreachable!("a predicate starts with #name"),
        };
        let cap = |c: &mut Self, t: &Tok<'_>| match t {
            Tok::Capture(n) => Some(format!("@{}", c.cap(n))),
            _ => None,
        };
        let strings = |args: &[Tok<'_>]| -> Vec<String> {
            args.iter()
                .filter_map(|t| {
                    if let Tok::Str(s) = t {
                        Some(s.clone())
                    } else {
                        None
                    }
                })
                .collect()
        };
        match (name, args) {
            ("#eq?", [a, b]) => {
                let x = cap(self, a).unwrap_or_else(|| string_of(a));
                let y = cap(self, b).unwrap_or_else(|| string_of(b));
                format!("(#eq? {x} {y})")
            }
            ("#match?", [a, Tok::Str(re)]) => {
                format!(
                    "(#match? {} {})",
                    cap(self, a).unwrap_or_default(),
                    scm_string(&emacs_regexp(re))
                )
            }
            ("#any-of?", [a, rest @ ..]) => {
                let alts: Vec<String> = strings(rest).iter().map(|s| quote(s)).collect();
                let re = format!("\\`\\(?:{}\\)\\'", alts.join("\\|"));
                format!(
                    "(#match? {} {})",
                    cap(self, a).unwrap_or_default(),
                    scm_string(&re)
                )
            }
            ("#not-eq?", [a, Tok::Str(s)]) => {
                let f = self.pred_fn(PredKind::NotEq, s.clone());
                format!("(#pred? {f} {})", cap(self, a).unwrap_or_default())
            }
            ("#not-eq?", [a, b @ Tok::Capture(_)]) => {
                let f = self.pred_fn(PredKind::NotEqNodes, String::new());
                format!(
                    "(#pred? {f} {} {})",
                    cap(self, a).unwrap_or_default(),
                    cap(self, b).unwrap_or_default()
                )
            }
            ("#not-match?", [a, Tok::Str(re)]) => {
                let f = self.pred_fn(PredKind::NotMatch, emacs_regexp(re));
                format!("(#pred? {f} {})", cap(self, a).unwrap_or_default())
            }
            (other, _) => {
                self.refused.push(format!(
                    "{other} (or its arguments) is not in the portable subset"
                ));
                String::new()
            }
        }
    }
}

fn string_of(t: &Tok<'_>) -> String {
    match t {
        Tok::Str(s) => scm_string(s),
        _ => String::new(),
    }
}

/// `s` as an Emacs regexp matching exactly it.
fn quote(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        if matches!(c, '.' | '*' | '+' | '?' | '[' | ']' | '^' | '$' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// Renders one pattern, and the feature of its first known capture.
fn render(ctx: &mut Ctx<'_>, toks: &[Tok<'_>]) -> (Option<&'static str>, String) {
    let (mut out, mut feature) = (String::new(), None);
    let mut i = 0;
    let sep = |out: &mut String| {
        if !out.is_empty() && !out.ends_with(['(', '[']) {
            out.push(' ');
        }
    };
    while i < toks.len() {
        match &toks[i] {
            Tok::Open("(") if matches!(toks.get(i + 1), Some(Tok::Pred(_))) => {
                // the predicate runs to its matching close paren
                let mut depth = 0;
                let mut j = i;
                loop {
                    match &toks[j] {
                        Tok::Open(_) => depth += 1,
                        Tok::Close(_) => {
                            depth -= 1;
                            if depth == 0 {
                                break;
                            }
                        }
                        _ => {}
                    }
                    j += 1;
                }
                let text = ctx.predicate(&toks[i..=j]);
                sep(&mut out);
                out.push_str(&text);
                i = j;
            }
            Tok::Open(o) => {
                sep(&mut out);
                out.push_str(o);
            }
            Tok::Close(c) => out.push_str(c),
            Tok::Str(s) => {
                sep(&mut out);
                out.push_str(&scm_string(s));
            }
            Tok::Capture(n) => {
                if feature.is_none() {
                    feature = capture(n).map(|(f, _)| f);
                }
                sep(&mut out);
                let _ = write!(out, "@{}", ctx.cap(n));
            }
            Tok::Pred(p) => {
                ctx.refused.push(format!("{p} outside a predicate"));
            }
            Tok::Other(w) => {
                sep(&mut out);
                out.push_str(w);
            }
        }
        i += 1;
    }
    (feature, out)
}

/// PACK's `highlights.scm` TEXT as Emacs queries. `Err` lists what is refused (a predicate outside the subset).
pub fn translate(pack: &str, text: &str) -> Result<Translated, Vec<String>> {
    let mut ctx = Ctx {
        pack,
        preds: Vec::new(),
        unmapped: Vec::new(),
        refused: Vec::new(),
    };
    let mut rules: Vec<Rule> = Vec::new();
    for p in patterns(lex(text)) {
        let (feature, q) = render(&mut ctx, &p);
        // a pattern none of whose captures is known would highlight nothing: it is dropped
        let Some(feature) = feature else {
            continue;
        };
        match rules.last_mut().filter(|r| r.feature == feature) {
            Some(r) => {
                r.query.push('\n');
                r.query.push_str(&q);
            }
            None => rules.push(Rule {
                feature: feature.to_string(),
                query: q,
            }),
        }
    }
    if ctx.refused.is_empty() {
        Ok(Translated {
            rules,
            preds: ctx.preds,
            unmapped: ctx.unmapped,
        })
    } else {
        Err(ctx.refused)
    }
}

/// The node kinds `tags.scm` defines (`@definition.*`): what the generic mode treats as a function or type to navigate
/// to (`treesit-defun-type-regexp`). The first node name of each pattern with such a capture, each once.
pub fn definition_kinds(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for p in patterns(lex(text)) {
        if !p
            .iter()
            .any(|t| matches!(t, Tok::Capture(n) if n.starts_with("definition.")))
        {
            continue;
        }
        if let Some(Tok::Other(kind)) = p
            .iter()
            .find(|t| matches!(t, Tok::Other(w) if !w.starts_with(['_', '.', ':'])))
            && !out.iter().any(|k| k == kind)
            && !kind.contains(':')
        {
            out.push((*kind).to_string());
        }
    }
    out
}
