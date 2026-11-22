//! Settings files: one `(HEAD :version 1 META… ENTRY… SECTION…)` form, read into entries and problems (Task 3).

use std::collections::HashMap;

use crate::read::{Limits, Refusal, RefusalKind, read_all};
use crate::span::{Span, line_col};
use crate::value::{Datum, Node};

/// The head of a workspace file, the only one that may hold `:dir` and `:eval` sections.
const WORKSPACE_HEAD: &str = "drgnx-workspace-settings";

/// A settings file as read: its head, its meta (`:version`, `:roots`, `:project`, keys with their colon), its
/// entries in file order, and the entries that could not be read (the rest of the file stands).
#[derive(Debug, Clone, PartialEq)]
pub struct SettingsFile {
    pub head: String,
    pub meta: Vec<(String, Node)>,
    pub entries: Vec<Entry>,
    pub problems: Vec<Problem>,
}

/// `(VAR VALUE)` or `(VAR VALUE :merge KIND)`, where it sits (the sections around it) and its span. An `:eval`
/// section is an entry with `var` `":eval"` whose value is the list of its forms (`nil` when it has none), only in
/// a `drgnx-workspace-settings` file.
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    pub var: String,
    pub value: Node,
    pub merge: Option<String>,
    pub scope: Vec<ScopeStep>,
    pub span: Span,
}

/// One section around an entry: `(:mode MODE …)` or `(:dir "D/" …)`; a `:mode` may sit inside a `:dir`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ScopeStep {
    Mode(String),
    Dir(String),
}

/// An entry that could not be read, and why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Problem {
    pub span: Span,
    pub message: String,
}

fn refuse(span: Span, message: impl Into<String>) -> Refusal {
    Refusal {
        kind: RefusalKind::Syntax,
        span,
        message: message.into(),
    }
}

/// The settings file in `bytes`, whose one top-level form must have head `expect_head` and `:version 1`.
pub fn parse_settings(
    bytes: &[u8],
    expect_head: &str,
    limits: Limits,
) -> Result<SettingsFile, Refusal> {
    let mut forms = read_all(bytes, limits)?.into_iter();
    let Some(top) = forms.next() else {
        return Err(refuse(Span::default(), "the file holds no form"));
    };
    if let Some(extra) = forms.next() {
        return Err(refuse(extra.span, "a settings file is one form"));
    }
    let Datum::List(items) = top.datum else {
        return Err(refuse(top.span, format!("expected ({expect_head} …)")));
    };
    if !matches!(items.first(), Some(Node { datum: Datum::Sym(h), .. }) if h == expect_head) {
        return Err(refuse(top.span, format!("expected the head {expect_head}")));
    }

    let mut parser = Parser {
        text: std::str::from_utf8(bytes).unwrap_or_default(),
        workspace: expect_head == WORKSPACE_HEAD,
        entries: Vec::new(),
        problems: Vec::new(),
        seen: HashMap::new(),
    };

    let mut meta: Vec<(String, Node)> = Vec::new();
    let mut at = 1;
    while let Some(key) = items.get(at)
        && let Datum::Sym(name) = &key.datum
        && name.starts_with(':')
    {
        let Some(value) = items.get(at + 1) else {
            parser.problem(key.span, format!("{name} has no value"));
            break;
        };
        if !matches!(name.as_str(), ":version" | ":roots" | ":project") {
            parser.problem(key.span, format!("unknown meta key {name}"));
        } else if meta.iter().any(|(m, _)| m == name) {
            parser.problem(key.span, format!("{name} is given twice"));
        } else {
            meta.push((name.clone(), value.clone()));
        }
        at += 2;
    }

    match meta.iter().find(|(k, _)| k == ":version") {
        Some((
            _,
            Node {
                datum: Datum::Int(1),
                ..
            },
        )) => {}
        Some((
            _,
            Node {
                datum: Datum::Int(n),
                span,
            },
        )) if *n > 1 => {
            return Err(refuse(
                *span,
                format!("version {n} was written by a newer drgnx"),
            ));
        }
        Some((_, node)) => return Err(refuse(node.span, "unsupported :version")),
        None => return Err(refuse(top.span, "the file has no :version")),
    }

    let mut scope = Vec::new();
    for item in items.get(at..).unwrap_or_default() {
        parser.item(item, &mut scope);
    }
    Ok(SettingsFile {
        head: expect_head.to_string(),
        meta,
        entries: parser.entries,
        problems: parser.problems,
    })
}

struct Parser<'a> {
    text: &'a str,
    workspace: bool,
    entries: Vec<Entry>,
    problems: Vec<Problem>,
    /// The line of the first entry for each variable in each scope path.
    seen: HashMap<(String, Vec<ScopeStep>), u32>,
}

impl Parser<'_> {
    fn problem(&mut self, span: Span, message: impl Into<String>) {
        self.problems.push(Problem {
            span,
            message: message.into(),
        });
    }

    /// One item inside the head form or a section: an entry or a section.
    fn item(&mut self, node: &Node, scope: &mut Vec<ScopeStep>) {
        let Datum::List(parts) = &node.datum else {
            self.problem(node.span, "expected an entry (VARIABLE VALUE)");
            return;
        };
        let Some(Node {
            datum: Datum::Sym(head),
            ..
        }) = parts.first()
        else {
            self.problem(node.span, "an entry starts with a variable name");
            return;
        };
        match head.as_str() {
            ":mode" => self.mode(node, parts, scope),
            ":dir" => self.dir(node, parts, scope),
            ":eval" => self.eval(node, parts, scope),
            h if h.starts_with(':') => self.problem(node.span, format!("unknown section {h}")),
            "nil" | "t" => self.problem(node.span, format!("{head} is not a variable")),
            _ => self.entry(node, head, parts, scope),
        }
    }

    fn mode(&mut self, node: &Node, parts: &[Node], scope: &mut Vec<ScopeStep>) {
        if scope.iter().any(|s| matches!(s, ScopeStep::Mode(_))) {
            self.problem(node.span, ":mode cannot sit inside :mode");
            return;
        }
        let Some(Node {
            datum: Datum::Sym(mode),
            ..
        }) = parts.get(1)
        else {
            self.problem(node.span, "(:mode MODE …) needs a mode name");
            return;
        };
        if mode.starts_with(':') || mode == "nil" || mode == "t" {
            self.problem(node.span, format!("{mode} is not a mode name"));
            return;
        }
        scope.push(ScopeStep::Mode(mode.clone()));
        for inner in &parts[2..] {
            self.item(inner, scope);
        }
        scope.pop();
    }

    fn dir(&mut self, node: &Node, parts: &[Node], scope: &mut Vec<ScopeStep>) {
        if !self.workspace {
            self.problem(node.span, ":dir is only for workspace files");
            return;
        }
        if !scope.is_empty() {
            self.problem(node.span, ":dir cannot sit inside another section");
            return;
        }
        let Some(Node {
            datum: Datum::Str(dir),
            ..
        }) = parts.get(1)
        else {
            self.problem(node.span, "(:dir \"SUBDIR/\" …) needs a directory string");
            return;
        };
        scope.push(ScopeStep::Dir(dir.clone()));
        for inner in &parts[2..] {
            self.item(inner, scope);
        }
        scope.pop();
    }

    fn eval(&mut self, node: &Node, parts: &[Node], scope: &[ScopeStep]) {
        if !self.workspace {
            self.problem(node.span, ":eval is only for workspace files");
            return;
        }
        let forms = &parts[1..];
        let datum = if forms.is_empty() {
            Datum::Sym("nil".to_string())
        } else {
            Datum::List(forms.to_vec())
        };
        self.entries.push(Entry {
            var: ":eval".to_string(),
            value: Node {
                datum,
                span: node.span,
            },
            merge: None,
            scope: scope.to_vec(),
            span: node.span,
        });
    }

    fn entry(&mut self, node: &Node, var: &str, parts: &[Node], scope: &[ScopeStep]) {
        let (value, merge) = match &parts[1..] {
            [value] => (value, None),
            [
                value,
                Node {
                    datum: Datum::Sym(option),
                    ..
                },
                Node {
                    datum: Datum::Sym(kind),
                    ..
                },
            ] if option == ":merge" => (value, Some(kind.clone())),
            _ => {
                self.problem(
                    node.span,
                    format!("{var}: an entry is (VARIABLE VALUE) or (VARIABLE VALUE :merge KIND)"),
                );
                return;
            }
        };
        let line = line_col(self.text, node.span.start).0;
        if let Some(first) = self.seen.get(&(var.to_string(), scope.to_vec())) {
            let message = format!(
                "{var} is set twice in the same place (lines {first} and {line}); the first stands"
            );
            self.problem(node.span, message);
            return;
        }
        self.seen.insert((var.to_string(), scope.to_vec()), line);
        self.entries.push(Entry {
            var: var.to_string(),
            value: unquote(value).clone(),
            merge,
            scope: scope.to_vec(),
            span: node.span,
        });
    }
}

/// `VALUE` for `'VALUE` and `#'VALUE`, dropped once; any other node as it is.
fn unquote(node: &Node) -> &Node {
    if let Datum::List(parts) = &node.datum
        && let [
            Node {
                datum: Datum::Sym(head),
                ..
            },
            inner,
        ] = parts.as_slice()
        && (head == "quote" || head == "function")
    {
        inner
    } else {
        node
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DESIGN_EXAMPLE: &str = r##";;; settings.el --- your settings  -*- lexical-binding: t; mode: lisp-data -*-
;; Written by drgnx Settings and by you. Kept sorted; a comment above an entry stays with it.
;; Values are data: write 80 or (a b), not '(a b). Code goes in config.el. drgnx reads this file; never load it.
(drgnx-settings
 :version 1
 (drgnx-agents-default "claude")
 ;; the review profile reads every project
 (drgnx-agents-profiles
  (("review" :command ("claude-agent-acp") :mode queue :model "opus" :doc "Reviews")))
 (drgnx-keys-layers ((vscode app editing window)))
 (drgnx-trust-parents (("~/workspace/")))
 (eglot-autoshutdown t)
 (fill-column 100)
 (:mode python-ts-mode
  (fill-column 88)))
"##;

    const WORKSPACE_EXAMPLE: &str = r##"(drgnx-workspace-settings
 :version 1
 (drgnx-search-exclude ("vendor/**" "*.min.js"))
 (fill-column 100)
 (:mode python-ts-mode (python-indent-offset 4))
 (:dir "docs/" (fill-column 72))
 (:eval (add-hook 'before-save-hook #'my-format-buffer nil t)))
"##;

    fn parse(src: &str, head: &str) -> Result<SettingsFile, Refusal> {
        parse_settings(src.as_bytes(), head, Limits::default())
    }

    fn global(src: &str) -> SettingsFile {
        parse(src, "drgnx-settings").expect("the file reads")
    }

    fn sym(name: &str) -> Datum {
        Datum::Sym(name.to_string())
    }

    #[test]
    fn the_design_example_parses() {
        let file = global(DESIGN_EXAMPLE);
        assert_eq!(file.head, "drgnx-settings");
        assert_eq!(file.problems, []);
        assert_eq!(file.meta.len(), 1);
        assert_eq!(file.meta[0].0, ":version");
        assert_eq!(file.meta[0].1.datum, Datum::Int(1));
        let vars: Vec<&str> = file.entries.iter().map(|e| e.var.as_str()).collect();
        assert_eq!(
            vars,
            [
                "drgnx-agents-default",
                "drgnx-agents-profiles",
                "drgnx-keys-layers",
                "drgnx-trust-parents",
                "eglot-autoshutdown",
                "fill-column",
                "fill-column",
            ]
        );
        assert_eq!(file.entries[0].value.datum, Datum::Str("claude".into()));
        assert_eq!(file.entries[4].value.datum, sym("t"));
        assert_eq!(file.entries[5].scope, []);
        assert_eq!(file.entries[5].value.datum, Datum::Int(100));
        assert_eq!(
            file.entries[6].scope,
            [ScopeStep::Mode("python-ts-mode".into())]
        );
        assert_eq!(file.entries[6].value.datum, Datum::Int(88));
        let span = file.entries[0].span;
        assert_eq!(
            &DESIGN_EXAMPLE[span.start..span.end],
            "(drgnx-agents-default \"claude\")"
        );
    }

    #[test]
    fn a_workspace_file_with_dir_mode_and_eval() {
        let file = parse(WORKSPACE_EXAMPLE, "drgnx-workspace-settings").expect("reads");
        assert_eq!(file.problems, []);
        let shape: Vec<(&str, &[ScopeStep])> = file
            .entries
            .iter()
            .map(|e| (e.var.as_str(), e.scope.as_slice()))
            .collect();
        assert_eq!(
            shape,
            [
                ("drgnx-search-exclude", &[][..]),
                ("fill-column", &[][..]),
                (
                    "python-indent-offset",
                    &[ScopeStep::Mode("python-ts-mode".into())][..]
                ),
                ("fill-column", &[ScopeStep::Dir("docs/".into())][..]),
                (":eval", &[][..]),
            ]
        );
        let Datum::List(forms) = &file.entries[4].value.datum else {
            panic!("the :eval value is its forms");
        };
        assert_eq!(forms.len(), 1);
    }

    #[test]
    fn eval_is_refused_in_a_global_file() {
        let file = global("(drgnx-settings :version 1 (:eval (foo)) (fill-column 1))");
        assert_eq!(file.problems.len(), 1);
        assert!(file.problems[0].message.contains(":eval"));
        assert_eq!(file.entries.len(), 1);
        let file = global("(drgnx-settings :version 1 (:dir \"d/\" (fill-column 1)))");
        assert_eq!(file.problems.len(), 1);
        assert_eq!(file.entries, []);
    }

    #[test]
    fn a_newer_version_is_refused() {
        let err = parse("(drgnx-settings :version 2)", "drgnx-settings").unwrap_err();
        assert!(err.message.contains("newer drgnx"), "{err}");
        assert!(parse("(drgnx-settings (fill-column 1))", "drgnx-settings").is_err());
        assert!(parse("(drgnx-settings :version 1)", "drgnx-workspace-settings").is_err());
        assert!(parse("(drgnx-settings :version 1) (a 1)", "drgnx-settings").is_err());
        assert!(parse("", "drgnx-settings").is_err());
        let err = parse("(drgnx-settings :version 0)", "drgnx-settings").unwrap_err();
        assert!(err.message.contains("unsupported :version"), "{err}");
    }

    #[test]
    fn each_meta_key_once() {
        let file =
            global("(drgnx-settings :version 1 :roots (\"~/a/\") :project \"p\" :roots nil (a 1))");
        let keys: Vec<&str> = file.meta.iter().map(|(k, _)| k.as_str()).collect();
        assert_eq!(keys, [":version", ":roots", ":project"]);
        assert_eq!(file.problems.len(), 1);
        assert!(file.problems[0].message.contains(":roots is given twice"));
    }

    #[test]
    fn keywords_nil_and_t_name_no_variable_or_mode() {
        let file = global(
            "(drgnx-settings :version 1 (:foo 1) (nil 1) (t 1) (:mode :m (a 1)) (:mode nil (b 1)) (:mode t (c 1)) \
             (d 1 :foo e))",
        );
        assert_eq!(file.entries, []);
        assert_eq!(file.problems.len(), 7);
    }

    #[test]
    fn a_bad_entry_is_one_problem() {
        let src = "(drgnx-settings :version 1 (fill-column) (tab-width 4))";
        let file = global(src);
        assert_eq!(file.problems.len(), 1);
        let span = file.problems[0].span;
        assert_eq!(&src[span.start..span.end], "(fill-column)");
        assert_eq!(file.entries.len(), 1);
        assert_eq!(file.entries[0].var, "tab-width");
    }

    #[test]
    fn quote_and_function_dropped_once() {
        let file = global("(drgnx-settings :version 1 (a 'b) (c #'d) (e ''f) (g (quote h i)))");
        assert_eq!(file.problems, []);
        assert_eq!(file.entries[0].value.datum, sym("b"));
        assert_eq!(file.entries[1].value.datum, sym("d"));
        let Datum::List(parts) = &file.entries[2].value.datum else {
            panic!("one quote is left");
        };
        assert_eq!(parts[0].datum, sym("quote"));
        assert_eq!(parts[1].datum, sym("f"));
        assert!(matches!(&file.entries[3].value.datum, Datum::List(p) if p.len() == 3));
    }

    #[test]
    fn merge_option_read() {
        let file = global(
            "(drgnx-settings :version 1 (drgnx-keys-layers ((vscode)) :merge append) (a 1) (b 1 :merge))",
        );
        assert_eq!(file.entries.len(), 2);
        assert_eq!(file.entries[0].merge.as_deref(), Some("append"));
        assert_eq!(file.entries[1].merge, None);
        assert_eq!(file.problems.len(), 1);
    }

    #[test]
    fn mode_inside_dir_only() {
        let head = "drgnx-workspace-settings";
        let ok = parse(
            "(drgnx-workspace-settings :version 1 (:dir \"d/\" (:mode text-mode (fill-column 70))))",
            head,
        )
        .expect("reads");
        assert_eq!(ok.problems, []);
        assert_eq!(
            ok.entries[0].scope,
            [
                ScopeStep::Dir("d/".into()),
                ScopeStep::Mode("text-mode".into())
            ]
        );
        for bad in [
            "(:mode text-mode (:dir \"d/\" (a 1)))",
            "(:mode a (:mode b (x 1)))",
            "(:dir \"a/\" (:dir \"b/\" (x 1)))",
        ] {
            let src = format!("(drgnx-workspace-settings :version 1 {bad})");
            let file = parse(&src, head).expect("reads");
            assert_eq!(file.problems.len(), 1, "{bad}");
            assert_eq!(file.entries, [], "{bad}");
        }
    }

    #[test]
    fn a_duplicate_names_both_lines_and_the_first_stands() {
        let file = global("(drgnx-settings\n :version 1\n (a 1)\n (a 2)\n (:mode m (a 3)))");
        assert_eq!(file.entries.len(), 2);
        assert_eq!(file.entries[0].value.datum, Datum::Int(1));
        assert_eq!(file.problems.len(), 1);
        assert!(file.problems[0].message.contains("lines 3 and 4"));
    }
}
