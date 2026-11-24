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
/// standard's id, whether the crate runs on the UI thread, and whether the file holds UI state (a `ui` crate, or any
/// file under `crates/ui/`: the ui-reactivity rules' reach).
#[derive(Default)]
pub struct Rules {
    pub methods: BTreeMap<String, (String, String)>,
    pub types: BTreeMap<String, (String, String)>,
    pub scan: BTreeMap<String, String>,
    pub ui: bool,
    pub reactive: bool,
}

const SECRET_SUFFIXES: &[&str] = &["Token", "Secret", "Key", "Password", "Credential"];
const PRINTS: &[&str] = &["println", "print", "eprintln", "eprint", "dbg"];
/// skel's raw input types: its key event, the keyboard's own state and what a key press resolves to.
const KEY_TYPES: &[&str] = &["KeyEv", "KeyEvent", "Keyed", "KeyboardState"];
/// The functions that make a colour from numbers.
const COLOUR_FNS: &[&str] = &[
    "rgb",
    "rgba",
    "from_rgb",
    "from_rgba",
    "from_rgb8",
    "from_rgba8",
];

/// Types whose constructors make a colour from numbers (`Rgba::new(…)`).
const COLOUR_TYPES: &[&str] = &["Rgba", "Rgb", "Argb", "Colour", "Color"];

/// A name that says it holds a colour.
fn names_colour(name: &str) -> bool {
    let l = name.to_ascii_lowercase();
    ["colour", "color", "rgb"].iter().any(|w| l.contains(w))
}

/// An integer literal written as `0xRRGGBB` or `0xRRGGBBAA`.
fn is_hex_colour_int(e: &Expr) -> bool {
    match e {
        Expr::Lit(l) => match &l.lit {
            syn::Lit::Int(i) => {
                let t = i.to_string().replace('_', "");
                t.strip_prefix("0x")
                    .or_else(|| t.strip_prefix("0X"))
                    .is_some_and(|h| {
                        matches!(h.chars().take_while(char::is_ascii_hexdigit).count(), 6 | 8)
                    })
            }
            _ => false,
        },
        Expr::Paren(p) => is_hex_colour_int(&p.expr),
        Expr::Group(g) => is_hex_colour_int(&g.expr),
        Expr::Cast(c) => is_hex_colour_int(&c.expr),
        _ => false,
    }
}

/// Whether E is a value whose name contains `scale`: a path, a field or a method, through parentheses, casts, references
/// and a sign.
fn names_scale(e: &Expr) -> bool {
    let has = |n: &str| n.to_ascii_lowercase().contains("scale");
    match e {
        Expr::Path(p) => p
            .path
            .segments
            .last()
            .is_some_and(|s| has(&s.ident.to_string())),
        Expr::Field(f) => match &f.member {
            syn::Member::Named(n) => has(&n.to_string()),
            syn::Member::Unnamed(_) => false,
        },
        Expr::MethodCall(m) => has(&m.method.to_string()),
        Expr::Paren(p) => names_scale(&p.expr),
        Expr::Group(g) => names_scale(&g.expr),
        Expr::Cast(c) => names_scale(&c.expr),
        Expr::Reference(r) => names_scale(&r.expr),
        Expr::Unary(u) => names_scale(&u.expr),
        _ => false,
    }
}

/// The calls whose closure arguments are formulas or callbacks of the reactive engine (`no-ui-observer`); a name that
/// starts with `on_` registers a callback.
const REACTIVE_SINKS: &[&str] = &["formula", "filter", "filter_by", "sort_by"];
/// The types that make an observer when shared (`Rc<RefCell<…>>`, `Arc<Mutex<…>>` and their kin).
const SHARED: &[&str] = &["Rc", "Arc"];
const INTERIOR: &[&str] = &["RefCell", "Cell", "Mutex", "RwLock"];
/// The functions that make a channel, and a channel's ends.
const CHANNEL_FNS: &[&str] = &["channel", "sync_channel", "unbounded", "bounded"];
const CHANNEL_ENDS: &[&str] = &[
    "Sender",
    "SyncSender",
    "Receiver",
    "UnboundedSender",
    "UnboundedReceiver",
];

/// The last segment of a path expression.
fn last_ident(e: &Expr) -> Option<String> {
    match e {
        Expr::Path(p) => p.path.segments.last().map(|s| s.ident.to_string()),
        _ => None,
    }
}

/// A single-segment path expression's name (a local).
fn local_name(e: &Expr) -> Option<String> {
    match e {
        Expr::Path(p) if p.path.segments.len() == 1 && p.qself.is_none() => {
            Some(p.path.segments[0].ident.to_string())
        }
        Expr::Reference(r) => local_name(&r.expr),
        Expr::Paren(p) => local_name(&p.expr),
        _ => None,
    }
}

/// Whether TY is `Rc<RefCell<…>>`, `Arc<Mutex<…>>` or a kin.
fn is_shared_interior_type(ty: &syn::Type) -> bool {
    let syn::Type::Path(p) = ty else {
        return false;
    };
    let Some(last) = p.path.segments.last() else {
        return false;
    };
    if !SHARED.contains(&last.ident.to_string().as_str()) {
        return false;
    }
    let syn::PathArguments::AngleBracketed(args) = &last.arguments else {
        return false;
    };
    args.args.iter().any(|a| {
        matches!(a, syn::GenericArgument::Type(syn::Type::Path(inner))
            if inner.path.segments.last().is_some_and(|s| INTERIOR.contains(&s.ident.to_string().as_str())))
    })
}

/// The locals of a function that hold an observer: `Rc::new(RefCell::new(…))`, `Arc::new(Mutex::new(…))` and kin, a
/// local typed so, a clone of one, and both ends of a channel.
fn observer_locals(block: &syn::Block) -> std::collections::BTreeSet<String> {
    struct Locals {
        found: std::collections::BTreeSet<String>,
    }
    fn names(p: &syn::Pat, out: &mut Vec<String>) {
        match p {
            syn::Pat::Ident(i) => out.push(i.ident.to_string()),
            syn::Pat::Tuple(t) => t.elems.iter().for_each(|e| names(e, out)),
            syn::Pat::Type(t) => names(&t.pat, out),
            syn::Pat::Reference(r) => names(&r.pat, out),
            _ => {}
        }
    }
    impl Locals {
        fn observer_init(&self, e: &Expr) -> bool {
            match e {
                Expr::Call(c) => {
                    let Expr::Path(f) = &*c.func else {
                        return false;
                    };
                    let segs = &f.path.segments;
                    let last = segs.last().map(|s| s.ident.to_string()).unwrap_or_default();
                    let ty = segs
                        .len()
                        .checked_sub(2)
                        .and_then(|i| segs.iter().nth(i))
                        .map(|s| s.ident.to_string())
                        .unwrap_or_default();
                    if SHARED.contains(&ty.as_str()) && last == "new" {
                        return c.args.first().is_some_and(|a| {
                            matches!(a, Expr::Call(inner) if matches!(&*inner.func, Expr::Path(ip)
                                if ip.path.segments.len() >= 2
                                    && INTERIOR.contains(&ip.path.segments[ip.path.segments.len() - 2].ident.to_string().as_str())))
                        });
                    }
                    if SHARED.contains(&ty.as_str()) && last == "clone" {
                        return c
                            .args
                            .first()
                            .and_then(local_name)
                            .is_some_and(|n| self.found.contains(&n));
                    }
                    false
                }
                Expr::MethodCall(m) if m.method == "clone" => {
                    local_name(&m.receiver).is_some_and(|n| self.found.contains(&n))
                }
                _ => false,
            }
        }
    }
    impl<'ast> Visit<'ast> for Locals {
        fn visit_local(&mut self, l: &'ast syn::Local) {
            let mut bound = Vec::new();
            names(&l.pat, &mut bound);
            let typed = matches!(&l.pat, syn::Pat::Type(t) if is_shared_interior_type(&t.ty));
            let channel = l.init.as_ref().is_some_and(|i| {
                matches!(&*i.expr, Expr::Call(c) if last_ident(&c.func)
                    .is_some_and(|n| CHANNEL_FNS.contains(&n.as_str())))
            });
            let shared = l.init.as_ref().is_some_and(|i| self.observer_init(&i.expr));
            if typed || channel || shared {
                self.found.extend(bound);
            }
            visit::visit_local(self, l);
        }
    }
    let mut l = Locals {
        found: Default::default(),
    };
    // twice, so a clone of a clone made later in the text is found too
    for _ in 0..2 {
        l.visit_block(block);
    }
    l.found
}

/// Whether a signature takes or returns a closure type (`impl Fn…`, `dyn FnMut…`, a parameter bound by `FnOnce`).
fn mentions_fn_trait(sig: &syn::Signature) -> bool {
    struct F(bool);
    impl<'ast> Visit<'ast> for F {
        fn visit_path_segment(&mut self, s: &'ast syn::PathSegment) {
            if s.ident == "Fn" || s.ident == "FnMut" || s.ident == "FnOnce" {
                self.0 = true;
            }
            visit::visit_path_segment(self, s);
        }
    }
    let mut f = F(false);
    f.visit_signature(sig);
    f.0
}

pub fn scan(file: &syn::File, rules: &Rules) -> Vec<Hit> {
    let mut aliases = Aliases::default();
    aliases.collect(file);
    let mut v = Scanner {
        rules,
        aliases: &aliases,
        hits: Vec::new(),
        observers: Vec::new(),
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
    /// The observer locals of each function being visited, innermost last.
    observers: Vec<std::collections::BTreeSet<String>>,
}

impl Scanner<'_> {
    /// The ui-reactivity rule RULE's standard id, when the file is in its reach.
    fn reactive_rule(&self, rule: &str) -> Option<String> {
        if self.rules.reactive {
            self.rule(rule)
        } else {
            None
        }
    }

    /// `no-dependency-list-api`: a public hook-shaped function: `create_signal`; `use_*`, `*_effect` or `memo*` taking or
    /// returning a closure; `signal*` taking a closure or returning a pair; anything with a `deps` parameter.
    fn check_dependency_api(&mut self, vis: &syn::Visibility, sig: &syn::Signature) {
        if !matches!(vis, syn::Visibility::Public(_)) {
            return;
        }
        let Some(id) = self.reactive_rule("no-dependency-list-api") else {
            return;
        };
        let name = sig.ident.to_string();
        let closure = mentions_fn_trait(sig);
        let pair = matches!(&sig.output, syn::ReturnType::Type(_, t) if matches!(**t, syn::Type::Tuple(_)));
        let deps = sig.inputs.iter().any(|a| {
            matches!(a, syn::FnArg::Typed(t) if matches!(&*t.pat, syn::Pat::Ident(i) if i.ident == "deps"))
        });
        let hook = name == "create_signal"
            || deps
            || ((name.starts_with("use_")
                || name.ends_with("_effect")
                || name.starts_with("memo"))
                && closure)
            || (name.starts_with("signal") && (closure || pair));
        if hook {
            self.hit(
                sig.ident.span(),
                &id,
                "no-dependency-list-api",
                format!("`{name}` is a hook, signal or dependency-list API: UI state is a tafl State and derived values are formulas (`move |r| …`)"),
            );
        }
    }

    /// `no-ui-observer`: a closure given to a formula or registered as a callback that captures an observer local.
    fn check_sink(&mut self, name: &str, args: &Punctuated<Expr, Token![,]>) {
        if !(REACTIVE_SINKS.contains(&name) || name.starts_with("on_")) {
            return;
        }
        let Some(id) = self.reactive_rule("no-ui-observer") else {
            return;
        };
        let Some(observers) = self.observers.last() else {
            return;
        };
        if observers.is_empty() {
            return;
        }
        struct Uses<'s> {
            observers: &'s std::collections::BTreeSet<String>,
            used: Option<String>,
        }
        impl<'ast> Visit<'ast> for Uses<'_> {
            fn visit_expr_path(&mut self, p: &'ast syn::ExprPath) {
                if p.path.segments.len() == 1 {
                    let n = p.path.segments[0].ident.to_string();
                    if self.used.is_none() && self.observers.contains(&n) {
                        self.used = Some(n);
                    }
                }
                visit::visit_expr_path(self, p);
            }
        }
        let mut found = Vec::new();
        for a in args {
            if let Expr::Closure(c) = a {
                let mut u = Uses {
                    observers,
                    used: None,
                };
                u.visit_expr(&c.body);
                if let Some(n) = u.used {
                    found.push((c.span(), n));
                }
            }
        }
        for (span, n) in found {
            self.hit(
                span,
                &id,
                "no-ui-observer",
                format!("a closure given to `{name}` captures `{n}`, a shared cell, lock or channel: UI state is a tafl State, read through `&Rd`"),
            );
        }
    }

    /// `no-ui-observer`: a channel held as a state cell's value.
    fn check_channel_state(&mut self, t: &syn::TypePath) {
        let Some(last) = t.path.segments.last() else {
            return;
        };
        if last.ident != "State" && last.ident != "Formula" {
            return;
        }
        let syn::PathArguments::AngleBracketed(args) = &last.arguments else {
            return;
        };
        let channel = args.args.iter().any(|a| {
            matches!(a, syn::GenericArgument::Type(syn::Type::Path(p))
                if p.path.segments.last().is_some_and(|s| CHANNEL_ENDS.contains(&s.ident.to_string().as_str())))
        });
        if channel && let Some(id) = self.reactive_rule("no-ui-observer") {
            self.hit(
                t.span(),
                &id,
                "no-ui-observer",
                "a channel held as UI state: state is a value in a tafl State, and work comes back through saman's UiQueue".into(),
            );
        }
    }

    fn hit(&mut self, span: Span, id: &str, rule: &str, message: String) {
        self.hits.push(Hit {
            line: line(span),
            id: id.to_string(),
            rule: rule.to_string(),
            message,
        });
    }

    /// A hex number given to something named for a colour (`const BG_COLOUR: u32 = 0x1e1f25`, `Style { color: 0xff8800 }`).
    fn check_named_colour(&mut self, name: &str, value: &Expr) {
        if names_colour(name)
            && is_hex_colour_int(value)
            && let Some(id) = self.rule("no-colour-literal")
        {
            self.hit(
                value.span(),
                &id,
                "no-colour-literal",
                format!("`{name}` is a colour given as a hex number: colours come from the kit's tokens (themes/)"),
            );
        }
    }

    fn rule(&self, rule: &str) -> Option<String> {
        self.rules.scan.get(rule).cloned()
    }

    /// A path in an expression: a disallowed method, or a path under a disallowed type.
    fn check_path(&mut self, path: &syn::Path) {
        let segs = segments(path);
        for full in self.aliases.resolve(&segs) {
            self.check_key(path.span(), &full);
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

    /// A path into skel's raw key events (`no-raw-key-event`): only lykill reads them.
    fn check_key(&mut self, span: Span, full: &[String]) {
        let Some(id) = self.rule("no-raw-key-event") else {
            return;
        };
        if full.first().map(String::as_str) != Some("skel") {
            return;
        }
        let raw = full.iter().enumerate().skip(1).any(|(i, s)| {
            KEY_TYPES.contains(&s.as_str()) || (s == "Key" && full[i - 1] == "Event")
        });
        if raw {
            self.hit(
                span,
                &id,
                "no-raw-key-event",
                format!(
                    "`{}` is skel's raw key event: keys are read through lykill's Keymap",
                    full.join("::")
                ),
            );
        }
    }

    fn check_pat_path(&mut self, path: &syn::Path) {
        for full in self.aliases.resolve(&segments(path)) {
            self.check_key(path.span(), &full);
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
        if name == "command"
            && let Some(id) = self.rule("command-has-doc")
            && !command_has_doc(mac)
        {
            self.hit(
                mac.path.span(),
                &id,
                "command-has-doc",
                "`command!` has no doc, or an empty one: every command says what it does".into(),
            );
        }
        self.visit_macro_args(mac);
    }
}

/// Whether a `command!` invocation has `doc: "…"` with some text.
fn command_has_doc(mac: &syn::Macro) -> bool {
    use proc_macro2::TokenTree;
    let toks: Vec<TokenTree> = mac.tokens.clone().into_iter().collect();
    toks.windows(3).any(|w| {
        if let [
            TokenTree::Ident(i),
            TokenTree::Punct(p),
            TokenTree::Literal(l),
        ] = w
        {
            i == "doc"
                && p.as_char() == ':'
                && syn::parse_str::<syn::LitStr>(&l.to_string())
                    .is_ok_and(|s| !s.value().trim().is_empty())
        } else {
            false
        }
    })
}

/// `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`.
fn is_hex_colour(v: &str) -> bool {
    v.strip_prefix('#').is_some_and(|h| {
        matches!(h.len(), 3 | 4 | 6 | 8) && h.chars().all(|c| c.is_ascii_hexdigit())
    })
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

/// Whether E is a chain of calls that starts at `OpenOptions::new()` or `File::options()`.
fn opens_by_options(e: &Expr) -> bool {
    match e {
        Expr::MethodCall(m) => opens_by_options(&m.receiver),
        Expr::Call(c) => match &*c.func {
            Expr::Path(p) => {
                let segs: Vec<String> = p
                    .path
                    .segments
                    .iter()
                    .map(|s| s.ident.to_string())
                    .collect();
                matches!(
                    segs.as_slice(),
                    [.., t, f] if (t == "OpenOptions" && f == "new") || (t == "File" && f == "options")
                )
            }
            _ => false,
        },
        Expr::Paren(p) => opens_by_options(&p.expr),
        _ => false,
    }
}

/// A number, a flag or a character, or a tuple or array of them.
fn is_number_type(ty: &syn::Type) -> bool {
    const SCALARS: &[&str] = &[
        "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize",
        "f32", "f64", "bool", "char",
    ];
    match ty {
        syn::Type::Path(p) => {
            p.qself.is_none()
                && p.path.segments.len() == 1
                && SCALARS.contains(&p.path.segments[0].ident.to_string().as_str())
        }
        syn::Type::Tuple(t) => !t.elems.is_empty() && t.elems.iter().all(is_number_type),
        syn::Type::Array(a) => is_number_type(&a.elem),
        _ => false,
    }
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
        self.check_channel_state(t);
        let segs = segments(&t.path);
        for full in self.aliases.resolve(&segs) {
            self.check_key(t.span(), &full);
            if self.check_type_prefix(t.span(), &full) {
                break;
            }
        }
        visit::visit_type_path(self, t);
    }

    fn visit_pat_tuple_struct(&mut self, p: &'ast syn::PatTupleStruct) {
        self.check_pat_path(&p.path);
        visit::visit_pat_tuple_struct(self, p);
    }

    fn visit_pat_struct(&mut self, p: &'ast syn::PatStruct) {
        self.check_pat_path(&p.path);
        visit::visit_pat_struct(self, p);
    }

    fn visit_item_impl(&mut self, i: &'ast syn::ItemImpl) {
        if let Some((_, path, _)) = &i.trait_
            && let Some(id) = self.rule("no-hand-luau-binding")
            && self
                .aliases
                .resolve(&segments(path))
                .iter()
                .any(|f| f.last().is_some_and(|l| l == "UserData"))
        {
            self.hit(
                path.span(),
                &id,
                "no-hand-luau-binding",
                "a hand-written `UserData` impl: Luau bindings are generated from the WIT (mal-gen), in sattr".into(),
            );
        }
        visit::visit_item_impl(self, i);
    }

    fn visit_expr_call(&mut self, c: &'ast syn::ExprCall) {
        if let Expr::Path(p) = &*c.func
            && let Some(id) = self.rule("no-colour-literal")
        {
            let segs = &p.path.segments;
            let last = segs.last().map(|s| s.ident.to_string()).unwrap_or_default();
            let ty = segs.len().checked_sub(2).and_then(|i| segs.iter().nth(i));
            let of_colour_type =
                ty.is_some_and(|t| COLOUR_TYPES.contains(&t.ident.to_string().as_str()));
            let made = COLOUR_FNS.contains(&last.as_str()) || of_colour_type;
            // a colour's channels are three or four numbers: one number is a palette index (`Colour::Ansi(1)`)
            let literal_numbers = !c.args.is_empty()
                && c.args.iter().all(|a| matches!(a, Expr::Lit(_)))
                && (c.args.len() >= 3 || !of_colour_type);
            let hex_colour =
                (names_colour(&last) || of_colour_type) && c.args.iter().any(is_hex_colour_int);
            if (made && literal_numbers) || hex_colour {
                self.hit(
                    p.path.span(),
                    &id,
                    "no-colour-literal",
                    "a colour made from literal numbers: colours come from the kit's tokens (themes/)"
                        .into(),
                );
            }
        }
        visit::visit_expr_call(self, c);
    }

    fn visit_expr_method_call(&mut self, m: &'ast syn::ExprMethodCall) {
        self.check_sink(&m.method.to_string(), &m.args);
        // `OpenOptions::new()….open(path)`: a method of a value, so no path names it, but clippy's disallowed-methods
        // lint does; the two agree here
        if m.method == "open"
            && opens_by_options(&m.receiver)
            && let Some((id, owner)) = self
                .rules
                .methods
                .get("std::fs::OpenOptions::open")
                .cloned()
        {
            self.hit(
                m.method.span(),
                &id,
                "disallowed-path",
                format!("`std::fs::OpenOptions::open` is reached only through `{owner}`"),
            );
        }
        if names_colour(&m.method.to_string())
            && m.args.iter().any(is_hex_colour_int)
            && let Some(id) = self.rule("no-colour-literal")
        {
            self.hit(
                m.method.span(),
                &id,
                "no-colour-literal",
                "a hex number used as a colour: colours come from the kit's tokens (themes/)"
                    .into(),
            );
        }
        visit::visit_expr_method_call(self, m);
    }

    fn visit_field_value(&mut self, f: &'ast syn::FieldValue) {
        if let syn::Member::Named(n) = &f.member {
            self.check_named_colour(&n.to_string(), &f.expr);
        }
        visit::visit_field_value(self, f);
    }

    fn visit_item_const(&mut self, c: &'ast syn::ItemConst) {
        self.check_named_colour(&c.ident.to_string(), &c.expr);
        visit::visit_item_const(self, c);
    }

    fn visit_item_static(&mut self, s: &'ast syn::ItemStatic) {
        self.check_named_colour(&s.ident.to_string(), &s.expr);
        visit::visit_item_static(self, s);
    }

    fn visit_item_fn(&mut self, f: &'ast syn::ItemFn) {
        self.check_fn(&f.vis, &f.sig);
        self.check_dependency_api(&f.vis, &f.sig);
        self.observers.push(if self.rules.reactive {
            observer_locals(&f.block)
        } else {
            Default::default()
        });
        visit::visit_item_fn(self, f);
        self.observers.pop();
    }

    fn visit_impl_item_fn(&mut self, f: &'ast syn::ImplItemFn) {
        self.check_fn(&f.vis, &f.sig);
        self.check_dependency_api(&f.vis, &f.sig);
        self.observers.push(if self.rules.reactive {
            observer_locals(&f.block)
        } else {
            Default::default()
        });
        visit::visit_impl_item_fn(self, f);
        self.observers.pop();
    }

    fn visit_item_struct(&mut self, s: &'ast syn::ItemStruct) {
        let all_secret = !s.fields.is_empty() && s.fields.iter().all(|f| is_secret_type(&f.ty));
        // numbers and flags only (a cache key, an id) hold no secret whatever the type is called
        let numbers = !s.fields.is_empty() && s.fields.iter().all(|f| is_number_type(&f.ty));
        self.check_secret(&s.ident, &s.attrs, all_secret || numbers);
        visit::visit_item_struct(self, s);
    }

    fn visit_item_enum(&mut self, e: &'ast syn::ItemEnum) {
        self.check_secret(&e.ident, &e.attrs, false);
        visit::visit_item_enum(self, e);
    }

    fn visit_local(&mut self, l: &'ast syn::Local) {
        if let syn::Pat::Ident(i) = &l.pat
            && let Some(init) = &l.init
        {
            self.check_named_colour(&i.ident.to_string(), &init.expr);
        }
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
        if is_hex_colour(&v)
            && let Some(id) = self.rule("no-colour-literal")
        {
            self.hit(
                s.span(),
                &id,
                "no-colour-literal",
                format!(
                    "\"{v}\" is a colour literal: colours come from the kit's tokens (themes/)"
                ),
            );
        }
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
        if let Expr::Binary(b) = e
            && matches!(b.op, syn::BinOp::Mul(_) | syn::BinOp::MulAssign(_))
            && self.rules.reactive
            && (names_scale(&b.left) || names_scale(&b.right))
            && let Some(id) = self.rule("no-raw-scale-mul")
        {
            self.hit(
                b.op.span(),
                &id,
                "no-raw-scale-mul",
                "a length multiplied by a scale by hand: logical lengths become pixels only through kvardi's `Lp::to_px`".into(),
            );
        }
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
