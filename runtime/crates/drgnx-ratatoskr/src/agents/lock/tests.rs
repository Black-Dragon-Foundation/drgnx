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
    // The fixture is `drgnx-agents-job-claude-options` plus `:env` as `drgnx-agents--session-meta` adds it.
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

#[test]
fn codex_overrides_route_every_approval() {
    let p = profile(&["codex-acp"], None, &[], None);
    let plan = plan(&p, Role::Worker, &Effective::default());
    let a = args(&plan);
    assert_eq!(a[0], "codex-acp");
    let cs: Vec<&String> = a.iter().skip(1).step_by(2).collect();
    assert!(a.iter().skip(1).step_by(2).all(|x| x == "-c"));
    let kv: Vec<&String> = a.iter().skip(2).step_by(2).collect();
    assert_eq!(cs.len(), 3);
    for cat in [
        "sandbox_approval",
        "rules",
        "mcp_elicitations",
        "request_permissions",
        "skill_approval",
    ] {
        assert!(
            kv[0].contains(&format!("{cat} = true")),
            "{cat} is asked of the client"
        );
    }
    assert_eq!(kv[1], "approvals_reviewer=\"user\"");
    assert_eq!(kv[2], "sandbox_mode=\"danger-full-access\"");
    assert!(plan.session_meta.is_none());
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
            [("CLAUDE_CODE_PROMPT_CACHE_TTL".to_string(), "1h".to_string())]
        );
        let env = &plan.session_meta.unwrap()["claudeCode"]["options"]["env"];
        assert_eq!(env["CLAUDE_CODE_PROMPT_CACHE_TTL"], "1h");
    }
    // Chats keep 5 m; a subscription profile has no TTL variable.
    assert!(plan(&gw, Role::Chat, &Effective::default()).env.is_empty());
    let sub = profile(&["claude-agent-acp"], None, &[], None);
    let plan = plan(&sub, Role::Worker, &Effective::default());
    assert!(plan.env.is_empty() && plan.session_meta.is_some());
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

#[test]
fn a_profile_without_a_lock_is_not_enforced() {
    let p = profile(&["my-agent", "--flag"], None, &[], None);
    let plan = plan(&p, Role::Worker, &Effective::default());
    assert!(matches!(plan.enforced, Enforced::No(_)));
    assert_eq!(args(&plan), ["my-agent", "--flag"]);
    assert!(plan.session_meta.is_none() && plan.env.is_empty());
}
