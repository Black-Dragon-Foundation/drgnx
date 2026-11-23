//! The scanner: `syn` over one file, the rules of the standards its crate does not own. A path resolves through the
//! file's `use … as`, `type` aliases and glob imports (one file; clippy, which resolves paths, catches the rest), and
//! a macro's arguments are scanned when they parse as expressions.

use std::collections::BTreeMap;

use proc_macro2::Span;
use syn::punctuated::Punctuated;
use syn::spanned::Spanned;
use syn::visit::{self, Visit};
use syn::{Expr, Token};

/// One rule broken: the line, the standard's id, the rule, the message.
pub struct Hit {
    pub line: usize,
    pub id: String,
    pub rule: String,
    pub message: String,
}

/// What the scanner checks in one file: each disallowed path with its standard's id and owner, each scan rule with its
/// standard's id, and whether the crate runs on the UI thread.
#[derive(Default)]
pub struct Rules {
    pub methods: BTreeMap<String, (String, String)>,
    pub types: BTreeMap<String, (String, String)>,
    pub scan: BTreeMap<String, String>,
    pub ui: bool,
}

const SECRET_SUFFIXES: &[&str] = &["Token", "Secret", "Key", "Password", "Credential"];
const PRINTS: &[&str] = &["println", "print", "eprintln", "eprint", "dbg"];

pub fn scan(file: &syn::File, rules: &Rules) -> Vec<Hit> {
    let mut aliases = Aliases::default();
    aliases.collect(file);
    let mut v = Scanner {
        rules,
        aliases: &aliases,
        hits: Vec::new(),
    };
    v.visit_file(file);
    v.hits
}

fn line(span: Span) -> usize {
    span.start().line
}

/// The file's names for paths: `use a::b::C as D` → D = a::b::C, `type T = a::B` → T = a::B, plus the glob
/// prefixes; `type R<T> = Result<T, String>`'s own type, for the string-error rule.
#[derive(Default)]
struct Aliases {
    names: BTreeMap<String, Vec<String>>,
    globs: Vec<Vec<String>>,
    types: BTreeMap<String, syn::Type>,
}

impl Aliases {
    fn collect(&mut self, file: &syn::File) {
        // twice, so a `use` through an earlier alias (`use std::process; use process::Command as C;`) resolves
        for _ in 0..2 {
            let mut c = Collect { a: self };
            c.visit_file(file);
        }
    }

    fn resolve(&self, segs: &[String]) -> Vec<Vec<String>> {
        let Some(first) = segs.first() else {
            return Vec::new();
        };
        if let Some(full) = self.names.get(first) {
            let mut p = full.clone();
            p.extend_from_slice(&segs[1..]);
            return vec![p];
        }
        let mut out = vec![segs.to_vec()];
        for g in &self.globs {
            let mut p = g.clone();
            p.extend_from_slice(segs);
            out.push(p);
        }
        out
    }

    fn add_use(&mut self, prefix: &mut Vec<String>, tree: &syn::UseTree) {
        match tree {
            syn::UseTree::Path(p) => {
                prefix.push(p.ident.to_string());
                self.add_use(prefix, &p.tree);
                prefix.pop();
            }
            syn::UseTree::Name(n) => {
                let name = n.ident.to_string();
                if name == "self" {
                    if let Some(last) = prefix.last().cloned() {
                        let full = self.absolute(prefix);
                        self.names.insert(last, full);
                    }
                } else {
                    prefix.push(name.clone());
                    let full = self.absolute(prefix);
                    prefix.pop();
                    self.names.insert(name, full);
                }
            }
            syn::UseTree::Rename(r) => {
                prefix.push(r.ident.to_string());
                let full = self.absolute(prefix);
                prefix.pop();
                let name = r.rename.to_string();
                if name != "_" {
                    self.names.insert(name, full);
                }
            }
            syn::UseTree::Glob(_) => {
                let full = self.absolute(prefix);
                if !self.globs.contains(&full) {
                    self.globs.push(full);
                }
            }
            syn::UseTree::Group(g) => {
                for t in &g.items {
                    self.add_use(prefix, t);
                }
            }
        }
    }

    /// PREFIX with its first segment resolved through an alias seen so far.
    fn absolute(&self, prefix: &[String]) -> Vec<String> {
        match prefix.first().and_then(|f| self.names.get(f)) {
            // (an alias naming itself, `use foo::foo`, stays as written)
            Some(full) if full.first() != prefix.first() => {
                let mut p = full.clone();
                p.extend_from_slice(&prefix[1..]);
                p
            }
            _ => prefix.to_vec(),
        }
    }
}

struct Collect<'a> {
    a: &'a mut Aliases,
}

impl<'ast> Visit<'ast> for Collect<'_> {
    fn visit_item_use(&mut self, u: &'ast syn::ItemUse) {
        let mut prefix = Vec::new();
        self.a.add_use(&mut prefix, &u.tree);
    }

    fn visit_item_type(&mut self, t: &'ast syn::ItemType) {
        let name = t.ident.to_string();
        if let syn::Type::Path(p) = &*t.ty {
            let segs = segments(&p.path);
            if let Some(full) = self.a.resolve(&segs).into_iter().next() {
                self.a.names.insert(name.clone(), full);
            }
        }
        self.a.types.insert(name, (*t.ty).clone());
        visit::visit_item_type(self, t);
    }
}

fn segments(p: &syn::Path) -> Vec<String> {
    p.segments.iter().map(|s| s.ident.to_string()).collect()
}

struct Scanner<'a> {
    rules: &'a Rules,
    aliases: &'a Aliases,
    hits: Vec<Hit>,
}

impl Scanner<'_> {
    fn hit(&mut self, span: Span, id: &str, rule: &str, message: String) {
        self.hits.push(Hit {
            line: line(span),
            id: id.to_string(),
            rule: rule.to_string(),
            message,
        });
    }

    fn rule(&self, rule: &str) -> Option<String> {
        self.rules.scan.get(rule).cloned()
    }

    /// A path in an expression: a disallowed method, or a path under a disallowed type.
    fn check_path(&mut self, path: &syn::Path) {
        let segs = segments(path);
        for full in self.aliases.resolve(&segs) {
            let joined = full.join("::");
            if let Some((id, owner)) = self.rules.methods.get(&joined) {
                let (id, owner) = (id.clone(), owner.clone());
                self.hit(
                    path.span(),
                    &id,
                    "disallowed-path",
                    format!("`{joined}` is reached only through `{owner}`"),
                );
                return;
            }
            if self.check_type_prefix(path.span(), &full) {
                return;
            }
        }
    }

    fn check_type_prefix(&mut self, span: Span, full: &[String]) -> bool {
        for n in (1..=full.len()).rev() {
            let joined = full[..n].join("::");
            if let Some((id, owner)) = self.rules.types.get(&joined) {
                let (id, owner) = (id.clone(), owner.clone());
                self.hit(
                    span,
                    &id,
                    "disallowed-type",
                    format!("the type `{joined}` is used only through `{owner}`"),
                );
                return true;
            }
        }
        false
    }

    /// Whether TY is a `Result` whose error is a string (directly, or through a `type` alias in this file).
    fn is_string_result(&self, ty: &syn::Type, depth: u8) -> bool {
        let syn::Type::Path(p) = ty else {
            return false;
        };
        let Some(last) = p.path.segments.last() else {
            return false;
        };
        let name = last.ident.to_string();
        if depth < 4
            && p.path.segments.len() == 1
            && let Some(aliased) = self.aliases.types.get(&name)
        {
            return self.is_string_result(aliased, depth + 1);
        }
        let resolved = self
            .aliases
            .resolve(&segments(&p.path))
            .into_iter()
            .next()
            .unwrap_or_default();
        if resolved.last().map(String::as_str) != Some("Result") {
            return false;
        }
        let syn::PathArguments::AngleBracketed(args) = &last.arguments else {
            return false;
        };
        let types: Vec<&syn::Type> = args
            .args
            .iter()
            .filter_map(|a| match a {
                syn::GenericArgument::Type(t) => Some(t),
                _ => None,
            })
            .collect();
        types.len() == 2 && self.is_string(types[1])
    }

    fn is_string(&self, ty: &syn::Type) -> bool {
        match ty {
            syn::Type::Reference(r) => self.is_string(&r.elem),
            syn::Type::Path(p) => {
                let full = self.aliases.resolve(&segments(&p.path));
                full.iter()
                    .any(|f| matches!(f.last().map(String::as_str), Some("String" | "str")))
            }
            _ => false,
        }
    }

    fn check_fn(&mut self, vis: &syn::Visibility, sig: &syn::Signature) {
        let Some(id) = self.rule("no-string-error") else {
            return;
        };
        if !matches!(vis, syn::Visibility::Public(_)) {
            return;
        }
        if let syn::ReturnType::Type(_, ty) = &sig.output
            && self.is_string_result(ty, 0)
        {
            self.hit(
                sig.ident.span(),
                &id,
                "no-string-error",
                format!(
                    "`{}` returns a string error: return villa's Error (a kind and the user's sentence)",
                    sig.ident
                ),
            );
        }
    }

    fn check_secret(&mut self, ident: &syn::Ident, attrs: &[syn::Attribute], all_secret: bool) {
        let Some(id) = self.rule("secret-has-redact") else {
            return;
        };
        let name = ident.to_string();
        if !SECRET_SUFFIXES.iter().any(|s| name.ends_with(s)) || all_secret {
            return;
        }
        if derives_debug(attrs) {
            self.hit(
                ident.span(),
                &id,
                "secret-has-redact",
                format!("`{name}` derives Debug: wrap its secret in hulda's Secret, or write a Debug that redacts"),
            );
        }
    }

    /// A macro's arguments, scanned when they parse as comma-separated expressions.
    fn visit_macro_args(&mut self, mac: &syn::Macro) {
        if let Ok(args) = mac.parse_body_with(Punctuated::<Expr, Token![,]>::parse_terminated) {
            for e in &args {
                self.visit_expr(e);
            }
        }
    }

    fn check_macro(&mut self, mac: &syn::Macro) {
        let name = mac
            .path
            .segments
            .last()
            .map(|s| s.ident.to_string())
            .unwrap_or_default();
        if PRINTS.contains(&name.as_str())
            && let Some(id) = self.rule("no-print")
        {
            self.hit(
                mac.path.span(),
                &id,
                "no-print",
                format!("`{name}!` prints: use annall (cli_out / cli_err, or tracing)"),
            );
        }
        self.visit_macro_args(mac);
    }
}

fn derives_debug(attrs: &[syn::Attribute]) -> bool {
    attrs.iter().any(|a| {
        if !a.path().is_ident("derive") {
            return false;
        }
        let mut found = false;
        let parsed = a.parse_nested_meta(|m| {
            if m.path.segments.last().is_some_and(|s| s.ident == "Debug") {
                found = true;
            }
            Ok(())
        });
        parsed.is_ok() && found
    })
}

fn is_secret_type(ty: &syn::Type) -> bool {
    matches!(ty, syn::Type::Path(p) if p.path.segments.last().is_some_and(|s| s.ident == "Secret"))
}

impl<'ast> Visit<'ast> for Scanner<'_> {
    fn visit_expr_path(&mut self, e: &'ast syn::ExprPath) {
        self.check_path(&e.path);
        visit::visit_expr_path(self, e);
    }

    fn visit_type_path(&mut self, t: &'ast syn::TypePath) {
        let segs = segments(&t.path);
        for full in self.aliases.resolve(&segs) {
            if self.check_type_prefix(t.span(), &full) {
                break;
            }
        }
        visit::visit_type_path(self, t);
    }

    fn visit_item_fn(&mut self, f: &'ast syn::ItemFn) {
        self.check_fn(&f.vis, &f.sig);
        visit::visit_item_fn(self, f);
    }

    fn visit_impl_item_fn(&mut self, f: &'ast syn::ImplItemFn) {
        self.check_fn(&f.vis, &f.sig);
        visit::visit_impl_item_fn(self, f);
    }

    fn visit_item_struct(&mut self, s: &'ast syn::ItemStruct) {
        let all_secret = !s.fields.is_empty() && s.fields.iter().all(|f| is_secret_type(&f.ty));
        self.check_secret(&s.ident, &s.attrs, all_secret);
        visit::visit_item_struct(self, s);
    }

    fn visit_item_enum(&mut self, e: &'ast syn::ItemEnum) {
        self.check_secret(&e.ident, &e.attrs, false);
        visit::visit_item_enum(self, e);
    }

    fn visit_local(&mut self, l: &'ast syn::Local) {
        if matches!(l.pat, syn::Pat::Wild(_))
            && l.init.is_some()
            && let Some(id) = self.rule("no-let-underscore-result")
        {
            self.hit(
                l.let_token.span(),
                &id,
                "no-let-underscore-result",
                "`let _ =` drops a value unread: handle the Result, or bind it to a name that says why".into(),
            );
        }
        visit::visit_local(self, l);
    }

    fn visit_lit_str(&mut self, s: &'ast syn::LitStr) {
        let v = s.value();
        if (v == "HOME" || v.starts_with("XDG_"))
            && let Some(id) = self.rule("no-env-home")
        {
            self.hit(
                s.span(),
                &id,
                "no-env-home",
                format!("\"{v}\" names the user's home: resolve paths through stig"),
            );
        }
    }

    fn visit_expr(&mut self, e: &'ast Expr) {
        if self.rules.ui
            && let Some(id) = self.rule("no-blocking-recv-on-ui")
        {
            match e {
                // an awaited `recv()` is async, not blocking: scan what it is called on, not the call
                Expr::Await(a) => {
                    if let Expr::MethodCall(m) = &*a.base
                        && m.method == "recv"
                    {
                        self.visit_expr(&m.receiver);
                        for arg in &m.args {
                            self.visit_expr(arg);
                        }
                        return;
                    }
                }
                Expr::MethodCall(m) => {
                    let name = m.method.to_string();
                    if name == "recv" || name == "recv_timeout" || name.starts_with("blocking_") {
                        self.hit(
                            m.method.span(),
                            &id,
                            "no-blocking-recv-on-ui",
                            format!("`.{name}()` blocks the UI thread: post the work and take the result through saman's UiQueue"),
                        );
                    }
                }
                _ => {}
            }
        }
        visit::visit_expr(self, e);
    }

    fn visit_macro(&mut self, m: &'ast syn::Macro) {
        self.check_macro(m);
    }
}
