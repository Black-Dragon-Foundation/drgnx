//! The rules a pack must meet: the schema checks every pack passes, and, for a pack that is not built in, the command,
//! install, reserved-name and claim rules (design §3.5, B2).

use std::collections::HashMap;

use regex::Regex;

use crate::manifest::{Adapter, Find, Install, Manifest};
use crate::reserved;

/// Where a pack comes from. Built-in packs are ours: only the schema rules run.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    Builtin,
    Fetched,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProblemKind {
    Schema,
    Reserved,
    Command,
    Install,
    /// A file, interpreter, mode, launch type or grammar another pack owns. On the card the user may pick it anyway.
    Claim,
    Highlights,
    Missing,
    Tree,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Problem {
    pub kind: ProblemKind,
    /// The field (`grammars[0].commit`) or file (`queries/highlights.scm`).
    pub path: String,
    pub message: String,
}

pub(crate) fn p(kind: ProblemKind, path: impl Into<String>, message: impl Into<String>) -> Problem {
    Problem {
        kind,
        path: path.into(),
        message: message.into(),
    }
}

/// What the installed and built-in packs and the adapter table already own, by owner name.
#[derive(Clone, Debug, Default)]
pub struct Claims {
    extensions: HashMap<String, String>,
    names: HashMap<String, String>,
    shebangs: Vec<(String, String)>,
    classic: HashMap<String, String>,
    grammars: HashMap<String, String>,
    types: HashMap<String, String>,
}

impl Claims {
    /// Records everything MANIFEST owns.
    pub fn add_pack(&mut self, m: &Manifest) {
        let o = &m.pack;
        for e in &m.files.extensions {
            self.extensions
                .entry(e.clone())
                .or_insert_with(|| o.clone());
        }
        for n in &m.files.names {
            self.names.entry(n.clone()).or_insert_with(|| o.clone());
        }
        for s in &m.files.shebangs {
            self.shebangs.push((s.clone(), o.clone()));
        }
        if let Some(c) = m.mode.as_ref().and_then(|m| m.classic.as_ref()) {
            self.classic.entry(c.clone()).or_insert_with(|| o.clone());
        }
        for g in m.grammars.iter().filter(|g| g.from_pack.is_none()) {
            self.grammars
                .entry(g.name.clone())
                .or_insert_with(|| o.clone());
        }
        for a in &m.adapters {
            self.add_adapter_types(o, &a.types);
        }
    }

    /// Records the launch types of an adapter in `etc/debug-adapters.eld`.
    pub fn add_adapter_types(&mut self, owner: &str, types: &[String]) {
        for t in types {
            self.types
                .entry(t.clone())
                .or_insert_with(|| owner.to_string());
        }
    }
}

const SHELLS: &[&str] = &[
    "sh", "bash", "zsh", "dash", "ash", "ksh", "csh", "tcsh", "fish",
];

/// The first byte of an argument a program takes as code, or `None`.
fn inline_code(argv: &[String]) -> Option<String> {
    let first = argv.first()?;
    let base = first.rsplit('/').next().unwrap_or(first);
    let base = base.trim_matches(|c| c == '{' || c == '}');
    let rest = &argv[1..];
    let single = |flag: char| {
        rest.iter()
            .find(|a| a.starts_with('-') && !a.starts_with("--") && a.contains(flag))
    };
    let exact = |flags: &[&str]| rest.iter().find(|a| flags.contains(&a.as_str()));
    let hit = if SHELLS.contains(&base) {
        single('c').or_else(|| exact(&["--command"]))
    } else if base.starts_with("python") {
        single('c')
    } else if matches!(base, "node" | "nodejs" | "deno" | "bun") {
        exact(&["-e", "--eval", "-p", "--print", "eval"])
    } else if matches!(base, "ruby" | "perl") {
        single('e').or_else(|| single('E'))
    } else if matches!(base, "php") {
        exact(&["-r"])
    } else if base == "lua" {
        exact(&["-e"])
    } else if base == "env" {
        let i = rest
            .iter()
            .position(|a| !a.starts_with('-') && !a.contains('='))?;
        return inline_code(&rest[i..]).or_else(|| Some(format!("env runs {}", rest[i])));
    } else {
        None
    };
    hit.map(|a| format!("{base} {a}"))
}

fn named_program(argv0: &str, find: Option<&Find>, install: Option<&Install>) -> bool {
    if let Some(f) = find {
        if f.path.as_deref() == Some(argv0) {
            return true;
        }
        if let Some(t) = &f.tools
            && argv0 == format!("{{tools}}/{t}")
        {
            return true;
        }
        if argv0 == "{program}" || (argv0 == "{python}" && f.python_module.is_some()) {
            return true;
        }
    }
    install
        .and_then(|i| i.into.as_deref())
        .is_some_and(|d| argv0.starts_with(&format!("{{tools}}/{d}/")))
}

fn command_rules(
    path: &str,
    argv: &[String],
    find: Option<&Find>,
    install: Option<&Install>,
    bare: bool,
    out: &mut Vec<Problem>,
) {
    let Some(argv0) = argv.first() else {
        return;
    };
    if let Some(code) = inline_code(argv) {
        out.push(p(
            ProblemKind::Command,
            path,
            format!("{code}: a shell or interpreter with inline code"),
        ));
        return;
    }
    let ok = if bare {
        !argv0.contains('/') && !argv0.starts_with(['{', '.', '~', '-'])
    } else {
        named_program(argv0, find, install)
    };
    if !ok {
        out.push(p(
            ProblemKind::Command,
            path,
            format!("{argv0} is not the program the entry's find or install names"),
        ));
    }
}

fn hex(s: &str, n: usize) -> bool {
    s.len() == n
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn safe_rel(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('/')
        && !s.contains('\\')
        && s.split('/').all(|c| !c.is_empty() && c != "..")
}

fn install_rules(path: &str, i: &Install, out: &mut Vec<Problem>) {
    let digest = |d: &Option<String>| d.as_deref().is_some_and(|d| hex(d, 64));
    let bad = |at: String, why: &str, out: &mut Vec<Problem>| {
        out.push(p(ProblemKind::Install, at, why.to_string()))
    };
    if i.system.is_some() {
        if i.url.is_some() || i.pip.is_some() || !i.platforms.is_empty() {
            bad(
                path.into(),
                ":system stands alone: it is shown, never run",
                out,
            );
        }
        return;
    }
    if let Some(u) = &i.url {
        if !u.starts_with("https://") {
            bad(path.into(), "an install URL is https", out);
        }
        if !digest(&i.sha256) {
            bad(path.into(), "an install URL needs its sha256", out);
        }
    }
    for (n, pl) in i.platforms.iter().enumerate() {
        let at = format!("{path}.platforms[{n}]");
        if !pl.url.starts_with("https://") {
            bad(at.clone(), "an install URL is https", out);
        }
        if !digest(&pl.sha256) {
            bad(at, "a platform's install needs its sha256", out);
        }
    }
    if i.pip.is_some()
        && !i
            .hash
            .as_deref()
            .is_some_and(|h| h.starts_with("sha256:") && hex(&h[7..], 64))
    {
        bad(path.into(), "a pip install needs :hash \"sha256:…\"", out);
    }
    if i.file
        .as_deref()
        .is_some_and(|f| !safe_rel(f) || f.contains('/'))
    {
        bad(path.into(), ":file is a file name", out);
    }
    for (n, part) in i.parts.iter().enumerate() {
        let at = format!("{path}.parts[{n}]");
        if part.system.is_some() || part.pip.is_some() || !part.parts.is_empty() {
            bad(at.clone(), "a part is a download", out);
            continue;
        }
        install_rules(&at, part, out);
    }
    if !i.parts.is_empty() {
        return;
    }
    if i.url.is_none() && i.pip.is_none() && i.platforms.is_empty() {
        bad(
            path.into(),
            "an install names a URL, platforms, a pip package or a system command",
            out,
        );
    }
}

/// A literal an interpreter pattern surely matches (`^python3` → `python3`), to compare two patterns.
fn probe(pat: &str) -> Option<&str> {
    let s = pat.strip_prefix('^').unwrap_or(pat);
    let end = s
        .find(|c: char| "[](){}.*+?|\\$".contains(c))
        .unwrap_or(s.len());
    (end > 0).then(|| &s[..end])
}

fn shebangs_clash(a: &str, b: &str) -> bool {
    let hit = |re: &str, other: &str| match (Regex::new(re), probe(other)) {
        (Ok(re), Some(s)) => re.is_match(s),
        _ => false,
    };
    hit(a, b) || hit(b, a)
}

fn adapter_rules(i: usize, a: &Adapter, fetched: bool, out: &mut Vec<Problem>) {
    if a.types.is_empty() {
        out.push(p(
            ProblemKind::Schema,
            format!("adapters[{i}].types"),
            "an adapter has a launch type",
        ));
    }
    if !fetched {
        return;
    }
    if let Some(s) = &a.start {
        if s.lsp_command.is_some() {
            out.push(p(
                ProblemKind::Command,
                format!("adapters[{i}].start.lsp-command"),
                "a language server is started by built-in packs only",
            ));
        }
        for (key, argv) in [("stdio", &s.stdio), ("tcp", &s.tcp)] {
            if let Some(argv) = argv {
                command_rules(
                    &format!("adapters[{i}].start.{key}"),
                    argv,
                    a.find.as_ref(),
                    a.install.as_ref(),
                    false,
                    out,
                );
            }
        }
    }
    if let Some(inst) = &a.install {
        install_rules(&format!("adapters[{i}].install"), inst, out);
    }
}

/// All the problems MANIFEST has as a pack from SOURCE, given what CLAIMS already owns. Empty when it passes.
pub fn check(m: &Manifest, source: Source, claims: &Claims) -> Vec<Problem> {
    use ProblemKind::*;
    let fetched = source == Source::Fetched;
    let mut out = Vec::new();
    let name_ok = Regex::new(r"^[a-z][a-z0-9-]{0,47}$").expect("literal");
    if !name_ok.is_match(&m.pack) {
        out.push(p(
            Schema,
            "pack",
            "a pack name is lowercase letters, digits and dashes, starting with a letter",
        ));
    } else if fetched && reserved::is_pack(&m.pack) {
        out.push(p(
            Reserved,
            "pack",
            format!("{} is a built-in pack's name", m.pack),
        ));
    }
    for (path, v) in [
        ("version", &m.version),
        ("name", &m.name),
        ("summary", &m.summary),
        ("license", &m.license),
    ] {
        if v.trim().is_empty() {
            out.push(p(Schema, path, "must not be empty"));
        }
    }

    // files
    for (i, e) in m.files.extensions.iter().enumerate() {
        if e.is_empty() || e.contains(['.', '/', ' ']) {
            out.push(p(
                Schema,
                format!("files.extensions[{i}]"),
                "an extension has no dot, slash or space",
            ));
        }
    }
    for (i, n) in m.files.names.iter().enumerate() {
        if n.is_empty() || n.contains('/') {
            out.push(p(
                Schema,
                format!("files.names[{i}]"),
                "a file name has no slash",
            ));
        }
    }
    for (i, s) in m.files.shebangs.iter().enumerate() {
        if let Err(e) = Regex::new(s) {
            out.push(p(
                Schema,
                format!("files.shebangs[{i}]"),
                format!("not a regexp: {e}"),
            ));
        }
    }

    // grammars
    let mut seen: Vec<&str> = Vec::new();
    for (i, g) in m.grammars.iter().enumerate() {
        let at = format!("grammars[{i}]");
        if seen.contains(&g.name.as_str()) {
            out.push(p(
                Schema,
                format!("{at}.name"),
                "two units of one language in a pack",
            ));
        }
        seen.push(&g.name);
        let pinned =
            g.repo.is_some() || g.commit.is_some() || g.tree_sha256.is_some() || g.src.is_some();
        match (&g.from_pack, pinned) {
            (Some(_), true) => out.push(p(
                Schema,
                &at,
                "a grammar is pinned or referenced (:from-pack), not both",
            )),
            (Some(_), false) => {}
            (None, _) if g.repo.is_none() && g.commit.is_none() && g.tree_sha256.is_none() => {
                out.push(p(
                    Schema,
                    &at,
                    "a grammar is pinned (repo, commit, tree-sha256) or referenced (:from-pack)",
                ));
            }
            (None, _) => {
                if !g.repo.as_deref().is_some_and(|r| r.starts_with("https://")) {
                    out.push(p(Schema, format!("{at}.repo"), "an https repository URL"));
                }
                if !g.commit.as_deref().is_some_and(|c| hex(c, 40)) {
                    out.push(p(Schema, format!("{at}.commit"), "a full 40-hex commit"));
                }
                if !g.tree_sha256.as_deref().is_some_and(|c| hex(c, 64)) {
                    out.push(p(Schema, format!("{at}.tree-sha256"), "a 64-hex tree hash"));
                }
                if g.src.as_deref().is_some_and(|s| !safe_rel(s)) {
                    out.push(p(
                        Schema,
                        format!("{at}.src"),
                        "a relative folder inside the repository",
                    ));
                }
                if fetched && reserved::is_grammar(&g.name) {
                    out.push(p(
                        Reserved,
                        format!("{at}.name"),
                        format!("a built-in pack owns the {} grammar: reference it", g.name),
                    ));
                }
                if fetched
                    && let Some(o) = claims.grammars.get(&g.name)
                    && *o != m.pack
                {
                    out.push(p(
                        Claim,
                        format!("{at}.name"),
                        format!("the pack {o} already pins the {} grammar", g.name),
                    ));
                }
            }
        }
    }

    // mode
    if let Some(mode) = &m.mode {
        let ts = mode.ts.is_some();
        if mode.generic == ts && (ts || mode.classic.is_none()) {
            out.push(p(
                Schema,
                "mode",
                "a mode is (:generic t), (:ts MODE …) or (:classic MODE)",
            ));
        }
        if ts && mode.builtin == mode.package.is_some() {
            out.push(p(
                Schema,
                "mode",
                "a :ts mode is :builtin t or comes from a :package",
            ));
        }
        if !ts && (mode.builtin || mode.package.is_some()) {
            out.push(p(Schema, "mode", ":builtin and :package go with :ts"));
        }
        if !mode.generic && !mode.indent.is_empty() {
            out.push(p(
                Schema,
                "mode.indent",
                "indent rules are the generic mode's",
            ));
        }
    }

    // servers, format
    let mut ids: Vec<&str> = Vec::new();
    for (i, s) in m.servers.iter().enumerate() {
        let at = format!("servers[{i}]");
        if s.id.is_empty() || ids.contains(&s.id.as_str()) {
            out.push(p(Schema, format!("{at}.id"), "a server has a unique id"));
        }
        ids.push(&s.id);
        if s.command.is_empty() {
            out.push(p(
                Schema,
                format!("{at}.command"),
                "a command names a program",
            ));
        } else if fetched {
            command_rules(
                &format!("{at}.command"),
                &s.command,
                s.find.as_ref(),
                s.install.as_ref(),
                false,
                &mut out,
            );
        }
        if fetched && let Some(inst) = &s.install {
            install_rules(&format!("{at}.install"), inst, &mut out);
        }
    }
    if let Some(f) = &m.format {
        if f.formatter.is_some() && f.command.is_empty() {
            out.push(p(Schema, "format.command", "a command names a program"));
        } else if f.formatter.is_none() && (f.standard || !f.command.is_empty()) {
            out.push(p(
                Schema,
                "format.formatter",
                "a command or :standard needs a formatter",
            ));
        } else if fetched && !f.command.is_empty() {
            command_rules("format.command", &f.command, None, None, true, &mut out);
        }
    }

    // hrafn, origin, inline
    if let Some(h) = &m.hrafn {
        if h.lang.is_empty() {
            out.push(p(Schema, "hrafn.lang", "a language name"));
        } else if fetched && reserved::is_lang(&h.lang) {
            out.push(p(
                Reserved,
                "hrafn.lang",
                format!("{} is a language the index already stores", h.lang),
            ));
        } else if !fetched && !reserved::is_lang(&h.lang) {
            out.push(p(
                Reserved,
                "hrafn.lang",
                format!(
                    "{} is not a stored language name (N1); add it to reserved::LANGS",
                    h.lang
                ),
            ));
        }
        for (path, f) in [("hrafn.tags", &h.tags), ("hrafn.chunks", &h.chunks)] {
            if f.as_deref().is_some_and(|f| !safe_rel(f)) {
                out.push(p(Schema, path, "a relative file inside the pack"));
            }
        }
        if h.sigil.as_deref().is_some_and(|s| s.chars().count() != 1) {
            out.push(p(Schema, "hrafn.sigil", "one character"));
        }
    }
    if let Some(o) = &m.origin
        && o.decls.iter().any(|d| d.trim().is_empty())
    {
        out.push(p(
            Schema,
            "origin.decls",
            "a declaration template is not empty",
        ));
    }
    if let Some(q) = m.inline.as_ref().and_then(|i| i.query.as_deref())
        && !safe_rel(q)
    {
        out.push(p(Schema, "inline.query", "a relative file inside the pack"));
    }
    for (i, a) in m.adapters.iter().enumerate() {
        adapter_rules(i, a, fetched, &mut out);
    }

    // claims
    if fetched {
        let other = |o: &String| *o != m.pack;
        for (i, e) in m.files.extensions.iter().enumerate() {
            if let Some(o) = claims.extensions.get(e).filter(|o| other(o)) {
                out.push(p(
                    Claim,
                    format!("files.extensions[{i}]"),
                    format!(".{e} belongs to {o}"),
                ));
            }
        }
        for (i, n) in m.files.names.iter().enumerate() {
            if let Some(o) = claims.names.get(n).filter(|o| other(o)) {
                out.push(p(
                    Claim,
                    format!("files.names[{i}]"),
                    format!("{n} belongs to {o}"),
                ));
            }
        }
        for (i, s) in m.files.shebangs.iter().enumerate() {
            if let Some((_, o)) = claims
                .shebangs
                .iter()
                .find(|(t, o)| other(o) && shebangs_clash(s, t))
            {
                out.push(p(
                    Claim,
                    format!("files.shebangs[{i}]"),
                    format!("an interpreter {o} owns"),
                ));
            }
        }
        if let Some(c) = m.mode.as_ref().and_then(|m| m.classic.as_ref())
            && let Some(o) = claims.classic.get(c).filter(|o| other(o))
        {
            out.push(p(Claim, "mode.classic", format!("{c} is remapped by {o}")));
        }
        for (i, a) in m.adapters.iter().enumerate() {
            for (j, t) in a.types.iter().enumerate() {
                if let Some(o) = claims.types.get(t).filter(|o| other(o)) {
                    out.push(p(
                        Claim,
                        format!("adapters[{i}].types[{j}]"),
                        format!("the launch type {t} belongs to {o}"),
                    ));
                }
            }
        }
    }
    out
}
