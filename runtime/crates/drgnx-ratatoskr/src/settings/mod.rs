//! The settings the hub reads itself (design §11.1; docs/develop/hub.md, "Settings"): `<config>/settings.el` and the
//! shipped `settings/runtime-defaults.el`, both as data through `huginn`, never loaded and never written.
//!
//! Only the runtime settings ([`RUNTIME`]) are decoded; every other entry is skipped, so a package's entry never
//! stops the hub.  A file that does not read gives the `strict` settings (the agents') their shipped defaults and the
//! others their last good values (kept in `runtime.db`'s `kv`); an entry with a mistake falls back alone, by its own
//! rule.  Each problem is a `notice`.
//!
//! - [`load`]: the file checks, the reading and the fallbacks ([`Settings::load`]).
//! - [`profiles`]: the agents' settings (`AgentProfile`, routes, OpenRouter restrictions).
//! - [`providers`]: the AI settings (provider entries, role chains) and the provider table (`ProviderConfig`).
//! - [`agents`]: the editor as the agents' settings tools reach it (`settings/proposed`, `settings/explain`).

pub mod agents;
pub mod containers;
pub mod load;
pub mod matrix;
pub mod overrides;
pub mod profiles;
pub mod providers;

#[cfg(test)]
mod conformance;
#[cfg(test)]
mod tests;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use huginn::form::parse_settings;
use huginn::read::Limits;
use huginn::value::Node;
use runstav::methods::hub::{SettingsFileState, SettingsStatus};
use serde_json::{Value, json};

pub use load::{FileState, Kv, Loaded, Problem};
pub use profiles::{AgentProfile, AgentRoute, OpenRouterRestrictions};
pub use providers::{ChainStep, ProviderEntry, RoleChain};

/// The shipped defaults, embedded at build time: with no editor and no `settings.el` the hub has every preset and
/// built-in profile.  The hub and the editor are built from one checkout, so the two cannot drift (design §11.1).
pub const DEFAULTS: &str = include_str!("../../../../../settings/runtime-defaults.el");

/// What a runtime setting falls back to when its value cannot be used (the Lisp declaration's `:on-error`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OnError {
    /// The shipped default (`:on-error strict`): never a half-read value.
    Strict,
    /// The last good value, kept in `runtime.db`'s `kv`; else the default.
    LastGood,
}

/// A runtime setting: its name, its Rust type as the Lisp declaration's `:runtime` names it, its fallback.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RuntimeSetting {
    pub name: &'static str,
    pub ty: &'static str,
    pub on_error: OnError,
}

const fn setting(name: &'static str, ty: &'static str, on_error: OnError) -> RuntimeSetting {
    RuntimeSetting { name, ty, on_error }
}

/// The `:runtime` settings (call 7: what agents.eld and ai.eld held, and `drgnx-agents-allow-unsandboxed`).  A
/// conformance test holds it equal to the Lisp declarations.
pub const RUNTIME: &[RuntimeSetting] = &[
    setting(
        "drgnx-agents-profiles",
        "Vec<AgentProfile>",
        OnError::Strict,
    ),
    setting("drgnx-agents-default", "Option<String>", OnError::Strict),
    setting("drgnx-agents-mcp", "Vec<String>", OnError::Strict),
    setting("drgnx-agents-routes", "Vec<AgentRoute>", OnError::Strict),
    setting(
        "drgnx-agents-openrouter",
        "OpenRouterRestrictions",
        OnError::Strict,
    ),
    setting("drgnx-agents-allow-unsandboxed", "bool", OnError::Strict),
    setting(
        "drgnx-agents-start-env-names",
        "Vec<String>",
        OnError::Strict,
    ),
    setting("drgnx-agents-trace-opens", "Vec<String>", OnError::Strict),
    setting(
        "drgnx-ai-providers",
        "Vec<ProviderConfig>",
        OnError::LastGood,
    ),
    setting("drgnx-ai-roles", "Vec<RoleChain>", OnError::LastGood),
    setting("drgnx-agents-matrix", "AgentsMatrix", OnError::Strict),
    setting("drgnx-agents-away-after", "u64", OnError::Strict),
    setting("drgnx-agents-wait-refusals", "u32", OnError::Strict),
    setting("drgnx-agents-close-idle-after", "u64", OnError::Strict),
    setting("drgnx-agents-checkpoint-cap", "u64", OnError::Strict),
    setting("drgnx-agents-job-memory", "String", OnError::Strict),
    setting("drgnx-agents-job-cpus", "u32", OnError::Strict),
    setting("drgnx-agents-net-hosts", "NetHosts", OnError::Strict),
    setting(
        "drgnx-agents-container-images",
        "Vec<ContainerImage>",
        OnError::Strict,
    ),
    setting("drgnx-agents-silent-after", "SilentAfter", OnError::Strict),
    setting("drgnx-agents-repeat-limit", "u32", OnError::Strict),
    setting("drgnx-agents-no-progress-tokens", "u64", OnError::Strict),
    setting("drgnx-agents-manager-context", "f64", OnError::Strict),
    setting(
        "drgnx-agents-model-prices",
        "Vec<ModelPrice>",
        OnError::Strict,
    ),
    setting(
        "drgnx-agents-browser-program",
        "Option<String>",
        OnError::Strict,
    ),
    setting(
        "drgnx-agents-browser-local-ports",
        "Vec<u16>",
        OnError::Strict,
    ),
    setting(
        "drgnx-agents-browser-deny-hosts",
        "Vec<String>",
        OnError::Strict,
    ),
    setting("drgnx-agents-browser-max-message", "u64", OnError::Strict),
    setting("drgnx-agents-browser-idle", "u64", OnError::Strict),
    setting("drgnx-agents-browser-once-window", "u64", OnError::Strict),
    setting("drgnx-agents-session-memory", "String", OnError::Strict),
    setting("drgnx-agents-browser-memory-high", "u32", OnError::Strict),
    setting("drgnx-runners-send", "String", OnError::Strict),
    setting("drgnx-runners-heavy", "Vec<String>", OnError::Strict),
    setting("drgnx-runners-image", "Option<String>", OnError::Strict),
    setting("drgnx-runners-weight", "f64", OnError::Strict),
    setting(
        "drgnx-runners-project-visibility",
        "String",
        OnError::Strict,
    ),
    setting("drgnx-runners-shared-overlay", "bool", OnError::Strict),
    setting("drgnx-runners-job-keys", "Vec<String>", OnError::Strict),
    setting("drgnx-runners-mac-tools", "Vec<String>", OnError::Strict),
    setting(
        "drgnx-runners-origin-key",
        "Option<String>",
        OnError::Strict,
    ),
    setting(
        "drgnx-sandbox-proxy-pinned-addresses",
        "ProxyPins",
        OnError::LastGood,
    ),
    setting(
        "drgnx-search-model-mirror",
        "Option<String>",
        OnError::Strict,
    ),
    setting("drgnx-search-builtin", "bool", OnError::Strict),
    setting("drgnx-search-include", "Vec<String>", OnError::Strict),
    setting("drgnx-search-exclude", "Vec<String>", OnError::Strict),
    setting("drgnx-search-off", "bool", OnError::Strict),
    setting("drgnx-search-base", "Option<String>", OnError::Strict),
    setting("drgnx-search-ignore-rules", "String", OnError::Strict),
    setting("drgnx-agents-plugins", "Vec<String>", OnError::Strict),
    setting("drgnx-agents-hook-rules", "Vec<HookRule>", OnError::Strict),
    setting(
        "drgnx-agents-hook-rules-off",
        "Vec<String>",
        OnError::Strict,
    ),
];

/// The names of [`RUNTIME`].
pub const RUNTIME_NAMES: [&str; RUNTIME.len()] = {
    let mut names = [""; RUNTIME.len()];
    let mut i = 0;
    while i < RUNTIME.len() {
        names[i] = RUNTIME[i].name;
        i += 1;
    }
    names
};

/// The decoded runtime settings: the user's values, or what they fell back to.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RuntimeValues {
    /// The user's profiles (the built-in ones are [`Defaults::profiles`]).
    pub agents_profiles: Vec<AgentProfile>,
    pub agents_default: Option<String>,
    pub agents_mcp: Vec<String>,
    pub agents_routes: Vec<AgentRoute>,
    pub agents_openrouter: Option<OpenRouterRestrictions>,
    pub agents_allow_unsandboxed: bool,
    /// The names an editor module may add to a session's environment (`agents/start`'s `env`).
    pub agents_start_env_names: Vec<String>,
    /// The providers whose shell steps' opens are traced on Linux (`work::trace`).
    pub agents_trace_opens: Vec<String>,
    /// The user's providers, each replacing the preset of its id.
    pub ai_providers: Vec<ProviderEntry>,
    /// The user's role chains (a role not named here has its shipped chain, [`Defaults::roles`]).
    pub ai_roles: Vec<RoleChain>,
    /// `drgnx-agents-matrix` in the wire's words (`matrix::decode` reads it); null until read.
    pub agents_matrix: Value,
    pub agents_away_after: u64,
    pub agents_wait_refusals: u32,
    pub agents_close_idle_after: u64,
    pub agents_checkpoint_cap: u64,
    pub agents_job_memory: String,
    pub agents_job_cpus: u32,
    pub agents_net_hosts: NetHosts,
    pub agents_container_images: Vec<ContainerImage>,
    pub agents_silent_after: SilentAfter,
    pub agents_repeat_limit: u32,
    pub agents_no_progress_tokens: u64,
    pub agents_manager_context: f64,
    /// What a model costs, by model-id prefix or provider name (the forecast's rates).
    pub agents_model_prices: Vec<ModelPrice>,
    /// The browser an agent session gets (an absolute path), or none to find one.
    pub agents_browser_program: Option<String>,
    /// The ports on the sandbox's own loopback that a session with the browser lets its agent and browser connect to
    /// (the agent's own servers).
    pub agents_browser_local_ports: Vec<u16>,
    pub agents_browser_deny_hosts: Vec<String>,
    /// Bytes.
    pub agents_browser_max_message: u64,
    /// Seconds.
    pub agents_browser_idle: u64,
    /// Seconds.
    pub agents_browser_once_window: u64,
    /// The memory cap of a session with its browser (`4G`).
    pub agents_session_memory: String,
    /// Percent (1 to 99) of the session's cap at which the browser is stopped.
    pub agents_browser_memory_high: u32,
    /// Which of a project's jobs may leave this machine: `all`, `heavy` or `none` (per project).
    pub runners_send: String,
    /// The suite or command patterns whose jobs are heavy (per project).
    pub runners_heavy: Vec<String>,
    /// The image a runner runs a project's command jobs in, by digest; none: the job's own (per project).
    pub runners_image: Option<String>,
    /// A project's weight in the queue's fairness (per project).
    pub runners_weight: f64,
    /// `public` or `private` (per project): with the commit on the public origin, what makes a job `public`.
    pub runners_project_visibility: String,
    /// A shared runner may get a project's uncommitted files, once each passes the secret scan (per project).
    pub runners_shared_overlay: bool,
    /// The keys a project's jobs may name, by name (per project): any other is refused at submit.
    pub runners_job_keys: Vec<String>,
    /// The Homebrew packages a project's Mac jobs need, by name (per project): each becomes a `brew:NAME` feature.
    pub runners_mac_tools: Vec<String>,
    /// The name of a project's read-only deploy key or token for its private origin (per project).
    pub runners_origin_key: Option<String>,
    pub sandbox_proxy_pins: ProxyPins,
    /// Where models come from instead of the Hugging Face host.
    pub search_model_mirror: Option<String>,
    /// Whether the built-in embedding model indexes (the floor under any server).
    pub search_builtin: bool,
    /// A project's search globs: only these files (none: all), not these, and search off. Per project
    /// ([`overrides::PER_PROJECT`]).
    pub search_include: Vec<String>,
    pub search_exclude: Vec<String>,
    pub search_off: bool,
    /// The checkout a project's search base is built from (none: the main checkout). Per project.
    pub search_base: Option<String>,
    /// Which files Quick Open, Find and the text search list: `index` (the index's filters) or `real`
    /// ([`crate::view::files::ignore_of`]).
    pub search_ignore_rules: String,
    /// The plugins that run, in hook order (`drgnx-agents-plugins`). A project's list replaces it
    /// ([`overrides::PER_PROJECT`]); a plugin runs only when the user approved it too ([`crate::plugins`]).
    pub agents_plugins: Vec<String>,
    /// The user's hook rules as a JSON list of rule objects (`drgnx-agents-hook-rules`), checked by [`hook_rules`]; a
    /// project's rules are added to these.
    pub agents_hook_rules: Value,
    /// The ids of rules a project switches off (`drgnx-agents-hook-rules-off`).
    pub agents_hook_rules_off: Vec<String>,
}

/// A hook rule list as the settings hold it, checked by `norn::hooks::parse_rules` (a rule's keys may be written with
/// `-`, as in the Lisp, or `_`); the list with `_` keys. A bad one is its JSON path and why. `null` is no rules.
pub(crate) fn hook_rules(v: &Value) -> Result<Value, (String, String)> {
    let fixed = match v {
        Value::Null => json!([]),
        Value::Array(rules) => Value::Array(
            rules
                .iter()
                .map(|r| match r {
                    Value::Object(o) => Value::Object(
                        o.iter()
                            .map(|(k, x)| (k.replace('-', "_"), x.clone()))
                            .collect(),
                    ),
                    other => other.clone(),
                })
                .collect(),
        ),
        other => other.clone(),
    };
    norn::hooks::parse_rules(&fixed).map_err(|e| (e.path, e.message))?;
    Ok(fixed)
}

/// The browser program setting: absolute, or none.
pub(crate) fn check_browser_program(p: &Option<String>) -> Result<(), String> {
    match p {
        Some(p) if !p.starts_with('/') => Err(format!("{p:?} is not an absolute path")),
        _ => Ok(()),
    }
}

/// The local ports setting: each 1 to 65535 (a u16 already holds the upper bound).
pub(crate) fn check_browser_ports(ports: &[u16]) -> Result<(), String> {
    match ports.iter().find(|p| **p == 0) {
        Some(_) => Err("a port is 1 to 65535, not 0".into()),
        None => Ok(()),
    }
}

/// A memory cap like `4G` or `512M`: digits (no leading 0) and an optional K, M, G or T.
pub(crate) fn check_memory(m: &str) -> Result<(), String> {
    let digits = m.strip_suffix(['K', 'M', 'G', 'T']).unwrap_or(m);
    let ok = !digits.is_empty()
        && !digits.starts_with('0')
        && digits.bytes().all(|b| b.is_ascii_digit());
    if ok {
        Ok(())
    } else {
        Err(format!("{m:?} is not a size like \"4G\" or \"512M\""))
    }
}

/// The high mark: a percent from 1 to 99.
pub(crate) fn check_memory_high(n: u32) -> Result<(), String> {
    if (1..=99).contains(&n) {
        Ok(())
    } else {
        Err(format!("{n} is not a percent from 1 to 99"))
    }
}

/// The browser max message: at least 1 byte.
pub(crate) fn check_max_message(n: u64) -> Result<(), String> {
    if n >= 1 {
        Ok(())
    } else {
        Err("a message limit is at least 1 byte".into())
    }
}

/// One entry of `drgnx-agents-container-images`: a name and its image reference pinned by digest (the shared podman
/// argv's type).
pub use sleipnir::linux::podman::ContainerImage;

/// `drgnx-agents-net-hosts`: the hosts (`host:port`) a granted network reaches, per tier name, in order.
pub type NetHosts = Vec<(String, Vec<String>)>;

/// `drgnx-agents-silent-after`: seconds without an update per kind of work, in order.
pub type SilentAfter = Vec<(String, u64)>;

/// `drgnx-sandbox-proxy-pinned-addresses`: the names the proxies (a session's provider proxy, a container job's)
/// resolve to a fixed address instead of asking DNS, in order.
pub type ProxyPins = Vec<(String, std::net::IpAddr)>;

/// One row of `drgnx-agents-model-prices`: US dollars per million tokens for a model-id prefix or a provider name.  A
/// cache price left out is the input price (as OpenRouter documents for a missing cache price).
#[derive(Clone, Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct ModelPrice {
    /// The alist key.
    #[serde(skip)]
    pub key: String,
    #[serde(rename = "in")]
    pub input: f64,
    #[serde(rename = "out")]
    pub output: f64,
    pub cache_read: Option<f64>,
    pub write_5m: Option<f64>,
    pub write_1h: Option<f64>,
    /// The date the row was read off the provider's page (`2026-11-01`).
    pub as_of: Option<String>,
}

/// The rows of the price table with their keys, each price a finite number of 0 or more.
pub(crate) fn prices(pairs: Vec<(String, ModelPrice)>) -> Result<Vec<ModelPrice>, String> {
    pairs
        .into_iter()
        .map(|(key, mut p)| {
            p.key = key;
            let all = [
                Some(p.input),
                Some(p.output),
                p.cache_read,
                p.write_5m,
                p.write_1h,
            ];
            match all
                .into_iter()
                .flatten()
                .find(|x| !(x.is_finite() && *x >= 0.0))
            {
                Some(_) => Err(format!(
                    "{}: a price is dollars per million tokens, a number of 0 or more",
                    p.key
                )),
                None => Ok(p),
            }
        })
        .collect()
}

/// An `agents-matrix` value that is valid, as a message when it is not.
pub(crate) fn check_matrix(v: &Value) -> Result<(), String> {
    matrix::decode(v).map(drop)
}

impl RuntimeValues {
    /// The profile names an agent may start on: the user's, then the built-in ones, each name once.
    pub fn profile_names(&self) -> Vec<&str> {
        let mut names: Vec<&str> = Vec::new();
        for p in self.agents_profiles.iter().chain(&defaults().profiles) {
            if !names.contains(&p.name.as_str()) {
                names.push(&p.name);
            }
        }
        names
    }
}

/// A value that does not fit its setting's type, and where.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Bad {
    /// Inside the value (`review.mode`, `[2]`); none for the value itself.
    pub path: Option<String>,
    pub message: String,
    pub span: huginn::span::Span,
}

impl Bad {
    pub(crate) fn at(node: &Node, path: Option<String>, message: impl Into<String>) -> Bad {
        Bad {
            path,
            message: message.into(),
            span: node.span,
        }
    }

    /// The path and the message, as a problem says them.
    pub fn text(&self) -> String {
        match &self.path {
            Some(p) => format!("{p}: {}", self.message),
            None => self.message.clone(),
        }
    }
}

/// NODE as a `T`, through huginn's deserializer; a mistake names its path.
pub(crate) fn de<'a, T: serde::Deserialize<'a>>(node: &'a Node) -> Result<T, Bad> {
    serde_path_to_error::deserialize(huginn::de::Deserializer::new(node)).map_err(|e| {
        let path = e.path().to_string();
        let inner = e.into_inner();
        Bad {
            path: (path != ".").then_some(path),
            message: inner.message,
            span: inner.span,
        }
    })
}

/// The value NODE of the runtime setting NAME, decoded into VALUES (which changes only when it decodes).
pub(crate) fn decode(name: &str, node: &Node, values: &mut RuntimeValues) -> Result<(), Bad> {
    match name {
        "drgnx-agents-profiles" => values.agents_profiles = profiles::profiles(node)?,
        "drgnx-agents-default" => values.agents_default = de(node)?,
        "drgnx-agents-mcp" => values.agents_mcp = profiles::mcp(node)?,
        "drgnx-agents-routes" => values.agents_routes = profiles::routes(node)?,
        "drgnx-agents-openrouter" => values.agents_openrouter = profiles::openrouter(node)?,
        "drgnx-agents-allow-unsandboxed" => values.agents_allow_unsandboxed = de(node)?,
        "drgnx-agents-start-env-names" => values.agents_start_env_names = de(node)?,
        "drgnx-agents-trace-opens" => values.agents_trace_opens = de(node)?,
        "drgnx-ai-providers" => values.ai_providers = providers::entries(node)?,
        "drgnx-ai-roles" => values.ai_roles = providers::roles(node)?,
        "drgnx-agents-matrix" => {
            let v: Value = de(node)?;
            check_matrix(&v).map_err(|m| Bad::at(node, None, m))?;
            values.agents_matrix = v;
        }
        "drgnx-agents-away-after" => values.agents_away_after = de(node)?,
        "drgnx-agents-wait-refusals" => values.agents_wait_refusals = de(node)?,
        "drgnx-agents-close-idle-after" => values.agents_close_idle_after = de(node)?,
        "drgnx-agents-checkpoint-cap" => values.agents_checkpoint_cap = de(node)?,
        "drgnx-agents-job-memory" => values.agents_job_memory = de(node)?,
        "drgnx-agents-job-cpus" => values.agents_job_cpus = de(node)?,
        "drgnx-agents-net-hosts" => {
            let profiles::Alist(pairs) = de::<profiles::Alist<Vec<String>>>(node)?;
            values.agents_net_hosts = pairs;
        }
        "drgnx-agents-container-images" => {
            let profiles::Alist(pairs) = de::<profiles::Alist<String>>(node)?;
            values.agents_container_images = images(pairs);
        }
        "drgnx-agents-silent-after" => {
            let profiles::Alist(pairs) = de::<profiles::Alist<u64>>(node)?;
            values.agents_silent_after = pairs;
        }
        "drgnx-agents-repeat-limit" => values.agents_repeat_limit = de(node)?,
        "drgnx-agents-no-progress-tokens" => values.agents_no_progress_tokens = de(node)?,
        "drgnx-agents-manager-context" => values.agents_manager_context = de(node)?,
        "drgnx-agents-model-prices" => {
            let profiles::Alist(pairs) = de::<profiles::Alist<ModelPrice>>(node)?;
            values.agents_model_prices = prices(pairs).map_err(|m| Bad::at(node, None, m))?;
        }
        "drgnx-runners-send" => {
            let v: String = de(node)?;
            if !["all", "heavy", "none"].contains(&v.as_str()) {
                return Err(Bad::at(node, None, "\"all\", \"heavy\" or \"none\""));
            }
            values.runners_send = v;
        }
        "drgnx-runners-heavy" => values.runners_heavy = de(node)?,
        "drgnx-runners-image" => values.runners_image = de(node)?,
        "drgnx-runners-weight" => values.runners_weight = de(node)?,
        "drgnx-runners-project-visibility" => {
            let v: String = de(node)?;
            if !["public", "private"].contains(&v.as_str()) {
                return Err(Bad::at(node, None, "\"public\" or \"private\""));
            }
            values.runners_project_visibility = v;
        }
        "drgnx-runners-shared-overlay" => values.runners_shared_overlay = de(node)?,
        "drgnx-runners-job-keys" => values.runners_job_keys = de(node)?,
        "drgnx-runners-mac-tools" => values.runners_mac_tools = de(node)?,
        "drgnx-runners-origin-key" => values.runners_origin_key = de(node)?,
        "drgnx-sandbox-proxy-pinned-addresses" => {
            let profiles::Alist(pairs) = de::<profiles::Alist<std::net::IpAddr>>(node)?;
            values.sandbox_proxy_pins = pairs;
        }
        "drgnx-search-model-mirror" => values.search_model_mirror = de(node)?,
        "drgnx-search-builtin" => values.search_builtin = de(node)?,
        "drgnx-search-include" => values.search_include = de(node)?,
        "drgnx-search-exclude" => values.search_exclude = de(node)?,
        "drgnx-search-off" => values.search_off = de(node)?,
        "drgnx-search-base" => values.search_base = de(node)?,
        "drgnx-search-ignore-rules" => {
            let v: String = de(node)?;
            if !["index", "real"].contains(&v.as_str()) {
                return Err(Bad::at(node, None, "\"index\" or \"real\""));
            }
            values.search_ignore_rules = v;
        }
        "drgnx-agents-plugins" => values.agents_plugins = de(node)?,
        "drgnx-agents-hook-rules" => {
            let v: Value = de(node)?;
            values.agents_hook_rules = hook_rules(&v).map_err(|(path, message)| Bad {
                path: (!path.is_empty()).then_some(path),
                message,
                span: node.span,
            })?;
        }
        "drgnx-agents-hook-rules-off" => values.agents_hook_rules_off = de(node)?,
        "drgnx-agents-browser-program" => {
            let v = de(node)?;
            check_browser_program(&v).map_err(|m| Bad::at(node, None, m))?;
            values.agents_browser_program = v;
        }
        "drgnx-agents-browser-local-ports" => {
            let v: Vec<u16> = de(node)?;
            check_browser_ports(&v).map_err(|m| Bad::at(node, None, m))?;
            values.agents_browser_local_ports = v;
        }
        "drgnx-agents-browser-deny-hosts" => values.agents_browser_deny_hosts = de(node)?,
        "drgnx-agents-browser-max-message" => {
            let v = de(node)?;
            check_max_message(v).map_err(|m| Bad::at(node, None, m))?;
            values.agents_browser_max_message = v;
        }
        "drgnx-agents-browser-idle" => values.agents_browser_idle = de(node)?,
        "drgnx-agents-browser-once-window" => values.agents_browser_once_window = de(node)?,
        "drgnx-agents-session-memory" => {
            let v: String = de(node)?;
            check_memory(&v).map_err(|m| Bad::at(node, None, m))?;
            values.agents_session_memory = v;
        }
        "drgnx-agents-browser-memory-high" => {
            let v = de(node)?;
            check_memory_high(v).map_err(|m| Bad::at(node, None, m))?;
            values.agents_browser_memory_high = v;
        }
        other => {
            return Err(Bad::at(
                node,
                None,
                format!("{other} is not a runtime setting"),
            ));
        }
    }
    Ok(())
}

pub(crate) fn images(pairs: Vec<(String, String)>) -> Vec<ContainerImage> {
    pairs
        .into_iter()
        .map(|(name, image)| ContainerImage { name, image })
        .collect()
}

/// The shipped defaults, read once from [`DEFAULTS`].
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Defaults {
    /// The strict default of every `strict` runtime setting; the others are empty (nil).
    pub values: RuntimeValues,
    /// `drgnx-ai-presets`: the providers drgnx knows without configuration.
    pub presets: Vec<ProviderEntry>,
    /// `drgnx-ai-default-roles`: each role's chain when nobody names one.
    pub roles: Vec<RoleChain>,
    /// `drgnx-agents-builtin-profiles`.
    pub profiles: Vec<AgentProfile>,
    /// What did not read (none in a shipped build: `defaults_parse` holds it so).
    pub problems: Vec<String>,
}

/// The shipped defaults.
pub fn defaults() -> &'static Defaults {
    static D: OnceLock<Defaults> = OnceLock::new();
    D.get_or_init(|| parse_defaults(DEFAULTS))
}

/// TEXT (a `runtime-defaults.el`) as [`Defaults`]; what does not read is a problem, and its part stays empty.
pub fn parse_defaults(text: &str) -> Defaults {
    let mut d = Defaults::default();
    let file = match parse_settings(text.as_bytes(), "drgnx-settings", Limits::default()) {
        Ok(f) => f,
        Err(r) => {
            d.problems.push(format!("runtime-defaults.el: {r}"));
            return d;
        }
    };
    d.problems.extend(
        file.problems
            .iter()
            .map(|p| format!("runtime-defaults.el: {}", p.message)),
    );
    for e in file.entries.iter().filter(|e| e.scope.is_empty()) {
        let got = match e.var.as_str() {
            "drgnx-ai-presets" => providers::entries(&e.value).map(|p| d.presets = p),
            "drgnx-ai-default-roles" => providers::roles(&e.value).map(|r| d.roles = r),
            "drgnx-agents-builtin-profiles" => profiles::profiles(&e.value).map(|p| d.profiles = p),
            name if strict(name) => decode(name, &e.value, &mut d.values),
            other => {
                d.problems.push(format!(
                    "runtime-defaults.el: {other} is not a runtime default"
                ));
                Ok(())
            }
        };
        if let Err(bad) = got {
            d.problems
                .push(format!("runtime-defaults.el: {}: {}", e.var, bad.text()));
        }
    }
    for s in RUNTIME.iter().filter(|s| s.on_error == OnError::Strict) {
        if !file.entries.iter().any(|e| e.var == s.name) {
            d.problems.push(format!(
                "runtime-defaults.el: no strict default for {}",
                s.name
            ));
        }
    }
    d
}

/// Whether NAME is a runtime setting that falls back to its shipped default.
pub fn strict(name: &str) -> bool {
    RUNTIME
        .iter()
        .any(|s| s.name == name && s.on_error == OnError::Strict)
}

/// The last read of `settings.el`, and the file's stamp then.
#[derive(Debug)]
pub struct Current {
    /// None until the file was read once (a front without a config folder: the shipped defaults).
    stamp: Option<load::Stamp>,
    pub loaded: Loaded,
}

impl Current {
    /// `status.settings`.
    pub fn status(&self) -> SettingsStatus {
        let l = &self.loaded;
        SettingsStatus {
            file: match l.file {
                FileState::Failed => SettingsFileState::Failed,
                FileState::Ok | FileState::Absent => SettingsFileState::Ok,
            },
            problems: l.problems.len() as u64,
            presets: l.providers.len() as u64,
            profiles: l.values.profile_names().len() as u64,
        }
    }

    /// Each problem as the `notice` event's data.
    pub fn notices(&self) -> Vec<Value> {
        self.loaded.problems.iter().map(notice).collect()
    }
}

/// PROBLEM as a `notice` (one id per setting, or for the file).
fn notice(problem: &Problem) -> Value {
    json!({
        "source": "hub",
        "severity": "warn",
        "id": format!("settings-{}", problem.setting.unwrap_or("file")),
        "life": "event",
        "text": problem.text,
    })
}

/// The hub's settings: read at start, and again whenever the file's stamp changed when a session starts (and on
/// `config/changed`, unified settings Task 21).
pub struct Settings {
    /// What is in effect: the file's (and the defaults'), the global overrides over it.
    current: Mutex<Arc<Current>>,
    /// The last read of the file alone.
    file: Mutex<Arc<Current>>,
    /// The editor's sets (`config/settings`).
    overrides: Mutex<overrides::Overrides>,
    overrides_loaded: AtomicBool,
    /// One read, or one set of overrides, at a time.
    reading: tokio::sync::Mutex<()>,
    /// The config folder and `runtime.db`, once the server opened it.
    store: OnceLock<(PathBuf, urdr::Handle)>,
}

impl Default for Settings {
    fn default() -> Self {
        Settings::new()
    }
}

impl Settings {
    /// The shipped defaults only, until [`Settings::open`] and [`Settings::refresh`].
    pub fn new() -> Settings {
        let d = defaults();
        let values = d.values.clone();
        let (providers, _) = providers::table(&d.presets, &values.ai_providers);
        let initial = Arc::new(Current {
            stamp: None,
            loaded: Loaded {
                file: FileState::Absent,
                values,
                providers,
                problems: Vec::new(),
                kv: Kv::default(),
            },
        });
        Settings {
            current: Mutex::new(initial.clone()),
            file: Mutex::new(initial),
            overrides: Mutex::new(overrides::Overrides::default()),
            overrides_loaded: AtomicBool::new(false),
            reading: tokio::sync::Mutex::new(()),
            store: OnceLock::new(),
        }
    }

    /// `settings.el` in CONFIG_DIR as KV's last good values allow (no file: the defaults).
    pub fn load(config_dir: &Path, kv: &Kv) -> Loaded {
        load::load(config_dir, kv)
    }

    /// Read from CONFIG_DIR, keeping the last good values in RUNTIME (`runtime.db`).
    pub fn open(&self, config_dir: PathBuf, runtime: urdr::Handle) {
        let _ = self.store.set((config_dir, runtime));
    }

    pub fn current(&self) -> Arc<Current> {
        self.current.lock().expect("settings").clone()
    }

    /// Whether [`Settings::open`] was called (the hub; a test front has no config folder).
    pub fn is_open(&self) -> bool {
        self.store.get().is_some()
    }

    /// Put the global overrides over the file's values: what is in effect now. The file is copied under the overrides'
    /// lock, which is held until the result is published.
    fn compose(&self) {
        let overrides = self.overrides.lock().expect("settings");
        let file = self.file.lock().expect("settings").clone();
        let current = match overrides.scope(None) {
            None | Some([]) => file,
            Some(list) => {
                let mut loaded = file.loaded.clone();
                overrides::apply(&mut loaded.values, list);
                let (providers, skipped) =
                    providers::table(&defaults().presets, &loaded.values.ai_providers);
                loaded.providers = providers;
                loaded
                    .problems
                    .retain(|p| !(p.setting == Some("drgnx-ai-providers") && p.line.is_none()));
                loaded.problems.extend(load::skipped_problems(skipped));
                Arc::new(Current {
                    stamp: file.stamp,
                    loaded,
                })
            }
        };
        *self.current.lock().expect("settings") = current;
    }

    /// NAME's value in effect for PROJECT (none: global), as JSON of its runtime type, and whether PROJECT has ever
    /// sent its values (phase 6's card asks).  The project's override, else the global one, else `settings.el`, else
    /// the shipped default.  None for a name that is not a runtime setting.
    pub fn effective(&self, name: &str, project: Option<&str>) -> Option<(Value, bool)> {
        let overrides = self.overrides.lock().expect("settings");
        let seen = project.is_none_or(|p| overrides.scope(Some(p)).is_some());
        let own = project
            .and_then(|p| overrides.scope(Some(p)))
            .and_then(|l| l.iter().rev().find(|o| o.name == name));
        let value = match own {
            Some(o) => o.value.clone(),
            None => overrides::to_json(name, &self.current().loaded.values)?,
        };
        Some((value, seen))
    }

    /// NAME's value in PROJECT's own set, or none when PROJECT never sent one for it (unlike [`Self::effective`], which
    /// falls back to the global value): a setting a project's value is added to, not put in place of.
    pub fn project_value(&self, name: &str, project: &str) -> Option<Value> {
        let overrides = self.overrides.lock().expect("settings");
        overrides
            .scope(Some(project))?
            .iter()
            .rev()
            .find(|o| o.name == name)
            .map(|o| o.value.clone())
    }

    /// `config/settings`: LIST is the whole set of PROJECT (none: global), kept as the last good one.  A name that
    /// is not a runtime setting, a global one in a project's set ([`overrides::PER_PROJECT`]) or a value that does
    /// not fit its type is refused with its path, and nothing changes.
    pub async fn set_overrides(
        &self,
        project: Option<&str>,
        list: Vec<overrides::Override>,
    ) -> Result<u64, runstav::wire::Error> {
        if project == Some("global") {
            return Err(runstav::wire::Error {
                code: runstav::wire::ErrorCode::InvalidParams,
                message: "global is the name of the global set, not a project".into(),
                path: Some("project".into()),
            });
        }
        if let Err((i, why)) = overrides::validate(&list, project.is_some()) {
            return Err(runstav::wire::Error {
                code: runstav::wire::ErrorCode::InvalidParams,
                message: why.message,
                path: Some(format!("overrides[{i}].{}", why.path)),
            });
        }
        // one at a time with refresh and each other: the kv row and memory hold the same last set, and compose
        // never publishes a file copy older than the one refresh put
        let _one = self.reading.lock().await;
        if let Some((_, db)) = self.store.get() {
            crate::gateway::kv_set(db, &overrides::kv_key(project), &overrides::to_text(&list))
                .await;
        }
        let n = list.len() as u64;
        self.overrides.lock().expect("settings").set(project, list);
        self.compose();
        Ok(n)
    }

    /// Read `settings.el` again when its stamp changed since the last read (the first time always): the notices of
    /// the problems the last read did not have.  Nothing before [`Settings::open`].
    pub async fn refresh(&self) -> Vec<Value> {
        let Some((dir, db)) = self.store.get() else {
            return Vec::new();
        };
        let _one = self.reading.lock().await;
        if !self.overrides_loaded.swap(true, Ordering::Relaxed) {
            let kept = overrides::Overrides::load(db).await;
            let mut mine = self.overrides.lock().expect("settings");
            // a set sent before the first read stays
            for scope in std::iter::once(None).chain(kept.projects().map(Some)) {
                if mine.scope(scope).is_none()
                    && let Some(list) = kept.scope(scope)
                {
                    mine.set(scope, list.to_vec());
                }
            }
        }
        let before = self.file.lock().expect("settings").clone();
        let stamp = load::stamp(&dir.join(load::FILE));
        if before.stamp.is_some() && before.stamp == Some(stamp) {
            self.compose();
            return Vec::new();
        }
        let kv = Kv::from_text(
            crate::gateway::kv_get(db, load::KV_LAST_GOOD)
                .await
                .as_deref(),
        );
        let (dir2, kv2) = (dir.clone(), kv.clone());
        let loaded = match crate::clock::blocking(move || load::load(&dir2, &kv2)).await {
            Ok(l) => l,
            Err(e) => {
                tracing::warn!("settings.el was not read: {e}");
                return Vec::new();
            }
        };
        if loaded.kv != kv {
            crate::gateway::kv_set(db, load::KV_LAST_GOOD, &loaded.kv.to_text()).await;
        }
        for p in &loaded.problems {
            tracing::warn!("{}", p.text);
        }
        let new: Vec<Value> = loaded
            .problems
            .iter()
            .filter(|p| !before.loaded.problems.contains(p))
            .map(notice)
            .collect();
        *self.file.lock().expect("settings") = Arc::new(Current {
            stamp: Some(stamp),
            loaded,
        });
        self.compose();
        new
    }
}
