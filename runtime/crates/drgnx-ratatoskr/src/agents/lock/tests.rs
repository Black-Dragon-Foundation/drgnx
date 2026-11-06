use super::*;

fn profile(
    command: &[&str],
    ai: Option<&str>,
    env: &[&str],
    provider: Option<Provider>,
) -> AgentProfile {
    AgentProfile {
        name: "t".into(),
        command: command.iter().map(|s| s.to_string()).collect(),
        env: env.iter().map(|s| s.to_string()).collect(),
        mode: None,
        ai: ai.map(String::from),
        model: None,
        tracker_tools: None,
        doc: None,
        provider,
        job_safe: false,
    }
}

fn args(p: &LaunchPlan) -> Vec<String> {
    p.argv
        .iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect()
}

#[test]
fn claude_options_equal_the_lisp_oracle() {
    // The fixture is `drgnx-agents-job-claude-options` plus `:env` as `drgnx-agents--session-meta` adds it, with the
    // lock's own `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` after the profile's variables.
    let want: Value = serde_json::from_str(include_str!("claude-options.json")).unwrap();
    let p = profile(&["claude-agent-acp"], None, &["A=1", "A=2", "B"], None);
    let plan = plan(&p, Role::Worker, &Effective::default());
    assert_eq!(
        plan.session_meta,
        Some(json!({"claudeCode": {"options": want}}))
    );
    assert_eq!(plan.enforced, Enforced::Yes);
    // The deny and ask rules join the policy tier, never an allow rule.
    let with = plan.with_claude_rules(vec!["Bash(rm:*)".into()], vec!["Edit".into()]);
    let perms =
        &with.session_meta.unwrap()["claudeCode"]["options"]["managedSettings"]["permissions"];
    assert_eq!(perms["deny"], json!(["Bash(rm:*)"]));
    assert_eq!(perms["ask"], json!(["Edit"]));
    assert!(perms.get("allow").is_none());
}

#[test]
fn claude_rules_are_read_like_the_lisp_does() {
    let d = tempfile::tempdir().unwrap();
    let (home, cwd) = (d.path().join("home"), d.path().join("wt"));
    std::fs::create_dir_all(cwd.join(".claude")).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(
        home.join("settings.json"),
        r#"{"permissions":{"deny":["A","B"],"ask":["X"],"allow":["Z"]}}"#,
    )
    .unwrap();
    std::fs::write(
        cwd.join(".claude/settings.json"),
        r#"{"permissions":{"deny":["B","C"]}}"#,
    )
    .unwrap();
    std::fs::write(cwd.join(".claude/settings.local.json"), "not json").unwrap();
    let (deny, ask) = claude_deny_ask(&home, &cwd);
    assert_eq!(
        (deny, ask),
        (vec!["A".into(), "B".into(), "C".into()], vec!["X".into()])
    );
}

fn kinds(k: &[&str]) -> Vec<String> {
    k.iter().map(|s| s.to_string()).collect()
}

/// Where a test's lock writes: a worktree, the session's lock folder and a stand-in for Gemini's system policies.
fn at(d: &Path) -> LockAt {
    LockAt {
        cwd: d.join("wt"),
        dir: d.join("run/lock"),
        gemini_policies: d.join("etc/gemini-cli/policies"),
    }
}

/// PROFILE's whole lock for KINDS: the plan, then its files (`agents::session::prepare`'s order).
fn locked(p: &AgentProfile, k: &[&str], d: &Path) -> LaunchPlan {
    plan(p, Role::Worker, &Effective::default())
        .with_hook_asks(&kinds(k))
        .with_locks(p, &kinds(k), &at(d))
}

fn env_of<'a>(plan: &'a LaunchPlan, name: &str) -> Option<&'a str> {
    plan.env
        .iter()
        .find(|(k, _)| k == name)
        .map(|(_, v)| v.as_str())
}

fn file_of(plan: &LaunchPlan, path: &Path) -> Option<String> {
    plan.ro_files
        .iter()
        .find(|(p, _)| p == path)
        .map(|(_, b)| String::from_utf8(b.clone()).unwrap())
}

// [D] pure: codex-acp 2.x reads its environment only, so the lock is `INITIAL_AGENT_MODE` (a mode codex-acp 2.5.0
// knows: `read-only`, whose every turn asks the user, in Codex's read-only sandbox) and `CODEX_CONFIG` (the same
// policy, no hosted web search, MCP tools that prompt, the worktree untrusted), never argv; Codex 0.165 refuses a
// config with `approval_policy = "untrusted"`, so the lock never writes it; the managed PreToolUse hook calls the
// hub's `before_tool`.
#[test]
fn codex_config_is_in_the_environment_not_argv() {
    let d = tempfile::tempdir().unwrap();
    let p = profile(
        &["codex-acp", "-c", "approval_policy=never"],
        None,
        &[],
        None,
    );
    let plan = locked(&p, &["execute"], d.path());
    assert_eq!(args(&plan), ["codex-acp"], "argv overrides are dropped");
    assert_eq!(env_of(&plan, "INITIAL_AGENT_MODE"), Some("read-only"));
    let c: Value = serde_json::from_str(env_of(&plan, "CODEX_CONFIG").unwrap()).unwrap();
    assert_eq!(c["approval_policy"], "on-request");
    assert_eq!(c["approvals_reviewer"], "user");
    assert_eq!(c["sandbox_mode"], "read-only");
    assert_eq!(c["web_search"], "disabled");
    assert!(c.get("profiles").is_none(), "{c}");
    for server in ["drgnx", "drgnx-search", "drgnx-plugins"] {
        assert_eq!(
            c["mcp_servers"][server]["default_tools_approval_mode"], "prompt",
            "{server}"
        );
    }
    let cwd = d.path().join("wt");
    assert_eq!(
        c["projects"][cwd.to_str().unwrap()]["trust_level"],
        "untrusted"
    );
    let hook = file_of(&plan, Path::new("/etc/codex/config.toml")).unwrap();
    for line in [
        "[[hooks.PreToolUse]]",
        "type = \"mcp_tool\"",
        "server = \"drgnx\"",
        "tool = \"before_tool\"",
    ] {
        assert!(hook.contains(line), "{line} in {hook}");
    }
    assert!(plan.session_meta.is_none());
    // nothing subscribed: no managed hook, the policy stays
    let none = locked(&p, &[], d.path());
    let hook = file_of(&none, Path::new("/etc/codex/config.toml")).unwrap();
    assert!(!hook.contains("mcp_tool"), "{hook}");
    assert!(env_of(&none, "CODEX_CONFIG").is_some());
}

// [D] pure: the requirements layer the agent cannot edit pins the policy of the lock's mode (a turn in any other
// codex-acp mode breaks one of them, and Codex refuses it), and Codex stays unenforced until proven.
#[test]
fn codex_requirements_pin_the_policy() {
    let d = tempfile::tempdir().unwrap();
    let p = profile(&["codex-acp"], None, &[], Some(Provider::Codex));
    let plan = locked(&p, &["read"], d.path());
    let req = file_of(&plan, Path::new("/etc/codex/requirements.toml")).unwrap();
    for line in [
        "allowed_approval_policies = [\"on-request\"]",
        "allowed_approvals_reviewers = [\"user\"]",
        "allowed_sandbox_modes = [\"read-only\"]",
        "allowed_web_search_modes = [\"disabled\"]",
        "allow_managed_hooks_only = true",
    ] {
        assert!(req.lines().any(|l| l == line), "{line} in {req}");
    }
    assert!(!req.contains("untrusted"), "{req}");
    assert!(matches!(plan.enforced, Enforced::No(_)));
}

// [D] pure: Codex's lock holds only in the mode the adapter says the session is in, and that is the mode the lock
// asked for: another mode (codex-acp falls back to `agent`, its auto-review mode, for an id it does not know) or none
// reported refuses the session, with the reason.
#[test]
fn codex_mode_must_be_the_one_reported() {
    assert_eq!(codex_mode_confirmed(Some("read-only")), Ok(()));
    let LockBroken(why) = codex_mode_confirmed(Some("agent")).unwrap_err();
    assert!(
        why.contains("`agent`") && why.contains("`read-only`"),
        "{why}"
    );
    let LockBroken(why) = codex_mode_confirmed(None).unwrap_err();
    assert!(why.contains("did not report"), "{why}");
}

// [D] pure: Gemini gets an admin-tier policy that asks for the subscribed kinds' tools and every MCP tool, and
// withholds what can never ask (subagents' tools, the bundled docs); nothing subscribed: no policy.
#[test]
fn gemini_gets_an_admin_policy_for_subscribed_kinds() {
    let d = tempfile::tempdir().unwrap();
    let g = profile(&["gemini", "--acp", "--yolo"], None, &[], None);
    let plan = locked(&g, &["read", "execute"], d.path());
    let file = d.path().join("run/lock/gemini-policy.toml");
    assert_eq!(
        args(&plan),
        [
            "gemini",
            "--acp",
            "--approval-mode",
            "default",
            "--admin-policy",
            file.to_str().unwrap()
        ]
    );
    let policy = file_of(&plan, &file).unwrap();
    for want in [
        "toolName = \"read_file\"",
        "toolName = \"run_shell_command\"",
        "mcpName = \"*\"",
        "decision = \"ask_user\"",
        "priority = 999",
        "subagent = \"*\"",
        "toolName = \"get_internal_docs\"",
        "decision = \"deny\"",
    ] {
        assert!(policy.contains(want), "{want} in {policy}");
    }
    assert!(!policy.contains("write_file"), "{policy}");
    assert_eq!(plan.enforced, Enforced::Yes);
    // a kind with no tool names drgnx knows asks for every tool
    let wide = file_of(
        &locked(&g, &["think"], d.path()),
        &d.path().join("run/lock/gemini-policy.toml"),
    )
    .unwrap();
    assert!(wide.contains("toolName = \"*\""), "{wide}");
    let none = locked(&g, &[], d.path());
    assert!(!args(&none).iter().any(|a| a == "--admin-policy"));
    assert!(none.ro_files.is_empty());
}

// [D] pure: a policy in Gemini's system folder makes it ignore `--admin-policy`: the lock says so, the kinds are
// unhooked, and a session they are subscribed for is refused.
#[test]
fn gemini_admin_policy_shadowed_is_not_enforced() {
    let d = tempfile::tempdir().unwrap();
    let policies = d.path().join("etc/gemini-cli/policies");
    std::fs::create_dir_all(&policies).unwrap();
    std::fs::write(policies.join("notes.txt"), "").unwrap();
    let g = profile(&["gemini", "--acp"], None, &[], None);
    assert_eq!(locked(&g, &["read"], d.path()).enforced, Enforced::Yes);
    std::fs::write(policies.join("site.toml"), "").unwrap();
    let plan = locked(&g, &["read"], d.path());
    let Enforced::No(why) = plan.enforced else {
        panic!("enforced")
    };
    assert!(why.contains("/etc/gemini-cli/policies"), "{why}");
    assert!(!args(&plan).iter().any(|a| a == "--admin-policy"));
    let h = hooked(&g, &kinds(&["read", "drgnx"]), &plan).unwrap();
    assert_eq!(
        (h.before_tool, h.unhooked.clone()),
        (kinds(&["drgnx"]), kinds(&["read"]))
    );
    let refused = unhooked_refusal(&g, Some(&hooked(&g, &kinds(&["read"]), &plan).unwrap()));
    assert!(refused.unwrap().contains("read"));
}

// [D] pure: Kimi Code's hub-owned home holds a manual-mode config asking for the subscribed kinds' tools; the yolo
// flags go.
#[test]
fn kimi_strips_yolo_and_asks_for_subscribed_kinds() {
    let d = tempfile::tempdir().unwrap();
    let k = profile(
        &[
            "kimi",
            "acp",
            "--yolo",
            "-y",
            "--yes",
            "--auto-approve",
            "--auto",
        ],
        None,
        &[],
        None,
    );
    let plan = locked(&k, &["read"], d.path());
    assert_eq!(args(&plan), ["kimi", "acp"]);
    let home = plan.login_dir.clone().expect("a hub-owned home");
    assert_eq!(env_of(&plan, "KIMI_CODE_HOME"), home.to_str());
    let config = file_of(&plan, &home.join("config.toml")).unwrap();
    for want in [
        "default_permission_mode = \"manual\"",
        "[[permission.rules]]",
        "tool = \"Read\"",
        "decision = \"ask\"",
    ] {
        assert!(config.contains(want), "{want} in {config}");
    }
    assert!(!config.contains("\"Bash\""), "{config}");
    assert_eq!(plan.enforced, Enforced::Yes);
    let entries = login_entries(&home);
    for (name, used) in [
        ("credentials", LoginUse::Dir),
        ("sessions", LoginUse::Dir),
        ("logs", LoginUse::Dir),
        ("locks", LoginUse::Dir),
        ("config.toml", LoginUse::Read),
    ] {
        assert!(entries.contains(&(name, used)), "{name}");
    }
}

// [D] pure: DeepSeek Harness gets an overlay that keeps `approval.policy: ask` beside the full-access sandbox mode
// (the base bundle ties `never` to that mode) and mounts the drgnx ask plugin for the subscribed kinds.
#[test]
fn dsh_overlay_keeps_policy_ask_under_full_access() {
    let d = tempfile::tempdir().unwrap();
    let p = profile(&["dsh", "--profile", "acp"], None, &[], None);
    let plan = locked(&p, &["read", "search"], d.path());
    let overlay = d.path().join("run/lock/dsh-overlay.yml");
    assert_eq!(
        args(&plan),
        [
            "dsh",
            "--profile",
            "acp",
            "--patch",
            overlay.to_str().unwrap()
        ]
    );
    let text = file_of(&plan, &overlay).unwrap();
    for want in [
        "mode: danger-full-access",
        "policy: ask",
        "kinds: [read, search]",
    ] {
        assert!(text.contains(want), "{want} in {text}");
    }
    assert!(!text.contains("never"), "{text}");
    let home = plan.login_dir.clone().expect("a hub-owned home");
    assert_eq!(env_of(&plan, "DSH_HOME"), home.to_str());
    // the ask plugin ships with the fork: until then the lock is not enforced, and says so
    assert!(matches!(plan.enforced, Enforced::No(_)));
}

// [D] pure: the provider guess finds Kimi Code and DeepSeek Harness by their programs' names, after the others.
#[test]
fn kind_guess_finds_kimi_and_dsh() {
    let guess = |c: &[&str]| profile(c, None, &[], None).provider();
    assert_eq!(guess(&["/opt/bin/kimi", "acp"]), Some(Provider::Kimi));
    assert_eq!(
        guess(&["dsh", "--profile", "acp"]),
        Some(Provider::DeepSeek)
    );
    assert_eq!(guess(&["claude-agent-acp"]), Some(Provider::Claude));
    assert_eq!(guess(&["my-agent"]), None);
    let de = |s: &str| serde_json::from_str::<Provider>(s).unwrap();
    assert_eq!(
        (de("\"kimi\""), de("\"deepseek\"")),
        (Provider::Kimi, Provider::DeepSeek)
    );
}

// [D] pure: every provider, for every kind a hook can subscribe to: the kind reaches the hooks (an ask the hub
// answers, or the adapter's hook), or the provider has no tool of it, or the session is refused with the reason.
// Never a kind that runs unhooked.
#[test]
fn every_provider_hooks_withholds_or_refuses_each_kind() {
    let d = tempfile::tempdir().unwrap();
    let all: Vec<&str> = brokkr::TOOL_KINDS.to_vec();
    let cases: [(&[&str], &[&str], bool); 6] = [
        // command, the kinds it has no tool of (withheld or absent), refused
        (&["claude-agent-acp"], &["delete", "move"], false),
        (&["codex-acp"], &["fetch"], false),
        (&["gemini", "--acp"], &[], false),
        (&["kimi", "acp"], &[], false),
        (&["dsh", "--profile", "acp"], &[], false),
        (&["my-agent"], &[], true),
    ];
    for (command, absent, refused) in cases {
        let p = profile(command, None, &[], None);
        let plan = locked(&p, &all, d.path());
        let h = hooked(&p, &kinds(&all), &plan).unwrap();
        assert_eq!(
            unhooked_refusal(&p, Some(&h)).is_some(),
            refused,
            "{command:?}: {h:?}"
        );
        for k in &all {
            let hooks = h.before_tool.iter().chain(&h.by_adapter).any(|x| x == k);
            let unhooked = h.unhooked.iter().any(|x| x == k);
            assert!(
                hooks || absent.contains(k) || (unhooked && refused),
                "{command:?} runs {k} unhooked: {h:?}"
            );
        }
    }
}

// [D] pure: a gateway profile of Kimi Code or DeepSeek Harness gets the gateway's URL and the session's own token in
// the variables its CLI reads, never a provider key.
#[test]
fn kimi_and_dsh_gateway_profiles_get_the_session_token() {
    let env = &[
        "ANTHROPIC_BASE_URL=http://127.0.0.1:9",
        "ANTHROPIC_AUTH_TOKEN=tok",
        "ANTHROPIC_API_KEY=",
    ];
    let mut k = profile(&["kimi", "acp"], Some("kimi-moonshot"), env, None);
    k.model = Some("kimi-k3".into());
    let kp = plan(&k, Role::Worker, &Effective::default()).with_gateway_env(&k);
    for (name, value) in [
        ("KIMI_MODEL_PROVIDER_TYPE", "anthropic"),
        ("KIMI_MODEL_BASE_URL", "http://127.0.0.1:9"),
        ("KIMI_MODEL_API_KEY", "tok"),
        ("KIMI_MODEL_NAME", "kimi-k3"),
    ] {
        assert_eq!(env_of(&kp, name), Some(value), "{name}");
    }
    assert_eq!(kp.gateway_url_env, ["KIMI_MODEL_BASE_URL"]);
    let dsh = profile(
        &["dsh", "--profile", "acp"],
        Some("dsh-deepseek"),
        env,
        None,
    );
    let dp = plan(&dsh, Role::Worker, &Effective::default()).with_gateway_env(&dsh);
    assert_eq!(env_of(&dp, "DEEPSEEK_BASE_URL"), Some("http://127.0.0.1:9"));
    assert_eq!(env_of(&dp, "DEEPSEEK_API_KEY"), Some("tok"));
    assert_eq!(dp.gateway_url_env, ["DEEPSEEK_BASE_URL"]);
    for p in [&kp, &dp] {
        assert!(
            p.env.iter().all(|(n, _)| !n.ends_with("_KEY")
                || n == "KIMI_MODEL_API_KEY"
                || n == "DEEPSEEK_API_KEY"),
            "{:?}",
            p.env
        );
    }
}

#[test]
fn codex_is_not_enforced_until_proven() {
    let p = profile(&["codex-acp"], None, &[], Some(Provider::Codex));
    assert!(matches!(
        plan(&p, Role::Worker, &Effective::default()).enforced,
        Enforced::No(_)
    ));
}

#[test]
fn gemini_has_no_yolo() {
    let p = profile(
        &[
            "gemini",
            "--experimental-acp",
            "--yolo",
            "-y",
            "--approval-mode",
            "yolo",
            "--approval-mode=yolo",
        ],
        None,
        &[],
        None,
    );
    let a = args(&plan(&p, Role::Chat, &Effective::default()));
    assert_eq!(
        a,
        ["gemini", "--experimental-acp", "--approval-mode", "default"]
    );
}

#[test]
fn gateway_profiles_get_claudes_lock_and_ttl_1h() {
    let gw = profile(&["claude-agent-acp"], Some("claude-openrouter"), &[], None);
    for role in [Role::Worker, Role::Manager] {
        let plan = plan(&gw, role, &Effective::default());
        assert_eq!(
            plan.env,
            [
                (
                    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC".to_string(),
                    "1".to_string()
                ),
                ("CLAUDE_CODE_PROMPT_CACHE_TTL".to_string(), "1h".to_string())
            ]
        );
        let env = &plan.session_meta.unwrap()["claudeCode"]["options"]["env"];
        assert_eq!(env["CLAUDE_CODE_PROMPT_CACHE_TTL"], "1h");
    }
    // Chats keep 5 m; a subscription profile has no TTL variable.
    let ttl = |p: &LaunchPlan| {
        p.env
            .iter()
            .any(|(k, _)| k == "CLAUDE_CODE_PROMPT_CACHE_TTL")
    };
    assert!(!ttl(&plan(&gw, Role::Chat, &Effective::default())));
    let sub = profile(&["claude-agent-acp"], None, &[], None);
    let plan = plan(&sub, Role::Worker, &Effective::default());
    assert!(!ttl(&plan) && plan.session_meta.is_some());
}

/// Every Claude session sends no nonessential traffic (telemetry, error reports, update checks): its proxy denies
/// those hosts.  Another CLI's plan does not get the variable.
#[test]
fn claude_sends_no_nonessential_traffic() {
    for (cmd, ai) in [
        ("claude-agent-acp", None),
        ("claude-agent-acp", Some("claude-openrouter")),
    ] {
        for role in [Role::Chat, Role::Worker, Role::Manager] {
            let plan = plan(&profile(&[cmd], ai, &[], None), role, &Effective::default());
            assert!(
                plan.env.contains(&(
                    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC".into(),
                    "1".into()
                )),
                "{ai:?} {role:?}"
            );
            let env = &plan.session_meta.unwrap()["claudeCode"]["options"]["env"];
            assert_eq!(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1");
        }
    }
    for cmd in ["codex-acp", "gemini"] {
        let plan = plan(
            &profile(&[cmd], None, &[], None),
            Role::Worker,
            &Effective::default(),
        );
        assert!(
            plan.env
                .iter()
                .all(|(k, _)| k != "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"),
            "{cmd}"
        );
    }
}

#[test]
fn protected_paths_are_listed() {
    for c in [
        &["claude-agent-acp"][..],
        &["codex-acp"],
        &["gemini"],
        &["other"],
    ] {
        let plan = plan(
            &profile(c, None, &[], None),
            Role::Worker,
            &Effective::default(),
        );
        let got: Vec<&str> = plan
            .protected_ro
            .iter()
            .map(|p| p.to_str().unwrap())
            .collect();
        assert_eq!(
            got,
            [
                ".claude",
                ".codex",
                ".gemini",
                ".envrc",
                ".git/hooks",
                "mise.toml"
            ]
        );
    }
}

// [D] pure: hooks/lock-turns-subscribed-kinds-into-asks. The subscribed kinds' Claude Code tools become
// managed ask rules beside the user's own, never an allow rule; a kind Claude has no tool of is not listed; Codex's
// shell reads reach the managed hook, which fails open; an agent with no lock has its kinds unhooked and is refused.
#[test]
fn subscribed_kinds_become_asks() {
    let d = tempfile::tempdir().unwrap();
    let p = profile(&["claude-agent-acp"], None, &[], None);
    let with = plan(&p, Role::Worker, &Effective::default())
        .with_claude_rules(Vec::new(), vec!["Edit".into()])
        .with_hook_asks(&kinds(&["execute", "edit", "search", "think"]));
    let perms = &with.session_meta.clone().unwrap()["claudeCode"]["options"]["managedSettings"]["permissions"];
    assert_eq!(
        perms["ask"],
        json!([
            "Edit",
            "Bash",
            "BashOutput",
            "KillShell",
            "Write",
            "MultiEdit",
            "NotebookEdit",
            "Grep",
            "Glob",
            "LS",
            "Task",
            "TodoWrite"
        ])
    );
    assert!(perms.get("allow").is_none() && perms.get("deny").is_none());
    assert_eq!(claude_ask_tools("read"), ["Read", "NotebookRead"]);
    assert_eq!(claude_ask_tools("fetch"), ["WebFetch", "WebSearch"]);
    assert_eq!(claude_ask_tools("switch_mode"), ["ExitPlanMode"]);
    assert!(claude_ask_tools("delete").is_empty());
    let h = hooked(&p, &kinds(&["execute", "think", "drgnx", "move"]), &with).unwrap();
    assert_eq!(h.before_tool, ["drgnx", "execute", "think"]);
    assert!(h.unhooked.is_empty() && h.by_adapter.is_empty() && h.why.is_none());
    assert_eq!(hooked(&p, &[], &with), None);
    // nothing subscribed: the lock is today's
    let none = plan(&p, Role::Worker, &Effective::default()).with_hook_asks(&[]);
    assert!(
        none.session_meta.unwrap()["claudeCode"]["options"]["managedSettings"]["permissions"]
            .get("ask")
            .is_none()
    );
    // Codex: apply_patch asks; its shell steps (reads and searches too) reach the managed hook
    let c = profile(&["codex-acp"], None, &[], None);
    let cp = locked(&c, &["read", "edit"], d.path());
    let h = hooked(&c, &kinds(&["read", "edit"]), &cp).unwrap();
    assert_eq!(
        (h.before_tool, h.by_adapter, h.unhooked),
        (kinds(&["edit"]), kinds(&["read"]), kinds(&[]))
    );
    assert!(h.why.unwrap().contains("fails open on a timeout"));
    // an agent with no lock asks about nothing the hub can name: refused while a hook subscribes
    let x = profile(&["my-agent"], None, &[], None);
    let xp = locked(&x, &["execute", "drgnx"], d.path());
    let h = hooked(&x, &kinds(&["execute", "drgnx"]), &xp).unwrap();
    assert_eq!(
        (h.before_tool.clone(), h.unhooked.clone()),
        (kinds(&["drgnx"]), kinds(&["execute"]))
    );
    let why = unhooked_refusal(&x, Some(&h)).unwrap();
    assert!(why.contains("execute") && why.contains("no lock"), "{why}");
    // only the hub's own tools subscribed: nothing to refuse
    let only = hooked(&x, &kinds(&["drgnx"]), &xp);
    assert_eq!(unhooked_refusal(&x, only.as_ref()), None);
}

#[test]
fn a_profile_without_a_lock_is_not_enforced() {
    let p = profile(&["my-agent", "--flag"], None, &[], None);
    let plan = plan(&p, Role::Worker, &Effective::default());
    assert!(matches!(plan.enforced, Enforced::No(_)));
    assert_eq!(args(&plan), ["my-agent", "--flag"]);
    assert!(plan.session_meta.is_none() && plan.env.is_empty());
}
