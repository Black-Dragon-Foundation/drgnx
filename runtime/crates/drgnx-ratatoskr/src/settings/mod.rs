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

pub mod load;
pub mod profiles;
pub mod providers;

#[cfg(test)]
mod conformance;
#[cfg(test)]
mod tests;

use std::path::{Path, PathBuf};
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
        "drgnx-ai-providers",
        "Vec<ProviderConfig>",
        OnError::LastGood,
    ),
    setting("drgnx-ai-roles", "Vec<RoleChain>", OnError::LastGood),
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
    /// The user's providers, each replacing the preset of its id.
    pub ai_providers: Vec<ProviderEntry>,
    /// The user's role chains (a role not named here has its shipped chain, [`Defaults::roles`]).
    pub ai_roles: Vec<RoleChain>,
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
        "drgnx-ai-providers" => values.ai_providers = providers::entries(node)?,
        "drgnx-ai-roles" => values.ai_roles = providers::roles(node)?,
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
    current: Mutex<Arc<Current>>,
    /// One read at a time.
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
        Settings {
            current: Mutex::new(Arc::new(Current {
                stamp: None,
                loaded: Loaded {
                    file: FileState::Absent,
                    values,
                    providers,
                    problems: Vec::new(),
                    kv: Kv::default(),
                },
            })),
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

    /// Read `settings.el` again when its stamp changed since the last read (the first time always): the notices of
    /// the problems the last read did not have.  Nothing before [`Settings::open`].
    pub async fn refresh(&self) -> Vec<Value> {
        let Some((dir, db)) = self.store.get() else {
            return Vec::new();
        };
        let _one = self.reading.lock().await;
        let before = self.current();
        let stamp = load::stamp(&dir.join(load::FILE));
        if before.stamp.is_some() && before.stamp == Some(stamp) {
            return Vec::new();
        }
        let kv = Kv::from_text(
            crate::gateway::kv_get(db, load::KV_LAST_GOOD)
                .await
                .as_deref(),
        );
        let (dir2, kv2) = (dir.clone(), kv.clone());
        let loaded = match tokio::task::spawn_blocking(move || load::load(&dir2, &kv2)).await {
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
        *self.current.lock().expect("settings") = Arc::new(Current {
            stamp: Some(stamp),
            loaded,
        });
        new
    }
}
