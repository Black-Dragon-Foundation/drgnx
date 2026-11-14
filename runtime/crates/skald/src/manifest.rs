//! `pack.eld` as types (design §3.2). Every field is frozen here: `deny_unknown_fields` everywhere, so a misspelt or
//! future key is refused with its path. A key `:tree-sha256` is the field `tree_sha256`.

use huginn::read::{Limits, read_all};
use serde::Deserialize;

/// The manifest format this crate reads. A pack says it in `:schema`.
pub const SCHEMA: i64 = 1;

/// The most a manifest may hold.
const LIMITS: Limits = Limits {
    max_bytes: 256 * 1024,
    max_depth: 24,
};

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    /// The pack's name (also its folder in the catalog).
    pub pack: String,
    /// The manifest format; `SCHEMA`. (The design's example spells it `:format`, which it also uses for the formatter;
    /// the formatter keeps `:format`, this is `:schema`.)
    pub schema: i64,
    pub version: String,
    pub name: String,
    pub summary: String,
    #[serde(default)]
    pub files: Files,
    #[serde(default)]
    pub grammars: Vec<Grammar>,
    #[serde(default)]
    pub mode: Option<Mode>,
    #[serde(default)]
    pub servers: Vec<Server>,
    #[serde(default)]
    pub format: Option<Format>,
    #[serde(default)]
    pub hrafn: Option<Hrafn>,
    #[serde(default)]
    pub origin: Option<Origin>,
    #[serde(default)]
    pub adapters: Vec<Adapter>,
    #[serde(default)]
    pub inline: Option<Inline>,
    #[serde(default)]
    pub requires: Requires,
    pub license: String,
    #[serde(default)]
    pub maintainers: Vec<String>,
}

/// Which files are the language's.
#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Files {
    /// Extensions without the dot.
    #[serde(default)]
    pub extensions: Vec<String>,
    /// Whole file names (`Makefile`).
    #[serde(default)]
    pub names: Vec<String>,
    /// Regexps on the interpreter's base name of a `#!` line (`^kotlin`, N2).
    #[serde(default)]
    pub shebangs: Vec<String>,
    /// The Emacs `auto-mode-alist` regexp.
    #[serde(default)]
    pub mode_regexp: Option<String>,
}

/// A grammar unit, keyed by its language name. Owned (repo + commit + tree hash) or referenced (`:from-pack`).
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Grammar {
    pub name: String,
    #[serde(default)]
    pub repo: Option<String>,
    #[serde(default)]
    pub commit: Option<String>,
    #[serde(default)]
    pub tree_sha256: Option<String>,
    /// The folder holding `parser.c` (default `src`).
    #[serde(default)]
    pub src: Option<String>,
    /// Must load before the pack's mode is remapped.
    #[serde(default)]
    pub required: bool,
    #[serde(default)]
    pub from_pack: Option<String>,
}

/// The Emacs side: `(:generic t)`, `(:ts MODE :builtin t [:classic MODE])`, `(:ts MODE :package PKG [:classic MODE])`,
/// or `(:classic MODE)` alone for a language with no tree-sitter mode (a format-only pack: Terraform, Dart).
#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Mode {
    #[serde(default)]
    pub generic: bool,
    #[serde(default)]
    pub ts: Option<String>,
    #[serde(default)]
    pub builtin: bool,
    #[serde(default)]
    pub package: Option<String>,
    /// The classic mode `ts` is remapped from (`major-mode-remap-alist`).
    #[serde(default)]
    pub classic: Option<String>,
    /// The generic mode's indentation: `(NODE-KIND . OFFSET)` rules (§3.4).
    #[serde(default)]
    pub indent: Vec<(String, i64)>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Server {
    pub id: String,
    #[serde(default)]
    pub modes: Vec<String>,
    pub command: Vec<String>,
    #[serde(default)]
    pub find: Option<Find>,
    #[serde(default)]
    pub install: Option<Install>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Find {
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub python_module: Option<String>,
    #[serde(default)]
    pub tools: Option<String>,
}

/// How to get a program (the vocabulary of `etc/debug-adapters.eld`, F19). Run only on a click.
#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Install {
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub sha256: Option<String>,
    #[serde(default)]
    pub into: Option<String>,
    #[serde(default)]
    pub root: Option<String>,
    #[serde(default)]
    pub platforms: Vec<Platform>,
    #[serde(default)]
    pub pip: Option<String>,
    #[serde(default)]
    pub hash: Option<String>,
    /// A system package command: shown, never run.
    #[serde(default)]
    pub system: Option<String>,
    /// The version this download is pinned at, for the doctor (`pinned 21.0.5, installed 21.0.4`).
    #[serde(default)]
    pub version: Option<String>,
    /// A single file (a jar) instead of an archive: the download is written to `tools/INTO/FILE`.
    #[serde(default)]
    pub file: Option<String>,
    /// Several downloads for one adapter (a JDK, a language server, a plugin): all or none.
    #[serde(default)]
    pub parts: Vec<Install>,
}

impl Install {
    /// The recipe as the hub reads it (`debug/install.rs`): a JSON object with the keys of the `.eld` form, unset ones left out.
    pub fn to_json(&self) -> serde_json::Value {
        let mut m = serde_json::Map::new();
        for (k, v) in [
            ("url", &self.url),
            ("sha256", &self.sha256),
            ("into", &self.into),
            ("root", &self.root),
            ("pip", &self.pip),
            ("hash", &self.hash),
            ("system", &self.system),
            ("file", &self.file),
            ("version", &self.version),
        ] {
            if let Some(v) = v {
                m.insert(k.into(), v.clone().into());
            }
        }
        if !self.platforms.is_empty() {
            let rows = self.platforms.iter().map(|p| {
                let mut r = serde_json::Map::new();
                r.insert("platform".into(), p.platform.clone().into());
                r.insert("url".into(), p.url.clone().into());
                if let Some(h) = &p.sha256 {
                    r.insert("sha256".into(), h.clone().into());
                }
                if let Some(root) = &p.root {
                    r.insert("root".into(), root.clone().into());
                }
                serde_json::Value::Object(r)
            });
            m.insert("platforms".into(), rows.collect());
        }
        if !self.parts.is_empty() {
            m.insert(
                "parts".into(),
                self.parts.iter().map(Install::to_json).collect(),
            );
        }
        serde_json::Value::Object(m)
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Platform {
    pub platform: String,
    pub url: String,
    #[serde(default)]
    pub sha256: Option<String>,
    /// The folder of the archive that becomes the install on this platform, when it differs (a JDK's `Contents/Home`).
    #[serde(default)]
    pub root: Option<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Format {
    /// The formatter's name; none for a pack that only says which config files mean "this project formats".
    #[serde(default)]
    pub formatter: Option<String>,
    #[serde(default)]
    pub command: Vec<String>,
    /// On for every file of the pack's modes, not only under a project config.
    #[serde(default)]
    pub standard: bool,
    #[serde(default)]
    pub config_files: Vec<String>,
}

/// What Hrafn reads (design §4.1).
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Hrafn {
    /// The stored language name (`shell`, not `bash`).
    pub lang: String,
    #[serde(default)]
    pub tags: Option<String>,
    #[serde(default)]
    pub chunks: Option<String>,
    #[serde(default)]
    pub docs: Option<Docs>,
    /// One character: the structural search's metavariable sigil.
    #[serde(default)]
    pub sigil: Option<String>,
    #[serde(default)]
    pub helpers: Vec<Helper>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Docs {
    #[serde(default)]
    pub line: Option<String>,
    #[serde(default)]
    pub block: Option<String>,
    /// What documents a top-level definition itself (Rust: its `///` lines); the others take their form's doc.
    #[serde(default)]
    pub top: Vec<DocMember>,
    /// What documents a member of a container.
    #[serde(default)]
    pub members: Vec<DocMember>,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum DocMember {
    Line,
    Block,
    Docstring,
}

/// The closed set of named Rust helpers (design §4.2); a new one is a Rust change with a review.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Helper {
    JsCallbackBody,
    CDeclaratorName,
}

/// Origin trails: ast-grep templates for a variable's declaration.
#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Origin {
    #[serde(default)]
    pub decls: Vec<String>,
}

/// A debug adapter (the schema of `etc/debug-adapters.eld`, merged after it).
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Adapter {
    pub id: String,
    pub name: String,
    pub types: Vec<String>,
    #[serde(default)]
    pub languages: Vec<String>,
    #[serde(default)]
    pub tested: bool,
    #[serde(default)]
    pub find: Option<Find>,
    #[serde(default)]
    pub start: Option<Start>,
    #[serde(default)]
    pub defaults: Vec<serde_json::Value>,
    #[serde(default)]
    pub install: Option<Install>,
    #[serde(default)]
    pub not_built_in: bool,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Start {
    #[serde(default)]
    pub stdio: Option<Vec<String>>,
    #[serde(default)]
    pub tcp: Option<Vec<String>>,
    /// An adapter that lives inside a language server (java-debug in jdtls): the hub starts the server, asks it for the
    /// adapter's port and connects DAP there. Built-in packs only (`check`).
    #[serde(default)]
    pub lsp_command: Option<LspCommand>,
}

/// How to reach a DAP server a language server opens (`docs/develop/debugging.md`, "The lsp-command start kind").
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct LspCommand {
    /// The server's command line: `{tools}`, `{root}`, `{session}`, `{os}` and `{glob:DIR/PATTERN}` are filled in.
    pub server: Vec<String>,
    /// The LSP session's root folder (default `{root}`, the launch's project folder).
    #[serde(default)]
    pub root: Option<String>,
    /// `initializationOptions`, as data; every string in it is filled in like the command line.
    #[serde(default)]
    pub init_options: Option<serde_json::Value>,
    /// The `workspace/executeCommand` whose answer is the DAP server's TCP port.
    pub debug_command: String,
    #[serde(default)]
    pub debug_args: Vec<String>,
    /// Steps that complete the launch configuration from the server before the DAP `launch`.
    #[serde(default)]
    pub fill: Vec<Fill>,
    /// Open the launch's file in the server (`textDocument/didOpen`) once it is ready: a server such as jdtls makes the
    /// project of a lone file only when it is opened.
    #[serde(default)]
    pub open_file: Option<OpenFile>,
}

/// What `textDocument/didOpen` says of the file.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct OpenFile {
    pub language_id: String,
}

/// One `:fill` step: a server command whose answer (strings only) goes into the launch configuration.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Fill {
    pub command: String,
    /// Strings: `${config:KEY}` is a key of the launch configuration, `${file}` the current file, `{root-uri}` the root.
    #[serde(default)]
    pub args: Vec<String>,
    /// When the answer is a list of objects, the first whose FIELD equals the filled-in value.
    #[serde(default)]
    pub select: Option<Select>,
    /// Run only when the launch configuration has no such key.
    #[serde(default)]
    pub when_missing: Option<String>,
    /// While the answer is an empty list, ask again every half second for up to this many seconds (a project still
    /// being imported lists nothing yet).
    #[serde(default)]
    pub retry_empty: Option<u64>,
    #[serde(default)]
    pub into: Vec<Put>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Select {
    pub field: String,
    pub equals: String,
}

/// Where a launch key's value lives in the (selected) answer: a field, an index, or the whole answer.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Put {
    pub key: String,
    #[serde(default)]
    pub field: Option<String>,
    #[serde(default)]
    pub index: Option<usize>,
    /// The answer may lack it (a lone file's project has no name): then the key is left out.
    #[serde(default)]
    pub optional: bool,
}

/// Inline values: node kinds, and a query for "not a value".
#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Inline {
    #[serde(default)]
    pub functions: Vec<String>,
    #[serde(default)]
    pub loops: Vec<String>,
    #[serde(default)]
    pub names: Vec<String>,
    #[serde(default)]
    pub query: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Requires {
    #[serde(default)]
    pub packs: Vec<String>,
    #[serde(default)]
    pub packages: Vec<String>,
}

/// Why a manifest was not read: where in it, and what.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PackError {
    /// The field path (`grammars[0].commit`), when the problem has one.
    pub path: Option<String>,
    pub message: String,
}

impl std::fmt::Display for PackError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match &self.path {
            Some(p) => write!(f, "{p}: {}", self.message),
            None => f.write_str(&self.message),
        }
    }
}

impl std::error::Error for PackError {}

fn plain(message: impl Into<String>) -> PackError {
    PackError {
        path: None,
        message: message.into(),
    }
}

/// The manifest in BYTES: one plist, read as data, every field known. The format version is checked
/// (`:schema` must be `SCHEMA`); the other rules are `check::check`'s.
pub fn read(bytes: &[u8]) -> Result<Manifest, PackError> {
    let nodes = read_all(bytes, LIMITS).map_err(|e| plain(format!("pack.eld: {e}")))?;
    let [node] = nodes.as_slice() else {
        return Err(plain(format!(
            "pack.eld holds {} forms; it is one plist",
            nodes.len()
        )));
    };
    let m: Manifest = serde_path_to_error::deserialize(huginn::de::Deserializer::new(node))
        .map_err(|e| {
            let path = e.path().to_string();
            PackError {
                path: (path != ".").then_some(path),
                message: e.into_inner().message,
            }
        })?;
    if m.schema != SCHEMA {
        return Err(PackError {
            path: Some("schema".into()),
            message: format!("format {} is not one this drgnx reads ({SCHEMA})", m.schema),
        });
    }
    Ok(m)
}
