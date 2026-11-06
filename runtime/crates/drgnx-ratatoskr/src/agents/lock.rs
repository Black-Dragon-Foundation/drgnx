//! Provider locks (`docs/guide/security.md`, "What each provider obeys"): `lock::plan(profile, role, effective) ->
//! LaunchPlan` — the argv, environment, session `_meta`, read-only protected paths and hub-written read-only files that
//! make a provider's CLI ask the hub for every permission — `Enforced::{Yes, No(why)}`, and `lock::verify` at session
//! start (a lock that does not hold kills the session).
//!
//! - **Claude:** `_meta.claudeCode.options` (ported from `drgnx-agents-job-claude-options`), with managed ask rules
//!   for the kinds the session's hooks subscribe to ([`LaunchPlan::with_hook_asks`]).
//! - **Codex** (codex-acp 2.x reads its environment only): `INITIAL_AGENT_MODE` (its `read-only` mode, which
//!   [`verify`] checks the adapter reports) and `CODEX_CONFIG`, `/etc/codex/requirements.toml` pinning that mode's
//!   policy and `/etc/codex/config.toml` holding a managed PreToolUse hook that calls the hub's `before_tool` tool,
//!   both bound read-only by the sandbox.
//! - **Gemini:** `--approval-mode default`, and an admin-tier `--admin-policy` asking for the subscribed kinds' tools.
//! - **Kimi Code:** a hub-owned `KIMI_CODE_HOME` whose `config.toml` (manual mode, ask rules) is bound read-only.
//! - **DeepSeek Harness:** a hub-owned `DSH_HOME`, and `--patch` with an overlay keeping `approval.policy: ask`.
//!
//! The provider-specific files that depend on the session (its worktree, its subscribed kinds) are added by
//! [`LaunchPlan::with_locks`]; [`hooked`] says which subscribed kinds reach the hooks, and [`unhooked_refusal`]
//! refuses a session that would run a subscribed kind unhooked.

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

/// The entries of [`PROTECTED_RO`] that are files (the others are folders): a missing one is created empty to be pinned.
pub const PROTECTED_FILES: [&str; 2] = [".envrc", "mise.toml"];

/// The largest Claude settings file read for deny/ask rules, in bytes.
const SETTINGS_MAX: u64 = 1_048_576;

/// Codex's lock is unproven until the sandboxed launch and the laundering rows pass on it: flip it then.
const CODEX_LOCK_PROVEN: bool = false;

/// DeepSeek Harness's lock is unproven until the drgnx ask plugin its overlay inserts ships in the installed `dsh`
/// (the fork's `@deepseek-ai/dsh-acp-drgnx-ask`, resolvable from its profile), a sandboxed launch row passes on it, and
/// the session's start can tell the plugin loaded (a patch to a row the bundle lacks is only a Loader warning): flip
/// it then.
const DSH_LOCK_PROVEN: bool = false;

/// Codex's requirements layer and its managed (System) config, bound read-only inside the sandbox; the user's own
/// `/etc` is never touched.
pub const CODEX_REQUIREMENTS: &str = "/etc/codex/requirements.toml";
pub const CODEX_MANAGED: &str = "/etc/codex/config.toml";

/// The codex-acp mode Codex's lock asks for (`INITIAL_AGENT_MODE`): codex-acp 2.5.0's `read-only`
/// (`src/AgentMode.ts:39-51`), whose every turn is `on-request` approvals by the user in Codex's read-only sandbox.
/// codex-acp takes an id it does not know for its default, `agent` (auto review by a model; `:95`, `:144-151`),
/// silently, so the lock holds only when the adapter reports this mode ([`codex_mode_confirmed`]).
pub const CODEX_MODE: &str = "read-only";

/// The MCP servers a session can get, whose tools Codex asks about before it runs them.
const CODEX_MCP_SERVERS: [&str; 3] = ["drgnx", "drgnx-search", "drgnx-plugins"];

/// The `drgnx` server's tool Codex's managed PreToolUse hook calls.
pub const BEFORE_TOOL: &str = "before_tool";

/// Where Gemini CLI looks for system policies: one `.toml` there and it ignores `--admin-policy`.
pub const GEMINI_SYSTEM_POLICIES: &str = "/etc/gemini-cli/policies";

const GEMINI_SHADOWED: &str =
    "/etc/gemini-cli/policies holds a policy; the admin policy is ignored";

/// The hub-owned homes of Kimi Code (`KIMI_CODE_HOME`) and DeepSeek Harness (`DSH_HOME`), under the hub's state
/// folder's `agents/`.
const KIMI_HOME: &str = "kimi-code";
const DSH_HOME: &str = "dsh";

/// The flags that put Kimi Code in a mode that does not ask.
const KIMI_NO_ASK: [&str; 5] = ["--yolo", "-y", "--yes", "--auto-approve", "--auto"];

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
    /// sandbox shows this CLI alone what [`login_entries`] names of it (Task 10).
    pub login_dir: Option<PathBuf>,
    pub enforced: Enforced,
    /// The session's gateway token is good on its `gateway.sock`: the sandbox relays a port to that socket and points
    /// `ANTHROPIC_BASE_URL` at it (`sandbox::session_spec`).  Set by the session's start for a gateway profile, never
    /// by a lock.
    pub gateway: bool,
    /// The session's shell steps are traced (`work::trace`): per step through Gleipnir's wrapper, or over the whole
    /// tree; the spec gets the hand-off socket (`sandbox::session_spec`).  Set by the session's start, never by a lock.
    pub trace: Option<gleipnir::trace::Scope>,
    /// Hub-written files the agent reads and never writes, `(path, content)`: one in the session's own folder is
    /// written there (the agent reads that folder and never writes it, on every target); one elsewhere (Codex's
    /// `/etc/codex` files, Kimi Code's `config.toml`) is bound read-only at its path, which only the full tier can do
    /// (`sandbox::session_spec` refuses the launch elsewhere).
    pub ro_files: Vec<(PathBuf, Vec<u8>)>,
    /// Variables that get the gateway's base URL beside `ANTHROPIC_BASE_URL` on a gateway plan (Kimi Code's
    /// `KIMI_MODEL_BASE_URL`, DeepSeek Harness's `DEEPSEEK_BASE_URL`).
    pub gateway_url_env: Vec<String>,
}

/// Where a session's lock puts what it writes, and what it reads of the host.
#[derive(Clone, Debug)]
pub struct LockAt {
    /// The session's working folder (Codex marks it untrusted).
    pub cwd: PathBuf,
    /// The session's own lock folder (`lock` in its session dir): Gemini's admin policy, DeepSeek's overlay.
    pub dir: PathBuf,
    /// [`GEMINI_SYSTEM_POLICIES`] (a test's stand-in).
    pub gemini_policies: PathBuf,
}

impl LockAt {
    /// The lock folder of the session whose dir is RUN, working in CWD.
    pub fn new(cwd: &Path, run: &Path) -> LockAt {
        LockAt {
            cwd: cwd.to_path_buf(),
            dir: run.join("lock"),
            gemini_policies: PathBuf::from(GEMINI_SYSTEM_POLICIES),
        }
    }
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
    let mut ro_files = Vec::new();
    let enforced = match p.provider() {
        None => Enforced::No("drgnx has no lock for this agent's CLI"),
        Some(Provider::Claude) => {
            // no telemetry, error reports or update checks: the session's proxy denies those hosts anyway, and a
            // sandboxed CLI should not keep trying them (code.claude.com/docs/en/network-config, env-vars)
            env.push((
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC".to_string(),
                "1".to_string(),
            ));
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
            // codex-acp 2.x reads its environment only (an argv `-c` is a no-op there, and a profile's own one is
            // dropped): every turn carries its mode's approval policy and sandbox (`CodexAcpClient.ts`, `sendPrompt`),
            // so the policy is the mode, CODEX_CONFIG says the same, and the two read-only files of /etc/codex pin it.
            argv = strip(argv, &[], &["-c", "--config"]);
            env.push(("INITIAL_AGENT_MODE".to_string(), CODEX_MODE.to_string()));
            env.push(("CODEX_CONFIG".to_string(), codex_config(None)));
            ro_files.push((
                PathBuf::from(CODEX_REQUIREMENTS),
                CODEX_REQUIREMENTS_TOML.as_bytes().to_vec(),
            ));
            ro_files.push((PathBuf::from(CODEX_MANAGED), codex_managed(false)));
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
            argv = strip(argv, &["--yolo", "-y"], &["--approval-mode"]);
            argv.push("--approval-mode".into());
            argv.push("default".into());
            Enforced::Yes
        }
        Some(Provider::Kimi) => {
            // no mode that does not ask; its one config file is the hub's (`with_locks` writes the ask rules)
            argv = strip(argv, &KIMI_NO_ASK, &[]);
            if let Some(home) = hub_home(KIMI_HOME) {
                env.push((
                    "KIMI_CODE_HOME".to_string(),
                    home.to_string_lossy().into_owned(),
                ));
                ro_files.push((home.join("config.toml"), kimi_config(&[])));
            }
            Enforced::Yes
        }
        Some(Provider::DeepSeek) => {
            if let Some(home) = hub_home(DSH_HOME) {
                env.push(("DSH_HOME".to_string(), home.to_string_lossy().into_owned()));
            }
            if DSH_LOCK_PROVEN {
                Enforced::Yes
            } else {
                Enforced::No(
                    "DeepSeek Harness's lock is not proven yet (the drgnx ask plugin ships with its fork)",
                )
            }
        }
    };
    let login_dir = p.provider().and_then(|pv| {
        let name = match pv {
            Provider::Claude => ".claude",
            Provider::Codex => ".codex",
            Provider::Gemini => ".gemini",
            Provider::Kimi => return hub_home(KIMI_HOME),
            Provider::DeepSeek => return hub_home(DSH_HOME),
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
        gateway: false,
        trace: None,
        ro_files,
        gateway_url_env: Vec::new(),
    }
}

/// ARGV without the flags in DROP and the flags in DROP_WITH_VALUE with the value after each (or joined by `=`).  The
/// program itself is kept.
fn strip(argv: Vec<OsString>, drop: &[&str], drop_with_value: &[&str]) -> Vec<OsString> {
    let mut kept: Vec<OsString> = Vec::new();
    let mut skip = false;
    for (i, a) in argv.into_iter().enumerate() {
        let s = a.to_string_lossy();
        if i == 0 {
            kept.push(a);
        } else if skip {
            skip = false;
        } else if drop_with_value.contains(&s.as_ref()) {
            skip = true;
        } else if !(drop.contains(&s.as_ref())
            || drop_with_value
                .iter()
                .any(|f| s.starts_with(&format!("{f}="))))
        {
            kept.push(a);
        }
    }
    kept
}

/// The hub-owned home NAME of a CLI (`agents/NAME` in the hub's state folder).
fn hub_home(name: &str) -> Option<PathBuf> {
    let state = runstav::paths::state_dir(&runstav::paths::Env::process());
    (!state.as_os_str().is_empty()).then(|| state.join("agents").join(name))
}

/// What a session's Codex runs under (`CODEX_CONFIG`): [`CODEX_MODE`]'s policy (approvals the user's client gives,
/// never a reviewer model; Codex's read-only sandbox inside Gleipnir, so a write or a network call asks); no hosted web
/// search (it can neither ask nor be hooked); the MCP tools prompt; CWD (when known) is untrusted, so a
/// `.codex/config.toml` in it is not loaded as the user's.  Never `approval_policy = "untrusted"`: Codex 0.165 refuses
/// a config that has it (`core/src/config/mod.rs:3898-3903`).
fn codex_config(cwd: Option<&Path>) -> String {
    let mut c = json!({
        "approval_policy": "on-request",
        "approvals_reviewer": "user",
        "sandbox_mode": "read-only",
        "web_search": "disabled",
    });
    let servers: serde_json::Map<String, Value> = CODEX_MCP_SERVERS
        .iter()
        .map(|s| {
            (
                s.to_string(),
                json!({"default_tools_approval_mode": "prompt"}),
            )
        })
        .collect();
    c["mcp_servers"] = Value::Object(servers);
    if let Some(cwd) = cwd {
        let mut projects = serde_json::Map::new();
        projects.insert(
            cwd.to_string_lossy().into_owned(),
            json!({"trust_level": "untrusted"}),
        );
        c["projects"] = Value::Object(projects);
    }
    c.to_string()
}

/// Codex's requirements layer (`config/src/config_requirements.rs:1044-1094`): only [`CODEX_MODE`]'s policy, and only
/// managed hooks.  A turn in another codex-acp mode (`agent`: the `auto_review` reviewer; `workspace-write`: its
/// sandbox; `agent-full-access`: `never`) breaks one of them, and Codex refuses it (`core/src/session/
/// step_settings.rs:283-291`; the sandbox, `config/src/config_requirements.rs:1929-1958`).
const CODEX_REQUIREMENTS_TOML: &str = "\
# drgnx: the hub's requirements for this session's Codex (read-only inside its sandbox).
allowed_approval_policies = [\"on-request\"]
allowed_approvals_reviewers = [\"user\"]
allowed_sandbox_modes = [\"read-only\"]
allowed_web_search_modes = [\"disabled\"]
allow_managed_hooks_only = true
";

/// Codex's managed config: with HOOK, a PreToolUse hook on every tool that calls the `drgnx` server's
/// [`BEFORE_TOOL`] (Codex fails it open on a timeout or an error; its approvals still fail closed).
fn codex_managed(hook: bool) -> Vec<u8> {
    let mut t = String::from(
        "# drgnx: the hub's managed layer for this session's Codex (read-only inside its sandbox).\n",
    );
    if hook {
        t.push_str(&format!(
            "\n[[hooks.PreToolUse]]\nmatcher = \".*\"\n\n[[hooks.PreToolUse.hooks]]\ntype = \"mcp_tool\"\n\
             server = \"drgnx\"\ntool = \"{BEFORE_TOOL}\"\ntimeout = 10\n"
        ));
    }
    t.into_bytes()
}

/// Gemini CLI's main-agent tools of each kind, as its policy names them.
fn gemini_tools(kind: &str) -> Option<&'static [&'static str]> {
    Some(match kind {
        "read" => &["read_file", "read_many_files"],
        "search" => &["glob", "grep_search", "list_directory"],
        "fetch" => &["web_fetch", "google_web_search"],
        "execute" => &["run_shell_command"],
        "edit" => &["write_file", "replace"],
        _ => return None,
    })
}

/// Gemini's admin-tier policy for KINDS (none of them `drgnx`): their tools and every MCP tool ask the user's client
/// (a kind whose tools drgnx cannot name: every tool); a subagent's tools, which never reach the client, and the
/// bundled docs, which never ask, are refused.
fn gemini_policy(kinds: &[&str]) -> Vec<u8> {
    let rule = |key: &str, value: &str, decision: &str| {
        format!("\n[[rule]]\n{key} = \"{value}\"\ndecision = \"{decision}\"\npriority = 999\n")
    };
    let mut t = String::from(
        "# drgnx: the hub's admin policy for this session's Gemini CLI: the hooked kinds ask, what cannot ask is \
         refused.\n",
    );
    let named: Option<Vec<&str>> = kinds
        .iter()
        .map(|k| gemini_tools(k))
        .collect::<Option<Vec<_>>>()
        .map(|l| l.concat());
    match &named {
        Some(tools) => {
            for tool in tools {
                t.push_str(&rule("toolName", tool, "ask_user"));
            }
        }
        None => t.push_str(&rule("toolName", "*", "ask_user")),
    }
    t.push_str(
        "\n[[rule]]\nmcpName = \"*\"\ntoolName = \"*\"\ndecision = \"ask_user\"\npriority = 999\n",
    );
    t.push_str(
        "\n[[rule]]\ntoolName = \"*\"\nsubagent = \"*\"\ndecision = \"deny\"\npriority = 999\n",
    );
    if named.is_none() || kinds.contains(&"read") {
        t.push_str(&rule("toolName", "get_internal_docs", "deny"));
    }
    t.into_bytes()
}

/// Why Gemini CLI 0.67 would drop the policy TEXT, if it would.  Its loader drops a whole file that fails its schema
/// and runs on without it, telling only its stderr at exit in ACP mode (`packages/core/src/policy/toml-loader.ts:
/// 376-389`, `config.ts:361-370`; `packages/cli/src/gemini.tsx:478-483`), so the lock checks what the schema needs
/// (`toml-loader.ts:39-70`) on every `[[rule]]` of the TOML it writes (`key = value` lines): `toolName`, a non-empty
/// string or an array (`:40`, `:419-430`), `decision` one of `allow`, `deny`, `ask_user` (`:46`, `types.ts:10-14`),
/// `priority` an integer in 0..=999 (`:52-62`).
fn gemini_policy_problem(text: &str) -> Option<String> {
    let mut rules: Vec<Vec<(&str, &str)>> = Vec::new();
    for line in text.lines().map(str::trim) {
        if line == "[[rule]]" {
            rules.push(Vec::new());
        } else if !line.starts_with('#')
            && let (Some(rule), Some((k, v))) = (rules.last_mut(), line.split_once('='))
        {
            rule.push((k.trim(), v.trim()));
        }
    }
    rules.iter().enumerate().find_map(|(i, rule)| {
        let get = |k: &str| rule.iter().find(|(key, _)| *key == k).map(|(_, v)| *v);
        let n = i + 1;
        let tool_ok = get("toolName")
            .is_some_and(|v| v != "\"\"" && (v.starts_with('"') || v.starts_with('[')));
        let decision_ok = matches!(
            get("decision"),
            Some("\"allow\"" | "\"deny\"" | "\"ask_user\"")
        );
        let priority_ok = get("priority")
            .and_then(|p| p.parse::<i64>().ok())
            .is_some_and(|p| (0..=999).contains(&p));
        if !tool_ok {
            Some(format!(
                "rule {n}: toolName must be a non-empty string or an array"
            ))
        } else if !decision_ok {
            Some(format!(
                "rule {n}: decision must be allow, deny or ask_user"
            ))
        } else if !priority_ok {
            Some(format!("rule {n}: priority must be an integer in 0..=999"))
        } else {
            None
        }
    })
}

/// The file name of the admin POLICY: `drgnx-` and the first 16 hex digits of its SHA-256.  drgnx's Gemini fork counts
/// the rules whose source is `Admin: <the file's name>` (`packages/cli/src/acp/acpDrgnxPanel.ts:56-86`), and a policy in
/// Gemini's system folder has the same source form, so the name is one no such file has by accident.
fn gemini_policy_name(policy: &[u8]) -> String {
    use sha2::Digest;
    let hash: String = sha2::Sha256::digest(policy)
        .iter()
        .take(8)
        .map(|b| format!("{b:02x}"))
        .collect();
    format!("drgnx-{hash}.toml")
}

/// How many rules the lock wrote in the policy file PLAN's `--admin-policy` names (none passed: 0).
pub fn gemini_policy_rules(plan: &LaunchPlan) -> usize {
    let Some(file) = plan
        .argv
        .windows(2)
        .find(|w| w[0] == "--admin-policy")
        .map(|w| PathBuf::from(&w[1]))
    else {
        return 0;
    };
    plan.ro_files
        .iter()
        .find(|(p, _)| *p == file)
        .map_or(0, |(_, b)| {
            String::from_utf8_lossy(b)
                .lines()
                .filter(|l| l.trim() == "[[rule]]")
                .count()
        })
}

/// Whether Gemini holds the WROTE rules of the lock's admin policy, by what drgnx's Gemini fork reports in
/// `initialize` (CAPS, the agent's capabilities: `_meta["_drgnx/panel"].adminPolicy {loaded, rules}`,
/// `packages/cli/src/acp/acpRpcDispatcher.ts:94-123`).  No report (the stock adapter) leaves the check before launch
/// ([`gemini_policy_problem`]) as the only one.
pub fn gemini_policy_confirmed(caps: Option<&Value>, wrote: usize) -> Result<(), LockBroken> {
    if wrote == 0 {
        return Ok(());
    }
    let Some(report) = caps.and_then(|c| c.pointer("/_meta/_drgnx~1panel/adminPolicy")) else {
        return Ok(());
    };
    let (Some(loaded), Some(rules)) = (
        report.get("loaded").and_then(Value::as_bool),
        report.get("rules").and_then(Value::as_u64),
    ) else {
        return Err(LockBroken(format!(
            "Gemini's report of drgnx's admin policy cannot be read: {report}"
        )));
    };
    if !loaded {
        Err(LockBroken(
            "Gemini says drgnx's admin policy did not load".into(),
        ))
    } else if rules < wrote as u64 {
        Err(LockBroken(format!(
            "Gemini holds {rules} of the {wrote} rules of drgnx's admin policy"
        )))
    } else {
        Ok(())
    }
}

const GEMINI_POLICY_DROPPED: &str =
    "drgnx's admin policy would not load in Gemini CLI, which would run without it";

/// Whether DIR (Gemini's system policies) holds a `.toml`, which makes Gemini ignore `--admin-policy`.
fn gemini_shadowed(dir: &Path) -> bool {
    std::fs::read_dir(dir).is_ok_and(|entries| {
        entries
            .flatten()
            .any(|e| e.path().extension().is_some_and(|x| x == "toml"))
    })
}

/// Kimi Code's tools of each kind it approves or may approve itself; any other tool falls back to asking in manual
/// mode.
fn kimi_tools(kind: &str) -> &'static [&'static str] {
    match kind {
        "read" => &["Read", "ReadMediaFile"],
        "search" => &["Glob", "Grep"],
        "fetch" => &["FetchURL", "WebSearch"],
        "execute" => &["Bash", "TaskStop"],
        "edit" => &["Write", "Edit"],
        "think" => &["Agent"],
        _ => &[],
    }
}

/// Kimi Code's config: manual mode, no plan mode at start (`default_plan_mode` would enter it,
/// `packages/agent-core-v2/src/features/plan/configSection.ts:5-13`), and a user ask rule (which beats its default
/// approval of reads) for each tool of KINDS.
fn kimi_config(kinds: &[&str]) -> Vec<u8> {
    let mut t = String::from(
        "# drgnx: the hub's config for this session's Kimi Code (read-only inside its sandbox).\n\
         default_permission_mode = \"manual\"\n\
         default_plan_mode = false\n",
    );
    for tool in kinds.iter().flat_map(|k| kimi_tools(k)) {
        t.push_str(&format!(
            "\n[[permission.rules]]\ntool = \"{tool}\"\ndecision = \"ask\"\nscope = \"user\"\n"
        ));
    }
    t.into_bytes()
}

/// DeepSeek Harness's overlay, as `--patch` reads it (0.2.2: a top-level YAML array of loader patches; anything else
/// stops its boot, `packages/boot/app-boot/src/index.ts:536-545`, `:571-589`): the `sandbox-policy` row's mode
/// full-access (Gleipnir is the one sandbox) and, set apart from it, the `approval` row's policy `ask` (the base bundle
/// ties that mode to `never`, which rejects every ask: `packages/bundle/base/cordis.patch.yml:243-262`); the drgnx
/// ask plugin, inserted, asks for the tools of KINDS (the fork's `packages/acp/acp-drgnx-ask`, whose fixture
/// `tests/fixtures/drgnx.overlay.yml` this is).
fn dsh_overlay(kinds: &[&str]) -> Vec<u8> {
    format!(
        "# drgnx: the hub's overlay for this session's DeepSeek Harness (read-only inside its sandbox).\n\
         - id: sandbox-policy\n  config:\n    mode: danger-full-access\n\n\
         - id: approval\n  config:\n    policy: ask\n\n\
         - insert:\n    - id: drgnx-ask\n      name: '@deepseek-ai/dsh-acp-drgnx-ask'\n      config:\n        kinds: [{}]\n",
        kinds.join(", ")
    )
    .into_bytes()
}

impl LaunchPlan {
    /// The lock's files for PROFILE's session at AT, given the KINDS its `before-tool` hooks and rules subscribe to
    /// (`drgnx` is the hub's own servers', and needs nothing of a lock): Codex's config for its worktree and, with a
    /// kind, its managed hook; Gemini's admin policy (none when no kind is subscribed, and none when a system policy
    /// would shadow it: the lock is then not enforced); Kimi Code's ask rules; DeepSeek Harness's overlay.  Claude's
    /// ask rules are [`LaunchPlan::with_hook_asks`]'s.
    pub fn with_locks(mut self, p: &AgentProfile, kinds: &[String], at: &LockAt) -> Self {
        let mut kinds: Vec<&str> = kinds
            .iter()
            .map(String::as_str)
            .filter(|k| *k != "drgnx")
            .collect();
        kinds.sort_unstable();
        kinds.dedup();
        match p.provider() {
            Some(Provider::Codex) => {
                set_env(&mut self.env, "CODEX_CONFIG", codex_config(Some(&at.cwd)));
                self.put_file(
                    PathBuf::from(CODEX_MANAGED),
                    codex_managed(!kinds.is_empty()),
                );
            }
            Some(Provider::Gemini) if !kinds.is_empty() => {
                let policy = gemini_policy(&kinds);
                let dropped = gemini_policy_problem(&String::from_utf8_lossy(&policy));
                if gemini_shadowed(&at.gemini_policies) {
                    self.enforced = Enforced::No(GEMINI_SHADOWED);
                } else if let Some(why) = dropped {
                    // never passed: Gemini would drop it and run on, so the kinds are unhooked and the session refused
                    tracing::warn!("{GEMINI_POLICY_DROPPED}: {why}");
                    self.enforced = Enforced::No(GEMINI_POLICY_DROPPED);
                } else {
                    let file = at.dir.join(gemini_policy_name(&policy));
                    self.argv.push("--admin-policy".into());
                    self.argv.push(file.clone().into());
                    self.put_file(file, policy);
                }
            }
            Some(Provider::Kimi) => {
                if let Some(home) = self.login_dir.clone() {
                    self.put_file(home.join("config.toml"), kimi_config(&kinds));
                }
            }
            Some(Provider::DeepSeek) => {
                let file = at.dir.join("dsh-overlay.yml");
                self.argv.push("--patch".into());
                self.argv.push(file.clone().into());
                self.put_file(file, dsh_overlay(&kinds));
            }
            _ => {}
        }
        self
    }

    /// PATH's content is BYTES (replacing what the plan had for it).
    fn put_file(&mut self, path: PathBuf, bytes: Vec<u8>) {
        self.ro_files.retain(|(p, _)| *p != path);
        self.ro_files.push((path, bytes));
    }

    /// A gateway profile of Kimi Code or DeepSeek Harness: the gateway's URL and the session's own token (from P's
    /// `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN`, which the session's start put there) in the variables its CLI
    /// reads, so no provider key ever reaches it; a sandboxed plan's URL is its relay's (`gateway_url_env`).  A no-op
    /// for another provider or a profile with no gateway token.
    pub fn with_gateway_env(mut self, p: &AgentProfile) -> Self {
        let var = |name: &str| {
            p.env.iter().rev().find_map(|e| {
                e.split_once('=')
                    .filter(|(k, v)| *k == name && !v.is_empty())
                    .map(|(_, v)| v.to_string())
            })
        };
        let Some(token) = var("ANTHROPIC_AUTH_TOKEN") else {
            return self;
        };
        let url = var("ANTHROPIC_BASE_URL");
        let (url_var, mut extra) = match p.provider() {
            Some(Provider::Kimi) => (
                "KIMI_MODEL_BASE_URL",
                vec![
                    ("KIMI_MODEL_PROVIDER_TYPE", "anthropic".to_string()),
                    ("KIMI_MODEL_API_KEY", token),
                ],
            ),
            Some(Provider::DeepSeek) => ("DEEPSEEK_BASE_URL", vec![("DEEPSEEK_API_KEY", token)]),
            _ => return self,
        };
        if p.provider() == Some(Provider::Kimi)
            && let Some(m) = &p.model
        {
            extra.push(("KIMI_MODEL_NAME", m.clone()));
        }
        if let Some(u) = url {
            extra.push((url_var, u));
        }
        for (k, v) in extra {
            set_env(&mut self.env, k, v);
        }
        self.gateway_url_env = vec![url_var.to_string()];
        self
    }

    /// Makes the hub-owned home of the plan's CLI (Kimi Code's, DeepSeek Harness's: 0700), and an empty file at each
    /// of its read-only files' paths in it, where the sandbox binds the session's copy.  A no-op for another CLI.
    pub fn make_home(&self) -> std::io::Result<()> {
        let Some(home) = self.login_dir.as_ref().filter(|d| {
            d.file_name()
                .is_some_and(|n| n == KIMI_HOME || n == DSH_HOME)
        }) else {
            return Ok(());
        };
        std::fs::create_dir_all(home)?;
        runstav::paths::private_dir(home)?;
        for (path, _) in self.ro_files.iter().filter(|(p, _)| p.starts_with(home)) {
            if path.symlink_metadata().is_err() {
                std::fs::write(path, b"")?;
            }
        }
        Ok(())
    }
}

/// Sets NAME to VALUE in ENV (the first entry of NAME, else a new one at the end).
fn set_env(env: &mut Vec<(String, String)>, name: &str, value: String) {
    match env.iter_mut().find(|(k, _)| k == name) {
        Some((_, v)) => *v = value,
        None => env.push((name.to_string(), value)),
    }
}

/// The refusal of PROFILE's session when HOOKED has a subscribed kind its agent would run unhooked: the lock can make
/// it neither ask nor withhold it.  `None` when every subscribed kind reaches the hooks or has no tool.
pub fn unhooked_refusal(
    p: &AgentProfile,
    hooked: Option<&runstav::methods::agents::Hooked>,
) -> Option<String> {
    let h = hooked.filter(|h| !h.unhooked.is_empty())?;
    let kinds = h.unhooked.join(", ");
    Some(format!(
        "{} would run {kinds} steps unhooked ({}), and a before-tool hook or rule subscribes to them: drgnx does not \
         start it",
        p.name,
        h.why.as_deref().unwrap_or("its lock cannot make them ask")
    ))
}

/// How a session's CLI uses one entry of its login dir.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LoginUse {
    /// It loads it (its settings, your instructions and commands): readable, never writable.
    Read,
    /// A file it rewrites in place: its token.
    File,
    /// A folder of its own state it writes (made when missing).
    Dir,
    /// The folder where it keeps every session it runs, yours too: each sandboxed session gets an empty one of its
    /// own in that place (`sandbox::login_grants`), never yours.
    Own,
}

/// What a CLI uses in its login dir LOGIN_DIR during a session, relative to it: what it loads, the token file it
/// refreshes in place, and its sessions' state.  Nothing else of the login dir is shown: not the dir itself, so not
/// the keys of your own CLI's daemon and live sessions, its prompt history, shell snapshots, IDE locks or another
/// project's transcripts.  Nothing your own CLI runs or reads as instructions later (settings and their hooks,
/// commands, agents, skills, plugins, `CLAUDE.md`/`AGENTS.md`/`GEMINI.md`, Codex's `config.toml` and rules) is
/// writable.  Claude's project folder is [`claude_project`]'s.
pub fn login_entries(login_dir: &Path) -> &'static [(&'static str, LoginUse)] {
    use LoginUse::{Dir, File, Own, Read};
    match login_dir.file_name().and_then(|n| n.to_str()) {
        Some(".claude") => &[
            (".credentials.json", File),
            ("settings.json", Read),
            ("CLAUDE.md", Read),
            ("agents", Read),
            ("commands", Read),
            ("skills", Read),
            ("plugins", Read),
            ("output-styles", Read),
            ("keybindings.json", Read),
            ("todos", Dir),
        ],
        Some(".codex") => &[
            ("auth.json", File),
            ("config.toml", Read),
            ("AGENTS.md", Read),
            ("prompts", Read),
            ("skills", Read),
            ("rules", Read),
            ("sessions", Own),
            ("log", Dir),
        ],
        Some(".gemini") => &[
            ("oauth_creds.json", File),
            ("google_accounts.json", Read),
            ("settings.json", Read),
            ("GEMINI.md", Read),
            ("commands", Read),
            ("extensions", Read),
            ("tmp", Own),
        ],
        // the hub-owned homes: drgnx's sessions of the CLI only, never the user's own
        Some(KIMI_HOME) => &[
            ("credentials", Dir),
            ("sessions", Dir),
            ("logs", Dir),
            ("locks", Dir),
            ("config.toml", Read),
            ("mcp.json", Read),
            ("plugins", Read),
            ("skills", Read),
            ("AGENTS.md", Read),
        ],
        Some(DSH_HOME) => &[
            ("sessions", Dir),
            ("logs", Dir),
            ("profiles", Read),
            ("cordis.patch.yml", Read),
        ],
        _ => &[],
    }
}

/// The longest folder name Claude Code uses as it is under `projects`; a longer one it cuts and gives a hash.
const CLAUDE_PROJECT_MAX: usize = 200;

/// The folder under Claude's login dir LOGIN_DIR (`projects/NAME`) where Claude Code keeps the sessions it runs in CWD:
/// NAME is CWD with every UTF-16 unit that is not an ASCII letter or digit made `-` (`/srv/u/p.x` →
/// `-srv-u-p-x`).  None for another CLI's login dir, a CWD that is not UTF-8, or a name over
/// [`CLAUDE_PROJECT_MAX`] (Claude Code's own hash is not repeated here: such a session keeps no transcript).
pub fn claude_project(login_dir: &Path, cwd: &Path) -> Option<PathBuf> {
    if login_dir.file_name()? != ".claude" {
        return None;
    }
    let mut name = String::new();
    for c in cwd.to_str()?.chars() {
        if c.is_ascii_alphanumeric() {
            name.push(c);
        } else {
            name.extend(std::iter::repeat_n('-', c.len_utf16()));
        }
    }
    (name.len() <= CLAUDE_PROJECT_MAX).then(|| login_dir.join("projects").join(name))
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

// ------------------------------------------------------------------------------------- hooks before a tool call

/// Claude Code's built-in tools of the ACP kind KIND, the names an ask rule can give (design addendum §4.10), the
/// ones Claude runs without asking included (its subagents and to-do list are `think`, leaving plan mode is
/// `switch_mode`, its MCP resource tools are `other`; MCP tools ask by default, since only managed rules apply).
/// Claude has no tool of kind `delete` or `move`. The pinned adapter has no `mcp__acp__*` replacements to add.
pub fn claude_ask_tools(kind: &str) -> &'static [&'static str] {
    match kind {
        "read" => &["Read", "NotebookRead"],
        "search" => &["Grep", "Glob", "LS"],
        "fetch" => &["WebFetch", "WebSearch"],
        "execute" => &["Bash", "BashOutput", "KillShell"],
        "edit" => &["Edit", "Write", "MultiEdit", "NotebookEdit"],
        "think" => &["Task", "TodoWrite"],
        "switch_mode" => &["ExitPlanMode"],
        "other" => &["ListMcpResourcesTool", "ReadMcpResourceTool"],
        _ => &[],
    }
}

impl LaunchPlan {
    /// Makes the agent ask the hub for every step of KINDS (the kinds the session's `before-tool` hooks and rules
    /// subscribe to, at its launch), so those steps reach the permission seam and its hooks even where the agent
    /// would allow itself. Claude only: managed ask rules beside the user's own (Claude evaluates deny, then ask, then
    /// allow), never an allow rule. A no-op for a plan with no Claude options.
    pub fn with_hook_asks(mut self, kinds: &[String]) -> Self {
        let tools: Vec<&str> = kinds
            .iter()
            .flat_map(|k| claude_ask_tools(k).iter().copied())
            .collect();
        if tools.is_empty() {
            return self;
        }
        if let Some(perms) = self
            .session_meta
            .as_mut()
            .and_then(|m| m.pointer_mut("/claudeCode/options/managedSettings/permissions"))
            .and_then(Value::as_object_mut)
            && let Some(ask) = perms
                .entry("ask")
                .or_insert_with(|| json!([]))
                .as_array_mut()
        {
            for t in tools {
                if !ask.iter().any(|a| a == t) {
                    ask.push(json!(t));
                }
            }
        }
        self
    }
}

/// How one subscribed kind reaches a session's `before-tool` hooks.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Route {
    /// The agent asks the client, so the step reaches the permission seam.
    Seam,
    /// The adapter's own hook calls the hub (Codex's managed PreToolUse hook).
    Adapter,
    /// The agent has no tool of the kind, or the lock withholds it: nothing of it runs.
    Absent,
    /// It would run without the hooks seeing it.
    Unhooked,
}

/// Which of KINDS (the subscribed kinds; none: `None`) reach the session's `before-tool` hooks under PROFILE's lock
/// PLAN (its files already added), and which do not, and why. `drgnx` is hooked at the hub's servers whatever the
/// agent; a kind the agent has no tool of (Claude's `delete` and `move`, Codex's withheld `fetch`) is not listed.
/// `by_adapter` is Codex's managed hook here (it fails open on a timeout); the panel extension adds a fork's
/// `_drgnx/before_tool` once the adapter advertises it. A session with `unhooked` kinds is refused
/// ([`unhooked_refusal`]).
pub fn hooked(
    p: &AgentProfile,
    kinds: &[String],
    plan: &LaunchPlan,
) -> Option<runstav::methods::agents::Hooked> {
    if kinds.is_empty() {
        return None;
    }
    let has_arg = |a: &str| plan.argv.iter().any(|x| x == a);
    let managed_hook = plan.ro_files.iter().any(|(path, bytes)| {
        path == Path::new(CODEX_MANAGED) && String::from_utf8_lossy(bytes).contains("mcp_tool")
    });
    let not_enforced = match plan.enforced {
        Enforced::No(w) => Some(w),
        Enforced::Yes => None,
    };
    let (route, why): (&dyn Fn(&str) -> Route, &str) = match p.provider() {
        Some(Provider::Claude) => (
            &|k: &str| {
                if claude_ask_tools(k).is_empty() {
                    Route::Absent
                } else {
                    Route::Seam
                }
            },
            "Claude Code runs them without asking: no ask rule can name them",
        ),
        // apply_patch and MCP tools always ask; shell steps (Codex reads and searches through them too) that its
        // policy calls safe run unasked, so they are the managed hook's; hosted web search is off
        Some(Provider::Codex) => (
            &|k: &str| match k {
                "edit" | "other" => Route::Seam,
                "fetch" => Route::Absent,
                _ if managed_hook => Route::Adapter,
                _ => Route::Unhooked,
            },
            "Codex's managed hook is not installed",
        ),
        Some(Provider::Gemini) => (
            &|_: &str| {
                if has_arg("--admin-policy") {
                    Route::Seam
                } else {
                    Route::Unhooked
                }
            },
            not_enforced
                .unwrap_or("Gemini runs them without asking: its admin policy is not applied"),
        ),
        Some(Provider::Kimi) => (&|_: &str| Route::Seam, ""),
        Some(Provider::DeepSeek) => (
            &|_: &str| {
                if has_arg("--patch") {
                    Route::Seam
                } else {
                    Route::Unhooked
                }
            },
            "DeepSeek Harness runs them without asking: its overlay is not applied",
        ),
        None => (
            &|_: &str| Route::Unhooked,
            "drgnx has no lock for this agent's CLI",
        ),
    };
    let mut h = runstav::methods::agents::Hooked::default();
    for k in kinds {
        let r = if k == "drgnx" { Route::Seam } else { route(k) };
        match r {
            Route::Seam => h.before_tool.push(k.clone()),
            Route::Adapter => h.by_adapter.push(k.clone()),
            Route::Absent => {}
            Route::Unhooked => h.unhooked.push(k.clone()),
        }
    }
    for l in [&mut h.before_tool, &mut h.by_adapter, &mut h.unhooked] {
        l.sort();
        l.dedup();
    }
    h.why = if !h.unhooked.is_empty() {
        Some(why.to_owned())
    } else if !h.by_adapter.is_empty() {
        Some("Codex's managed hook fails open on a timeout (Codex)".to_owned())
    } else {
        None
    };
    Some(h)
}

/// Whether Codex runs in the mode its lock asked for, by what the adapter REPORTED (`modes.currentModeId` of the
/// answer that opened the session), never by what was asked.
pub fn codex_mode_confirmed(reported: Option<&str>) -> Result<(), LockBroken> {
    match reported {
        Some(m) if m == CODEX_MODE => Ok(()),
        Some(m) => Err(LockBroken(format!(
            "Codex runs in mode `{m}`, not `{CODEX_MODE}`"
        ))),
        None => Err(LockBroken(format!(
            "Codex did not report its mode (`{CODEX_MODE}` was asked for)"
        ))),
    }
}

/// Kimi Code's plan mode lets the writes of its plan file through without asking its hooks (`event.allow()`,
/// `packages/agent-core-v2/src/features/plan/planService.ts:112-116`), so under Kimi's lock a session in it is refused:
/// REPORTED is the mode Kimi reported (`modes.currentModeId` of the answer that opened the session, or a
/// `current_mode_update`).
pub fn kimi_mode_refused(reported: Option<&str>) -> Result<(), LockBroken> {
    match reported {
        Some("plan") => Err(LockBroken(
            "Kimi Code runs in plan mode, whose plan-file writes skip its hooks".into(),
        )),
        _ => Ok(()),
    }
}

/// Why UPDATE, a `session/update` of a running session whose agent is PROVIDER, breaks the lock, when LOCKED (the lock
/// holds) and UPDATE is a switch to a mode the lock refuses ([`kimi_mode_refused`]).  Kimi Code tells every switch it
/// makes for the client (`packages/acp-server/src/session.ts:1138-1156`); one its engine makes alone is not told.
pub fn refused_mode_switch(
    provider: Option<Provider>,
    locked: bool,
    update: &Value,
) -> Option<LockBroken> {
    if !locked
        || provider != Some(Provider::Kimi)
        || update.get("sessionUpdate").and_then(Value::as_str) != Some("current_mode_update")
    {
        return None;
    }
    kimi_mode_refused(update.get("currentModeId").and_then(Value::as_str)).err()
}

/// Checks the lock of PLAN at session start, with CAPS the agent's capabilities from `initialize`: the mode the CLI is
/// put in is the asking one.  Codex's mode is checked whether or not its lock is proven: the one it reports must be
/// [`CODEX_MODE`].  With an enforced lock, Gemini must hold its admin policy's rules when it reports them
/// ([`gemini_policy_confirmed`]), Kimi Code must not report plan mode ([`kimi_mode_refused`]); Claude, Gemini and
/// Kimi Code are set to `default` (a refusal ends the session), and DeepSeek Harness has no modes; a profile with no
/// lock fails.
pub async fn verify(
    conn: &hermod::Conn,
    sid: &hermod::SessionId,
    p: &AgentProfile,
    plan: &LaunchPlan,
    caps: Option<&Value>,
) -> Result<(), LockBroken> {
    match p.provider() {
        Some(Provider::Codex) => codex_mode_confirmed(conn.reported_mode(sid).as_deref()),
        _ if plan.enforced != Enforced::Yes => Ok(()),
        Some(Provider::Gemini) => {
            gemini_policy_confirmed(caps, gemini_policy_rules(plan))?;
            conn.set_mode(sid, "default")
                .await
                .map_err(|e| LockBroken(format!("`default` mode refused: {e}")))
        }
        Some(Provider::Kimi) => {
            kimi_mode_refused(conn.reported_mode(sid).as_deref())?;
            conn.set_mode(sid, "default")
                .await
                .map_err(|e| LockBroken(format!("`default` mode refused: {e}")))
        }
        Some(Provider::Claude) => conn
            .set_mode(sid, "default")
            .await
            .map_err(|e| LockBroken(format!("`default` mode refused: {e}"))),
        Some(Provider::DeepSeek) => Ok(()),
        None => Err(LockBroken("this agent has no lock".into())),
    }
}

#[cfg(test)]
mod tests;
