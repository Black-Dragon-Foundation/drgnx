//! Where did this come from? The origin trail (spec §19.4, D3), for Python.  The trail replays the recorded run to the
//! stop under a small tracer (`etc/debug-origin.py`, `sys.monitoring`, Python ≥ 3.12) that records every store
//! to the names and attributes asked about, with the values of the operands on that line; the last store before the
//! stop is a link, and its operands are the next level's question (one replay per level, at most [`DEPTH_MAX`]).  A
//! call of a method on a watched value (`items.append(x)`) is a link "changed inside `list.append`".  Python older than
//! 3.12 gets the static candidates instead: the assignments to the name in the files asked, found with Hrafn's
//! grammar, labelled "candidates, not traced".
//!
//! Other languages (JavaScript, TypeScript, Go, C, Rust, Java: by the stop's file) are traced by logpoints instead: the
//! lines that store to the asked names are found with Hrafn's grammar for the language ([`stores`]), each gets one
//! logpoint in the sealed replay that logs what the line reads, and the last of them to log before the stop is the
//! link.  A line's value is logged only when what it stores is a pure read (no call, no `new`, no increment), so the
//! logpoint never runs the program's code twice; a store through an alias, or in a file that is neither the stop's nor
//! on its stack, is not seen (the card says so).

use super::BoxFut;
use super::record::{RunHit, RunProbe};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The tracer, written into the replay's tree.
pub const TRACER: &str = include_str!("../../../../../etc/debug-origin.py");
/// What turns it on at the interpreter's start (Python imports `sitecustomize` from the path).
pub const SITECUSTOMIZE: &str = "import drgnx_origin\ndrgnx_origin.from_env()\n";
/// The folder of the replay's tree the tracer is written to, and its records file.
pub const DIR: &str = ".drgnx-origin";
pub const OUT: &str = "records.jsonl";
/// The deepest trail.
pub const DEPTH_MAX: u32 = 3;
/// The most questions one level asks.
pub const WIDTH_MAX: usize = 6;

/// One record of the tracer: a store to a watched target, or a call of a method on one.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
pub struct Rec {
    pub seq: u64,
    pub kind: String,
    pub target: String,
    #[serde(default)]
    pub key: Option<String>,
    #[serde(default)]
    pub value: Option<String>,
    pub file: String,
    pub line: u32,
    #[serde(default)]
    pub func: String,
    #[serde(default)]
    pub operands: BTreeMap<String, String>,
    #[serde(default)]
    pub inside: Option<String>,
}

/// The tracer's records file, line by line (a line that does not parse is left out).
pub fn parse(text: &str) -> Vec<Rec> {
    text.lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

/// The records file TEXT as a replay's answer: the Python that ran is older than 3.12 (its first line names it), or
/// the records; an empty file means the tracer never started (not a Python program, or its start failed).
pub fn traced(text: &str) -> Result<Traced, String> {
    let Some(first) = text.lines().next() else {
        return Err("the tracer did not start: is the program Python?".into());
    };
    if let Ok(v) = serde_json::from_str::<Value>(first)
        && let Some(py) = v["python"].as_str()
    {
        let mut parts = py.split('.').map(|p| p.parse::<u32>().unwrap_or(0));
        let (major, minor) = (parts.next().unwrap_or(0), parts.next().unwrap_or(0));
        if (major, minor) < (3, 12) {
            return Ok(Traced::Old(py.to_owned()));
        }
    }
    Ok(Traced::Records(parse(text)))
}

/// A link of the trail: what set QUESTION last before the stop.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Link {
    pub level: u32,
    /// What was asked: a name or a dotted path.
    pub question: String,
    /// The target as the line wrote it (`item.reserve`, `self.reserve`).
    pub target: String,
    pub value: Option<String>,
    pub path: String,
    pub line: u32,
    pub func: String,
    pub operands: Vec<(String, String)>,
    /// A change made by a call: `list.append`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub inside: Option<String>,
    /// False for the static candidates (Python < 3.12).
    pub traced: bool,
}

/// Whether record R is about QUESTION: the same target, or (a dotted question) a store to its attribute on any object,
/// or (a plain name) a store to that name.
fn about(r: &Rec, question: &str) -> bool {
    if r.target == question {
        return true;
    }
    match question.rsplit_once('.') {
        Some((_, attr)) => r.kind == "store" && r.key.as_deref() == Some(&format!(".{attr}")),
        None => r.kind == "store" && r.key.as_deref() == Some(question),
    }
}

/// The link of QUESTION at LEVEL: the last record about it (records come in the order the program made them, and the
/// replay ends at the stop).
pub fn link(recs: &[Rec], question: &str, level: u32) -> Option<Link> {
    let r = recs
        .iter()
        .filter(|r| about(r, question))
        .max_by_key(|r| r.seq)?;
    Some(Link {
        level,
        question: question.to_owned(),
        target: r.target.clone(),
        value: r.value.clone(),
        path: r.file.clone(),
        line: r.line,
        func: r.func.clone(),
        // an operand worth showing: not the target itself, not a value without a repr (a function, an object)
        operands: r
            .operands
            .iter()
            .filter(|(k, v)| **k != r.target && !v.starts_with('<'))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect(),
        inside: r.inside.clone(),
        traced: true,
    })
}

/// The next level's questions from LINK: its operands that hold data (not a function, class or module), the target
/// itself left out.
pub fn follow(link: &Link) -> Vec<String> {
    link.operands
        .iter()
        .filter(|(e, _)| *e != link.target)
        .map(|(e, _)| e.clone())
        .collect()
}

/// What a replay gave: the tracer's records, or the interpreter is older than 3.12 (its version).
#[derive(Clone, Debug, PartialEq)]
pub enum Traced {
    Records(Vec<Rec>),
    Old(String),
}

/// Runs the recorded run again to a stop with the tracer on (spec §19.3's sealed replay, D2).
pub trait Replay: Send + Sync {
    /// RUN replayed to its stop STOP, the tracer watching WATCH.
    fn trace(
        &self,
        run: &str,
        stop: u64,
        watch: Vec<String>,
    ) -> BoxFut<'static, Result<Traced, String>>;

    /// RUN replayed to its stop STOP with PROBES (paths in the project) set: their hits, in order.
    fn probe(
        &self,
        run: &str,
        stop: u64,
        probes: Vec<RunProbe>,
    ) -> BoxFut<'static, Result<Vec<RunHit>, String>>;
}

/// The tracer's files written into DIR (`<tree>/.drgnx-origin`): the folder to put first on `PYTHONPATH`.
pub fn write_tracer(dir: &Path) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(dir)?;
    std::fs::write(dir.join("drgnx_origin.py"), TRACER)?;
    std::fs::write(dir.join("sitecustomize.py"), SITECUSTOMIZE)?;
    Ok(dir.to_owned())
}

/// The tracer's files for a replay's tree (relative paths: `.drgnx-origin/…`).
pub fn trace_files() -> Vec<(String, Vec<u8>)> {
    vec![
        (format!("{DIR}/drgnx_origin.py"), TRACER.as_bytes().to_vec()),
        (
            format!("{DIR}/sitecustomize.py"),
            SITECUSTOMIZE.as_bytes().to_vec(),
        ),
    ]
}

/// The environment that turns the tracer on in the replay's TREE, watching WATCH in the code under it.
pub fn trace_env(tree: &Path, watch: &[String]) -> Vec<(String, String)> {
    env(&tree.join(DIR), tree, watch, None)
}

/// A replay's answer from its TREE: the tracer's records, their files named under ROOT (the project).
pub fn read_trace(tree: &Path, root: &Path) -> Result<Traced, String> {
    let text = std::fs::read_to_string(tree.join(DIR).join(OUT)).unwrap_or_default();
    Ok(match traced(&text)? {
        Traced::Records(mut r) => {
            rebase(&mut r, tree, root);
            Traced::Records(r)
        }
        old => old,
    })
}

/// RECS' files as the project's: a file under TREE (the replay's copy, as named or as resolved) is named under ROOT.
pub fn rebase(recs: &mut [Rec], tree: &Path, root: &Path) {
    let real = std::fs::canonicalize(tree).ok();
    for r in recs {
        let file = Path::new(&r.file);
        let rel = file
            .strip_prefix(tree)
            .ok()
            .or_else(|| real.as_deref().and_then(|t| file.strip_prefix(t).ok()));
        if let Some(rel) = rel {
            r.file = root.join(rel).to_string_lossy().into_owned();
        }
    }
}

/// The environment that turns the tracer on: `PYTHONPATH` (DIR first, then BASE's) and `DRGNX_ORIGIN`.
pub fn env(dir: &Path, root: &Path, watch: &[String], base: Option<&str>) -> Vec<(String, String)> {
    let mut path = dir.to_string_lossy().into_owned();
    if let Some(b) = base.filter(|b| !b.is_empty()) {
        path.push(':');
        path.push_str(b);
    }
    let cfg = serde_json::json!({"out": dir.join(OUT), "root": root, "watch": watch});
    vec![
        ("PYTHONPATH".into(), path),
        ("DRGNX_ORIGIN".into(), cfg.to_string()),
    ]
}

/// The trail of QUESTION at RUN's stop STOP, DEPTH levels deep; SOURCES gives the files (path, text) the static
/// candidates are looked for in when the replay's Python is older than 3.12.  ON_LEVEL sees each level's links.
pub async fn trail(
    replay: &dyn Replay,
    run: &str,
    stop: u64,
    question: &str,
    depth: u32,
    sources: impl Fn() -> Vec<(String, String)>,
    mut on_level: impl FnMut(&[Link]),
) -> Result<Trail, String> {
    let files = sources();
    if let Some(lang) = files.first().and_then(|(p, _)| lang_of(p))
        && lang != hrafn::Lang::Python
    {
        return probed_trail(replay, run, stop, question, depth, lang, &files, on_level).await;
    }
    let mut links: Vec<Link> = Vec::new();
    let mut asked: Vec<String> = Vec::new();
    let mut questions = vec![question.to_owned()];
    for level in 1..=depth.clamp(1, DEPTH_MAX) {
        asked.extend(questions.iter().cloned());
        let got = replay.trace(run, stop, questions.clone()).await?;
        let recs = match got {
            Traced::Records(r) => r,
            Traced::Old(version) => {
                let c = candidates(&sources(), question);
                on_level(&c);
                return Ok(Trail {
                    links: c,
                    note: Some(format!(
                        "Python {version} has no sys.monitoring (3.12): candidates, not traced"
                    )),
                });
            }
        };
        let found: Vec<Link> = questions
            .iter()
            .filter_map(|q| link(&recs, q, level))
            .collect();
        on_level(&found);
        let mut next: Vec<String> = Vec::new();
        for l in &found {
            for q in follow(l) {
                if !asked.contains(&q) && !next.contains(&q) {
                    next.push(q);
                }
            }
        }
        links.extend(found);
        next.truncate(WIDTH_MAX);
        if next.is_empty() {
            break;
        }
        questions = next;
    }
    Ok(Trail { links, note: None })
}

/// The trail of a language without a tracer: per level, the lines storing to its questions in FILES get logpoints in
/// one replay (see the module's doc).
#[allow(clippy::too_many_arguments)]
async fn probed_trail(
    replay: &dyn Replay,
    run: &str,
    stop: u64,
    question: &str,
    depth: u32,
    lang: hrafn::Lang,
    files: &[(String, String)],
    mut on_level: impl FnMut(&[Link]),
) -> Result<Trail, String> {
    let mut links: Vec<Link> = Vec::new();
    let mut asked: Vec<String> = Vec::new();
    let mut questions = vec![question.to_owned()];
    for level in 1..=depth.clamp(1, DEPTH_MAX) {
        asked.extend(questions.iter().cloned());
        let lines: Vec<(String, Vec<StoreLine>)> = questions
            .iter()
            .map(|q| (q.clone(), stores(lang, files, q)))
            .collect();
        // one logpoint a line, whichever questions it answers
        let mut probes: Vec<(RunProbe, StoreLine)> = Vec::new();
        for s in lines.iter().flat_map(|(_, s)| s) {
            if !probes
                .iter()
                .any(|(_, o)| o.path == s.path && o.line == s.line)
            {
                let p = RunProbe {
                    id: format!("origin-{}", probes.len() + 1),
                    path: s.path.clone(),
                    line: s.line,
                    expr: probe_expr(&s.logged()),
                };
                probes.push((p, s.clone()));
            }
        }
        if probes.is_empty() {
            break;
        }
        let hits = replay
            .probe(run, stop, probes.iter().map(|(p, _)| p.clone()).collect())
            .await?;
        let mut found: Vec<Link> = Vec::new();
        for (q, of_q) in &lines {
            let last = hits
                .iter()
                .filter_map(|h| {
                    let (_, s) = probes.iter().find(|(p, _)| p.id == h.probe)?;
                    of_q.iter()
                        .any(|o| o.path == s.path && o.line == s.line)
                        .then_some((h, s))
                })
                .max_by_key(|(h, _)| h.seq);
            if let Some((h, s)) = last {
                found.push(s.link(q, level, &h.value));
            }
        }
        on_level(&found);
        let mut next: Vec<String> = Vec::new();
        for l in &found {
            for q in follow(l) {
                if !asked.contains(&q) && !next.contains(&q) {
                    next.push(q);
                }
            }
        }
        links.extend(found);
        next.truncate(WIDTH_MAX);
        if next.is_empty() {
            break;
        }
        questions = next;
    }
    Ok(Trail {
        links,
        note: Some(PROBED.into()),
    })
}

/// What a trail traced by logpoints cannot see, said on its card.
pub const PROBED: &str = "traced by logpoints: a store through another name, or in a file off the stop's stack, is not seen";

/// The language of PATH's code, by its extension: the built-in packs whose `:origin` says trails work in their language
/// (a pack with no `:origin` has none: shell and Lisp are not traced).
pub fn lang_of(path: &str) -> Option<hrafn::Lang> {
    let ext = Path::new(path).extension()?.to_str()?;
    skald::builtin::manifests()
        .iter()
        .filter(|m| m.origin.is_some())
        .find(|m| m.files.extensions.iter().any(|e| e == ext))
        .and_then(|m| m.hrafn.as_ref())
        .map(|h| hrafn::Lang::parse(&h.lang))
}

/// The declaration templates of LANG's pack (`:origin :decls`, `{t}` the name asked about).
fn decls_of(lang: hrafn::Lang) -> &'static [String] {
    skald::builtin::manifests()
        .iter()
        .find(|m| {
            m.hrafn
                .as_ref()
                .is_some_and(|h| hrafn::Lang::parse(&h.lang) == lang)
        })
        .and_then(|m| m.origin.as_ref())
        .map_or(&[], |o| o.decls.as_slice())
}

/// Separates the values one logpoint logs (the unit separator: never in a value the adapters print).
const SEP: char = '\u{1f}';

/// A logpoint expression logging EXPRS in order, SEP between: [`super::probes::log_message`] puts the whole in one
/// `{…}`, so the inner ones close and reopen it.
fn probe_expr(exprs: &[String]) -> String {
    exprs.join(&format!("}}{SEP}{{"))
}

/// A line that stores to a question: its TARGET as written, what it reads (OPERANDS, sorted), and its stored
/// expression when that is a pure read of a plain store (its value is then logged last).
#[derive(Clone, Debug, PartialEq)]
pub struct StoreLine {
    pub path: String,
    pub line: u32,
    pub target: String,
    pub operands: Vec<String>,
    pub pure: Option<String>,
}

impl StoreLine {
    /// What its logpoint logs: the operands, then the value when pure.
    fn logged(&self) -> Vec<String> {
        let mut v = self.operands.clone();
        v.extend(self.pure.clone());
        if v.is_empty() {
            // a line that reads nothing (a literal not pure enough to log): it still says it ran
            v.push("0".into());
        }
        v
    }

    /// The link this line makes for QUESTION at LEVEL from its logpoint's VALUE.
    fn link(&self, question: &str, level: u32, value: &str) -> Link {
        let parts: Vec<&str> = value.split(SEP).collect();
        let operands: Vec<(String, String)> = self
            .operands
            .iter()
            .zip(&parts)
            // a value that is code, not data (a function, a class)
            .filter(|(_, v)| {
                !(v.starts_with('ƒ') || v.starts_with("class ") || v.starts_with("func"))
            })
            .map(|(k, v)| (k.clone(), (*v).to_owned()))
            .collect();
        let value = self
            .pure
            .as_ref()
            .and_then(|_| parts.get(self.operands.len()))
            .map(|v| (*v).to_owned());
        Link {
            level,
            question: question.to_owned(),
            target: self.target.clone(),
            value,
            path: self.path.clone(),
            line: self.line,
            func: String::new(),
            operands,
            inside: None,
            traced: true,
        }
    }
}

/// The lines of FILES (in LANG) that store to QUESTION: a plain name's assignments and declarations, or (dotted) a
/// store to its attribute on any object; plain or compound; in file order.
pub fn stores(lang: hrafn::Lang, files: &[(String, String)], question: &str) -> Vec<StoreLine> {
    use hrafn::structural::Pattern;
    let (target, attr) = match question.rsplit_once('.') {
        Some((_, attr)) => ("$O.".to_owned() + attr, Some(attr)),
        None => (question.to_owned(), None),
    };
    let mut forms: Vec<(String, bool)> = ["=", "+=", "-=", "*=", "/=", "|=", "&="]
        .iter()
        .map(|op| (format!("{target} {op} $V"), *op == "="))
        .collect();
    if attr.is_none() {
        let decls = decls_of(lang);
        forms.extend(decls.iter().map(|d| (d.replace("{t}", question), true)));
    }
    // a language whose top level takes statements only (C#) needs the `;`: each form is also tried with one (a line a
    // form already found is not found twice)
    let semi: Vec<(String, bool)> = forms
        .iter()
        .filter(|(f, _)| !f.ends_with(';'))
        .map(|(f, plain)| (format!("{f};"), *plain))
        .collect();
    forms.extend(semi);
    let patterns: Vec<(Pattern, bool)> = forms
        .iter()
        .filter_map(|(f, plain)| Some((Pattern::new(lang, f, None).ok()?, *plain)))
        .collect();
    let mut out: Vec<StoreLine> = Vec::new();
    for (path, text) in files {
        let mut found: Vec<StoreLine> = Vec::new();
        for (p, plain) in &patterns {
            for m in p.find(text.as_bytes()).unwrap_or_default() {
                if found.iter().any(|s| s.line == m.line) {
                    continue;
                }
                let v = m.captures.get("V").cloned().unwrap_or_default();
                let target = match (attr, m.captures.get("O")) {
                    (Some(a), Some(o)) => format!("{o}.{a}"),
                    _ => question.to_owned(),
                };
                found.push(StoreLine {
                    path: path.clone(),
                    line: m.line,
                    target,
                    operands: reads(&v),
                    pure: (*plain && is_pure(&v)).then(|| v.trim().to_owned()),
                });
            }
        }
        found.sort_by_key(|s| s.line);
        out.extend(found);
    }
    out
}

/// The names and member paths EXPR reads (`item.min`), sorted: not the called ones, not keywords or literals.
fn reads(expr: &str) -> Vec<String> {
    const NOT: &[&str] = &[
        "new",
        "this",
        "true",
        "false",
        "null",
        "undefined",
        "nil",
        "None",
        "typeof",
        "instanceof",
        "await",
        "yield",
        "async",
        "function",
        "return",
        "in",
        "of",
        "void",
        "delete",
        "self",
        "Some",
        "Ok",
        "Err",
        "as",
        "mut",
    ];
    let b = expr.as_bytes();
    let word = |c: u8| c.is_ascii_alphanumeric() || c == b'_' || c == b'$';
    let mut out: Vec<String> = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        if c == b'"' || c == b'\'' || c == b'`' {
            // a string literal: skipped whole
            i += 1;
            while i < b.len() && b[i] != c {
                i += if b[i] == b'\\' { 2 } else { 1 };
            }
            i += 1;
            continue;
        }
        let starts =
            word(c) && !c.is_ascii_digit() && (i == 0 || (b[i - 1] != b'.' && !word(b[i - 1])));
        if !starts {
            i += 1;
            continue;
        }
        let from = i;
        loop {
            while i < b.len() && word(b[i]) {
                i += 1;
            }
            if i + 1 < b.len() && b[i] == b'.' && word(b[i + 1]) && !b[i + 1].is_ascii_digit() {
                i += 1;
            } else {
                break;
            }
        }
        let name = &expr[from..i];
        let called = expr[i..].trim_start().starts_with('(');
        let first = name.split('.').next().unwrap_or_default();
        if called || NOT.contains(&name) {
            continue;
        }
        // `this.min` is a read, plain `this` is not
        if NOT.contains(&first) && !matches!(first, "this" | "self") {
            continue;
        }
        if !out.iter().any(|o| o == name) {
            out.push(name.to_owned());
        }
    }
    out.sort();
    out
}

/// Whether logging EXPR again runs nothing of the program: no call, construction, increment or assignment.
fn is_pure(expr: &str) -> bool {
    let e = expr
        .replace("==", "")
        .replace("!=", "")
        .replace("<=", "")
        .replace(">=", "");
    !(e.contains('(')
        || e.contains("++")
        || e.contains("--")
        || e.contains('=')
        || e.contains("<-")
        || ["new ", "await ", "yield "].iter().any(|k| e.contains(k)))
}

/// A trail: its links by level, and a note (why it is only candidates).
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Trail {
    pub links: Vec<Link>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

/// The static candidates of QUESTION in FILES: every assignment to the name (or, dotted, to the attribute on any
/// object), plain or augmented, found with Hrafn's Python grammar; in file order.
pub fn candidates(files: &[(String, String)], question: &str) -> Vec<Link> {
    use hrafn::Lang;
    use hrafn::structural::Pattern;
    let target = match question.rsplit_once('.') {
        Some((_, attr)) => format!("$O.{attr}"),
        None => question.to_owned(),
    };
    let patterns: Vec<Pattern> = ["=", "+=", "-=", "*=", "/=", "|=", "&="]
        .iter()
        .filter_map(|op| Pattern::new(Lang::Python, &format!("{target} {op} $V"), None).ok())
        .collect();
    let mut out: Vec<Link> = Vec::new();
    for (path, text) in files {
        let mut found: Vec<(u32, String)> = Vec::new();
        for p in &patterns {
            for m in p.find(text.as_bytes()).unwrap_or_default() {
                let line_text = text
                    .lines()
                    .nth(m.line.saturating_sub(1) as usize)
                    .unwrap_or_default()
                    .trim()
                    .to_owned();
                if !found.iter().any(|(l, _)| *l == m.line) {
                    found.push((m.line, line_text));
                }
            }
        }
        found.sort();
        for (line, text) in found {
            let target = text
                .split_once('=')
                .map(|(t, _)| {
                    t.trim_end_matches(['+', '-', '*', '/', '|', '&'])
                        .trim()
                        .to_owned()
                })
                .unwrap_or_default();
            out.push(Link {
                level: 1,
                question: question.to_owned(),
                target,
                value: None,
                path: path.clone(),
                line,
                func: String::new(),
                operands: Vec::new(),
                inside: None,
                traced: false,
            });
        }
    }
    out
}

/// A link as the card's JSON (`debug/origin`'s event).
pub fn link_json(l: &Link) -> Value {
    serde_json::to_value(l).unwrap_or(Value::Null)
}

/// The trail card's rows (docs/develop/hub.md "Rows"): a head (the question, the run and stop, what it does now), the
/// note when the links are only candidates, then a row per link, indented by level, its index as
/// `drgnx-debug-origin-link` (the editor opens it as a past stop).
pub fn rows(state: &Value) -> Vec<drgnx_rows::Row> {
    use drgnx_rows::RowBuilder;
    use serde_json::json;
    let mut out = Vec::new();
    let mut head = RowBuilder::new("head");
    head.push("Where did ", Some("drgnx-debug-timeline-head"));
    head.push(
        state["expr"].as_str().unwrap_or_default(),
        Some("drgnx-debug-probe"),
    );
    head.push(" come from?", Some("drgnx-debug-timeline-head"));
    let doing = match state["state"].as_str().unwrap_or_default() {
        "tracing" => format!("replaying, level {}", state["level"].as_u64().unwrap_or(1)),
        "done" => "done".to_owned(),
        "failed" => "failed".to_owned(),
        s => s.to_owned(),
    };
    head.push(
        &format!(
            " · run {}, stop {} · {doing}",
            state["n"].as_u64().unwrap_or(0),
            state["stop"].as_u64().unwrap_or(0)
        ),
        Some("drgnx-debug-timeline-dim"),
    );
    out.push(head.finish());
    if let Some(n) = state["note"].as_str() {
        let mut r = RowBuilder::new("note");
        r.push(n, Some("drgnx-status-warn"));
        out.push(r.finish());
    }
    if let Some(w) = state["why"].as_str() {
        let mut r = RowBuilder::new("why");
        r.push(w, Some("drgnx-status-fail"));
        out.push(r.finish());
    }
    let links = state["links"].as_array().cloned().unwrap_or_default();
    if links.is_empty() && state["state"] == "done" {
        let mut r = RowBuilder::new("none");
        r.push(
            "No store to it before this stop was found",
            Some("drgnx-debug-timeline-dim"),
        );
        out.push(r.finish());
    }
    for (i, l) in links.iter().enumerate() {
        let level = l["level"].as_u64().unwrap_or(1).max(1) as usize;
        let mut r = RowBuilder::new(format!("link:{i}"));
        r.push(&"  ".repeat(level - 1), None);
        r.push("← ", Some("drgnx-debug-timeline-dim"));
        let target = l["target"].as_str().unwrap_or_default();
        match (l["inside"].as_str(), l["value"].as_str()) {
            (Some(inside), v) => {
                r.push(target, Some("drgnx-debug-timeline-head"));
                r.push(&format!(" changed inside {inside}"), None);
                if let Some(v) = v {
                    r.push(&format!(" → {v}"), Some("drgnx-debug-probe-values"));
                }
            }
            (None, Some(v)) => {
                r.push(target, Some("drgnx-debug-timeline-head"));
                r.push(&format!(" = {v}"), Some("drgnx-debug-probe-values"));
            }
            (None, None) => {
                r.push(target, Some("drgnx-debug-timeline-head"));
            }
        }
        let ops: Vec<String> = l["operands"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|p| Some(format!("{} {}", p[0].as_str()?, p[1].as_str()?)))
            .collect();
        if !ops.is_empty() {
            r.push(
                &format!("  ({})", ops.join(", ")),
                Some("drgnx-debug-timeline-dim"),
            );
        }
        let file = l["path"]
            .as_str()
            .unwrap_or_default()
            .rsplit('/')
            .next()
            .unwrap_or_default();
        r.push(
            &format!("  {file} {}", l["line"]),
            Some("drgnx-debug-timeline-dim"),
        );
        if l["traced"] == false {
            r.push("  candidate", Some("drgnx-status-warn"));
        }
        let end = r.pos();
        r.prop(0, end, "drgnx-debug-origin-link", json!(i));
        r.prop(0, end, "help-echo", json!("open this moment as it ran"));
        out.push(r.finish());
    }
    out
}

#[cfg(test)]
mod pack_tests {
    use super::*;
    use hrafn::Lang;

    #[test]
    fn the_extensions_and_declarations_are_the_ones_trails_had() {
        for (path, lang) in [
            ("a.py", Lang::Python),
            ("a.js", Lang::JavaScript),
            ("a.mjs", Lang::JavaScript),
            ("a.cjs", Lang::JavaScript),
            ("a.jsx", Lang::JavaScript),
            ("a.ts", Lang::TypeScript),
            ("a.mts", Lang::TypeScript),
            ("a.cts", Lang::TypeScript),
            ("a.tsx", Lang::Tsx),
            ("a.go", Lang::Go),
            ("a.c", Lang::C),
            ("a.h", Lang::C),
            ("a.cc", Lang::Cpp),
            ("a.cpp", Lang::Cpp),
            ("a.hpp", Lang::Cpp),
            ("a.rs", Lang::Rust),
            ("a.java", Lang::Java),
            ("A.cs", Lang::Csharp),
        ] {
            assert_eq!(lang_of(path), Some(lang), "{path}");
        }
        // shell, Lisp, Org and unknown files are not traced
        for path in ["a.sh", "a.el", "a.org", "a.md", "a.txt", "noext", "a.rb"] {
            assert_eq!(lang_of(path), None, "{path}");
        }
        assert_eq!(
            decls_of(Lang::Go),
            ["{t} := $V", "var {t} = $V", "var {t} $TY = $V"]
        );
        assert_eq!(
            decls_of(Lang::Rust),
            ["let {t} = $V;", "let mut {t} = $V;", "let {t}: $TY = $V;"]
        );
        assert_eq!(decls_of(Lang::C), ["$TY {t} = $V;"]);
        assert_eq!(decls_of(Lang::Cpp), ["$TY {t} = $V;"]);
        assert_eq!(decls_of(Lang::Java), ["$TY {t} = $V;"]);
        assert_eq!(decls_of(Lang::Csharp), ["$TY {t} = $V;"]);
        assert_eq!(
            decls_of(Lang::TypeScript),
            ["const {t} = $V", "let {t} = $V", "var {t} = $V"]
        );
        assert!(decls_of(Lang::Python).is_empty());
    }
}
