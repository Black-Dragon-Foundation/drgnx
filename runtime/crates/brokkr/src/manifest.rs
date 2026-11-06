//! `plugin.json`: what a plugin declares, checked as data before anything of it runs.
//!
//! `parse` refuses unknown keys, and every error carries the JSON path of the value at fault. The rules that need
//! one value only are checked by the types' own `Deserialize` (so the path comes from the parser); the rules that
//! relate several values are in `validate`.

use std::collections::BTreeSet;
use std::fmt;

use serde::Deserialize;
use sha2::{Digest, Sha256};

#[cfg(test)]
mod tests;

/// The most a manifest file may hold, read by `store::scan`.
pub const MAX_MANIFEST_BYTES: u64 = 256 * 1024;
/// `kv_bytes` may not exceed this, and this is also the default.
pub const MAX_KV_BYTES: u32 = 1024 * 1024;
const MAX_HOSTS: usize = 16;
const MAX_DESCRIPTION_CHARS: usize = 1024;
/// `len(name) + 1 + len(ability)`: the full tool name `mcp__drgnx-plugins__NAME_ABILITY` stays within 64 characters.
const MAX_QUALIFIED_ABILITY: usize = 44;
/// The ACP tool kinds, then `drgnx` (last) for the hub's own tools. The hook engine's rules use the same list.
pub const TOOL_KINDS: &[&str] = &[
    "read",
    "edit",
    "delete",
    "move",
    "search",
    "execute",
    "think",
    "fetch",
    "switch_mode",
    "other",
    "drgnx",
];
/// What a `change` at `before-tool` may name: the hub's own servers' tools.
const HUB_TOOL_PREFIXES: &[&str] = &["mcp__drgnx__", "mcp__drgnx-plugins__"];

/// Why a manifest was refused: the JSON path of the offending value ("" for the document) and what is wrong.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestError {
    pub path: String,
    pub message: String,
}

impl ManifestError {
    fn at(path: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            path: path.into(),
            message: message.into(),
        }
    }
}

impl fmt::Display for ManifestError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.path.is_empty() {
            f.write_str(&self.message)
        } else {
            write!(f, "{}: {}", self.path, self.message)
        }
    }
}

impl std::error::Error for ManifestError {}

/// A string newtype whose `Deserialize` runs `$check`.
macro_rules! text_newtype {
    ($(#[$m:meta])* $t:ident, $check:expr) => {
        $(#[$m])*
        #[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Deserialize)]
        #[serde(try_from = "String")]
        pub struct $t(String);
        impl $t {
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }
        impl TryFrom<String> for $t {
            type Error = String;
            fn try_from(s: String) -> Result<Self, String> {
                let check: fn(&str) -> Result<(), String> = $check;
                check(&s)?;
                Ok(Self(s))
            }
        }
    };
}

text_newtype!(
    /// `^[a-z][a-z0-9-]{0,31}$`
    PluginName,
    |s| ident(s, 32, '-')
);
text_newtype!(
    /// An ability's name: `^[a-z][a-z0-9_]{0,47}$`
    ToolName,
    |s| ident(s, 48, '_')
);
text_newtype!(
    /// A path glob of a filter. The matcher is the hook engine's; here it is only a bounded, printable string.
    Glob,
    |s| {
        if s.is_empty() || s.chars().count() > 512 || s.chars().any(char::is_control) {
            Err("a glob is 1 to 512 printable characters".into())
        } else {
            Ok(())
        }
    }
);

/// A lowercase name of `[a-z]` then `[a-z0-9]` and `extra`, at most `max` characters.
fn ident(s: &str, max: usize, extra: char) -> Result<(), String> {
    let mut chars = s.chars();
    let ok = chars.next().is_some_and(|c| c.is_ascii_lowercase())
        && s.len() <= max
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == extra);
    if ok {
        Ok(())
    } else {
        Err(format!(
            "{s:?} is not a name: a lowercase letter, then lowercase letters, digits and `{extra}`, at most {max} characters"
        ))
    }
}

/// A host a plugin may reach over https: a lowercase ASCII name (A-labels) and a port (default 443).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(try_from = "String")]
pub struct HostName {
    host: String,
    port: u16,
}

impl HostName {
    pub fn host(&self) -> &str {
        &self.host
    }
    pub fn port(&self) -> u16 {
        self.port
    }
}

impl TryFrom<String> for HostName {
    type Error = String;
    fn try_from(s: String) -> Result<Self, String> {
        if s.starts_with('[') {
            return Err("an IP literal is not a host name".into());
        }
        let (host, port) = match s.split_once(':') {
            None => (s.as_str(), 443),
            Some((h, p)) => {
                let digits = !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit());
                match p.parse::<u16>() {
                    Ok(n) if digits && n != 0 => (h, n),
                    _ => return Err(format!("{p:?} is not a port (1 to 65535)")),
                }
            }
        };
        check_host(host)?;
        Ok(Self {
            host: host.to_string(),
            port,
        })
    }
}

fn check_host(host: &str) -> Result<(), String> {
    if host.is_empty() || host.len() > 253 {
        return Err("a host name is 1 to 253 characters".into());
    }
    let labels: Vec<&str> = host.split('.').collect();
    for l in &labels {
        let ok = (1..=63).contains(&l.len())
            && l.bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
            && !l.starts_with('-')
            && !l.ends_with('-');
        if !ok {
            return Err(format!(
                "{host:?} is not a host name: lowercase ASCII labels of letters, digits and `-` (an international name as its xn-- form); no wildcard"
            ));
        }
    }
    if labels.len() < 2 {
        return Err(format!("{host:?} is a single-label name"));
    }
    // A name ending in a digit is an address in disguise (`127.1`, `0x7f.0x1`, `2130706433`).
    if !labels[labels.len() - 1].starts_with(|c: char| c.is_ascii_lowercase()) {
        return Err(format!("{host:?} looks like an IP address"));
    }
    let under = |e: &str| host == e || host.strip_suffix(e).is_some_and(|p| p.ends_with('.'));
    if under("localhost") || under("internal") {
        return Err(format!("{host:?} is a local or internal name"));
    }
    if gleipnir::net::policy::NAME_NEVER.iter().any(|e| under(e)) {
        return Err(format!("{host:?} is refused by name by the web policy"));
    }
    Ok(())
}

/// A place in the agent's work where hooks run. `budget_ms` is the budget of the whole point run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Point {
    BeforeTool,
    AfterEdit,
    BeforeCommit,
    AtReview,
}

impl Point {
    pub fn budget_ms(self) -> u32 {
        match self {
            Point::BeforeTool => 2_000,
            Point::AfterEdit => 5_000,
            Point::BeforeCommit => 10_000,
            Point::AtReview => 30_000,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum VerdictKind {
    Allow,
    Deny,
    Change,
    Annotate,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AbilityDecl {
    pub name: ToolName,
    /// At most 1024 characters.
    pub description: String,
    /// A JSON Schema (draft 2020-12) object schema.
    pub input_schema: serde_json::Value,
}

/// Which steps a hook is called for. The fields AND together; an empty one matches everything.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Filter {
    /// ACP tool kinds, or `drgnx` for the hub's own tools.
    #[serde(default)]
    pub tool_kinds: Vec<String>,
    /// Exact full tool names.
    #[serde(default)]
    pub tools: Vec<String>,
    #[serde(default)]
    pub paths: Vec<Glob>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HookDecl {
    pub point: Point,
    pub verdicts: BTreeSet<VerdictKind>,
    /// At most the point's budget.
    #[serde(default)]
    pub deadline_ms: Option<u32>,
    /// An advisory hook's failure is a note, not a deny. Forced when `verdicts` is only `annotate`.
    #[serde(default)]
    pub advisory: bool,
    #[serde(default)]
    pub filter: Option<Filter>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub name: PluginName,
    pub version: String,
    #[serde(default)]
    pub abilities: Vec<AbilityDecl>,
    #[serde(default)]
    pub hooks: Vec<HookDecl>,
    #[serde(default)]
    pub hosts: Vec<HostName>,
    /// At most [`MAX_KV_BYTES`], which is also the default.
    #[serde(default)]
    pub kv_bytes: Option<u32>,
}

/// Parses and checks a manifest.
pub fn parse(json: &[u8]) -> Result<Manifest, ManifestError> {
    let mut de = serde_json::Deserializer::from_slice(json);
    let mut m: Manifest = serde_path_to_error::deserialize(&mut de).map_err(|e| {
        let path = e.path().to_string();
        ManifestError::at(path.trim_start_matches('.'), e.inner().to_string())
    })?;
    validate(&mut m)?;
    Ok(m)
}

fn validate(m: &mut Manifest) -> Result<(), ManifestError> {
    let v = &m.version;
    if v.is_empty()
        || v.len() > 64
        || !v
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'+' | b'-'))
    {
        return Err(ManifestError::at(
            "version",
            "a version is 1 to 64 characters of letters, digits, `.`, `+` and `-`",
        ));
    }
    for (i, a) in m.abilities.iter().enumerate() {
        let at = |f: &str| format!("abilities[{i}].{f}");
        if m.name.as_str().len() + 1 + a.name.as_str().len() > MAX_QUALIFIED_ABILITY {
            return Err(ManifestError::at(
                at("name"),
                format!(
                    "the plugin name, `_` and the ability name together are at most {MAX_QUALIFIED_ABILITY} characters"
                ),
            ));
        }
        if m.abilities[..i].iter().any(|b| b.name == a.name) {
            return Err(ManifestError::at(at("name"), "an ability name twice"));
        }
        if a.description.chars().count() > MAX_DESCRIPTION_CHARS {
            return Err(ManifestError::at(
                at("description"),
                format!("longer than {MAX_DESCRIPTION_CHARS} characters"),
            ));
        }
        if a.input_schema.get("type").and_then(|t| t.as_str()) != Some("object") {
            return Err(ManifestError::at(
                at("input_schema"),
                "must be an object schema (`\"type\": \"object\"`)",
            ));
        }
    }
    if m.hosts.len() > MAX_HOSTS {
        return Err(ManifestError::at(
            format!("hosts[{MAX_HOSTS}]"),
            format!("at most {MAX_HOSTS} hosts"),
        ));
    }
    for (i, h) in m.hosts.iter().enumerate() {
        if m.hosts[..i].contains(h) {
            return Err(ManifestError::at(format!("hosts[{i}]"), "a host twice"));
        }
    }
    if m.kv_bytes.is_some_and(|k| k > MAX_KV_BYTES) {
        return Err(ManifestError::at(
            "kv_bytes",
            format!("at most {MAX_KV_BYTES} (1 MiB)"),
        ));
    }
    for (i, h) in m.hooks.iter_mut().enumerate() {
        validate_hook(i, h)?;
    }
    for (i, h) in m.hooks.iter().enumerate() {
        if m.hooks[..i].iter().any(|b| b.point == h.point) {
            return Err(ManifestError::at(
                format!("hooks[{i}].point"),
                "at most one hook per point",
            ));
        }
    }
    Ok(())
}

fn validate_hook(i: usize, h: &mut HookDecl) -> Result<(), ManifestError> {
    let at = |f: &str| format!("hooks[{i}].{f}");
    if h.verdicts.is_empty() {
        return Err(ManifestError::at(at("verdicts"), "at least one verdict"));
    }
    let budget = h.point.budget_ms();
    if let Some(d) = h.deadline_ms
        && !(1..=budget).contains(&d)
    {
        return Err(ManifestError::at(
            at("deadline_ms"),
            format!("1 to {budget} at this point (the whole point's budget)"),
        ));
    }
    if let Some(f) = &h.filter {
        for (j, k) in f.tool_kinds.iter().enumerate() {
            if !TOOL_KINDS.contains(&k.as_str()) {
                return Err(ManifestError::at(
                    at(&format!("filter.tool_kinds[{j}]")),
                    format!("{k:?} is not a tool kind"),
                ));
            }
        }
        for (j, t) in f.tools.iter().enumerate() {
            let ok = (1..=128).contains(&t.len())
                && t.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
            if !ok {
                return Err(ManifestError::at(
                    at(&format!("filter.tools[{j}]")),
                    "a tool name is 1 to 128 characters of letters, digits, `_` and `-`",
                ));
            }
        }
    }
    if h.verdicts.contains(&VerdictKind::Change) && h.point == Point::BeforeTool {
        let named = h.filter.as_ref().is_some_and(|f| {
            f.tool_kinds == ["drgnx"]
                && !f.tools.is_empty()
                && f.tools.iter().all(|t| {
                    HUB_TOOL_PREFIXES
                        .iter()
                        .any(|p| t.strip_prefix(p).is_some_and(|rest| !rest.is_empty()))
                })
        });
        if !named {
            return Err(ManifestError::at(
                at("filter"),
                "a `change` before a tool needs `tool_kinds` [\"drgnx\"] and `tools` naming the hub tools it may \
                 change, each starting `mcp__drgnx__` or `mcp__drgnx-plugins__`",
            ));
        }
    }
    if h.verdicts.len() == 1 && h.verdicts.contains(&VerdictKind::Annotate) {
        h.advisory = true;
    }
    Ok(())
}

/// The hash a user approves: SHA-256 over the manifest and the component, each with its length in front (8 bytes,
/// big endian), so no byte can move from one to the other.
pub fn plugin_hash(manifest: &[u8], wasm: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    for part in [manifest, wasm] {
        h.update((part.len() as u64).to_be_bytes());
        h.update(part);
    }
    h.finalize().into()
}
