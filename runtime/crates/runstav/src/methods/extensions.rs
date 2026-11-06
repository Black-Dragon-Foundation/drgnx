//! The Extensions view's methods (docs/develop/hub.md, "Extensions"): search and read the catalog of packages, the
//! lock, the modules and the Emacs built-ins as one list of rows.  None writes; the install itself is `drgnx sync`
//! run as a job, never a method.
//!
//! `extensions/search` and `extensions/details` are open to agents (a catalog is public data); `extensions/rows` and
//! `extensions/modules` are the editor's: the module table is the editor's own state, and no agent may set it.

use super::{Empty, invalid, method};
use crate::registry::Method;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// The most rows one `extensions/search` answers.
pub const LIMIT_MAX: u32 = 500;
/// The rows it answers when `limit` is not given.
pub const LIMIT_DEFAULT: u32 = 200;
/// The longest query, in characters.
pub const QUERY_MAX: usize = 200;

/// What a row is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Package,
    Plugin,
    Module,
    Emacs,
}

/// Where a row stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum State {
    /// In an archive, not installed.
    Available,
    Installed,
    /// Installed, and the update plan takes a newer version.
    Update,
    /// Installed only because another installed package needs it.
    Dependency,
    /// A newer version exists that the update plan does not take (a pin or a dependant's bound).
    Held,
    /// Installed, and the newest version needs a newer Emacs than this one.
    Incompat,
    /// Named by a module, `packages.eld`, the wanted file or the lock's `:wanted`, and not in the lock.
    Missing,
    On,
    Off,
    /// A module waiting for a package.
    NeedsPackage,
    /// A module the editor reported failed.  A failed job is the editor's overlay, never a hub state.
    Failed,
    /// A plugin installed and never approved.
    Unapproved,
    /// A plugin whose files are not the ones the user approved.
    Changed,
    /// A plugin the user switched off in the hub.
    Disabled,
    /// A plugin whose manifest does not read.
    Broken,
    BuiltIn,
}

/// How far the user can trust where a row comes from (the trust words of the details page).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum Signed {
    /// The lock entry says `:verified t`.
    Signed,
    UnsignedArchive,
    /// A directory archive.
    Local,
    GitCommit,
    HashApproved,
    None,
}

/// Why a package is wanted or installed.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum Why {
    /// A module names it.
    Module(String),
    /// The user asked for it (`:wanted user` in the lock).
    You,
    PackagesEld,
    /// A `use-package :ensure` recorded it in the wanted file.
    Ensure,
    /// Installed packages that require it.
    NeededBy(Vec<String>),
    /// Its lock entry has no hash: installed by hand or seeded.
    ByHand,
}

/// One line of the list.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Row {
    /// `pkg:NAME`, `module:NAME`, `emacs:NAME`, `plugin:NAME`.
    pub id: String,
    pub kind: Kind,
    pub name: String,
    pub summary: String,
    pub state: State,
    /// The archive (`gnu`, `melpa`, …), `git`, `emacs` or `module`.
    pub source: String,
    pub signed: Signed,
    /// What is installed (a module has none).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// The version the update would install, when one is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub downloads: Option<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub why: Vec<Why>,
}

/// What a search keeps; every field off or absent keeps everything.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct Filters {
    #[serde(default)]
    pub installed: bool,
    #[serde(default)]
    pub updates: bool,
    /// Modules that are on.
    #[serde(default)]
    pub enabled: bool,
    /// Modules that are off.
    #[serde(default)]
    pub disabled: bool,
    #[serde(default)]
    pub builtin: bool,
    #[serde(default)]
    pub plugins: bool,
    /// Packages from an archive that does not sign.
    #[serde(default)]
    pub unsigned: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<Kind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archive: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keyword: Option<String>,
    /// Only these rows (`@failed`, `@restart`, `@this-project` and `@recommended` arrive this way: the editor knows
    /// them).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ids: Option<Vec<String>>,
}

/// How the rows are ordered.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Sort {
    /// The query's rank, then installed first, then downloads, then name (the default).
    Relevance,
    Name,
    Downloads,
    /// Newest version first (an archive's version strings carry the date).
    Updated,
    Installed,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SearchParams {
    /// Words; a row matches when every word is a prefix of a word of its name, or inside its name, keywords or
    /// summary.  Empty keeps all rows.
    #[serde(default)]
    pub query: String,
    #[serde(default)]
    pub filters: Filters,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sort: Option<Sort>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub offset: Option<u32>,
    /// 1 to 500; default 200.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SearchResult {
    pub rows: Vec<Row>,
    /// Every row that matched, before `offset` and `limit`.
    pub total: u32,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DetailsParams {
    pub id: String,
}

/// A requirement.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Requirement {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct DetailsResult {
    pub row: Row,
    pub requires: Vec<Requirement>,
    /// Installed packages that require it.
    pub required_by: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub maintainer: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    pub keywords: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revdesc: Option<String>,
    /// The readme the refresh job cached, as text (at most 256 KiB).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub readme: Option<String>,
    /// What the hub could not read, in its own words (a catalog or lock it refused and kept the last good one of).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct RowsParams {
    pub ids: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RowsResult {
    /// In the ids' order; an unknown id is left out.
    pub rows: Vec<Row>,
}

/// A module's state as the editor knows it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum ModuleState {
    On,
    Off,
    NeedsPackage,
    Failed,
}

/// One module of the editor's table.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ModuleEntry {
    pub name: String,
    #[serde(default)]
    pub doc: String,
    /// The packages it names.
    #[serde(default)]
    pub packages: Vec<String>,
    #[serde(default)]
    pub flags: Vec<String>,
    pub state: ModuleState,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ModulesParams {
    pub modules: Vec<ModuleEntry>,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "extensions/search", ExtensionsSearch(SearchParams) -> SearchResult,
            classes: [User, Agent], writes: false,
            doc: "rows of the extensions catalog (packages, modules, Emacs built-ins) matching words, filters and an order; reads the refresh job's catalog, the lock and the modules, never the network",
            check: |p| {
                if p.query.chars().count() > QUERY_MAX {
                    return Err(invalid("query", "the query is too long"));
                }
                if p.limit.is_some_and(|l| l == 0 || l > LIMIT_MAX) {
                    return Err(invalid("limit", "limit is 1 to 500"));
                }
                Ok(())
            },
        ),
        method!(
            "extensions/details", ExtensionsDetails(DetailsParams) -> DetailsResult,
            classes: [User, Agent], writes: false,
            doc: "one row with its requirements, who needs it, where it comes from and its cached readme",
        ),
        method!(
            "extensions/rows", ExtensionsRows(RowsParams) -> RowsResult,
            classes: [User], writes: false,
            doc: "the rows of these ids, in their order; an unknown id is left out",
        ),
        method!(
            "extensions/modules", ExtensionsModules(ModulesParams) -> Empty,
            classes: [User], writes: false,
            doc: "the editor's module table (name, doc, packages, flags, state), held in memory so the list can show modules; replaces the last table",
        ),
    ]
}
