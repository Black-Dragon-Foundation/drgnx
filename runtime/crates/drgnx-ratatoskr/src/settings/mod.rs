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
        *self.file.lock().expect("settings") = Arc::new(Current {
            stamp: Some(stamp),
            loaded,
        });
        self.compose();
        new
    }
}
