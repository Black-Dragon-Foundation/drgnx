//! The job pack: a project's `.drgnx/jobs.toml` (docs/guide/job-packs.md). Pure: it reads text, never a file.
//!
//! - **Stages** (`[[stage]]`) and **artifacts** (`[[artifact]]`) share their fields ([`FIELDS`]); an artifact adds
//!   `kind`, `keep` and `retain`. A stage word is any word: nothing here names a language, a tool or a project.
//! - **Toolchains** (`[toolchains.NAME]`) are an image by digest or an image artifact; **caches** (`[caches.NAME]`) are
//!   named, runner-side folders; **pipelines** (`[pipelines]`) are lists of stages; **`[gate]`** names the stages that
//!   make a tree green; **`[defaults]`** fills stage fields an entry leaves out.
//! - **Refusals point at file and line.** An unknown key, a timebox without its `why`, a field the product does not
//!   build yet (they say "not built yet (after launch)"), an unknown placeholder, a stage a pipeline or the gate names
//!   but the pack does not have.
//! - [`JobPack::resolve`] gives an entry as the key reads it: the defaults merged under it, its toolchain and caches
//!   inlined (`forseti::artifact`).

use std::ops::Range;

use forseti::Canon;
use toml_edit::{Document, Item, TableLike, Value};

/// The pack's file in a tree.
pub const FILE: &str = ".drgnx/jobs.toml";

/// The schema version this reader knows.
pub const VERSION: i64 = 1;

/// Every field of a stage, an artifact, a toolchain or a cache (TOML names): `forseti::artifact::FIELDS`, the list the
/// key's property row walks, so a field is added in one place.
pub use forseti::artifact::FIELDS;

/// The row parsers a stage may name (`sleipnir::linux::parse::PARSERS`; a hub row keeps the two equal). `regex` takes
/// its pattern after a `:`.
pub const PARSERS: [&str; 6] = ["exit", "regex", "tap", "junit", "libtest", "libtest-json"];

const TOP: &[&str] = &[
    "jobs",
    "project",
    "toolchains",
    "caches",
    "stage",
    "artifact",
    "pipelines",
    "gate",
    "defaults",
    "policy-files",
];
const STAGE_ONLY: &[&str] = &["host", "split", "preset"];
const ARTIFACT_ONLY: &[&str] = &["kind", "keep", "retain"];
const TOOLCHAIN: &[&str] = &["image", "env"];
const CACHE: &[&str] = &["kind", "env", "sharing", "budget-gib"];
const EXPECT: &[&str] = &["min-ran", "max-skipped"];
const GATE: &[&str] = &["stages", "max-age"];
/// Keys the product does not build yet: a pack that sets one is refused, saying so. (`flaky`, `recheck`, `kind`,
/// `parser`, `os` and `expect` have values that stay allowed; those are checked in place.)
const RESERVED: &[&str] = &["matrix", "matrices", "sync", "sparse", "shards", "bisect"];
const LATER: &str = "is not built yet (after launch)";

/// One refusal: where, and why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LintError {
    pub file: String,
    pub line: u32,
    pub msg: String,
}

impl std::fmt::Display for LintError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}:{}: {}", self.file, self.line, self.msg)
    }
}

/// How a stage weighs on the machine (memory and IO admission); never part of a key.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Class {
    Light,
    #[default]
    Normal,
    IoHeavy,
}

impl Class {
    fn parse(s: &str) -> Option<Class> {
        match s {
            "light" => Some(Class::Light),
            "normal" => Some(Class::Normal),
            "io-heavy" => Some(Class::IoHeavy),
            _ => None,
        }
    }
}

/// Where a toolchain's image comes from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ImageSrc {
    /// `name@sha256:…`: by digest, always (the runner's allow-list decides whether it may be pulled).
    Ref(String),
    /// An `image` artifact of the pack, built from the tree's Containerfile.
    Artifact(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Toolchain {
    pub name: String,
    pub image: ImageSrc,
    pub env: Vec<(String, String)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CacheDef {
    pub name: String,
    /// `compiler`, `packages` or `other`.
    pub kind: Option<String>,
    pub env: Vec<(String, String)>,
}

/// A use of an artifact: `ro` (mounted read-only), `seed` (copied into an empty build folder), `image` (the job's image)
/// or `toolchain`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Use {
    pub artifact: String,
    pub how: String,
}

/// A stage or an artifact: the typed fields the hub reads, and the whole entry as data under TOML's names (`raw`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    /// `command` or `image` for an artifact; none for a stage.
    pub kind: Option<String>,
    pub toolchain: Option<String>,
    pub caches: Vec<String>,
    pub uses: Vec<Use>,
    pub needs: Vec<String>,
    pub class: Class,
    pub host: bool,
    pub preset: Option<String>,
    pub inputs: Vec<String>,
    pub key_ignore: Vec<String>,
    pub outputs: Vec<String>,
    pub split: Option<String>,
    pub parser: Option<String>,
    pub select: Option<String>,
    /// The entry as the file wrote it.
    pub raw: Canon,
    /// The line it starts on.
    pub line: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pipeline {
    pub name: String,
    pub stages: Vec<String>,
}

/// `[gate]`: what "green" means.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Gate {
    pub stages: Vec<String>,
    /// `(stage, seconds)`: a record older than this counts as missing.
    pub max_age: Vec<(String, u64)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JobPack {
    pub version: i64,
    pub project: String,
    pub toolchains: Vec<Toolchain>,
    pub caches: Vec<CacheDef>,
    pub artifacts: Vec<Entry>,
    pub stages: Vec<Entry>,
    pub pipelines: Vec<Pipeline>,
    pub gate: Option<Gate>,
    /// `[defaults]`: the stage fields an entry leaves out.
    pub defaults: Canon,
    pub policy_files: Vec<String>,
    /// The entries an overlay replaced (stage and artifact names), for `jobs pack show`.
    pub replaced: Vec<String>,
}

struct Cx<'a> {
    file: &'a str,
    text: &'a str,
    errs: Vec<LintError>,
}

impl Cx<'_> {
    fn line(&self, span: Option<Range<usize>>) -> u32 {
        let at = span.map_or(0, |s| s.start).min(self.text.len());
        1 + self.text.as_bytes()[..at]
            .iter()
            .filter(|b| **b == b'\n')
            .count() as u32
    }

    fn err(&mut self, span: Option<Range<usize>>, msg: impl Into<String>) {
        let line = self.line(span);
        self.errs.push(LintError {
            file: self.file.to_string(),
            line,
            msg: msg.into(),
        });
    }

    /// The keys of T that LIST does not allow (reserved ones say so), each at its own line.
    fn keys(&mut self, t: &dyn TableLike, allowed: &[&[&str]], what: &str) {
        for (k, _) in t.iter() {
            if allowed.iter().any(|a| a.contains(&k)) {
                continue;
            }
            let span = t.get_key_value(k).and_then(|(key, _)| key.span());
            if RESERVED.contains(&k) {
                self.err(span, format!("`{k}` {LATER}"));
            } else {
                self.err(span, format!("unknown key `{k}` in {what}"));
            }
        }
    }
}

fn str_of(item: &Item) -> Option<&str> {
    item.as_str()
}

fn value_canon(cx: &mut Cx, v: &Value) -> Option<Canon> {
    Some(match v {
        Value::String(s) => Canon::Str(s.value().clone()),
        Value::Integer(n) => Canon::Int(*n.value()),
        Value::Boolean(b) => Canon::Bool(*b.value()),
        Value::Array(a) => Canon::List(a.iter().filter_map(|x| value_canon(cx, x)).collect()),
        Value::InlineTable(t) => like_canon(cx, t),
        Value::Float(_) | Value::Datetime(_) => {
            cx.err(
                v.span(),
                "a pack holds strings, integers, booleans, lists and tables only",
            );
            return None;
        }
    })
}

fn like_canon(cx: &mut Cx, t: &dyn TableLike) -> Canon {
    Canon::Plist(
        t.iter()
            .filter_map(|(k, v)| item_canon(cx, v).map(|c| (k.to_string(), c)))
            .collect(),
    )
}

fn item_canon(cx: &mut Cx, item: &Item) -> Option<Canon> {
    match item {
        Item::Value(v) => value_canon(cx, v),
        Item::Table(t) => Some(like_canon(cx, t)),
        Item::ArrayOfTables(a) => Some(Canon::List(a.iter().map(|t| like_canon(cx, t)).collect())),
        Item::None => None,
    }
}

fn strings(cx: &mut Cx, item: &Item, what: &str) -> Vec<String> {
    match item.as_array() {
        Some(a) => a
            .iter()
            .filter_map(|v| match v.as_str() {
                Some(s) => Some(s.to_string()),
                None => {
                    cx.err(v.span(), format!("`{what}` holds strings"));
                    None
                }
            })
            .collect(),
        None => {
            cx.err(item.span(), format!("`{what}` is a list of strings"));
            vec![]
        }
    }
}

fn env_pairs(cx: &mut Cx, item: &Item, what: &str) -> Vec<(String, String)> {
    let Some(t) = item.as_table_like() else {
        cx.err(
            item.span(),
            format!("`{what}` is a table of NAME = \"value\""),
        );
        return vec![];
    };
    let mut out = vec![];
    for (k, v) in t.iter() {
        match v.as_str() {
            Some(s) => {
                placeholders(cx, v.span(), s, true);
                out.push((k.to_string(), s.to_string()));
            }
            None => cx.err(v.span(), format!("`{what}.{k}` is a string")),
        }
    }
    out
}

/// A `{name}` in S that the pack may not use: unknown names are refused, the ones that ship later say so. `{key:NAME}`
/// is allowed only where KEYS_OK (an `env` value). `${…}` and text that is no placeholder (`{ }`, `{1,2}`) pass.
fn placeholders(cx: &mut Cx, span: Option<Range<usize>>, s: &str, keys_ok: bool) {
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'{'
            && (i == 0 || b[i - 1] != b'$')
            && let Some(end) = s[i + 1..].find('}')
        {
            let name = &s[i + 1..i + 1 + end];
            let word = name.bytes().next().is_some_and(|c| c.is_ascii_lowercase())
                && name
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b':' | b'_' | b'-'));
            if word {
                let head = name.split([':', '.']).next().unwrap_or("");
                match head {
                    "rows" | "src" | "out" | "build" | "jobs" | "deadline" | "island" => {}
                    "art" | "cache" if name.contains(':') => {}
                    "key" if name.contains(':') && keys_ok => {}
                    "key" => cx.err(span.clone(), "`{key:NAME}` is allowed only in `env`"),
                    "cell" | "shard" | "shards" | "input" => {
                        cx.err(span.clone(), format!("`{{{name}}}` {LATER}"))
                    }
                    _ => cx.err(span.clone(), format!("unknown placeholder `{{{name}}}`")),
                }
            }
            i += end + 2;
            continue;
        }
        i += 1;
    }
}

fn digest_ok(image: &str) -> bool {
    image.rsplit_once("@sha256:").is_some_and(|(n, d)| {
        !n.is_empty() && d.len() == 64 && d.bytes().all(|b| b.is_ascii_hexdigit())
    })
}

fn duration_secs(s: &str) -> Option<u64> {
    let (n, unit) = s.split_at(s.len().checked_sub(1)?);
    let n: u64 = n.parse().ok()?;
    Some(
        n * match unit {
            "s" => 1,
            "m" => 60,
            "h" => 3600,
            "d" => 86400,
            _ => return None,
        },
    )
}

fn toolchain(cx: &mut Cx, name: &str, item: &Item) -> Option<Toolchain> {
    let t = item.as_table_like()?;
    for (k, _) in t.iter() {
        if k == "host-mise" || k == "host_mise" || k == "macos" {
            let span = t.get_key_value(k).and_then(|(key, _)| key.span());
            cx.err(
                span,
                format!("`{k}` is refused: a toolchain is an image by digest or an image artifact"),
            );
        }
    }
    cx.keys(
        t,
        &[TOOLCHAIN, &["host-mise", "host_mise", "macos"]],
        "a toolchain",
    );
    let image = match t.get("image") {
        Some(i) => match (i.as_str(), i.as_table_like()) {
            (Some(s), _) if digest_ok(s) => Some(ImageSrc::Ref(s.to_string())),
            (Some(s), _) => {
                cx.err(
                    i.span(),
                    format!("the image `{s}` must carry a digest (name@sha256:…)"),
                );
                None
            }
            (None, Some(t)) => match t.get("artifact").and_then(str_of) {
                Some(a) => Some(ImageSrc::Artifact(a.to_string())),
                None => {
                    cx.err(
                        i.span(),
                        "an image table names its artifact: { artifact = \"NAME\" }",
                    );
                    None
                }
            },
            _ => {
                cx.err(
                    i.span(),
                    "`image` is a reference with a digest, or { artifact = \"NAME\" }",
                );
                None
            }
        },
        None => {
            cx.err(
                item.span(),
                format!("the toolchain `{name}` has no `image`"),
            );
            None
        }
    }?;
    let env = t
        .get("env")
        .map(|e| env_pairs(cx, e, "env"))
        .unwrap_or_default();
    Some(Toolchain {
        name: name.to_string(),
        image,
        env,
    })
}

fn cache(cx: &mut Cx, name: &str, item: &Item) -> Option<CacheDef> {
    let t = item.as_table_like()?;
    cx.keys(t, &[CACHE], "a cache");
    let env = t
        .get("env")
        .map(|e| env_pairs(cx, e, "env"))
        .unwrap_or_default();
    Some(CacheDef {
        name: name.to_string(),
        kind: t.get("kind").and_then(str_of).map(String::from),
        env,
    })
}

fn entry(
    cx: &mut Cx,
    t: &dyn TableLike,
    span: Option<Range<usize>>,
    artifact: bool,
) -> Option<Entry> {
    let what = if artifact { "an artifact" } else { "a stage" };
    let extra: &[&str] = if artifact { ARTIFACT_ONLY } else { STAGE_ONLY };
    // the fields a stage or an artifact has: the schema's, less what belongs to toolchains and caches alone
    let own: Vec<&str> = FIELDS
        .iter()
        .copied()
        .filter(|f| {
            !matches!(
                *f,
                "image"
                    | "setup-image"
                    | "sharing"
                    | "budget-gib"
                    | "image-digest"
                    | "path"
                    | "kind"
                    | "keep"
                    | "retain"
            )
        })
        .collect();
    cx.keys(t, &[&own, extra, &["flaky", "recheck"]], what);
    let line_of = |k: &str, t: &dyn TableLike| t.get_key_value(k).and_then(|(key, _)| key.span());
    let Some(name) = t.get("name").and_then(str_of) else {
        cx.err(span, format!("{what} needs a `name`"));
        return None;
    };
    let name = name.to_string();
    // reserved values: flaky other than hold, recheck other than 0, kind fetch, a parser ktap, os macos
    if let Some(v) = t.get("flaky").and_then(str_of)
        && v == "hold"
    {
        // allowed
    } else if t.get("flaky").is_some() {
        cx.err(line_of("flaky", t), format!("`flaky` {LATER}"));
    }
    if t.get("recheck").and_then(|v| v.as_integer()) == Some(0) {
        // allowed
    } else if t.get("recheck").is_some() {
        cx.err(line_of("recheck", t), format!("`recheck` {LATER}"));
    }
    let kind = t.get("kind").and_then(str_of).map(String::from);
    if let Some(k) = &kind {
        match k.as_str() {
            "command" | "image" => {}
            "fetch" => cx.err(line_of("kind", t), format!("`kind = \"fetch\"` {LATER}")),
            other => cx.err(
                line_of("kind", t),
                format!("unknown artifact kind `{other}` (command or image)"),
            ),
        }
    }
    if artifact && kind.is_none() {
        cx.err(
            span.clone(),
            format!("the artifact `{name}` needs a `kind` (command or image)"),
        );
    }
    let parser = t.get("parser").and_then(str_of).map(String::from);
    if let Some(p) = &parser {
        let base = p.split(':').next().unwrap_or("");
        if base == "ktap" {
            cx.err(line_of("parser", t), format!("`parser = \"ktap\"` {LATER}"));
        } else if !PARSERS.contains(&base) {
            cx.err(
                line_of("parser", t),
                format!(
                    "no row parser `{p}` (the parsers are {})",
                    PARSERS.join(", ")
                ),
            );
        }
    }
    let select = t.get("select").and_then(str_of).map(String::from);
    if let Some(s) = &select
        && let Err(e) = forseti::dialect::by_name(s)
    {
        cx.err(line_of("select", t), e.to_string());
    }
    if t.get("os").and_then(str_of) == Some("macos") {
        cx.err(line_of("os", t), format!("`os = \"macos\"` {LATER}"));
    }
    if let Some(e) = t.get("expect") {
        match e.as_table_like() {
            Some(x) => {
                for (k, _) in x.iter() {
                    if k == "log-has" {
                        cx.err(
                            x.get_key_value(k).and_then(|(key, _)| key.span()),
                            format!("`expect.log-has` {LATER}"),
                        );
                    } else if !EXPECT.contains(&k) {
                        cx.err(
                            x.get_key_value(k).and_then(|(key, _)| key.span()),
                            format!("unknown key `{k}` in `expect`"),
                        );
                    }
                }
            }
            None => cx.err(
                e.span(),
                "`expect` is a table: { min-ran = 1, max-skipped = 0 }",
            ),
        }
    }
    // a limit that stops a job needs the reason it is set
    let limits: Vec<&str> = ["timebox", "stall", "silent"]
        .into_iter()
        .filter(|k| t.get(k).is_some())
        .collect();
    if !limits.is_empty()
        && t.get("why")
            .and_then(str_of)
            .is_none_or(|w| w.trim().is_empty())
    {
        cx.err(
            line_of(limits[0], t),
            format!(
                "`{}` needs a `why`: the reason this limit is set",
                limits[0]
            ),
        );
    }
    let class = match t.get("class").and_then(str_of) {
        None => Class::default(),
        Some(c) => Class::parse(c).unwrap_or_else(|| {
            cx.err(
                line_of("class", t),
                format!("`class` is light, normal or io-heavy, not `{c}`"),
            );
            Class::default()
        }),
    };
    // steps and run hold placeholders; so do dir and env
    for k in ["run", "steps", "dir"] {
        if let Some(v) = t.get(k) {
            let mut all = vec![];
            collect_strings(v, &mut all);
            for s in all {
                placeholders(cx, v.span(), &s, false);
            }
        }
    }
    let env_item = t.get("env");
    if let Some(e) = env_item {
        env_pairs(cx, e, "env");
    }
    let uses = match t.get("uses") {
        Some(u) => uses_of(cx, u),
        None => vec![],
    };
    let list = |cx: &mut Cx, k: &str| t.get(k).map(|i| strings(cx, i, k)).unwrap_or_default();
    let inputs = list(cx, "inputs");
    for i in &inputs {
        let u = i.trim_start_matches('!');
        if u.starts_with("git+") || u.starts_with("git@") || u.contains("://") {
            cx.err(
                line_of("inputs", t),
                format!("an input that is a git URL {LATER}"),
            );
        }
    }
    let e = Entry {
        name,
        kind,
        toolchain: t.get("toolchain").and_then(str_of).map(String::from),
        caches: list(cx, "caches"),
        uses,
        needs: list(cx, "needs"),
        class,
        host: t.get("host").and_then(|h| h.as_bool()).unwrap_or(false),
        preset: t.get("preset").and_then(str_of).map(String::from),
        inputs,
        key_ignore: list(cx, "key-ignore"),
        outputs: list(cx, "outputs"),
        split: t.get("split").and_then(str_of).map(String::from),
        parser,
        select,
        raw: like_canon(cx, t),
        line: cx.line(span),
    };
    if e.host && e.toolchain.is_some() {
        cx.err(
            line_of("host", t),
            "`host = true` runs outside a container: it takes no `toolchain`",
        );
    }
    if let Some(s) = &e.split
        && s != "units"
    {
        cx.err(
            line_of("split", t),
            format!("`split` is \"units\", not `{s}`"),
        );
    }
    Some(e)
}

fn collect_strings(item: &Item, out: &mut Vec<String>) {
    if let Item::Value(v) = item {
        collect_value(v, out);
    }
}

fn collect_value(v: &Value, out: &mut Vec<String>) {
    match v {
        Value::String(s) => out.push(s.value().clone()),
        Value::Array(a) => a.iter().for_each(|x| collect_value(x, out)),
        _ => {}
    }
}

fn uses_of(cx: &mut Cx, item: &Item) -> Vec<Use> {
    let Some(arr) = item.as_array() else {
        cx.err(
            item.span(),
            "`uses` is a list of { artifact = \"NAME\", use = \"ro\" }",
        );
        return vec![];
    };
    let mut out = vec![];
    for v in arr.iter() {
        let (artifact, how) = match v {
            Value::String(s) => (Some(s.value().as_str()), Some("ro")),
            Value::InlineTable(t) => (
                t.get("artifact").and_then(|a| a.as_str()),
                Some(t.get("use").and_then(|a| a.as_str()).unwrap_or("ro")),
            ),
            _ => (None, None),
        };
        match (artifact, how) {
            (Some(a), Some(h @ ("ro" | "seed" | "image" | "toolchain"))) => out.push(Use {
                artifact: a.to_string(),
                how: h.to_string(),
            }),
            (Some(_), Some(h)) => cx.err(
                v.span(),
                format!("`use` is ro, seed, image or toolchain, not `{h}`"),
            ),
            _ => cx.err(v.span(), "a use is { artifact = \"NAME\", use = \"ro\" }"),
        }
    }
    out
}

/// Reads TEXT (FILE's content): the pack, or every refusal with its line.
pub fn load(text: &str, file: &str) -> Result<JobPack, Vec<LintError>> {
    let mut cx = Cx {
        file,
        text,
        errs: vec![],
    };
    let doc = match Document::parse(text.to_string()) {
        Ok(d) => d,
        Err(e) => {
            cx.err(e.span(), e.message().to_string());
            return Err(cx.errs);
        }
    };
    let root = doc.as_table();
    cx.keys(root, &[TOP], "the pack");
    let version = root.get("jobs").and_then(|v| v.as_integer());
    if version != Some(VERSION) {
        cx.err(
            root.get("jobs").and_then(|v| v.span()),
            format!("`jobs = {VERSION}` (the schema version) is the pack's first line"),
        );
    }
    let project = root
        .get("project")
        .and_then(str_of)
        .unwrap_or("")
        .to_string();
    if project.is_empty() {
        cx.err(None, "the pack needs `project`");
    }
    let mut toolchains = vec![];
    if let Some(ts) = root.get("toolchains").and_then(|t| t.as_table_like()) {
        for (n, it) in ts.iter() {
            toolchains.extend(toolchain(&mut cx, n, it));
        }
    }
    let mut caches = vec![];
    if let Some(cs) = root.get("caches").and_then(|t| t.as_table_like()) {
        for (n, it) in cs.iter() {
            caches.extend(cache(&mut cx, n, it));
        }
    }
    let read = |cx: &mut Cx, key: &str, artifact: bool| -> Vec<Entry> {
        let mut out = vec![];
        let Some(item) = root.get(key) else {
            return out;
        };
        let tables: Vec<(&dyn TableLike, Option<Range<usize>>)> = match item {
            Item::ArrayOfTables(a) => a.iter().map(|t| (t as &dyn TableLike, t.span())).collect(),
            Item::Value(Value::Array(a)) => a
                .iter()
                .filter_map(|v| match v {
                    Value::InlineTable(t) => Some((t as &dyn TableLike, v.span())),
                    _ => None,
                })
                .collect(),
            _ => {
                cx.err(
                    item.span(),
                    format!("`{key}` is a list of tables: [[{key}]]"),
                );
                vec![]
            }
        };
        for (t, span) in tables {
            out.extend(entry(cx, t, span, artifact));
        }
        out
    };
    let stages = read(&mut cx, "stage", false);
    let artifacts = read(&mut cx, "artifact", true);
    let mut seen: Vec<&str> = vec![];
    for e in stages.iter().chain(&artifacts) {
        if seen.contains(&e.name.as_str()) {
            cx.errs.push(LintError {
                file: file.to_string(),
                line: e.line,
                msg: format!("the name `{}` is used twice", e.name),
            });
        }
        seen.push(&e.name);
    }
    let mut pipelines = vec![];
    if let Some(p) = root.get("pipelines").and_then(|t| t.as_table_like()) {
        for (n, it) in p.iter() {
            pipelines.push(Pipeline {
                name: n.to_string(),
                stages: strings(&mut cx, it, n),
            });
        }
    }
    let mut gate = None;
    if let Some(g) = root.get("gate").and_then(|t| t.as_table_like()) {
        cx.keys(g, &[GATE], "`[gate]`");
        let mut ga = Gate::default();
        if let Some(s) = g.get("stages") {
            ga.stages = strings(&mut cx, s, "stages");
        }
        if let Some(m) = g.get("max-age").and_then(|m| m.as_table_like()) {
            for (k, v) in m.iter() {
                match v.as_str().and_then(duration_secs) {
                    Some(s) => ga.max_age.push((k.to_string(), s)),
                    None => cx.err(
                        v.span(),
                        format!("`max-age.{k}` is a duration like 24h, 90m, 7d"),
                    ),
                }
            }
        }
        gate = Some(ga);
    }
    let defaults = match root.get("defaults") {
        Some(d) => {
            if let Some(t) = d.as_table_like() {
                let own: Vec<&str> = FIELDS.to_vec();
                cx.keys(t, &[&own, STAGE_ONLY], "`[defaults]`");
            }
            item_canon(&mut cx, d).unwrap_or(Canon::Plist(vec![]))
        }
        None => Canon::Plist(vec![]),
    };
    let policy_files = root
        .get("policy-files")
        .map(|p| strings(&mut cx, p, "policy-files"))
        .unwrap_or_default();
    let pack = JobPack {
        version: version.unwrap_or(0),
        project,
        toolchains,
        caches,
        artifacts,
        stages,
        pipelines,
        gate,
        defaults,
        policy_files,
        replaced: vec![],
    };
    pack.check_refs(&mut cx);
    if cx.errs.is_empty() {
        Ok(pack)
    } else {
        Err(cx.errs)
    }
}

/// The refusals of TEXT, if any.
pub fn lint(text: &str, file: &str) -> Vec<LintError> {
    load(text, file).err().unwrap_or_default()
}

impl JobPack {
    /// Every name an entry, a pipeline or the gate mentions exists.
    fn check_refs(&self, cx: &mut Cx) {
        let has_stage = |n: &str| self.stages.iter().any(|s| s.name == n);
        let has_artifact = |n: &str| self.artifacts.iter().any(|s| s.name == n);
        let has_entry = |n: &str| has_stage(n) || has_artifact(n);
        let mut bad = |line: u32, msg: String| {
            cx.errs.push(LintError {
                file: cx.file.to_string(),
                line,
                msg,
            })
        };
        for e in self.stages.iter().chain(&self.artifacts) {
            if let Some(t) = &e.toolchain
                && !self.toolchains.iter().any(|x| &x.name == t)
            {
                bad(
                    e.line,
                    format!(
                        "`{}` names the toolchain `{t}`, which the pack does not declare",
                        e.name
                    ),
                );
            }
            for c in &e.caches {
                if !self.caches.iter().any(|x| &x.name == c) {
                    bad(
                        e.line,
                        format!(
                            "`{}` names the cache `{c}`, which the pack does not declare",
                            e.name
                        ),
                    );
                }
            }
            for n in &e.needs {
                if !has_entry(n) {
                    bad(
                        e.line,
                        format!("`{}` needs `{n}`, which the pack does not have", e.name),
                    );
                }
            }
            for u in &e.uses {
                if !has_artifact(&u.artifact) {
                    bad(
                        e.line,
                        format!(
                            "`{}` uses the artifact `{}`, which the pack does not have",
                            e.name, u.artifact
                        ),
                    );
                }
            }
        }
        for t in &self.toolchains {
            if let ImageSrc::Artifact(a) = &t.image
                && !self
                    .artifacts
                    .iter()
                    .any(|x| &x.name == a && x.kind.as_deref() == Some("image"))
            {
                bad(
                    1,
                    format!(
                        "the toolchain `{}` names the image artifact `{a}`, which the pack does not have",
                        t.name
                    ),
                );
            }
        }
        for p in &self.pipelines {
            for s in &p.stages {
                if !has_stage(s) {
                    bad(
                        1,
                        format!(
                            "the pipeline `{}` names the stage `{s}`, which the pack does not have",
                            p.name
                        ),
                    );
                }
            }
        }
        if let Some(g) = &self.gate {
            for s in g.stages.iter().chain(g.max_age.iter().map(|(s, _)| s)) {
                if !has_stage(s) {
                    bad(
                        1,
                        format!("`[gate]` names the stage `{s}`, which the pack does not have"),
                    );
                }
            }
        }
    }

    /// The stage or artifact NAME.
    pub fn entry(&self, name: &str) -> Option<&Entry> {
        self.stages
            .iter()
            .chain(&self.artifacts)
            .find(|e| e.name == name)
    }

    /// NAME as a key and a job read it: `[defaults]` merged under it (a table merges key by key, the entry wins), its
    /// toolchain and caches inlined as tables under `toolchain` and `caches`.
    pub fn resolve(&self, name: &str) -> villa::Result<Canon> {
        let e = self.entry(name).ok_or_else(|| {
            villa::Error::not_found(format!("the pack has no stage or artifact `{name}`"))
        })?;
        let mut kv = merge(&self.defaults, &e.raw);
        if let Some(t) = &e.toolchain {
            let tc = self
                .toolchains
                .iter()
                .find(|x| &x.name == t)
                .ok_or_else(|| {
                    villa::Error::invalid(format!("the toolchain `{t}` is not declared"))
                })?;
            set(&mut kv, "toolchain", toolchain_canon(tc));
        }
        if !e.caches.is_empty() {
            let mut list = vec![];
            for c in &e.caches {
                let def = self.caches.iter().find(|x| &x.name == c).ok_or_else(|| {
                    villa::Error::invalid(format!("the cache `{c}` is not declared"))
                })?;
                list.push(cache_canon(def));
            }
            set(&mut kv, "caches", Canon::List(list));
        }
        Ok(Canon::Plist(kv))
    }
}

fn set(kv: &mut Vec<(String, Canon)>, key: &str, v: Canon) {
    match kv.iter_mut().find(|(k, _)| k == key) {
        Some(slot) => slot.1 = v,
        None => kv.push((key.to_string(), v)),
    }
}

/// DEFAULTS under ENTRY: the entry's keys win; two tables merge key by key.
fn merge(defaults: &Canon, entry: &Canon) -> Vec<(String, Canon)> {
    let (Canon::Plist(d), Canon::Plist(e)) = (defaults, entry) else {
        return vec![];
    };
    let mut out: Vec<(String, Canon)> = d
        .iter()
        // `name`, `kind`, `toolchain` and a table's own identity never default
        .filter(|(k, _)| !e.iter().any(|(ek, _)| ek == k) && k != "name")
        .cloned()
        .collect();
    for (k, v) in e {
        match (d.iter().find(|(dk, _)| dk == k), v) {
            (Some((_, dv @ Canon::Plist(_))), Canon::Plist(_)) => {
                out.push((k.clone(), Canon::Plist(merge(dv, v))))
            }
            _ => out.push((k.clone(), v.clone())),
        }
    }
    out
}

fn toolchain_canon(t: &Toolchain) -> Canon {
    let image = match &t.image {
        ImageSrc::Ref(r) => Canon::Str(r.clone()),
        ImageSrc::Artifact(a) => Canon::Plist(vec![("artifact".into(), Canon::Str(a.clone()))]),
    };
    let mut kv = vec![
        ("name".to_string(), Canon::Str(t.name.clone())),
        ("image".to_string(), image),
    ];
    if !t.env.is_empty() {
        kv.push(("env".into(), pairs(&t.env)));
    }
    Canon::Plist(kv)
}

fn cache_canon(c: &CacheDef) -> Canon {
    let mut kv = vec![("name".to_string(), Canon::Str(c.name.clone()))];
    if let Some(k) = &c.kind {
        kv.push(("kind".into(), Canon::Str(k.clone())));
    }
    if !c.env.is_empty() {
        kv.push(("env".into(), pairs(&c.env)));
    }
    Canon::Plist(kv)
}

fn pairs(p: &[(String, String)]) -> Canon {
    Canon::Plist(
        p.iter()
            .map(|(k, v)| (k.clone(), Canon::Str(v.clone())))
            .collect(),
    )
}

/// The pack of the repo with the OVERLAY's entries added; an overlay entry of an existing name replaces it and is listed
/// in `replaced`. The overlay's project name, version and gate never override the repo's.
pub fn merge_overlay(repo: JobPack, overlay: JobPack) -> JobPack {
    let mut out = repo;
    fn put<T: Clone>(
        list: &mut Vec<T>,
        new: &[T],
        name: impl Fn(&T) -> &str,
        replaced: &mut Vec<String>,
        mark: bool,
    ) {
        for n in new {
            match list.iter().position(|x| name(x) == name(n)) {
                Some(i) => {
                    if mark {
                        replaced.push(name(n).to_string());
                    }
                    list[i] = n.clone();
                }
                None => list.push(n.clone()),
            }
        }
    }
    let mut replaced = std::mem::take(&mut out.replaced);
    put(
        &mut out.stages,
        &overlay.stages,
        |e| &e.name,
        &mut replaced,
        true,
    );
    put(
        &mut out.artifacts,
        &overlay.artifacts,
        |e| &e.name,
        &mut replaced,
        true,
    );
    put(
        &mut out.toolchains,
        &overlay.toolchains,
        |t| &t.name,
        &mut replaced,
        true,
    );
    put(
        &mut out.caches,
        &overlay.caches,
        |c| &c.name,
        &mut replaced,
        true,
    );
    put(
        &mut out.pipelines,
        &overlay.pipelines,
        |p| &p.name,
        &mut replaced,
        true,
    );
    let more: Vec<String> = overlay
        .policy_files
        .iter()
        .filter(|p| !out.policy_files.contains(p))
        .cloned()
        .collect();
    out.policy_files.extend(more);
    out.replaced = replaced;
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const D: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    /// The acceptance pack P1: a small C project with an artifact and two stages.
    fn hello_c() -> String {
        format!(
            r#"jobs = 1
project = "hello-c"

[toolchains.gcc]
image = "registry.fedoraproject.org/fedora:45@sha256:{D}"

[caches.ccache]
kind = "compiler"
sharing = "shared"
budget-gib = 2
env = {{ CCACHE_DIR = "{{cache:ccache}}", CCACHE_BASEDIR = "{{src}}" }}

[[artifact]]
name = "build"
kind = "command"
toolchain = "gcc"
caches = ["ccache"]
inputs = ["src/**", "include/**", "Makefile"]
steps = [["make", "-C", "{{src}}", "O={{build}}", "-j{{jobs}}", "CC=ccache gcc"]]
keep = {{ from = "{{build}}", paths = ["test-runner", "fuzz"] }}
mem = [256, 2048]
disk-gib = 1

[[stage]]
name = "unit"
uses = [{{ artifact = "build", use = "ro" }}]
toolchain = "gcc"
run = ["{{art:build}}/test-runner", "--tap"]
parser = "tap"
expect = {{ min-ran = 1 }}
mem = [128, 512]
light = true

[[stage]]
name = "fuzz-smoke"
uses = [{{ artifact = "build", use = "ro" }}]
toolchain = "gcc"
run = ["{{art:build}}/fuzz", "-runs=10000"]
parser = "exit"
timebox = 600
why = "ten thousand runs take about ten minutes on the slowest runner"

[pipelines]
check = ["unit", "fuzz-smoke"]
"#
        )
    }

    fn refused(text: &str) -> Vec<LintError> {
        lint(text, "jobs.toml")
    }

    /// [D] pure
    #[test]
    fn the_hello_c_pack_parses() {
        let p = load(&hello_c(), FILE).unwrap();
        assert_eq!((p.version, p.project.as_str()), (1, "hello-c"));
        assert_eq!(p.toolchains.len(), 1);
        assert!(matches!(&p.toolchains[0].image, ImageSrc::Ref(r) if r.ends_with(D)));
        assert_eq!(p.caches[0].env[0].0, "CCACHE_DIR");
        assert_eq!(p.artifacts[0].kind.as_deref(), Some("command"));
        assert_eq!(p.artifacts[0].caches, ["ccache"]);
        let unit = p.entry("unit").unwrap();
        assert_eq!(unit.parser.as_deref(), Some("tap"));
        assert_eq!(
            unit.uses,
            [Use {
                artifact: "build".into(),
                how: "ro".into()
            }]
        );
        assert_eq!(p.pipelines[0].stages, ["unit", "fuzz-smoke"]);
        // the resolved artifact has its toolchain and cache inlined for the key
        let r = p.resolve("build").unwrap();
        assert!(matches!(r.get("toolchain"), Some(Canon::Plist(_))));
        assert!(matches!(r.get("caches"), Some(Canon::List(l)) if l.len() == 1));
    }

    /// [D] pure
    #[test]
    fn a_limit_without_a_reason_is_refused() {
        let text = hello_c().replace(
            "why = \"ten thousand runs take about ten minutes on the slowest runner\"\n",
            "",
        );
        let e = refused(&text);
        assert_eq!(e.len(), 1, "{e:?}");
        assert!(e[0].msg.contains("`timebox` needs a `why`"), "{e:?}");
        assert_eq!(
            e[0].line,
            text.lines().position(|l| l.starts_with("timebox")).unwrap() as u32 + 1
        );
    }

    /// [D] pure
    #[test]
    fn an_unknown_key_is_refused_with_its_line() {
        let text = hello_c().replace("parser = \"tap\"", "parser = \"tap\"\nfrobnicate = 1");
        let e = refused(&text);
        assert_eq!(e.len(), 1, "{e:?}");
        assert!(e[0].msg.contains("unknown key `frobnicate`"), "{e:?}");
        assert_eq!(
            e[0].line,
            text.lines()
                .position(|l| l.starts_with("frobnicate"))
                .unwrap() as u32
                + 1
        );
        // and an unknown top-level key, and a TOML syntax error, each at its own line
        assert!(
            refused(&format!("{}\nmystery = 1\n", hello_c()))[0]
                .msg
                .contains("mystery")
        );
        let broken = refused("jobs = 1\nproject = \n");
        assert_eq!(broken[0].line, 2, "{broken:?}");
    }

    /// [D] pure
    #[test]
    fn each_reserved_field_says_not_built_yet() {
        for extra in [
            "matrix = \"arch\"",
            "sparse = [\"src\"]",
            "shards = 4",
            "flaky = \"report\"",
            "recheck = 2",
            "bisect = \"exit\"",
            "os = \"macos\"",
            "expect = { log-has = \"x\" }",
            "inputs = [\"git+https://example.org/x\"]",
            "run = [\"x\", \"{cell.arch}\"]",
            "run = [\"x\", \"{shard}\"]",
        ] {
            // a second `parser`/`expect`/`run` key is a duplicate: use a fresh stage for those
            let text = hello_c() + &format!("\n[[stage]]\nname = \"later\"\n{extra}\n");
            let e = refused(&text);
            assert!(
                e.iter()
                    .any(|e| e.msg.contains("not built yet (after launch)")),
                "{extra}: {e:?}"
            );
        }
        let e = refused(&hello_c().replace("parser = \"tap\"", "parser = \"ktap\""));
        assert!(e[0].msg.contains("not built yet"), "{e:?}");
        let e = refused(&hello_c().replace("kind = \"command\"", "kind = \"fetch\""));
        assert!(e[0].msg.contains("not built yet"), "{e:?}");
        let top = refused(&format!("{}\n[matrices]\narch = [\"x\"]\n", hello_c()));
        assert!(
            top[0].msg.contains("`matrices` is not built yet"),
            "{top:?}"
        );
        // the values that stay allowed
        let ok = hello_c() + "\n[[stage]]\nname = \"calm\"\nflaky = \"hold\"\nrecheck = 0\n";
        assert!(refused(&ok).is_empty());
    }

    /// [D] pure
    #[test]
    fn defaults_merge_under_the_entry() {
        let text = hello_c()
            + "\n[defaults]\nparser = \"junit\"\nclass = \"io-heavy\"\nenv = { CI = \"1\", A = \"default\" }\n\n\
               [[stage]]\nname = \"plain\"\nenv = { A = \"mine\" }\nrun = [\"true\"]\n";
        let p = load(&text, FILE).unwrap();
        let r = p.resolve("plain").unwrap();
        assert_eq!(r.get("parser"), Some(&Canon::Str("junit".into())));
        let env = r.get("env").unwrap();
        assert_eq!(env.get("A"), Some(&Canon::Str("mine".into())));
        assert_eq!(env.get("CI"), Some(&Canon::Str("1".into())));
        // an entry's own value beats the default
        let unit = p.resolve("unit").unwrap();
        assert_eq!(unit.get("parser"), Some(&Canon::Str("tap".into())));
        assert_eq!(unit.get("name"), Some(&Canon::Str("unit".into())));
    }

    /// [D] pure
    #[test]
    fn an_overlay_entry_replaces_and_is_listed() {
        let repo = load(&hello_c(), FILE).unwrap();
        let overlay = load(
            r#"jobs = 1
project = "hello-c"

[[stage]]
name = "unit"
run = ["private-runner"]

[[stage]]
name = "extra"
run = ["true"]
"#,
            "overlay/jobs.toml",
        )
        .unwrap();
        let m = merge_overlay(repo, overlay);
        assert_eq!(m.replaced, ["unit"]);
        assert!(m.entry("extra").is_some());
        assert_eq!(m.stages.iter().filter(|s| s.name == "unit").count(), 1);
        assert_eq!(
            m.resolve("unit").unwrap().get("run"),
            Some(&Canon::List(vec![Canon::Str("private-runner".into())]))
        );
    }

    /// [D] pure
    #[test]
    fn resolve_inlines_toolchain_caches() {
        let p = load(&hello_c(), FILE).unwrap();
        let r = p.resolve("build").unwrap();
        let tc = r.get("toolchain").unwrap();
        assert_eq!(tc.get("name"), Some(&Canon::Str("gcc".into())));
        assert!(matches!(tc.get("image"), Some(Canon::Str(s)) if s.contains("@sha256:")));
        let Some(Canon::List(caches)) = r.get("caches") else {
            panic!("{r:?}")
        };
        assert_eq!(caches[0].get("name"), Some(&Canon::Str("ccache".into())));
        assert!(caches[0].get("env").is_some());
        assert!(p.resolve("nope").is_err());
    }

    /// [D] pure
    #[test]
    fn host_mise_is_refused() {
        let text = hello_c().replace(
            "[caches.ccache]",
            &format!("[toolchains.mise]\nhost-mise = [\"rust@1.95\"]\nimage = \"x@sha256:{D}\"\n\n[caches.ccache]"),
        );
        let e = refused(&text);
        assert!(
            e.iter().any(|e| e.msg.contains("`host-mise` is refused")),
            "{e:?}"
        );
        // an image without a digest is refused too
        let loose = hello_c().replace(&format!("@sha256:{D}"), "");
        assert!(refused(&loose)[0].msg.contains("must carry a digest"));
    }

    /// [D] pure
    #[test]
    fn class_parses_and_stays_out_of_the_key() {
        let text =
            hello_c() + "\n[[stage]]\nname = \"io\"\nclass = \"io-heavy\"\nrun = [\"true\"]\n";
        let p = load(&text, FILE).unwrap();
        assert_eq!(p.entry("io").unwrap().class, Class::IoHeavy);
        assert_eq!(p.entry("unit").unwrap().class, Class::Normal);
        assert!(
            refused(&(hello_c() + "\n[[stage]]\nname = \"b\"\nclass = \"huge\"\n"))[0]
                .msg
                .contains("light, normal or io-heavy")
        );
        assert!(forseti::SCHEDULING_ONLY.contains(&"class"));
        // two packs that differ only in class resolve to the same key's entry less its scheduling fields
        let key = |t: &str| {
            let p = load(t, FILE).unwrap();
            forseti::artifact_key(&forseti::KeyInputs {
                entry: p.resolve("io").unwrap(),
                toolchain: String::new(),
                blobs: vec![],
                overlay: vec![],
                used: vec![],
                inputs: vec![],
                recipe_files: vec![],
            })
        };
        assert_eq!(key(&text), key(&text.replace("io-heavy", "light")));
    }

    /// [D] pure
    #[test]
    fn stage_inputs_gate_and_split_parse() {
        let text = hello_c()
            + r#"
[[stage]]
name = "everything"
preset = "plain"
toolchain = "gcc"
run = ["true"]
inputs = ["packages/**", "!**/*.md"]
key-ignore = ["**/*.md"]
outputs = ["coverage/**"]
env = { CI = "1" }
class = "normal"
mem = [512, 4096]
split = "units"
needs = ["unit"]
select = "nextest"

[[stage]]
name = "on-host"
host = true
run = ["true"]

[gate]
stages = ["unit", "everything"]
max-age = { everything = "24h" }
"#;
        let p = load(&text, FILE).unwrap();
        let s = p.entry("everything").unwrap();
        assert_eq!(
            (s.split.as_deref(), s.preset.as_deref()),
            (Some("units"), Some("plain"))
        );
        assert_eq!(s.inputs, ["packages/**", "!**/*.md"]);
        assert_eq!(s.outputs, ["coverage/**"]);
        assert!(p.entry("on-host").unwrap().host);
        let g = p.gate.unwrap();
        assert_eq!(g.stages, ["unit", "everything"]);
        assert_eq!(g.max_age, [("everything".to_string(), 86400)]);
        // a gate naming an unknown stage is refused, and so is a pipeline
        let e = refused(&text.replace(
            "stages = [\"unit\", \"everything\"]",
            "stages = [\"unit\", \"nope\"]",
        ));
        assert!(
            e.iter()
                .any(|e| e.msg.contains("`[gate]` names the stage `nope`")),
            "{e:?}"
        );
        let e = refused(&text.replace(
            "check = [\"unit\", \"fuzz-smoke\"]",
            "check = [\"unit\", \"gone\"]",
        ));
        assert!(
            e.iter()
                .any(|e| e.msg.contains("pipeline `check` names the stage `gone`")),
            "{e:?}"
        );
        // a host stage never takes a toolchain
        let e = refused(&text.replace("host = true", "host = true\ntoolchain = \"gcc\""));
        assert!(e.iter().any(|e| e.msg.contains("`host = true`")), "{e:?}");
    }

    /// [D] pure: placeholders are checked; `{key:NAME}` only in `env`
    #[test]
    fn placeholders_are_validated() {
        let add = |extra: &str| hello_c() + &format!("\n[[stage]]\nname = \"p\"\n{extra}\n");
        assert!(
            refused(&add("run = [\"echo\", \"{nope}\"]"))[0]
                .msg
                .contains("unknown placeholder `{nope}`")
        );
        assert!(
            refused(&add("run = [\"echo\", \"{key:TOKEN}\"]"))[0]
                .msg
                .contains("only in `env`")
        );
        assert!(refused(&add("env = { T = \"{key:TOKEN}\" }")).is_empty());
        assert!(refused(&add("run = [\"sh\", \"-c\", \"echo ${HOME} {rows}\"]")).is_empty());
    }

    /// [D] pure: the pack's accepted parsers are the registry's names
    #[test]
    fn an_unknown_parser_is_refused() {
        let e = refused(&hello_c().replace("parser = \"tap\"", "parser = \"ert\""));
        assert!(e[0].msg.contains("no row parser `ert`"), "{e:?}");
        assert!(
            refused(&hello_c().replace("parser = \"tap\"", "parser = \"regex:^(?P<name>x)$\""))
                .is_empty()
        );
    }

    /// [D] pure: every field a table takes is in `FIELDS`, the list the key's property row walks
    #[test]
    fn the_allowed_keys_are_in_the_fields_list() {
        for k in STAGE_ONLY
            .iter()
            .chain(ARTIFACT_ONLY)
            .chain(TOOLCHAIN)
            .chain(CACHE)
        {
            assert!(FIELDS.contains(k), "{k} is accepted but not in FIELDS");
        }
    }
}
