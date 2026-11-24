//! Selector dialects: how a set of row names becomes the argv items that select them (docs/develop/forseti.md,
//! "Dialects"). A dialect is a plugin a toolchain preset names (`[units] dialect`); nothing here is a default. Pure.
//!
//! - `libtest-exact`: `--exact a b c` (libtest takes several filters).
//! - `nextest`: `-E 'test(=a) | test(=b)'`.
//! - `args`: one argv item per unit, from a template (`./{dir}/...`, `--filter={name}`).
//!
//! A selector is always argv items, never shell text. Every row name is checked first ([`check_name`]): a name that
//! could be read as an option or break out of an expression is refused.

use crate::row::Row;

/// The longest row name a dialect renders.
pub const MAX_NAME: usize = 128;

/// How a dialect names a selection, so selections of one shape share a history ([`Dialect::class`]).
pub const CLASSES: &[&str] = &["all", "package", "test-set", "units", "other"];

/// A row name a dialect may render: `[A-Za-z0-9._:/+-]`, at most [`MAX_NAME`] bytes, no leading `-`, no `..` segment.
pub fn check_name(name: &str) -> villa::Result<()> {
    let ok = !name.is_empty()
        && name.len() <= MAX_NAME
        && !name.starts_with('-')
        && name.bytes().all(|b| {
            b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'/' | b'+' | b'-')
        })
        && !name.split('/').any(|seg| seg == "..");
    if ok {
        Ok(())
    } else {
        Err(villa::Error::invalid(format!(
            "the row name {name:?} cannot go into a selector (letters, digits and . _ : / + -, at most {MAX_NAME} bytes, \
             no leading -, no .. segment)"
        )))
    }
}

/// A selector dialect.
pub trait Dialect: Send + Sync {
    fn name(&self) -> &str;
    /// The argv items that select ROWS (never shell text).
    fn selector(&self, rows: &[String]) -> villa::Result<Vec<String>>;
    /// The class of a selection in this dialect's own syntax: one of [`CLASSES`]; `all` when none is selected.
    fn class(&self, select: Option<&str>) -> &'static str;
}

/// What a preset names: a dialect by name, or the `args` template.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DialectSpec {
    Named(String),
    Args { template: String },
}

/// The dialect SPEC names; an unknown name is refused.
pub fn dialect(spec: &DialectSpec) -> villa::Result<Box<dyn Dialect>> {
    match spec {
        DialectSpec::Named(n) if n == LibtestExact.name() => Ok(Box::new(LibtestExact)),
        DialectSpec::Named(n) if n == Nextest.name() => Ok(Box::new(Nextest)),
        DialectSpec::Named(n) => Err(villa::Error::invalid(format!(
            "no selector dialect named {n:?} (libtest-exact, nextest; `args` takes a template)"
        ))),
        DialectSpec::Args { template } => Ok(Box::new(Args::new(template)?)),
    }
}

/// The dialect a wire or settings string names: a plain name, or `args:TEMPLATE`.
pub fn by_name(s: &str) -> villa::Result<Box<dyn Dialect>> {
    match s.strip_prefix("args:") {
        Some(template) => dialect(&DialectSpec::Args {
            template: template.to_string(),
        }),
        None => dialect(&DialectSpec::Named(s.to_string())),
    }
}

/// The class of a selection SELECT of the dialect named DIALECT (none: no dialect: `all` or `other`), for a history
/// key: it needs no template, so it is a plain function of the names.
pub fn class_of(dialect: Option<&str>, select: Option<&str>) -> &'static str {
    let Some(sel) = select else {
        return "all";
    };
    match dialect {
        Some(n) if n == LibtestExact.name() => LibtestExact.class(Some(sel)),
        Some(n) if n == Nextest.name() => Nextest.class(Some(sel)),
        Some("args") => "units",
        _ => "other",
    }
}

/// cargo's libtest: `--exact a b c`.
pub struct LibtestExact;

impl Dialect for LibtestExact {
    fn name(&self) -> &str {
        "libtest-exact"
    }

    fn selector(&self, rows: &[String]) -> villa::Result<Vec<String>> {
        let mut out = vec!["--exact".to_string()];
        for r in rows {
            check_name(r)?;
            out.push(r.clone());
        }
        Ok(out)
    }

    fn class(&self, select: Option<&str>) -> &'static str {
        match select {
            None => "all",
            Some(s) if s.starts_with("--exact") => "test-set",
            Some(_) => "other",
        }
    }
}

/// nextest: `-E 'test(=a) | test(=b)'`.
pub struct Nextest;

impl Dialect for Nextest {
    fn name(&self) -> &str {
        "nextest"
    }

    fn selector(&self, rows: &[String]) -> villa::Result<Vec<String>> {
        let mut terms = Vec::with_capacity(rows.len());
        for r in rows {
            check_name(r)?;
            terms.push(format!("test(={r})"));
        }
        Ok(vec!["-E".to_string(), terms.join(" | ")])
    }

    fn class(&self, select: Option<&str>) -> &'static str {
        match select {
            None => "all",
            Some(s) if s.starts_with("package(") => "package",
            Some(s) if s.starts_with("test(=") => "test-set",
            Some(_) => "other",
        }
    }
}

/// One argv item per unit, from a template with `{name}` and `{dir}`.
pub struct Args {
    template: String,
}

impl Args {
    /// A dialect over TEMPLATE, which must name `{name}` or `{dir}` and must not start with `{` followed by nothing
    /// that fixes it as a flag (an item that begins with `-` is the template's own text, never a row's).
    pub fn new(template: &str) -> villa::Result<Args> {
        if !template.contains("{name}") && !template.contains("{dir}") {
            return Err(villa::Error::invalid(format!(
                "the args template {template:?} names neither {{name}} nor {{dir}}"
            )));
        }
        Ok(Args {
            template: template.to_string(),
        })
    }

    /// The items for UNITS, each a `(name, dir)`.
    pub fn render(&self, units: &[(String, String)]) -> villa::Result<Vec<String>> {
        units
            .iter()
            .map(|(name, dir)| {
                check_name(name)?;
                check_name(dir.trim_start_matches("./"))?;
                Ok(self.template.replace("{name}", name).replace("{dir}", dir))
            })
            .collect()
    }
}

impl Dialect for Args {
    fn name(&self) -> &str {
        "args"
    }

    fn selector(&self, rows: &[String]) -> villa::Result<Vec<String>> {
        let units: Vec<(String, String)> = rows.iter().map(|r| (r.clone(), r.clone())).collect();
        self.render(&units)
    }

    fn class(&self, select: Option<&str>) -> &'static str {
        if select.is_some() { "units" } else { "all" }
    }
}

/// ROWS' names, for a caller that holds parsed rows.
pub fn names(rows: &[Row]) -> Vec<String> {
    rows.iter().map(|r| r.name.clone()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn nextest_filterset_renders_exact_names() {
        // [D] pure
        assert_eq!(
            Nextest.selector(&v(&["a::b", "c"])).unwrap(),
            v(&["-E", "test(=a::b) | test(=c)"])
        );
    }

    #[test]
    fn libtest_exact_renders_exact_names() {
        // [D] pure
        assert_eq!(
            LibtestExact.selector(&v(&["a", "b::c"])).unwrap(),
            v(&["--exact", "a", "b::c"])
        );
    }

    #[test]
    fn args_dialect_renders_one_item_per_unit() {
        // [D] pure
        let go = Args::new("./{dir}/...").unwrap();
        assert_eq!(
            go.render(&[("a".into(), "pkg/a".into()), ("b".into(), "pkg/b".into())])
                .unwrap(),
            v(&["./pkg/a/...", "./pkg/b/..."])
        );
        let pnpm = Args::new("--filter={name}").unwrap();
        assert_eq!(
            pnpm.selector(&v(&["web", "api"])).unwrap(),
            v(&["--filter=web", "--filter=api"])
        );
        assert!(Args::new("no placeholder").is_err());
    }

    #[test]
    fn a_row_name_that_could_break_out_is_refused_by_every_dialect() {
        // [D] pure
        for bad in [
            "a b",
            "-x",
            "a)|test(=b",
            "../x",
            "a/../b",
            "",
            "a;b",
            &"x".repeat(MAX_NAME + 1),
        ] {
            assert!(
                LibtestExact.selector(&v(&[bad])).is_err(),
                "libtest {bad:?}"
            );
            assert!(Nextest.selector(&v(&[bad])).is_err(), "nextest {bad:?}");
            assert!(
                Args::new("--filter={name}")
                    .unwrap()
                    .selector(&v(&[bad]))
                    .is_err(),
                "args {bad:?}"
            );
        }
    }

    #[test]
    fn selection_classes_are_the_dialects_own() {
        // [D] pure
        assert_eq!(Nextest.class(None), "all");
        assert_eq!(Nextest.class(Some("package(=a) | package(=b)")), "package");
        assert_eq!(Nextest.class(Some("test(=a)")), "test-set");
        assert_eq!(LibtestExact.class(Some("--exact a")), "test-set");
        assert_eq!(Args::new("{name}").unwrap().class(Some("x")), "units");
        for c in ["all", "package", "test-set", "units", "other"] {
            assert!(CLASSES.contains(&c));
        }
    }

    #[test]
    fn two_dialects_never_share_a_key() {
        // [D] pure: the same selection text in two dialects is two classes' worth of history, and the key names the
        // dialect: see `history::tests`
        assert_ne!(
            class_of(Some("nextest"), Some("--exact a")),
            class_of(Some("libtest-exact"), Some("--exact a"))
        );
        assert_eq!(class_of(None, None), "all");
        assert!(dialect(&DialectSpec::Named("ert".into())).is_err());
        assert_eq!(
            dialect(&DialectSpec::Named("nextest".into()))
                .unwrap()
                .name(),
            "nextest"
        );
    }
}
