//! What gets indexed: three layers of `include`, `ignore` and `no-embed` lists in gitignore syntax.
//!
//! The layers, later wins: the built-in defaults ([`builtin_rules`]), the repo's committed `.drgnx/search.toml`, and the
//! user's own override per project (`drgnx-search-rules`). Within a layer the last matching line wins, and `!` takes a
//! path back. `include`, when a layer has one, is an allowlist: only matching paths are indexed (the latest layer with
//! one decides). `no-embed` keeps a file in keyword and symbol search with no vectors. The fixed refusals (dot paths,
//! secret names, nested repositories, the hub's deny-list) are no layer's to lift.
//!
//! A line is a gitignore pattern: `#` starts a comment, `!` takes back, a leading `/` or a `/` inside anchors it to the
//! root (otherwise it matches at any depth), a trailing `/` names a directory (everything below it), `*` and `?` stay
//! within one path component, `**` crosses them. A pattern that names a directory matches everything below it.

use crate::files::{Tok, dot_path, sensitive_name, tok_match, tokens};

/// What the rules say of one path.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    Index,
    NoEmbed,
    Ignored,
}

impl Verdict {
    pub fn as_str(self) -> &'static str {
        match self {
            Verdict::Index => "index",
            Verdict::NoEmbed => "no-embed",
            Verdict::Ignored => "ignored",
        }
    }
}

/// The layer a decision came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Layer {
    Builtin,
    Repo,
    User,
}

impl Layer {
    pub fn as_str(self) -> &'static str {
        match self {
            Layer::Builtin => "builtin",
            Layer::Repo => "repo",
            Layer::User => "user",
        }
    }
}

/// The list of a layer a decision came from (`Default`: no list said anything).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum List {
    Include,
    Ignore,
    NoEmbed,
    Default,
}

impl List {
    pub fn as_str(self) -> &'static str {
        match self {
            List::Include => "include",
            List::Ignore => "ignore",
            List::NoEmbed => "no-embed",
            List::Default => "default",
        }
    }
}

/// A path's verdict, with the layer, list and rule line that decided it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Decision {
    pub verdict: Verdict,
    pub layer: Layer,
    pub rule: Option<String>,
    pub list: List,
}

/// One layer's three lists, in gitignore syntax.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RuleSet {
    pub include: Vec<String>,
    pub ignore: Vec<String>,
    pub no_embed: Vec<String>,
}

/// The built-in defaults (design section 11). Files over 1 MiB ([`crate::files::MAX_FILE_BYTES`]), binary files and
/// what `.gitattributes` marks `linguist-generated` or `linguist-vendored` are left out by the file list itself.
pub fn builtin_rules() -> RuleSet {
    let ignore = [
        // fuzz corpora
        "**/fuzz/corpus/**",
        "**/*fuzz*/corpus/**",
        // snapshots and goldens
        "*.snap",
        "**/golden/**",
        "**/snapshots/**",
        // images and SVG
        "*.png",
        "*.jpg",
        "*.jpeg",
        "*.gif",
        "*.webp",
        "*.bmp",
        "*.tiff",
        "*.ico",
        "*.icns",
        "*.svg",
        // licence texts
        "LICENSE*",
        "COPYING*",
        "LICENSES/**",
        "THIRD_PARTY*",
        // lock files, minified files
        "*.lock",
        "package-lock.json",
        "pnpm-lock.yaml",
        "*.min.js",
        "*.min.css",
        // vendored code
        "vendor/**",
        "third_party/**",
    ];
    RuleSet {
        include: vec![],
        ignore: ignore.iter().map(|s| s.to_string()).collect(),
        no_embed: vec![],
    }
}

/// `.drgnx/search.toml`'s text as a layer: `include`, `ignore` and `no-embed`, each a list of strings. Any other key,
/// or a value that is no list of strings, is an error.
pub fn parse_toml(text: &str) -> Result<RuleSet, String> {
    let doc: toml_edit::DocumentMut = text.parse().map_err(|e| format!("not TOML: {e}"))?;
    let mut out = RuleSet::default();
    for (key, item) in doc.iter() {
        let slot = match key {
            "include" => &mut out.include,
            "ignore" => &mut out.ignore,
            "no-embed" => &mut out.no_embed,
            other => return Err(format!("{other:?} is not include, ignore or no-embed")),
        };
        let list = item
            .as_array()
            .ok_or_else(|| format!("{key} is not a list of strings"))?;
        for v in list {
            let s = v
                .as_str()
                .ok_or_else(|| format!("{key} holds what is not a string"))?;
            slot.push(s.to_string());
        }
    }
    Ok(out)
}

/// One compiled line.
struct Pat {
    line: String,
    neg: bool,
    dir_only: bool,
    toks: Vec<Tok>,
}

impl Pat {
    /// None for a blank line or a comment.
    fn compile(line: &str) -> Option<Pat> {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            return None;
        }
        let (neg, rest) = match line.strip_prefix('!') {
            Some(r) => (true, r),
            None => (false, line),
        };
        let (dir_only, rest) = match rest.strip_suffix('/') {
            Some(r) => (true, r),
            None => (false, rest),
        };
        let (anchored, rest) = match rest.strip_prefix('/') {
            Some(r) => (true, r),
            None => (rest.contains('/'), rest),
        };
        if rest.is_empty() {
            return None;
        }
        let body = if anchored {
            rest.to_string()
        } else {
            format!("**/{rest}")
        };
        Some(Pat {
            line: line.to_string(),
            neg,
            dir_only,
            toks: tokens(&body),
        })
    }

    /// Whether the pattern names PATH, or a directory above it.
    fn matches(&self, path: &[char]) -> bool {
        let above = path
            .iter()
            .enumerate()
            .filter(|(_, c)| **c == '/')
            .any(|(i, _)| tok_match(&self.toks, &path[..i]));
        above || (!self.dir_only && tok_match(&self.toks, path))
    }
}

fn compile(lines: &[String]) -> Vec<Pat> {
    lines.iter().filter_map(|l| Pat::compile(l)).collect()
}

/// The last line of PATS that matches PATH.
fn last<'a>(pats: &'a [Pat], path: &[char]) -> Option<&'a Pat> {
    pats.iter().rev().find(|p| p.matches(path))
}

struct Lists {
    layer: Layer,
    include: Vec<Pat>,
    ignore: Vec<Pat>,
    no_embed: Vec<Pat>,
}

impl Lists {
    fn of(layer: Layer, set: &RuleSet) -> Lists {
        Lists {
            layer,
            include: compile(&set.include),
            ignore: compile(&set.ignore),
            no_embed: compile(&set.no_embed),
        }
    }
}

/// The three layers compiled, and the checkout's nested repositories.
pub struct Rules {
    layers: Vec<Lists>,
    nested: Vec<String>,
}

impl Rules {
    /// The layers BUILTIN, REPO and USER in a checkout whose nested repositories are NESTED (as `Git::nested` gives
    /// them).
    pub fn new(builtin: &RuleSet, repo: &RuleSet, user: &RuleSet, nested: &[String]) -> Rules {
        Rules {
            layers: vec![
                Lists::of(Layer::Builtin, builtin),
                Lists::of(Layer::Repo, repo),
                Lists::of(Layer::User, user),
            ],
            nested: nested.iter().map(|n| format!("{n}/")).collect(),
        }
    }

    /// The refusal no layer can lift, as the rule text `why` shows.
    fn refused(&self, path: &str, allow: &dyn Fn(&str) -> bool) -> Option<&'static str> {
        if path.contains('\n') {
            // `hash-object --stdin-paths` is line-based
            Some("a newline in the name")
        } else if dot_path(path) {
            Some("a dot path")
        } else if sensitive_name(path) {
            Some("the name of a key or secret")
        } else if self.nested.iter().any(|p| path.starts_with(p)) {
            Some("inside a nested repository")
        } else if !allow(path) {
            Some("the deny-list")
        } else {
            None
        }
    }

    pub fn decide(&self, path: &str, allow: &dyn Fn(&str) -> bool) -> Decision {
        if let Some(why) = self.refused(path, allow) {
            return Decision {
                verdict: Verdict::Ignored,
                layer: Layer::Builtin,
                rule: Some(why.to_string()),
                list: List::Default,
            };
        }
        let chars: Vec<char> = path.chars().collect();
        let mut ignore: Option<(Layer, &Pat)> = None;
        let mut no_embed: Option<(Layer, &Pat)> = None;
        // the latest layer with an allowlist decides it: whether PATH is in
        let mut gate: Option<(Layer, bool)> = None;
        // earlier layers first, so a later one's line replaces what an earlier one said
        for l in &self.layers {
            if let Some(p) = last(&l.ignore, &chars) {
                ignore = Some((l.layer, p));
            }
            if let Some(p) = last(&l.no_embed, &chars) {
                no_embed = Some((l.layer, p));
            }
            if l.include.iter().any(|p| !p.neg) {
                gate = Some((l.layer, last(&l.include, &chars).is_some_and(|p| !p.neg)));
            }
        }
        let by = |verdict, layer, p: &Pat, list| Decision {
            verdict,
            layer,
            rule: Some(p.line.clone()),
            list,
        };
        if let Some((layer, p)) = ignore
            && !p.neg
        {
            return by(Verdict::Ignored, layer, p, List::Ignore);
        }
        if let Some((layer, false)) = gate {
            return Decision {
                verdict: Verdict::Ignored,
                layer,
                rule: None,
                list: List::Include,
            };
        }
        if let Some((layer, p)) = no_embed
            && !p.neg
        {
            return by(Verdict::NoEmbed, layer, p, List::NoEmbed);
        }
        match ignore {
            Some((layer, p)) => by(Verdict::Index, layer, p, List::Ignore),
            None => Decision {
                verdict: Verdict::Index,
                layer: Layer::Builtin,
                rule: None,
                list: List::Default,
            },
        }
    }
}
