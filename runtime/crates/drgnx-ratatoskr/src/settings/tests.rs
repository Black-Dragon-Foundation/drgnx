//! `settings::tests`: the shipped defaults, the runtime entries, the fallbacks and the file checks (unified
//! settings Task 20).

use super::*;
use std::os::unix::fs::PermissionsExt;

/// A config folder holding settings.el with the entries ENTRIES (mode 0600).
fn config(entries: &str) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    write(dir.path(), entries);
    dir
}

fn write(dir: &Path, entries: &str) {
    let file = dir.join("settings.el");
    std::fs::write(
        &file,
        format!(";;; settings.el\n(drgnx-settings\n :version 1\n{entries})\n"),
    )
    .unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
}

fn ids(l: &Loaded) -> Vec<&str> {
    l.providers.iter().map(|p| p.id.as_str()).collect()
}

#[test]
fn defaults_parse() {
    let d = defaults();
    assert_eq!(d.problems, Vec::<String>::new());
    assert_eq!(d.presets.len(), 16);
    assert_eq!(d.presets[0].id, "openrouter");
    assert_eq!(d.presets[0].key_env.as_deref(), Some("OPENROUTER_API_KEY"));
    assert_eq!(
        d.roles.iter().map(|r| r.role.as_str()).collect::<Vec<_>>(),
        ["complete", "edit", "chat", "embed", "agent"]
    );
    assert_eq!(
        d.roles[0].chain,
        [ChainStep {
            provider: "ollama".into(),
            model: Some("qwen2.5-coder:1.5b".into())
        }]
    );
    assert_eq!(d.roles[3].chain[0].model, None);
    assert_eq!(d.profiles.len(), 7);
    assert_eq!(d.profiles[0].name, "claude");
    assert!(
        d.profiles
            .iter()
            .all(|p| p.job_safe && p.command == ["claude-agent-acp"])
    );
    assert_eq!(d.profiles[3].model.as_deref(), Some("kimi-k3"));
    // the strict defaults
    assert_eq!(d.values.agents_mcp, ["coordination"]);
    assert_eq!(d.values.agents_default, None);
    assert!(!d.values.agents_allow_unsandboxed);
    assert!(d.values.agents_profiles.is_empty());
    // with no settings.el: every preset and built-in profile
    let none = tempfile::tempdir().unwrap();
    let l = Settings::load(none.path(), &Kv::default());
    assert_eq!(l.file, FileState::Absent);
    assert_eq!(l.providers.len(), 16);
    assert_eq!(l.values.profile_names().len(), 7);
    assert!(l.problems.is_empty());
}

#[test]
fn only_runtime_names_decode() {
    let dir = config(
        r#" (drgnx-agents-default "review")
 (drgnx-agents-mcp (coordination search))
 (drgnx-agents-allow-unsandboxed t)
 (drgnx-agents-routes ((review . "claude") (code "a" "b")))
 (drgnx-agents-openrouter (:only ("anthropic") :data-collection deny :zdr t))
 (drgnx-ai-roles ((chat (ollama . "m") (tei))))
 (fill-column 100)
 (drgnx-keys-layers ((vscode app)))
 (:mode python-ts-mode (drgnx-agents-default "not here"))
"#,
    );
    let l = Settings::load(dir.path(), &Kv::default());
    assert_eq!(l.file, FileState::Ok);
    assert_eq!(l.problems, []);
    let v = &l.values;
    assert_eq!(v.agents_default.as_deref(), Some("review"));
    assert_eq!(v.agents_mcp, ["coordination", "search"]);
    assert!(v.agents_allow_unsandboxed);
    assert_eq!(v.agents_routes[0].profiles, ["claude"]);
    assert_eq!(v.agents_routes[1].profiles, ["a", "b"]);
    let or = v.agents_openrouter.as_ref().unwrap();
    assert_eq!(or.only.as_deref(), Some(&["anthropic".to_string()][..]));
    assert_eq!(or.zdr, Some(true));
    assert_eq!(v.ai_roles[0].chain.len(), 2);
    // what is not a runtime setting has no place to go: RUNTIME is the whole list
    assert_eq!(RUNTIME_NAMES.len(), 8);
    assert!(
        RUNTIME_NAMES
            .iter()
            .all(|n| n.starts_with("drgnx-agents-") || n.starts_with("drgnx-ai-"))
    );
}

#[test]
fn a_package_entry_is_skipped() {
    // entries the hub does not know, of any shape, even ones that could not be values of a runtime setting
    let dir = config(
        r#" (some-package-option (:a 1 :b "x" [1 2] (3 . 4)))
 (eglot-server-programs ((python-mode "pylsp")))
 (drgnx-agents-default "claude")
 (unknown-thing)
"#,
    );
    let l = Settings::load(dir.path(), &Kv::default());
    assert_eq!(l.file, FileState::Ok);
    assert_eq!(
        l.problems,
        [],
        "a package's entry is never the hub's problem"
    );
    assert_eq!(l.values.agents_default.as_deref(), Some("claude"));
}

#[test]
fn a_bad_runtime_entry_falls_back_alone() {
    let mut kv = Kv::default();
    kv.last_good.insert(
        "drgnx-ai-providers".into(),
        r#"((mine :kind openai :url "https://mine.example/v1" :caps (chat)))"#.into(),
    );
    let dir = config(
        r#" (drgnx-agents-default "review")
 (drgnx-agents-mcp (coordination bogus))
 (drgnx-ai-providers ((x :kind no-such-kind :url "https://x.example")))
 (drgnx-ai-roles ((chat (ollama . "m"))))
"#,
    );
    let l = Settings::load(dir.path(), &kv);
    assert_eq!(l.file, FileState::Ok);
    // the two bad ones fell back, each by its rule; the good ones stand
    assert_eq!(
        l.values.agents_mcp,
        ["coordination"],
        "strict: the shipped default"
    );
    assert_eq!(l.values.ai_providers[0].id, "mine", "the last good value");
    assert_eq!(l.values.agents_default.as_deref(), Some("review"));
    assert_eq!(l.values.ai_roles[0].role, "chat");
    assert_eq!(l.problems.len(), 2, "{:?}", l.problems);
    assert_eq!(l.problems[0].setting, Some("drgnx-agents-mcp"));
    assert_eq!(l.problems[0].line, Some(5));
    assert!(
        l.problems[0].text.contains("shipped default"),
        "{}",
        l.problems[0].text
    );
    assert_eq!(l.problems[1].line, Some(6));
    assert!(
        l.problems[1].text.contains("last good"),
        "{}",
        l.problems[1].text
    );
    // the last good value is kept on; the roles' good value becomes their last good
    assert!(l.kv.last_good["drgnx-ai-providers"].contains("mine"));
    assert_eq!(
        l.kv.last_good["drgnx-ai-roles"],
        r#"((chat (ollama . "m")))"#
    );
    // with no last good value: its default
    let l = Settings::load(dir.path(), &Kv::default());
    assert!(l.values.ai_providers.is_empty());
    assert!(
        l.problems[1].text.contains("no last good"),
        "{}",
        l.problems[1].text
    );
    // an entry that is not (VAR VALUE) falls back as a bad value does
    let dir = config(" (drgnx-agents-allow-unsandboxed t t)\n");
    let l = Settings::load(dir.path(), &Kv::default());
    assert!(!l.values.agents_allow_unsandboxed);
    assert_eq!(
        l.problems[0].setting,
        Some("drgnx-agents-allow-unsandboxed")
    );
}

#[test]
fn a_broken_file_gives_strict_defaults_and_last_good() {
    let dir = config(
        r#" (drgnx-agents-allow-unsandboxed t)
 (drgnx-agents-mcp (coordination search))
 (drgnx-ai-providers ((mine :kind openai :url "https://mine.example/v1" :caps (chat))))
"#,
    );
    let good = Settings::load(dir.path(), &Kv::default());
    assert!(good.values.agents_allow_unsandboxed);
    assert_eq!(ids(&good)[0], "mine");
    // the same file, broken: an unbalanced paren
    std::fs::write(
        dir.path().join("settings.el"),
        "(drgnx-settings :version 1\n (drgnx-agents-allow-unsandboxed t)\n (drgnx-ai-providers ((other :kind openai :url \"https://o.example\")))\n",
    )
    .unwrap();
    let l = Settings::load(dir.path(), &good.kv);
    assert_eq!(l.file, FileState::Failed);
    assert!(
        !l.values.agents_allow_unsandboxed,
        "strict: never a half-read value"
    );
    assert_eq!(l.values.agents_mcp, ["coordination"]);
    assert_eq!(ids(&l)[0], "mine", "the providers' last good value");
    assert_eq!(l.providers.len(), 17);
    assert_eq!(l.problems.len(), 1);
    assert_eq!(l.problems[0].setting, None);
    assert!(
        l.problems[0].text.starts_with("settings.el does not read"),
        "{}",
        l.problems[0].text
    );
    assert_eq!(l.kv, good.kv, "the last good values are kept on");
}

#[test]
fn a_group_writable_file_is_refused() {
    let dir = config(" (drgnx-agents-allow-unsandboxed t)\n");
    let file = dir.path().join("settings.el");
    for mode in [0o620, 0o602] {
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(mode)).unwrap();
        let l = Settings::load(dir.path(), &Kv::default());
        assert_eq!(l.file, FileState::Failed, "{mode:o}");
        assert!(!l.values.agents_allow_unsandboxed);
        assert!(
            l.problems[0].text.contains("writable by others"),
            "{}",
            l.problems[0].text
        );
    }
    // not a regular file, and too big
    std::fs::remove_file(&file).unwrap();
    std::fs::create_dir(&file).unwrap();
    let l = Settings::load(dir.path(), &Kv::default());
    assert!(
        l.problems[0].text.contains("not a regular file"),
        "{}",
        l.problems[0].text
    );
    std::fs::remove_dir(&file).unwrap();
    std::fs::write(&file, vec![b' '; (load::MAX_BYTES + 1) as usize]).unwrap();
    let l = Settings::load(dir.path(), &Kv::default());
    assert!(
        l.problems[0].text.contains("over 1 MiB"),
        "{}",
        l.problems[0].text
    );
}

#[test]
fn a_link_is_followed() {
    // a stow link: settings.el in the config folder points into a dotfiles checkout
    let dots = config(" (drgnx-agents-default \"linked\")\n");
    let conf = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(
        dots.path().join("settings.el"),
        conf.path().join("settings.el"),
    )
    .unwrap();
    let l = Settings::load(conf.path(), &Kv::default());
    assert_eq!(l.file, FileState::Ok);
    assert_eq!(l.values.agents_default.as_deref(), Some("linked"));
    // what it points at is checked
    std::fs::set_permissions(
        dots.path().join("settings.el"),
        std::fs::Permissions::from_mode(0o666),
    )
    .unwrap();
    assert_eq!(
        Settings::load(conf.path(), &Kv::default()).file,
        FileState::Failed
    );
    // a dangling link is no file
    let gone = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(
        gone.path().join("nothing.el"),
        gone.path().join("settings.el"),
    )
    .unwrap();
    assert_eq!(
        Settings::load(gone.path(), &Kv::default()).file,
        FileState::Absent
    );
}

#[test]
fn the_provider_table() {
    let dir = config(
        r#" (drgnx-ai-providers
  ((ollama :name "My Ollama" :kind ollama :url "http://10.0.0.5:11434" :caps (chat chat fim nonsense))
   (work :kind openai :url "https://llm.example/v1" :key-env "WORK_KEY" :caps (chat) :price (3 . 15) :messages t)
   (claude :kind anthropic :url "https://api.anthropic.com/v1" :key-env "K" :auth x-api-key :messages t)
   (nourl :kind openai :caps (chat))
   (nokind :url "https://nokind.example")
   (badurl :kind openai :url "ftp://x.example")))
"#,
    );
    let l = Settings::load(dir.path(), &Kv::default());
    assert_eq!(l.file, FileState::Ok);
    // the user's go first, in the order drgnx-ai-providers gives them (each one put in front of the rest), each
    // replacing the preset of its id; one without a URL or a kind is no provider; a bad URL is left out, said
    assert_eq!(&ids(&l)[..3], ["claude", "work", "ollama"]);
    assert_eq!(l.providers.len(), 2 + 16, "{:?}", ids(&l));
    assert_eq!(ids(&l).iter().filter(|i| **i == "ollama").count(), 1);
    let json = serde_json::to_value(&l.providers[..3]).unwrap();
    assert_eq!(
        json,
        serde_json::json!([
            {"id": "claude", "kind": "anthropic", "base": "https://api.anthropic.com/v1", "auth": "x-api-key",
             "messages": true, "caps": []},
            {"id": "work", "kind": "openai", "base": "https://llm.example/v1", "auth": "bearer", "messages": true,
             "caps": ["chat"], "price": {"input": 3.0, "output": 15.0}},
            {"id": "ollama", "kind": "ollama", "base": "http://10.0.0.5:11434", "auth": "none", "messages": false,
             "caps": ["chat", "fim"]},
        ])
    );
    assert_eq!(l.problems.len(), 1, "{:?}", l.problems);
    assert!(
        l.problems[0]
            .text
            .starts_with("drgnx-ai-providers: badurl: "),
        "{}",
        l.problems[0].text
    );
    // a price that is not two amounts is a mistake of the whole value
    write(
        dir.path(),
        " (drgnx-ai-providers ((p :kind openai :url \"https://p.example\" :price (-1 . 2))))\n",
    );
    let l = Settings::load(dir.path(), &Kv::default());
    assert!(l.values.ai_providers.is_empty());
    assert!(
        l.problems[0].text.contains("p.price"),
        "{}",
        l.problems[0].text
    );
}

#[test]
fn a_bad_profile_has_a_path() {
    let dir = config(
        r#" (drgnx-agents-profiles
  (("ok" :command ("agent"))
   ("review" :command ("claude-agent-acp") :mode sideways)))
"#,
    );
    let l = Settings::load(dir.path(), &Kv::default());
    assert!(
        l.values.agents_profiles.is_empty(),
        "strict: the whole value falls back"
    );
    assert_eq!(l.problems.len(), 1);
    let text = &l.problems[0].text;
    assert!(
        text.starts_with("settings.el line 4: drgnx-agents-profiles: review.mode: "),
        "{text}"
    );
    assert!(text.contains("sideways"), "{text}");
    // a profile without its command
    write(
        dir.path(),
        " (drgnx-agents-profiles ((\"x\" :doc \"no command\")))\n",
    );
    let l = Settings::load(dir.path(), &Kv::default());
    assert!(
        l.problems[0].text.contains("command"),
        "{}",
        l.problems[0].text
    );
    // a good one, with the keys the schema names (and one it does not, ignored as the Lisp ignores it)
    write(
        dir.path(),
        r#" (drgnx-agents-profiles (("r" :command ("a" "-x") :env ("A=1") :mode steer :ai claude-openrouter :model "m" :tracker-tools off :doc "d" :later 1)))
"#,
    );
    let l = Settings::load(dir.path(), &Kv::default());
    assert_eq!(l.problems, []);
    let p = &l.values.agents_profiles[0];
    assert_eq!(
        (p.name.as_str(), p.mode, p.tracker_tools),
        (
            "r",
            Some(profiles::Mode::Steer),
            Some(profiles::TrackerTools::Off)
        )
    );
    assert_eq!(p.ai.as_deref(), Some("claude-openrouter"));
    assert_eq!(l.values.profile_names().len(), 8);
}

#[tokio::test]
async fn refresh_reads_again_only_when_the_stamp_changed() {
    let dir = config(" (drgnx-agents-mcp (bogus))\n");
    let db_dir = tempfile::tempdir().unwrap();
    let (_store, db) = crate::runtime_db::open(db_dir.path()).unwrap();
    let s = Settings::new();
    assert!(s.refresh().await.is_empty(), "nothing before open");
    s.open(dir.path().to_path_buf(), db.clone());
    let told = s.refresh().await;
    assert_eq!(told.len(), 1);
    assert_eq!(told[0]["id"], "settings-drgnx-agents-mcp");
    assert!(runstav::events::event("notice").is_some_and(|e| (e.check)(&told[0]).is_ok()));
    assert!(
        s.refresh().await.is_empty(),
        "the same stamp: not read again"
    );
    // a good providers entry is kept in kv as the last good value
    write(
        dir.path(),
        " (drgnx-agents-mcp (bogus))\n (drgnx-ai-providers ((m :kind openai :url \"https://m.example\")))\n",
    );
    assert!(
        s.refresh().await.is_empty(),
        "the same problem is not told again"
    );
    assert_eq!(s.current().status().presets, 17);
    let kept = crate::gateway::kv_get(&db, load::KV_LAST_GOOD)
        .await
        .unwrap();
    assert!(kept.contains("m.example"), "{kept}");
}
