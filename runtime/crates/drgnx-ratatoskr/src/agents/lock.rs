//! Provider locks (Task 9; `docs/guide/security.md`, "What each provider obeys"): `lock::plan(profile, role,
//! effective) -> LaunchPlan` — the argv, environment, session `_meta` and read-only protected paths that make a
//! provider's CLI ask the hub for every permission (Claude ported from `drgnx-agents-job-claude-options`, Codex's
//! `-c` overrides, Gemini's `--approval-mode default`), `Enforced::{Yes, No(why)}`, and `lock::verify` at session
//! start (a lock that does not hold kills the session).

use std::ffi::OsString;
use std::fmt;
use std::path::{Path, PathBuf};

use norn::matrix::Effective;
use runstav::methods::matrix::Role;
use serde_json::{Value, json};

use crate::settings::profiles::{AgentProfile, Provider};

/// Paths in the worktree that stay read-only through Gleipnir whatever the provider (relative: `launch` joins them).
pub const PROTECTED_RO: [&str; 6] = [
    ".claude",
    ".codex",
    ".gemini",
    ".envrc",
    ".git/hooks",
    "mise.toml",
];

/// The largest Claude settings file read for deny/ask rules, in bytes.
const SETTINGS_MAX: u64 = 1_048_576;

/// Codex's lock is unproven until the sandboxed launch (Task 10) and the laundering rows pass (Calls made 8,
/// plan "Entry criteria" 3): flip it then.
const CODEX_LOCK_PROVEN: bool = false;

/// Whether a lock holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Enforced {
    Yes,
    /// Not enforced, and why (shown to the user).
    No(&'static str),
}

/// What launching a session needs from its provider's lock.
#[derive(Clone, Debug, PartialEq)]
pub struct LaunchPlan {
    pub argv: Vec<OsString>,
    /// Added to the process environment (the profile's own `env` is `launch`'s).
    pub env: Vec<(String, String)>,
    /// `_meta` of `session/new` and `session/load`.
    pub session_meta: Option<Value>,
    pub protected_ro: Vec<PathBuf>,
    /// The one place under the home where the CLI keeps its login token (`~/.claude`, `~/.codex`, `~/.gemini`): the
    /// sandbox binds it for this CLI alone (Task 10).
    pub login_dir: Option<PathBuf>,
    pub enforced: Enforced,
}

/// A lock that does not hold: the session is killed.
#[derive(Debug, PartialEq, Eq)]
pub struct LockBroken(pub String);

impl fmt::Display for LockBroken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "the provider's lock does not hold: {}", self.0)
    }
}

impl std::error::Error for LockBroken {}

/// The options a job session's Claude Code gets (`_meta.claudeCode.options`): the port of
/// `drgnx-agents-job-claude-options` (core/drgnx-agents.el).
fn claude_options() -> Value {
    json!({
        "allowDangerouslySkipPermissions": false,
        "managedSettings": {
            "allowManagedPermissionRulesOnly": true,
            "allowManagedHooksOnly": true,
            "permissions": {"disableBypassPermissionsMode": "disable", "disableAutoMode": "disable"},
        },
        "strictMcpConfig": true,
        "settings": {"sandbox": {"enabled": false}},
    })
}

/// `NAME=value` strings as the agent's process sees them, as an object: the first entry of a name decides, so a bare
/// name before a value leaves it out (`drgnx-agents--env-object`).
fn env_object(env: &[String]) -> Value {
    let mut seen: Vec<&str> = Vec::new();
    let mut object = serde_json::Map::new();
    for e in env {
        let (name, value) = match e.split_once('=') {
            Some((n, v)) => (n, Some(v)),
            None => (e.as_str(), None),
        };
        if name.is_empty() || seen.contains(&name) {
            continue;
        }
        seen.push(name);
        if let Some(v) = value {
            object.insert(name.to_string(), Value::String(v.to_string()));
        }
    }
    Value::Object(object)
}

/// The launch plan of profile P in ROLE.  `_e` (what the session may do) does not shape a lock: every action goes
/// through the matrix at the permission seam; a lock only makes the CLI ask.
pub fn plan(p: &AgentProfile, role: Role, _e: &Effective) -> LaunchPlan {
    let protected_ro: Vec<PathBuf> = PROTECTED_RO.iter().map(PathBuf::from).collect();
    let mut argv: Vec<OsString> = p.command.iter().map(OsString::from).collect();
    let mut env = Vec::new();
    let mut session_meta = None;
    let enforced = match p.provider() {
        None => Enforced::No("drgnx has no lock for this agent's CLI"),
        Some(Provider::Claude) => {
            if p.ai.is_some() && matches!(role, Role::Worker | Role::Manager) {
                env.push(("CLAUDE_CODE_PROMPT_CACHE_TTL".to_string(), "1h".to_string()));
            }
            let mut all: Vec<String> = p.env.clone();
            all.extend(env.iter().map(|(k, v)| format!("{k}={v}")));
            let mut options = claude_options();
            options["env"] = env_object(&all);
            session_meta = Some(json!({"claudeCode": {"options": options}}));
            Enforced::Yes
        }
        Some(Provider::Codex) => {
            // codex-acp 0.16 takes Codex's `-c key=value` overrides (TOML values).  Gleipnir is the one sandbox.
            for kv in [
                "approval_policy={ granular = { sandbox_approval = true, rules = true, mcp_elicitations = true, \
                 request_permissions = true, skill_approval = true } }",
                "approvals_reviewer=\"user\"",
                "sandbox_mode=\"danger-full-access\"",
            ] {
                argv.push("-c".into());
                argv.push(kv.into());
            }
            if CODEX_LOCK_PROVEN {
                Enforced::Yes
            } else {
                Enforced::No(
                    "Codex's lock is not proven yet (sandboxed launch and laundering rows)",
                )
            }
        }
        Some(Provider::Gemini) => {
            // No YOLO, whatever the profile's command says.
            let mut kept: Vec<OsString> = Vec::new();
            let mut skip = false;
            for a in std::mem::take(&mut argv) {
                let s = a.to_string_lossy();
                if skip {
                    skip = false;
                } else if s == "--approval-mode" {
                    skip = true;
                } else if !(s == "--yolo" || s == "-y" || s.starts_with("--approval-mode=")) {
                    kept.push(a);
                }
            }
            argv = kept;
            argv.push("--approval-mode".into());
            argv.push("default".into());
            Enforced::Yes
        }
    };
    let login_dir = p.provider().and_then(|pv| {
        let name = match pv {
            Provider::Claude => ".claude",
            Provider::Codex => ".codex",
            Provider::Gemini => ".gemini",
        };
        std::env::var_os("HOME")
            .filter(|h| !h.is_empty())
            .map(|h| PathBuf::from(h).join(name))
    });
    LaunchPlan {
        argv,
        env,
        session_meta,
        protected_ro,
        login_dir,
        enforced,
    }
}

/// The deny and ask rules of one Claude settings file, `(deny, ask)`; none when it is not a regular file (a link is
/// not followed), is over [`SETTINGS_MAX`], is outside WITHIN (when given, links resolved) or does not parse.
fn rules_of(file: &Path, within: Option<&Path>) -> Option<(Vec<String>, Vec<String>)> {
    let meta = std::fs::symlink_metadata(file).ok()?;
    if !meta.is_file() || meta.len() > SETTINGS_MAX {
        return None;
    }
    if let Some(w) = within
        && !std::fs::canonicalize(file)
            .ok()?
            .starts_with(std::fs::canonicalize(w).ok()?)
    {
        return None;
    }
    let v: Value = serde_json::from_slice(&std::fs::read(file).ok()?).ok()?;
    let perms = v.get("permissions")?.as_object()?;
    let strings = |k: &str| -> Vec<String> {
        perms
            .get(k)
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|s| s.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default()
    };
    Some((strings("deny"), strings("ask")))
}

/// The deny and ask rules of Claude's user settings (`settings.json` in CONFIG_DIR; a link there is followed, as
/// dotfile managers make one) and of CWD's `.claude/settings.json` and `.claude/settings.local.json` (never through
/// a link), without duplicates (`drgnx-agents--claude-deny-ask`).
pub fn claude_deny_ask(config_dir: &Path, cwd: &Path) -> (Vec<String>, Vec<String>) {
    let user = std::fs::canonicalize(config_dir.join("settings.json"))
        .unwrap_or_else(|_| config_dir.join("settings.json"));
    let all = [
        rules_of(&user, None),
        rules_of(&cwd.join(".claude/settings.json"), Some(cwd)),
        rules_of(&cwd.join(".claude/settings.local.json"), Some(cwd)),
    ];
    let (mut deny, mut ask) = (Vec::<String>::new(), Vec::<String>::new());
    for (d, a) in all.into_iter().flatten() {
        for r in d {
            if !deny.contains(&r) {
                deny.push(r);
            }
        }
        for r in a {
            if !ask.contains(&r) {
                ask.push(r);
            }
        }
    }
    (deny, ask)
}

impl LaunchPlan {
    /// Adds the deny and ask rules of the user's and the worktree's Claude settings to the policy tier's
    /// permissions (`drgnx-agents--session-meta`; never an allow rule).  A no-op for a plan with no Claude options.
    pub fn with_claude_rules(mut self, deny: Vec<String>, ask: Vec<String>) -> Self {
        if let Some(perms) = self
            .session_meta
            .as_mut()
            .and_then(|m| m.pointer_mut("/claudeCode/options/managedSettings/permissions"))
            .and_then(Value::as_object_mut)
        {
            if !deny.is_empty() {
                perms.insert("deny".into(), json!(deny));
            }
            if !ask.is_empty() {
                perms.insert("ask".into(), json!(ask));
            }
        }
        self
    }
}

impl LaunchPlan {
    /// Codex only: the worktree CWD is marked `untrusted` (`projects."<cwd>".trust_level`), so a `.codex/config.toml`
    /// in it is not loaded as the user's (ledger D9-3).  A no-op for another provider's plan.
    pub fn with_codex_untrusted(mut self, p: &AgentProfile, cwd: &Path) -> Self {
        if p.provider() == Some(Provider::Codex) {
            let q = cwd
                .to_string_lossy()
                .replace('\\', "\\\\")
                .replace('"', "\\\"");
            self.argv.push("-c".into());
            self.argv
                .push(format!("projects.\"{q}\".trust_level=\"untrusted\"").into());
        }
        self
    }
}

/// Checks the lock at session start: the mode the CLI is put in is the asking one.  Claude and Gemini are set to
/// `default` (a refusal ends the session); Codex is left alone, as codex-acp's `auto`/`full-access` presets would
/// replace the `-c` overrides.  A profile with no lock fails.  The probe permission is the session's (Task 8b).
pub async fn verify(
    conn: &hermod::Conn,
    sid: &hermod::SessionId,
    p: &AgentProfile,
) -> Result<(), LockBroken> {
    match p.provider() {
        Some(Provider::Claude | Provider::Gemini) => conn
            .set_mode(sid, "default")
            .await
            .map_err(|e| LockBroken(format!("`default` mode refused: {e}"))),
        Some(Provider::Codex) => Ok(()),
        None => Err(LockBroken("this agent has no lock".into())),
    }
}

#[cfg(test)]
mod tests;
