//! The table (`standards.toml`), the workspace's members (`cargo metadata`), the table's own checks and the clippy
//! configs generated from it.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Deserialize;

use super::Finding;

/// The rule ids the scanner implements (`scan.rs`).
pub const SCAN_RULES: &[&str] = &[
    "no-string-error",
    "no-let-underscore-result",
    "no-print",
    "no-env-home",
    "no-blocking-recv-on-ui",
    "secret-has-redact",
    "no-hand-luau-binding",
    "no-raw-key-event",
    "no-colour-literal",
    "no-raw-scale-mul",
    "command-has-doc",
    "no-ui-observer",
    "no-dependency-list-api",
];

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Table {
    #[serde(default)]
    pub crates: BTreeMap<String, Mark>,
    #[serde(default)]
    pub standard: Vec<Standard>,
    #[serde(default)]
    pub layer: Vec<Layer>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Mark {
    #[serde(default)]
    pub clean: bool,
    #[serde(default)]
    pub ui: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Standard {
    pub id: String,
    pub owner: String,
    /// Crates that own the standard with `owner`: the layer under it that the owner is built on.
    #[serde(default)]
    pub co_owners: Vec<String>,
    #[serde(default)]
    pub clippy: Vec<String>,
    #[serde(default)]
    pub clippy_types: Vec<String>,
    #[serde(default)]
    pub lints: Vec<String>,
    #[serde(default)]
    pub scan: Vec<String>,
    pub conformance: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Layer {
    #[serde(rename = "crate")]
    pub krate: String,
    pub may_not_depend: Vec<String>,
}

impl Standard {
    /// Whether KRATE owns this standard, as its owner or a co-owner.
    pub fn owned_by(&self, krate: &str) -> bool {
        self.owner == krate || self.co_owners.iter().any(|c| c == krate)
    }
}

impl Table {
    pub fn load(root: &Path) -> Result<Table, String> {
        let path = root.join("standards.toml");
        let text =
            std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        toml::from_str(&text).map_err(|e| format!("standards.toml: {e}"))
    }

    pub fn is_clean(&self, krate: &str) -> bool {
        self.crates.get(krate).is_some_and(|m| m.clean)
    }

    pub fn is_ui(&self, krate: &str) -> bool {
        self.crates.get(krate).is_some_and(|m| m.ui)
    }

    /// Every clippy lint the table denies: the rows' `lints`, and the disallowed-* lints when any row feeds them.
    pub fn all_lints(&self) -> BTreeSet<String> {
        let mut all: BTreeSet<String> =
            self.standard.iter().flat_map(|s| s.lints.clone()).collect();
        if self.standard.iter().any(|s| !s.clippy.is_empty()) {
            all.insert("disallowed_methods".into());
        }
        if self.standard.iter().any(|s| !s.clippy_types.is_empty()) {
            all.insert("disallowed_types".into());
        }
        all
    }

    /// The standard whose lint LINT is, if one row names it (the disallowed-* lints belong to no single row).
    pub fn lint_owner(&self, lint: &str) -> Option<&Standard> {
        self.standard
            .iter()
            .find(|s| s.lints.iter().any(|l| l == lint))
    }

    /// Whether KRATE may silence LINT: it owns a standard that denies it.
    pub fn may_silence(&self, krate: &str, lint: &str) -> bool {
        self.standard.iter().filter(|s| s.owned_by(krate)).any(|s| {
            s.lints.iter().any(|l| l == lint)
                || (lint == "disallowed_methods" && !s.clippy.is_empty())
                || (lint == "disallowed_types" && !s.clippy_types.is_empty())
        })
    }
}

/// A workspace member, from `cargo metadata`.
#[derive(Debug, Clone)]
pub struct Member {
    pub name: String,
    pub dir: PathBuf,
    /// Its normal and build dependencies, by package name.
    pub deps: Vec<String>,
}

#[derive(Deserialize)]
struct Metadata {
    packages: Vec<Package>,
}

#[derive(Deserialize)]
struct Package {
    name: String,
    manifest_path: PathBuf,
    dependencies: Vec<Dep>,
}

#[derive(Deserialize)]
struct Dep {
    name: String,
    kind: Option<String>,
}

/// The workspace's members (`cargo metadata --no-deps`: no resolution, no network, no lock written).
pub fn members(root: &Path) -> Result<Vec<Member>, String> {
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".into());
    let out = Command::new(cargo)
        .args([
            "metadata",
            "--format-version",
            "1",
            "--no-deps",
            "--offline",
            "--manifest-path",
        ])
        .arg(root.join("Cargo.toml"))
        .output()
        .map_err(|e| format!("cargo metadata: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "cargo metadata failed: {}",
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    let meta: Metadata =
        serde_json::from_slice(&out.stdout).map_err(|e| format!("cargo metadata: {e}"))?;
    Ok(meta
        .packages
        .into_iter()
        .map(|p| Member {
            name: p.name,
            dir: p
                .manifest_path
                .parent()
                .map(Path::to_path_buf)
                .unwrap_or_default(),
            deps: p
                .dependencies
                .into_iter()
                .filter(|d| d.kind.as_deref() != Some("dev"))
                .map(|d| d.name)
                .collect(),
        })
        .collect())
}

fn table_finding(file: &str, message: String) -> Finding {
    Finding {
        file: PathBuf::from(file),
        line: 1,
        id: "standards".into(),
        rule: "table".into(),
        message,
        krate: None,
    }
}

/// The table's own checks: every row's owner, doc page, conformance file and scan rules exist; every marked crate is a
/// member; a clean crate takes the workspace's lints; Cargo.toml denies every lint of the table.
pub fn check(root: &Path, table: &Table, members: &[Member]) -> Vec<Finding> {
    let mut out = Vec::new();
    let names: BTreeSet<&str> = members.iter().map(|m| m.name.as_str()).collect();
    let mut ids = BTreeSet::new();
    for s in &table.standard {
        if !ids.insert(s.id.as_str()) {
            out.push(table_finding(
                "standards.toml",
                format!("the id `{}` is in two rows", s.id),
            ));
        }
        if !names.contains(s.owner.as_str()) {
            out.push(table_finding(
                "standards.toml",
                format!(
                    "`{}`: its owner `{}` is not a workspace crate",
                    s.id, s.owner
                ),
            ));
        }
        for c in s.co_owners.iter().filter(|c| !names.contains(c.as_str())) {
            out.push(table_finding(
                "standards.toml",
                format!("`{}`: its co-owner `{c}` is not a workspace crate", s.id),
            ));
        }
        let doc = format!("docs/develop/standards/{}.md", s.id);
        if !root.join(&doc).is_file() {
            out.push(table_finding(
                "standards.toml",
                format!("`{}`: its doc page {doc} is missing", s.id),
            ));
        }
        if !root.join(&s.conformance).is_file() {
            out.push(table_finding(
                "standards.toml",
                format!(
                    "`{}`: its conformance test {} is missing",
                    s.id, s.conformance
                ),
            ));
        }
        for rule in &s.scan {
            if !SCAN_RULES.contains(&rule.as_str()) {
                out.push(table_finding(
                    "standards.toml",
                    format!("`{}`: the scan rule `{rule}` does not exist", s.id),
                ));
            }
        }
    }
    for name in table.crates.keys() {
        if !names.contains(name.as_str()) {
            out.push(table_finding(
                "standards.toml",
                format!("[crates] `{name}` is not a workspace crate"),
            ));
        }
    }
    for l in &table.layer {
        if !names.contains(l.krate.as_str()) {
            out.push(table_finding(
                "standards.toml",
                format!("[[layer]] `{}` is not a workspace crate", l.krate),
            ));
        }
    }
    let lints = workspace_lints(root);
    for lint in table.all_lints() {
        if lints.get(&lint).map(String::as_str) != Some("deny") {
            out.push(table_finding(
                "Cargo.toml",
                format!("[workspace.lints.clippy] must deny `{lint}` (standards.toml names it)"),
            ));
        }
    }
    for m in members.iter().filter(|m| table.is_clean(&m.name)) {
        if !takes_workspace_lints(&m.dir) {
            let rel = rel(root, &m.dir.join("Cargo.toml"));
            out.push(table_finding(
                &rel,
                format!(
                    "`{}` is clean: it must have `[lints] workspace = true`",
                    m.name
                ),
            ));
        }
    }
    out
}

fn read_toml(path: &Path) -> Option<toml::Table> {
    std::fs::read_to_string(path).ok()?.parse().ok()
}

/// [workspace.lints.clippy] of the root Cargo.toml, as lint → level.
fn workspace_lints(root: &Path) -> BTreeMap<String, String> {
    let Some(t) = read_toml(&root.join("Cargo.toml")) else {
        return BTreeMap::new();
    };
    let Some(clippy) = t
        .get("workspace")
        .and_then(|w| w.get("lints"))
        .and_then(|l| l.get("clippy"))
        .and_then(|c| c.as_table())
    else {
        return BTreeMap::new();
    };
    clippy
        .iter()
        .filter_map(|(k, v)| {
            let level = v
                .as_str()
                .or_else(|| v.get("level").and_then(|l| l.as_str()))?;
            Some((k.clone(), level.to_string()))
        })
        .collect()
}

fn takes_workspace_lints(dir: &Path) -> bool {
    read_toml(&dir.join("Cargo.toml"))
        .and_then(|t| t.get("lints")?.get("workspace")?.as_bool())
        .unwrap_or(false)
}

pub fn rel(root: &Path, p: &Path) -> String {
    p.strip_prefix(root)
        .unwrap_or(p)
        .to_string_lossy()
        .into_owned()
}

const HEADER: &str = "# Generated by `cargo xtask standards --write` from standards.toml: do not edit (docs/develop/standards/README.md).\n";

fn entry(path: &str, id: &str, owner: &str) -> String {
    // a std path always resolves; another crate's only where the crate depends on it
    let invalid = if ["std::", "core::", "alloc::"]
        .iter()
        .any(|p| path.starts_with(p))
    {
        ""
    } else {
        ", allow-invalid = true"
    };
    format!(
        "    {{ path = \"{path}\", reason = \"{id}: through {owner} (docs/develop/standards/{id}.md)\"{invalid} }},\n"
    )
}

/// The clippy.toml of a crate (KRATE) or of the root (None): every row's paths but those of the rows KRATE owns.
fn clippy_config(table: &Table, krate: Option<&str>) -> String {
    let mut s = String::from(HEADER);
    let rows: Vec<&Standard> = table
        .standard
        .iter()
        .filter(|r| !krate.is_some_and(|k| r.owned_by(k)))
        .collect();
    s.push_str("disallowed-methods = [\n");
    for r in &rows {
        for p in &r.clippy {
            s.push_str(&entry(p, &r.id, &r.owner));
        }
    }
    s.push_str("]\ndisallowed-types = [\n");
    for r in &rows {
        for p in &r.clippy_types {
            s.push_str(&entry(p, &r.id, &r.owner));
        }
    }
    s.push_str("]\n");
    s
}

/// The generated files: one clippy.toml in each clean crate, and the root's. Clippy reads the nearest clippy.toml
/// above a crate, so the root's carries the lists only once every member is clean; until then a crate not yet clean
/// sees none (its findings are the scanner's report, and the freeze holds it).
pub fn clippy_files(root: &Path, table: &Table, members: &[Member]) -> Vec<(PathBuf, String)> {
    let mut files = Vec::new();
    let all_clean = members.iter().all(|m| table.is_clean(&m.name));
    let root_text = if all_clean {
        clippy_config(table, None)
    } else {
        format!(
            "{HEADER}# Not every crate is clean yet: the lists are in each clean crate's own clippy.toml, and reach this file\n# once every member is clean.\n"
        )
    };
    files.push((root.join("clippy.toml"), root_text));
    for m in members.iter().filter(|m| table.is_clean(&m.name)) {
        files.push((
            m.dir.join("clippy.toml"),
            clippy_config(table, Some(&m.name)),
        ));
    }
    files
}
