//! The hub's hook points: where the rules and the approved plugins' hooks are asked, and what their answers become.
//!
//! `after_edit` is the point after an agent's edit. It runs off the agent's turn (the session's write request or its
//! completed edit step is handled in its own task), inside the point's 5 s budget, and it never widens anything: a
//! hook's answer is a note, a refusal of what an fs write would put on disk, or (fs writes only) a replacement of the
//! content.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use brokkr::{Host, HostIo, Installed, Limits, Plugin};
use norn::hooks::{Decision, HookInput, Outcome, PluginHooks, Point, Record, Source, combine, run};
use serde_json::{Value, json};

use crate::agents::session::Session;
use crate::front::Front;
use crate::plugins::Plugins;

/// The whole point's time: every rule and hook at `after-edit` shares it.
pub const AFTER_EDIT_BUDGET: Duration = Duration::from_secs(5);

/// An edit the hooks are asked about.
#[derive(Clone, Debug, Default)]
pub struct EditInfo {
    /// The file, absolute.
    pub path: PathBuf,
    /// The unified diff of the edit, when the hub can tell it.
    pub diff: Option<String>,
    /// What the hub is about to write: only for `fs/write_text_file`, the one edit a hook may change.
    pub content: Option<String>,
    /// The timeline step, when known.
    pub step: Option<i64>,
}

/// The shared plugin host, made at the first hook that needs it.
fn host() -> Result<&'static Host, String> {
    static HOST: OnceLock<Result<Host, String>> = OnceLock::new();
    HOST.get_or_init(|| Host::new(Limits::default()).map_err(|e| e.to_string()))
        .as_ref()
        .map_err(Clone::clone)
}

/// The loaded form of INSTALLED, kept by name and hash so a plugin is compiled once.
fn loaded(host: &Host, installed: &[Arc<Installed>]) -> (Vec<Arc<Plugin>>, Vec<String>) {
    type Cache = Mutex<HashMap<(String, [u8; 32]), Arc<Plugin>>>;
    static CACHE: OnceLock<Cache> = OnceLock::new();
    let cache = CACHE.get_or_init(Default::default);
    let mut out = Vec::new();
    let mut failed = Vec::new();
    for i in installed {
        let key = (i.manifest.name.as_str().to_owned(), i.hash);
        let hit = cache
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&key)
            .cloned();
        let plugin = match hit {
            Some(p) => p,
            None => match host.load(i, i.hash) {
                Ok(p) => {
                    let p = Arc::new(p);
                    cache
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .insert(key, p.clone());
                    p
                }
                Err(e) => {
                    failed.push(format!("hook {} not loaded: {e}", i.manifest.name.as_str()));
                    continue;
                }
            },
        };
        out.push(plugin);
    }
    (out, failed)
}

fn proceed(annotations: Vec<String>) -> Outcome {
    Outcome {
        decision: Decision::Proceed { changed: None },
        decided_by: None,
        annotations,
        provenance: Vec::new(),
    }
}

/// The hooks and rules of PROJECT asked about EDIT in SESSION (a file under ROOT), through IO.
pub(crate) async fn run_after_edit(
    plugins: &Plugins,
    project: Option<&str>,
    root: &Path,
    io: Arc<dyn HostIo>,
    session: &str,
    edit: &EditInfo,
) -> Outcome {
    let rules = plugins.rules_for(project);
    let installed = plugins.enabled_for(project);
    let rel = edit
        .path
        .strip_prefix(root)
        .unwrap_or(&edit.path)
        .to_path_buf();
    let mut detail = json!({"edit": {"path": rel, "diff": edit.diff}});
    if let Some(c) = &edit.content {
        detail["edit"]["content"] = json!(c);
    }
    let input = HookInput {
        point: Point::AfterEdit,
        session: Some(session.to_owned()),
        step: edit.step,
        tool_kind: Some("edit".into()),
        tool: None,
        paths: vec![rel],
        command: None,
        detail,
    };
    if !norn::hooks::subscribed(&input, &rules, &installed) {
        return proceed(Vec::new());
    }
    let host = match host() {
        Ok(h) => h,
        Err(e) => return proceed(vec![format!("hooks did not run: {e}")]),
    };
    let (plugs, failed) = loaded(host, &installed);
    let hooks = PluginHooks {
        host,
        io,
        refresh: |i: &mut HookInput| {
            if let Some(p) = i.detail.pointer("/edit/path").and_then(Value::as_str) {
                i.paths = vec![PathBuf::from(p)];
            }
        },
    };
    let records = run(
        &input,
        AFTER_EDIT_BUDGET,
        edit.content.is_some(),
        &rules,
        &plugs,
        &hooks,
    )
    .await;
    let mut out = combine(None, edit.content.is_some(), &records);
    out.annotations.extend(failed);
    out
}

/// The hooks asked about EDIT, an edit SESSION made (or is making). Never blocks the editor: callers run it in a
/// task of their own, and a hook that does not answer in time is a note or a refusal of this edit alone.
pub async fn after_edit(front: &Front, s: &Session, edit: &EditInfo) -> Outcome {
    let project = s.project();
    let root = s.cwd().to_path_buf();
    let manifests: Vec<_> = front
        .core
        .plugins
        .enabled_for(project.as_deref())
        .iter()
        .map(|p| p.manifest.clone())
        .collect();
    let refs: Vec<&brokkr::Manifest> = manifests.iter().collect();
    let io: Arc<dyn HostIo> = match crate::plugins::host_io(
        front,
        Some((
            crate::plugins::io::IoCtx::Session(s.id.clone()),
            crate::agents::launch::NetCell::ProviderOnly,
        )),
        &refs,
    ) {
        Ok(io) => io,
        Err(_) => return proceed(vec!["hooks did not run: the plugins are not open".into()]),
    };
    run_after_edit(
        &front.core.plugins,
        project.as_deref(),
        &root,
        io,
        &s.id,
        edit,
    )
    .await
}

/// The replacement content a `change` verdict carries, and the name of the hook that made it.
pub fn changed_content(out: &Outcome) -> Option<(String, String)> {
    let (Decision::Proceed {
        changed: Some(c), ..
    }
    | Decision::Ask {
        changed: Some(c), ..
    }) = &out.decision
    else {
        return None;
    };
    let content = c.get("content")?.as_str()?.to_owned();
    let name = out
        .provenance
        .iter()
        .rev()
        .find(|r: &&Record| matches!(r.verdict, Some(brokkr::Verdict::Change(_))))
        .map(|r| match &r.source {
            Source::Plugin { name, .. } => name.clone(),
            other => other.name(),
        })
        .unwrap_or_default();
    Some((content, name))
}

/// What the agent is told when a hook changed its write.
pub fn change_notice(hook: &str, path: &str) -> String {
    format!(
        "drgnx's hook {hook} changed your write to {path}; read the file before editing it again"
    )
}

/// The error an fs write is refused with.
pub fn refusal_message(reason: &str) -> String {
    format!("drgnx refused the write: {reason}")
}

/// What a deny of an edit is called, for the agent and the timeline.
pub fn refusal_of(out: &Outcome) -> Option<(String, String)> {
    let Decision::Deny(reason) = &out.decision else {
        return None;
    };
    let name = out
        .decided_by
        .and_then(|i| out.provenance.get(i))
        .map(|r| r.source.name())
        .unwrap_or_default();
    Some((name, reason.clone()))
}

#[cfg(test)]
mod tests;
