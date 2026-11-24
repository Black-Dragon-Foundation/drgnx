//! The ownership check: an `allow` or `expect` of a standard's lint (or of a group that holds one, or of `warnings`) is a
//! finding anywhere but in the crate that owns that standard; so is any `drgnx::allow` attribute. `cfg_attr` is looked
//! through.

use proc_macro2::Span;
use syn::spanned::Spanned;
use syn::visit::{self, Visit};

use super::scan::Hit;
use super::table::Table;

/// Groups that hold a standard's lint: silencing one silences the standard.
const GROUPS: &[&str] = &["all", "style", "restriction"];

pub fn check(file: &syn::File, table: &Table, krate: &str) -> Vec<Hit> {
    let mut v = Allows {
        table,
        krate,
        lints: table.all_lints().into_iter().collect(),
        hits: Vec::new(),
    };
    v.visit_file(file);
    v.hits
}

struct Allows<'a> {
    table: &'a Table,
    krate: &'a str,
    lints: Vec<String>,
    hits: Vec<Hit>,
}

impl Allows<'_> {
    fn hit(&mut self, span: Span, id: &str, message: String) {
        self.hits.push(Hit {
            line: span.start().line,
            id: id.to_string(),
            rule: "allow".into(),
            message,
        });
    }

    fn attr(&mut self, meta: &syn::Meta) {
        let path = meta.path();
        if path.segments.len() == 2
            && path.segments[0].ident == "drgnx"
            && path.segments[1].ident == "allow"
        {
            self.hit(
                path.span(),
                "standards",
                "a `drgnx::allow` attribute: a standard is silenced only by its owner".into(),
            );
            return;
        }
        let Some(name) = path.get_ident().map(ToString::to_string) else {
            return;
        };
        let syn::Meta::List(list) = meta else {
            return;
        };
        match name.as_str() {
            "allow" | "expect" => {
                let mut paths = Vec::new();
                let parsed = list.parse_nested_meta(|m| {
                    paths.push(m.path.clone());
                    Ok(())
                });
                if parsed.is_ok() {
                    for p in paths {
                        self.lint(&p);
                    }
                }
            }
            "cfg_attr" => {
                // cfg_attr(PREDICATE, attr, attr…): the attributes after the predicate
                let metas = list.parse_args_with(
                    syn::punctuated::Punctuated::<syn::Meta, syn::Token![,]>::parse_terminated,
                );
                if let Ok(metas) = metas {
                    for m in metas.iter().skip(1) {
                        self.attr(m);
                    }
                }
            }
            _ => {}
        }
    }

    fn lint(&mut self, p: &syn::Path) {
        let segs: Vec<String> = p.segments.iter().map(|s| s.ident.to_string()).collect();
        match segs.as_slice() {
            [w] if w == "warnings" => {
                self.hit(
                    p.span(),
                    "standards",
                    "`warnings` silenced: that silences every standard's lint".into(),
                );
            }
            [tool, lint] if tool == "clippy" => {
                if GROUPS.contains(&lint.as_str()) {
                    self.hit(
                        p.span(),
                        "standards",
                        format!("`clippy::{lint}` silenced: the group holds the standards' lints"),
                    );
                } else if self.lints.contains(lint) && !self.table.may_silence(self.krate, lint) {
                    let id = self
                        .table
                        .lint_owner(lint)
                        .map_or_else(|| "standards".to_string(), |s| s.id.clone());
                    let owner = self
                        .table
                        .lint_owner(lint)
                        .map_or_else(|| "the standard's owner".to_string(), |s| s.owner.clone());
                    self.hit(
                        p.span(),
                        &id,
                        format!("`clippy::{lint}` silenced outside its owner ({owner}): there is no allowlist"),
                    );
                }
            }
            _ => {}
        }
    }
}

impl<'ast> Visit<'ast> for Allows<'_> {
    fn visit_attribute(&mut self, a: &'ast syn::Attribute) {
        self.attr(&a.meta);
        visit::visit_attribute(self, a);
    }
}
