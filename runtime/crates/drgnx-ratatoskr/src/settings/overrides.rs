//! The editor's values of the runtime settings (`config/settings`, unified settings Task 21; docs/develop/hub.md,
//! "Settings"): the Lisp the editor runs and the workspaces it opened hold values `settings.el` does not have.  The
//! editor sends each set, global or for one project; the hub keeps it as the last good one in `runtime.db`'s `kv`
//! (`settings-override:global`, `settings-override:<project>`), so it works without an editor after a restart.
//!
//! A value is JSON of the setting's runtime type ([`to_json`] and [`from_json`] are the two directions): the alists
//! (`drgnx-agents-profiles`, `drgnx-agents-routes`, `drgnx-ai-providers`) are objects (keys come back sorted, JSON
//! objects have no order), `drgnx-ai-roles` is a list of `{role, chain: [{provider, model}]}`.
//!
//! What is in effect: the project's override, else the global one, else `settings.el`, else the shipped default
//! ([`super::Settings::effective`]).

use std::collections::BTreeMap;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::profiles::{self, AgentProfile, Alist, OpenRouterRestrictions};
use super::providers::{ProviderEntry, RoleChain};
use super::{RUNTIME_NAMES, RuntimeValues};

/// The `kv` keys' prefix; the rest is `global` or the project.
pub const KV_PREFIX: &str = "settings-override:";

/// One runtime setting's value as the editor sent it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct Override {
    pub name: String,
    pub value: Value,
    pub source: String,
}

/// Why a value is refused, and where in it (empty: the whole value).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refused {
    pub path: String,
    pub message: String,
}

fn refused(path: impl Into<String>, message: impl Into<String>) -> Refused {
    Refused {
        path: path.into(),
        message: message.into(),
    }
}

fn de<T: DeserializeOwned>(v: &Value) -> Result<T, Refused> {
    serde_json::from_value(v.clone()).map_err(|e| refused("", e.to_string()))
}

/// The value V of the runtime setting NAME decoded into VALUES (which changes only when it decodes).
pub fn from_json(name: &str, v: &Value, values: &mut RuntimeValues) -> Result<(), Refused> {
    match name {
        "drgnx-agents-profiles" => {
            let Alist(pairs) = de::<Alist<AgentProfile>>(v)?;
            values.agents_profiles = pairs
                .into_iter()
                .map(|(name, mut p)| {
                    p.name = name;
                    p
                })
                .collect();
        }
        "drgnx-agents-default" => values.agents_default = de(v)?,
        "drgnx-agents-mcp" => {
            let servers: Vec<String> = de(v)?;
            if let Some(bad) = servers
                .iter()
                .find(|s| !matches!(s.as_str(), "coordination" | "search"))
            {
                return Err(refused(
                    "",
                    format!("{bad:?} is not an MCP server (coordination, search)"),
                ));
            }
            values.agents_mcp = servers;
        }
        "drgnx-agents-routes" => {
            let Alist(pairs) = de::<Alist<Vec<String>>>(v)?;
            values.agents_routes = pairs
                .into_iter()
                .map(|(role, profiles)| profiles::AgentRoute { role, profiles })
                .collect();
        }
        "drgnx-agents-openrouter" => {
            let r: Option<OpenRouterRestrictions> = de(v)?;
            if let Some(r) = &r {
                for (key, slugs) in [("only", &r.only), ("ignore", &r.ignore)] {
                    if let Some(bad) = slugs.iter().flatten().find(|s| !profiles::slug(s)) {
                        return Err(refused(
                            key,
                            format!("{bad:?} is not a provider slug (like \"anthropic\")"),
                        ));
                    }
                }
            }
            values.agents_openrouter = r;
        }
        "drgnx-agents-allow-unsandboxed" => values.agents_allow_unsandboxed = de(v)?,
        "drgnx-ai-providers" => {
            let Alist(pairs) = de::<Alist<ProviderEntry>>(v)?;
            let mut out = Vec::with_capacity(pairs.len());
            for (id, mut p) in pairs {
                if let Some((i, o)) = p.price
                    && !(i >= 0.0 && o >= 0.0)
                {
                    return Err(refused(
                        format!("{id}.price"),
                        "(IN . OUT) dollars per million tokens, two numbers of 0 or more",
                    ));
                }
                p.id = id;
                out.push(p);
            }
            values.ai_providers = out;
        }
        "drgnx-ai-roles" => values.ai_roles = de::<Vec<RoleChain>>(v)?,
        "drgnx-agents-matrix" => {
            super::check_matrix(v).map_err(|m| refused("", m))?;
            values.agents_matrix = v.clone();
        }
        "drgnx-agents-away-after" => values.agents_away_after = de(v)?,
        "drgnx-agents-wait-refusals" => values.agents_wait_refusals = de(v)?,
        "drgnx-agents-close-idle-after" => values.agents_close_idle_after = de(v)?,
        "drgnx-agents-checkpoint-cap" => values.agents_checkpoint_cap = de(v)?,
        "drgnx-agents-job-memory" => values.agents_job_memory = de(v)?,
        "drgnx-agents-job-cpus" => values.agents_job_cpus = de(v)?,
        "drgnx-agents-net-hosts" => {
            let Alist(pairs) = de::<Alist<Vec<String>>>(v)?;
            values.agents_net_hosts = pairs;
        }
        "drgnx-agents-container-images" => {
            let Alist(pairs) = de::<Alist<String>>(v)?;
            values.agents_container_images = super::images(pairs);
        }
        "drgnx-agents-silent-after" => {
            let Alist(pairs) = de::<Alist<u64>>(v)?;
            values.agents_silent_after = pairs;
        }
        "drgnx-agents-repeat-limit" => values.agents_repeat_limit = de(v)?,
        "drgnx-agents-no-progress-tokens" => values.agents_no_progress_tokens = de(v)?,
        "drgnx-agents-manager-context" => values.agents_manager_context = de(v)?,
        other => return Err(refused("", format!("{other} is not a runtime setting"))),
    }
    Ok(())
}

/// The value of the runtime setting NAME in VALUES as JSON (what [`from_json`] takes); none for another name.
pub fn to_json(name: &str, values: &RuntimeValues) -> Option<Value> {
    let object = |pairs: Vec<(&str, Value)>| -> Value {
        Value::Object(
            pairs
                .into_iter()
                .map(|(k, mut v)| {
                    if let Value::Object(m) = &mut v {
                        m.remove("name");
                        m.remove("id");
                    }
                    (k.to_string(), v)
                })
                .collect::<Map<_, _>>(),
        )
    };
    Some(match name {
        "drgnx-agents-profiles" => object(
            values
                .agents_profiles
                .iter()
                .map(|p| (p.name.as_str(), enc(p)))
                .collect(),
        ),
        "drgnx-agents-default" => json!(values.agents_default),
        "drgnx-agents-mcp" => json!(values.agents_mcp),
        "drgnx-agents-routes" => object(
            values
                .agents_routes
                .iter()
                .map(|r| (r.role.as_str(), json!(r.profiles)))
                .collect(),
        ),
        "drgnx-agents-openrouter" => json!(values.agents_openrouter),
        "drgnx-agents-allow-unsandboxed" => json!(values.agents_allow_unsandboxed),
        "drgnx-ai-providers" => object(
            values
                .ai_providers
                .iter()
                .map(|p| (p.id.as_str(), enc(p)))
                .collect(),
        ),
        "drgnx-ai-roles" => json!(values.ai_roles),
        "drgnx-agents-matrix" => values.agents_matrix.clone(),
        "drgnx-agents-away-after" => json!(values.agents_away_after),
        "drgnx-agents-wait-refusals" => json!(values.agents_wait_refusals),
        "drgnx-agents-close-idle-after" => json!(values.agents_close_idle_after),
        "drgnx-agents-checkpoint-cap" => json!(values.agents_checkpoint_cap),
        "drgnx-agents-job-memory" => json!(values.agents_job_memory),
        "drgnx-agents-job-cpus" => json!(values.agents_job_cpus),
        "drgnx-agents-net-hosts" => object(
            values
                .agents_net_hosts
                .iter()
                .map(|(k, h)| (k.as_str(), json!(h)))
                .collect(),
        ),
        "drgnx-agents-container-images" => object(
            values
                .agents_container_images
                .iter()
                .map(|c| (c.name.as_str(), json!(c.image)))
                .collect(),
        ),
        "drgnx-agents-silent-after" => object(
            values
                .agents_silent_after
                .iter()
                .map(|(k, n)| (k.as_str(), json!(n)))
                .collect(),
        ),
        "drgnx-agents-repeat-limit" => json!(values.agents_repeat_limit),
        "drgnx-agents-no-progress-tokens" => json!(values.agents_no_progress_tokens),
        "drgnx-agents-manager-context" => json!(values.agents_manager_context),
        _ => return None,
    })
}

fn enc<T: Serialize>(v: &T) -> Value {
    serde_json::to_value(v).expect("a setting value serializes")
}

/// LIST's values put over VALUES, in order; one that does not decode is skipped (the sender was told when it sent).
pub fn apply(values: &mut RuntimeValues, list: &[Override]) {
    for o in list {
        if let Err(e) = from_json(&o.name, &o.value, values) {
            tracing::warn!("the override of {} does not apply: {}", o.name, e.message);
        }
    }
}

/// The runtime settings a project's set may hold: those the Lisp declares `:scope project` (a workspace sets them as
/// data). Every other one is `:scope global :workspace never :agents never` (profiles and their commands, providers
/// and their URLs, `drgnx-agents-allow-unsandboxed`, …): a project never changes it.
pub const PER_PROJECT: &[&str] = &["drgnx-ai-roles"];

/// The first override of LIST that cannot be one: its index and why (a name not in [`RUNTIME_NAMES`], one not in
/// [`PER_PROJECT`] in a project's set (PROJECT true), a value that does not fit the type).
pub fn validate(list: &[Override], project: bool) -> Result<(), (usize, Refused)> {
    for (i, o) in list.iter().enumerate() {
        if !RUNTIME_NAMES.contains(&o.name.as_str()) {
            return Err((
                i,
                refused("name", format!("{} is not a runtime setting", o.name)),
            ));
        }
        if project && !PER_PROJECT.contains(&o.name.as_str()) {
            return Err((
                i,
                refused(
                    "name",
                    format!("{} is a global setting: a project never changes it", o.name),
                ),
            ));
        }
        from_json(&o.name, &o.value, &mut RuntimeValues::default()).map_err(|mut e| {
            e.path = if e.path.is_empty() {
                "value".into()
            } else {
                format!("value.{}", e.path)
            };
            (i, e)
        })?;
    }
    Ok(())
}

/// The sets the editor sent: the global one and one per project.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Overrides {
    global: Option<Vec<Override>>,
    projects: BTreeMap<String, Vec<Override>>,
}

impl Overrides {
    /// The set of PROJECT (none: the global one), if the editor ever sent one.
    pub fn scope(&self, project: Option<&str>) -> Option<&[Override]> {
        match project {
            None => self.global.as_deref(),
            Some(p) => self.projects.get(p).map(Vec::as_slice),
        }
    }

    /// The projects that sent a set.
    pub fn projects(&self) -> impl Iterator<Item = &str> {
        self.projects.keys().map(String::as_str)
    }

    /// LIST is the set of PROJECT now (an empty one clears it, and is still a set that was sent).
    pub fn set(&mut self, project: Option<&str>, list: Vec<Override>) {
        match project {
            None => self.global = Some(list),
            Some(p) => {
                self.projects.insert(p.to_string(), list);
            }
        }
    }

    /// The sets `runtime.db` keeps.
    pub async fn load(db: &urdr::Handle) -> Overrides {
        let rows = db
            .read(|c| {
                let mut s =
                    c.prepare("select key, value from kv where key like 'settings-override:%'")?;
                let rows = s
                    .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
                    .collect::<Result<Vec<_>, _>>()?;
                Ok(rows)
            })
            .await;
        let mut out = Overrides::default();
        match rows {
            Err(e) => tracing::warn!("runtime.db's kept settings do not read: {e}"),
            Ok(rows) => {
                for (key, text) in rows {
                    let scope = key.trim_start_matches(KV_PREFIX);
                    match serde_json::from_str::<Vec<Override>>(&text) {
                        Ok(list) => out.set((scope != "global").then_some(scope), list),
                        Err(e) => tracing::warn!("the kept settings of {scope} do not read: {e}"),
                    }
                }
            }
        }
        out
    }
}

/// PROJECT's `kv` key.
pub fn kv_key(project: Option<&str>) -> String {
    format!("{KV_PREFIX}{}", project.unwrap_or("global"))
}

/// LIST as the text `runtime.db` keeps.
pub fn to_text(list: &[Override]) -> String {
    serde_json::to_string(list).expect("overrides serialize")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::Settings;
    use std::os::unix::fs::PermissionsExt;

    /// A config folder (settings.el with ENTRIES, mode 0600) and `runtime.db`, both in one temp dir.
    struct Rig {
        dir: tempfile::TempDir,
        db: urdr::Handle,
        _store: urdr::Store,
    }

    fn rig(entries: &str) -> Rig {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("settings.el");
        std::fs::write(
            &file,
            format!(";;; settings.el\n(drgnx-settings\n :version 1\n{entries})\n"),
        )
        .unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
        let (_store, db) = crate::runtime_db::open(dir.path()).unwrap();
        Rig { dir, db, _store }
    }

    async fn settings(r: &Rig) -> Settings {
        let s = Settings::new();
        s.open(r.dir.path().to_path_buf(), r.db.clone());
        s.refresh().await;
        s
    }

    fn o(name: &str, value: Value) -> Override {
        Override {
            name: name.into(),
            value,
            source: "test".into(),
        }
    }

    fn default(s: &Settings, project: Option<&str>) -> (Value, bool) {
        s.effective("drgnx-agents-default", project).unwrap()
    }

    fn roles(s: &Settings, project: Option<&str>) -> (Value, bool) {
        s.effective("drgnx-ai-roles", project).unwrap()
    }

    /// A `drgnx-ai-roles` value: one role whose chain is PROVIDER's own model.
    fn chain(provider: &str) -> Value {
        json!([{"role": "chat", "chain": [{"provider": provider, "model": null}]}])
    }

    #[tokio::test]
    async fn project_beats_global_beats_file_beats_default() {
        let bare = rig("");
        assert_eq!(default(&settings(&bare).await, None).0, Value::Null);
        let r = rig("(drgnx-agents-default \"file\")");
        let s = settings(&r).await;
        assert_eq!(default(&s, None), (json!("file"), true));
        assert_eq!(default(&s, Some("p")), (json!("file"), false));
        s.set_overrides(
            None,
            vec![
                o("drgnx-agents-default", json!("global")),
                o("drgnx-ai-roles", chain("global")),
            ],
        )
        .await
        .unwrap();
        s.set_overrides(Some("p"), vec![o("drgnx-ai-roles", chain("proj"))])
            .await
            .unwrap();
        assert_eq!(default(&s, None), (json!("global"), true));
        assert_eq!(roles(&s, None), (chain("global"), true));
        assert_eq!(roles(&s, Some("p")), (chain("proj"), true));
        assert_eq!(default(&s, Some("p")), (json!("global"), true));
        // another project has never sent: the global value, and it is told so
        assert_eq!(roles(&s, Some("q")), (chain("global"), false));
        // what the gateway reads has the global value too
        assert_eq!(
            s.current().loaded.values.agents_default.as_deref(),
            Some("global")
        );
    }

    #[tokio::test]
    async fn empty_clears() {
        let r = rig("(drgnx-agents-default \"file\")");
        let s = settings(&r).await;
        s.set_overrides(None, vec![o("drgnx-agents-default", json!("g"))])
            .await
            .unwrap();
        s.set_overrides(Some("p"), vec![o("drgnx-ai-roles", chain("p"))])
            .await
            .unwrap();
        assert_eq!(s.set_overrides(None, vec![]).await.unwrap(), 0);
        s.set_overrides(Some("p"), vec![]).await.unwrap();
        // back to the file; the project did send, so it is seen
        assert_eq!(default(&s, None), (json!("file"), true));
        assert_eq!(default(&s, Some("p")), (json!("file"), true));
        // and the cleared sets are what restarts find
        let again = settings(&r).await;
        assert_eq!(default(&again, None), (json!("file"), true));
    }

    #[tokio::test]
    async fn persists_across_restart() {
        let r = rig("");
        let s = settings(&r).await;
        let providers = json!({"mine": {"kind": "openai", "url": "https://llm.example/v1",
                                         "key_env": "MINE_KEY", "caps": ["chat"]}});
        s.set_overrides(None, vec![o("drgnx-ai-providers", providers.clone())])
            .await
            .unwrap();
        s.set_overrides(Some("p"), vec![o("drgnx-ai-roles", chain("proj"))])
            .await
            .unwrap();
        drop(s);
        // a new Settings over the same runtime.db, as after a restart
        let s2 = settings(&r).await;
        assert!(
            s2.current()
                .loaded
                .providers
                .iter()
                .any(|p| p.id.as_str() == "mine")
        );
        // global values come back in the type's full form
        assert_eq!(
            s2.effective("drgnx-ai-providers", None).unwrap().0["mine"]["url"],
            providers["mine"]["url"]
        );
        assert_eq!(roles(&s2, Some("p")), (chain("proj"), true));
        assert!(!default(&s2, Some("q")).1);
    }

    /// R4: a project's set never holds a global (security) setting: profiles, providers, allow-unsandboxed, …; the
    /// whole set is refused and nothing changes.
    #[tokio::test]
    async fn a_project_never_overrides_a_global_setting() {
        let r = rig("");
        let s = settings(&r).await;
        let profiles = json!({"evil": {"command": ["sh", "-c", "x"]}});
        for (name, value) in [
            ("drgnx-agents-allow-unsandboxed", json!(true)),
            ("drgnx-agents-profiles", profiles),
            (
                "drgnx-ai-providers",
                json!({"x": {"kind": "openai", "url": "https://evil.example/v1"}}),
            ),
            ("drgnx-agents-default", json!("evil")),
        ] {
            assert!(!PER_PROJECT.contains(&name));
            let e = s
                .set_overrides(
                    Some("p"),
                    vec![o("drgnx-ai-roles", chain("p")), o(name, value)],
                )
                .await
                .err()
                .unwrap_or_else(|| panic!("{name} was taken"));
            assert_eq!(e.path.as_deref(), Some("overrides[1].name"), "{name}");
            assert!(
                e.message.contains("a project never changes it"),
                "{name}: {}",
                e.message
            );
        }
        // nothing was kept: the project has not sent, and the global values hold
        assert!(!roles(&s, Some("p")).1);
        assert!(!s.current().loaded.values.agents_allow_unsandboxed);
        // every runtime setting but those the Lisp declares :scope project is global
        let d = &crate::settings::defaults().values;
        for name in RUNTIME_NAMES {
            let one = [o(name, to_json(name, d).unwrap())];
            assert_eq!(
                validate(&one, true).is_ok(),
                name == "drgnx-ai-roles",
                "{name}"
            );
            assert!(validate(&one, false).is_ok(), "{name}");
        }
    }

    #[tokio::test]
    async fn a_bad_value_has_a_path() {
        let r = rig("");
        let s = settings(&r).await;
        let path = |e: runstav::wire::Error| e.path.unwrap();
        let bad = |list| async { s.set_overrides(None, list).await.err().unwrap() };
        let e = bad(vec![
            o("drgnx-agents-default", json!("ok")),
            o("drgnx-agents-allow-unsandboxed", json!("yes")),
        ])
        .await;
        assert_eq!(path(e), "overrides[1].value");
        let e = bad(vec![o(
            "drgnx-ai-providers",
            json!({"x": {"kind": "openai", "url": "https://h", "price": [-1.0, 2.0]}}),
        )])
        .await;
        assert_eq!(path(e), "overrides[0].value.x.price");
        let e = bad(vec![o(
            "drgnx-agents-openrouter",
            json!({"only": ["bad slug"]}),
        )])
        .await;
        assert_eq!(path(e), "overrides[0].value.only");
        // nothing was kept
        assert_eq!(default(&s, None).0, Value::Null);
        assert!(s.current().loaded.values.agents_default.is_none());
    }

    #[tokio::test]
    async fn unknown_name_refused() {
        let r = rig("");
        let s = settings(&r).await;
        let e = s
            .set_overrides(None, vec![o("drgnx-no-such", json!(1))])
            .await
            .err()
            .unwrap();
        assert_eq!(e.path.as_deref(), Some("overrides[0].name"));
        let e = s.set_overrides(Some("global"), vec![]).await.err().unwrap();
        assert_eq!(e.path.as_deref(), Some("project"));
        assert!(s.effective("drgnx-no-such", None).is_none());
    }

    /// R6: sets of one scope racing each other and refreshes of a changing file: the kv row, memory and what is
    /// published end on the same last set, over the file's last read.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn racing_sets_and_refreshes_agree() {
        let r = rig("(drgnx-agents-mcp (f0))");
        let s = std::sync::Arc::new(settings(&r).await);
        let file = r.dir.path().join("settings.el");
        let mut tasks = Vec::new();
        for i in 0..24 {
            let s = s.clone();
            let file = file.clone();
            tasks.push(tokio::spawn(async move {
                if i % 3 == 0 {
                    std::fs::write(
                        &file,
                        format!(";;; settings.el\n(drgnx-settings\n :version 1\n(drgnx-agents-mcp (f{i})))\n"),
                    )
                    .unwrap();
                    s.refresh().await;
                } else {
                    let v = json!(format!("v{i}"));
                    s.set_overrides(None, vec![o("drgnx-agents-default", v)])
                        .await
                        .unwrap();
                }
            }));
        }
        for t in tasks {
            t.await.unwrap();
        }
        s.refresh().await;
        let mem = s.overrides.lock().unwrap().scope(None).unwrap().to_vec();
        let kept = Overrides::load(&r.db).await;
        assert_eq!(kept.scope(None), Some(mem.as_slice()), "kv and memory");
        let cur = s.current();
        assert_eq!(
            cur.loaded.values.agents_default.as_deref(),
            mem[0].value.as_str(),
            "published"
        );
        assert_eq!(
            cur.loaded.values.agents_mcp,
            s.file.lock().unwrap().loaded.values.agents_mcp,
            "over the file's last read"
        );
    }

    #[test]
    fn every_runtime_setting_round_trips() {
        let d = &crate::settings::defaults().values;
        for name in RUNTIME_NAMES {
            let v = to_json(name, d).unwrap();
            let mut back = RuntimeValues::default();
            from_json(name, &v, &mut back).unwrap_or_else(|e| panic!("{name}: {e:?}"));
            assert_eq!(to_json(name, &back).unwrap(), v, "{name}");
        }
    }
}
