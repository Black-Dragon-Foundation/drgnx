//! The plugins' rows: install, approval by hash, a changed file, the lists per project, the rules, the store's quota and
//! the address decision. Each test is a pure one over a temp folder and a `runtime.db` in it (pattern D: no timing, no
//! second task), unless it says otherwise.

use super::io::{Denied, HttpPolicy, IoCtx, KvError, judge_http, kv_delete, kv_get, kv_put};
use super::*;
use crate::agents::launch::NetCell;
use crate::settings::overrides::Override;
use gleipnir::net::policy::{Class, HostAddrs};
use std::net::IpAddr;

struct Rig {
    dir: tempfile::TempDir,
    db: urdr::Handle,
    _store: urdr::Store,
    settings: Arc<Settings>,
    plugins: Plugins,
}

impl Rig {
    fn root(&self) -> PathBuf {
        self.dir.path().join("data").join("plugins")
    }

    fn put(&self, name: &str, manifest: &str, wasm: &[u8]) {
        let d = self.root().join(name);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("plugin.json"), manifest).unwrap();
        std::fs::write(d.join("plugin.wasm"), wasm).unwrap();
    }

    async fn global(&self, name: &str, value: Value) {
        self.set(None, &[(name, value)]).await
    }

    /// The whole set of PROJECT (none: the global one).
    async fn set(&self, project: Option<&str>, list: &[(&str, Value)]) {
        let list = list
            .iter()
            .map(|(name, value)| Override {
                name: (*name).into(),
                value: value.clone(),
                source: "test".into(),
            })
            .collect();
        self.settings.set_overrides(project, list).await.unwrap();
    }
}

async fn rig() -> Rig {
    let dir = tempfile::tempdir().unwrap();
    let (store, db) = crate::runtime_db::open(dir.path()).unwrap();
    let settings = Arc::new(Settings::new());
    settings.open(dir.path().to_path_buf(), db.clone());
    settings.refresh().await;
    let plugins = Plugins::default();
    let r = Rig {
        dir,
        db: db.clone(),
        _store: store,
        settings: settings.clone(),
        plugins,
    };
    r.plugins.open(r.root(), db, settings);
    r
}

fn manifest(name: &str, extra: &str) -> String {
    format!(r#"{{"name":"{name}","version":"1.0.0"{extra}}}"#)
}

const ECHO: &str = r#","abilities":[{"name":"echo","description":"d","input_schema":{"type":"object"}}],"hosts":["api.example.com"]"#;

fn names(list: &[Arc<Plugin>]) -> Vec<&str> {
    list.iter().map(|p| p.manifest.name.as_str()).collect()
}

fn state(rows: &[PluginRow], name: &str) -> PluginState {
    rows.iter().find(|r| r.name == name).unwrap().state
}

fn hash_of(rows: &[PluginRow], name: &str) -> String {
    rows.iter()
        .find(|r| r.name == name)
        .and_then(|r| r.hash.as_ref())
        .unwrap()
        .as_str()
        .to_owned()
}

// [D] pure: plugins/install-then-list-unapproved
#[tokio::test]
async fn install_then_list_unapproved() {
    let r = rig().await;
    let m = manifest("alpha", ECHO);
    r.put("alpha", &m, b"\0asm-one");
    let s = r.plugins.sync().await.unwrap();
    assert_eq!(s.rows.len(), 1);
    let row = &s.rows[0];
    assert_eq!(row.state, PluginState::Unapproved);
    assert_eq!(row.abilities, ["echo"]);
    assert_eq!(row.hosts, ["api.example.com:443"]);
    assert_eq!(
        hash_of(&s.rows, "alpha"),
        hex(&brokkr::plugin_hash(m.as_bytes(), b"\0asm-one"))
    );
    assert_eq!(
        s.changes,
        [Change {
            name: "alpha".into(),
            state: Some(PluginState::Unapproved)
        }]
    );
    // a second look finds nothing new, and nothing runs
    assert!(r.plugins.sync().await.unwrap().changes.is_empty());
    r.global(SETTING_PLUGINS, json!(["alpha"])).await;
    assert!(r.plugins.enabled_for(None).is_empty());
}

// [D] pure: plugins/approve-enables, and disable until approved again
#[tokio::test]
async fn approve_enables_and_disable_switches_off() {
    let r = rig().await;
    r.put("alpha", &manifest("alpha", ECHO), b"one");
    r.global(SETTING_PLUGINS, json!(["alpha"])).await;
    let rows = r.plugins.sync().await.unwrap().rows;
    let (row, changes) = r
        .plugins
        .approve("alpha", &hash_of(&rows, "alpha"))
        .await
        .unwrap();
    assert_eq!(row.state, PluginState::Approved);
    assert_eq!(changes.len(), 1);
    assert_eq!(names(&r.plugins.enabled_for(None)), ["alpha"]);
    // approved, but not on the list: it does not run
    r.global(SETTING_PLUGINS, json!([])).await;
    assert!(r.plugins.enabled_for(None).is_empty());
    r.global(SETTING_PLUGINS, json!(["alpha"])).await;

    let (row, _) = r.plugins.disable("alpha").await.unwrap();
    assert_eq!(row.state, PluginState::Disabled);
    assert!(r.plugins.enabled_for(None).is_empty());
    let (row, _) = r
        .plugins
        .approve("alpha", &hash_of(&rows, "alpha"))
        .await
        .unwrap();
    assert_eq!(row.state, PluginState::Approved);
    assert_eq!(names(&r.plugins.enabled_for(None)), ["alpha"]);
}

// [D] pure: plugins/a-changed-wasm-is-disabled-until-approved, and a-changed-plugin-lists-its-approved-reach
#[tokio::test]
async fn a_changed_plugin_stops_and_lists_its_approved_reach() {
    let r = rig().await;
    r.put("alpha", &manifest("alpha", ECHO), b"one");
    r.global(SETTING_PLUGINS, json!(["alpha"])).await;
    let rows = r.plugins.sync().await.unwrap().rows;
    r.plugins
        .approve("alpha", &hash_of(&rows, "alpha"))
        .await
        .unwrap();
    assert_eq!(names(&r.plugins.enabled_for(None)), ["alpha"]);

    // the component is swapped, and the manifest asks for more
    let wider = r#","abilities":[{"name":"echo","description":"d","input_schema":{"type":"object"}},{"name":"more","description":"d","input_schema":{"type":"object"}}],"hosts":["api.example.com","evil.example.org"]"#;
    r.put("alpha", &manifest("alpha", wider), b"two");
    let s = r.plugins.sync().await.unwrap();
    let row = s.rows.iter().find(|x| x.name == "alpha").unwrap();
    assert_eq!(row.state, PluginState::Changed);
    assert!(
        r.plugins.enabled_for(None).is_empty(),
        "no call reaches the new code"
    );
    assert_eq!(row.abilities, ["echo", "more"]);
    assert_eq!(row.hosts, ["api.example.com:443", "evil.example.org:443"]);
    let was = row.approved_reach.clone().expect("the approved reach");
    assert_eq!(was.abilities, ["echo"]);
    assert_eq!(was.hosts, ["api.example.com:443"]);
    assert_eq!(
        s.changes,
        [Change {
            name: "alpha".into(),
            state: Some(PluginState::Changed)
        }]
    );

    // approving what is shown now turns it on again, and the old reach is not kept in the row
    let (row, _) = r
        .plugins
        .approve("alpha", &hash_of(&s.rows, "alpha"))
        .await
        .unwrap();
    assert_eq!(row.state, PluginState::Approved);
    assert_eq!(row.approved_reach, None);
    assert_eq!(names(&r.plugins.enabled_for(None)), ["alpha"]);
}

// [D] pure: plugins/approve-with-a-stale-hash-is-refused
#[tokio::test]
async fn approve_with_a_stale_hash_is_refused() {
    let r = rig().await;
    r.put("alpha", &manifest("alpha", ""), b"one");
    let shown = hash_of(&r.plugins.sync().await.unwrap().rows, "alpha");
    r.put("alpha", &manifest("alpha", ""), b"two");
    let e = r.plugins.approve("alpha", &shown).await.unwrap_err();
    assert_eq!(e.code, ErrorCode::InvalidParams);
    assert_eq!(e.path.as_deref(), Some("hash"));
    assert_eq!(
        state(&r.plugins.sync().await.unwrap().rows, "alpha"),
        PluginState::Unapproved
    );
    let e = r.plugins.approve("nope", &shown).await.unwrap_err();
    assert_eq!(e.path.as_deref(), Some("name"));
}

// [D] pure: a broken manifest is shown with its problem and cannot be approved; a removed folder is forgotten
#[tokio::test]
async fn broken_and_removed_plugins() {
    let r = rig().await;
    r.put("good", &manifest("good", ""), b"x");
    r.put("bad", "{not json", b"x");
    let s = r.plugins.sync().await.unwrap();
    assert_eq!(state(&s.rows, "bad"), PluginState::Broken);
    assert!(
        s.rows
            .iter()
            .find(|x| x.name == "bad")
            .unwrap()
            .problem
            .is_some()
    );
    let e = r.plugins.approve("bad", &"0".repeat(64)).await.unwrap_err();
    assert_eq!(e.path.as_deref(), Some("name"));

    let h = hash_of(&s.rows, "good");
    r.plugins.approve("good", &h).await.unwrap();
    std::fs::remove_dir_all(r.root().join("good")).unwrap();
    let s = r.plugins.sync().await.unwrap();
    assert!(s.changes.contains(&Change {
        name: "good".into(),
        state: None
    }));
    // its approval went with it: the same files back are unapproved again
    r.put("good", &manifest("good", ""), b"x");
    assert_eq!(
        state(&r.plugins.sync().await.unwrap().rows, "good"),
        PluginState::Unapproved
    );
}

// [D] pure: plugins/project-override-disables
#[tokio::test]
async fn a_project_list_replaces_the_global_one() {
    let r = rig().await;
    for n in ["alpha", "beta"] {
        r.put(n, &manifest(n, ""), n.as_bytes());
    }
    let rows = r.plugins.sync().await.unwrap().rows;
    for n in ["alpha", "beta"] {
        r.plugins.approve(n, &hash_of(&rows, n)).await.unwrap();
    }
    r.global(SETTING_PLUGINS, json!(["beta", "alpha"])).await;
    r.set(Some("p"), &[(SETTING_PLUGINS, json!(["beta"]))])
        .await;
    assert_eq!(names(&r.plugins.enabled_for(None)), ["beta", "alpha"]);
    assert_eq!(names(&r.plugins.enabled_for(Some("p"))), ["beta"]);
    // a project that never sent a list has the global one
    assert_eq!(names(&r.plugins.enabled_for(Some("q"))), ["beta", "alpha"]);
    // a project's empty list is its own: nothing runs there
    r.set(Some("p"), &[(SETTING_PLUGINS, json!([]))]).await;
    assert!(r.plugins.enabled_for(Some("p")).is_empty());
}

fn rule(id: Option<&str>, verdict: &str, reason: &str) -> Value {
    let mut r = json!({"point": "before-tool", "verdict": verdict, "reason": reason, "tool_kinds": ["execute"]});
    if let Some(id) = id {
        r["id"] = json!(id);
    }
    r
}

// [D] pure: rules_for_appends_and_switches_off_by_id
#[tokio::test]
async fn rules_for_appends_and_switches_off_by_id() {
    let r = rig().await;
    let (a, b) = (
        rule(Some("a"), "deny", "no a"),
        rule(Some("b"), "annotate", "note b"),
    );
    r.global(SETTING_RULES, json!([a, b])).await;
    let ids =
        |rules: &[Rule]| -> Vec<Option<String>> { rules.iter().map(|x| x.id.clone()).collect() };
    assert_eq!(
        ids(&r.plugins.rules_for(None)),
        [Some("a".into()), Some("b".into())]
    );
    // the project switches `a` off and adds its own; the editor sends the merged list, so `b` comes again
    let mine = rule(None, "deny", "mine");
    r.set(
        Some("p"),
        &[
            (SETTING_RULES, json!([b, mine])),
            (SETTING_RULES_OFF, json!(["a"])),
        ],
    )
    .await;
    let got = r.plugins.rules_for(Some("p"));
    assert_eq!(ids(&got), [Some("b".into()), None]);
    assert_eq!(got[1].reason, "mine");
    // another project keeps the global rules, and the global ones are unchanged
    assert_eq!(r.plugins.rules_for(Some("q")).len(), 2);
    assert_eq!(r.plugins.rules_for(None).len(), 2);
    // keys may be written as the Lisp spells them
    r.set(
        Some("p"),
        &[(
            SETTING_RULES,
            json!([{"point": "after-edit", "tool-kinds": ["edit"], "verdict": "annotate", "reason": "x"}]),
        )],
    )
    .await;
    assert_eq!(r.plugins.rules_for(Some("p")).len(), 3);
}

// [D] pure: settings/a-bad-project-rule-is-refused-with-its-path
#[tokio::test]
async fn a_bad_project_rule_refuses_the_whole_set_with_its_path() {
    let r = rig().await;
    let good = Override {
        name: SETTING_PLUGINS.into(),
        value: json!(["alpha"]),
        source: "test".into(),
    };
    let bad = Override {
        name: SETTING_RULES.into(),
        value: json!([rule(None, "deny", "ok"), rule(None, "wild", "no")]),
        source: "test".into(),
    };
    let e = r
        .settings
        .set_overrides(Some("p"), vec![good, bad])
        .await
        .unwrap_err();
    assert_eq!(
        e.path.as_deref(),
        Some("overrides[1].value[1].verdict"),
        "{e:?}"
    );
    // nothing was kept, not even the good entry
    assert!(r.settings.project_value(SETTING_PLUGINS, "p").is_none());
    // a bad id too
    let bad = Override {
        name: SETTING_RULES.into(),
        value: json!([rule(Some("Bad Id"), "deny", "no")]),
        source: "test".into(),
    };
    let e = r
        .settings
        .set_overrides(Some("p"), vec![bad])
        .await
        .unwrap_err();
    assert_eq!(e.path.as_deref(), Some("overrides[0].value[0].id"), "{e:?}");
}

// [D] pure: kv_quota_enforced
#[tokio::test]
async fn kv_quota_enforced() {
    let r = rig().await;
    let db = &r.db;
    kv_put(db, "alpha", "k1", b"12345678", 16).await.unwrap(); // 2 + 8
    assert_eq!(
        kv_put(db, "alpha", "k2", b"123456789", 16).await, // 2 + 9 more: over
        Err(KvError::Quota { limit: 16 })
    );
    assert_eq!(kv_get(db, "alpha", "k2").await, Ok(None));
    // replacing a value is counted by its new size, not added to the old
    kv_put(db, "alpha", "k1", b"123456789012", 16)
        .await
        .unwrap();
    assert_eq!(
        kv_get(db, "alpha", "k1").await,
        Ok(Some(b"123456789012".to_vec()))
    );
    assert_eq!(
        kv_put(db, "alpha", "k1", b"1234567890123456", 16).await,
        Err(KvError::Quota { limit: 16 })
    );
    // the store is the plugin's own
    kv_put(db, "beta", "k1", b"12345678901234", 16)
        .await
        .unwrap();
    kv_delete(db, "alpha", "k1").await.unwrap();
    kv_put(db, "alpha", "k2", b"1234567890", 16).await.unwrap();
}

fn public(name: &str) -> Vec<IpAddr> {
    let _ = name;
    vec!["93.184.216.34".parse().unwrap()]
}

fn policy<'a>(
    ctx: Option<(&'a IoCtx, NetCell)>,
    hosts: &'a [String],
    tier: &'a [String],
    pins: &'a [(String, IpAddr)],
    own: &'a HostAddrs,
) -> HttpPolicy<'a> {
    HttpPolicy {
        ctx,
        manifest_hosts: hosts,
        plugin_tier: tier,
        pins,
        host_addrs: own,
    }
}

// [D] pure: http_refused_for_a_host_off_the_plugin_tier
#[test]
fn http_refused_for_a_host_off_the_plugin_tier() {
    let (sid, own) = (IoCtx::Session("s1".into()), HostAddrs::default());
    let hosts = [
        "api.example.com:443".to_string(),
        "other.example.com:443".to_string(),
    ];
    let tier = ["api.example.com:443".to_string()];
    for cell in [NetCell::ProviderOnly, NetCell::ProviderAndPackages] {
        let p = policy(Some((&sid, cell)), &hosts, &tier, &[], &own);
        let ok = judge_http("api.example.com:443", &p, &public).unwrap();
        assert_eq!(ok[0].port(), 443);
        // the manifest names it, the tier does not
        assert_eq!(
            judge_http("other.example.com:443", &p, &public),
            Err(Denied::NotOnTier)
        );
        // the tier would, the manifest does not
        let t2 = [
            "api.example.com:443".to_string(),
            "free.example.com:443".to_string(),
        ];
        let p = policy(Some((&sid, cell)), &hosts, &t2, &[], &own);
        assert_eq!(
            judge_http("free.example.com:443", &p, &public),
            Err(Denied::NotInManifest)
        );
    }
    // in `open` a manifest host needs no tier
    let p = policy(Some((&sid, NetCell::Open)), &hosts, &[], &[], &own);
    assert!(judge_http("other.example.com:443", &p, &public).is_ok());
}

// [D] pure: open_cell_still_refuses_loopback (a stub resolver maps a public-looking name to 127.0.0.1)
#[test]
fn open_cell_still_refuses_loopback() {
    let (sid, own) = (IoCtx::Session("s1".into()), HostAddrs::default());
    let hosts = [
        "looks-public.example.com:443".to_string(),
        "localhost:9222".to_string(),
        "metadata.example.com:443".to_string(),
        "lan.example.com:443".to_string(),
        "metadata.google.internal:443".to_string(),
        "host.drgnx.internal:8080".to_string(),
    ];
    let p = policy(Some((&sid, NetCell::Open)), &hosts, &[], &[], &own);
    let resolve = |n: &str| -> Vec<IpAddr> {
        match n {
            "looks-public.example.com" | "localhost" => vec!["127.0.0.1".parse().unwrap()],
            "metadata.example.com" => vec!["169.254.169.254".parse().unwrap()],
            "lan.example.com" => vec!["192.168.1.5".parse().unwrap()],
            _ => public(n),
        }
    };
    let class = |r: Result<_, Denied>| match r {
        Err(Denied::Address(_, c)) => Some(c),
        _ => None,
    };
    assert_eq!(
        class(judge_http("looks-public.example.com:443", &p, &resolve)),
        Some(Class::Loopback)
    );
    assert_eq!(
        class(judge_http("localhost:9222", &p, &resolve)),
        Some(Class::Loopback)
    );
    assert_eq!(
        class(judge_http("metadata.example.com:443", &p, &resolve)),
        Some(Class::Never)
    );
    // a LAN address is refused for a name nobody pinned
    assert_eq!(
        class(judge_http("lan.example.com:443", &p, &resolve)),
        Some(Class::Lan)
    );
    // names the policy refuses by name, whatever they resolve to
    assert!(matches!(
        judge_http("metadata.google.internal:443", &p, &resolve),
        Err(Denied::Target(_))
    ));
    assert!(matches!(
        judge_http("host.drgnx.internal:8080", &p, &resolve),
        Err(Denied::Target(_))
    ));
    // one bad address among good ones refuses the name
    let mixed = |_: &str| -> Vec<IpAddr> {
        vec![
            "93.184.216.34".parse().unwrap(),
            "10.0.0.1".parse().unwrap(),
        ]
    };
    assert!(judge_http("lan.example.com:443", &p, &mixed).is_err());
    // a name the user pinned may reach the LAN, never loopback
    let pins = [
        (
            "lan.example.com".to_string(),
            "192.168.1.5".parse::<IpAddr>().unwrap(),
        ),
        (
            "looks-public.example.com".to_string(),
            "127.0.0.1".parse::<IpAddr>().unwrap(),
        ),
    ];
    let p = policy(Some((&sid, NetCell::Open)), &hosts, &[], &pins, &own);
    assert_eq!(
        judge_http("lan.example.com:443", &p, &resolve).unwrap()[0]
            .ip()
            .to_string(),
        "192.168.1.5"
    );
    assert_eq!(
        class(judge_http("looks-public.example.com:443", &p, &resolve)),
        Some(Class::Loopback)
    );
    // an IP literal is no host name
    let lit = ["10.0.0.1:443".to_string()];
    let p = policy(Some((&sid, NetCell::Open)), &lit, &[], &[], &own);
    assert!(matches!(
        judge_http("10.0.0.1:443", &p, &resolve),
        Err(Denied::Target(_))
    ));
}

// [D] pure: http_with_no_session_and_no_job_is_refused
#[test]
fn http_with_no_session_and_no_job_is_refused() {
    let own = HostAddrs::default();
    let hosts = ["api.example.com:443".to_string()];
    let p = policy(None, &hosts, &hosts, &[], &own);
    assert_eq!(
        judge_http("api.example.com:443", &p, &public),
        Err(Denied::NoContext)
    );
    let job = IoCtx::Job("j1".into());
    let p = policy(
        Some((&job, NetCell::ProviderOnly)),
        &hosts,
        &hosts,
        &[],
        &own,
    );
    assert!(judge_http("api.example.com:443", &p, &public).is_ok());
}

fn source(dir: &Path, manifest: &str, wasm: &[u8]) -> PathBuf {
    let s = dir.join("src");
    std::fs::create_dir_all(&s).unwrap();
    std::fs::write(s.join("plugin.json"), manifest).unwrap();
    std::fs::write(s.join("plugin.wasm"), wasm).unwrap();
    s
}

// [D] pure: install copies, refuses a name that is there, and replaces with the flag; an approved plugin turns changed
#[tokio::test]
async fn install_copies_refuses_an_existing_name_and_replaces_with_a_flag() {
    use std::os::unix::fs::PermissionsExt;
    let r = rig().await;
    let m = manifest("alpha", ECHO);
    let src = source(r.dir.path(), &m, b"one");
    let got = install(&r.root(), &src, false).unwrap();
    assert_eq!(got.name, "alpha");
    assert_eq!(got.version, "1.0.0");
    assert_eq!(got.hash, hex(&brokkr::plugin_hash(m.as_bytes(), b"one")));
    let dest = r.root().join("alpha");
    assert_eq!(std::fs::read(dest.join("plugin.wasm")).unwrap(), b"one");
    assert_eq!(
        std::fs::metadata(&dest).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert_eq!(
        std::fs::metadata(r.root()).unwrap().permissions().mode() & 0o777,
        0o700
    );

    let rows = r.plugins.sync().await.unwrap().rows;
    assert_eq!(hash_of(&rows, "alpha"), got.hash);
    r.plugins.approve("alpha", &got.hash).await.unwrap();

    std::fs::write(src.join("plugin.wasm"), b"two").unwrap();
    let e = install(&r.root(), &src, false).unwrap_err();
    assert!(e.contains("--replace"), "{e}");
    assert_eq!(
        std::fs::read(dest.join("plugin.wasm")).unwrap(),
        b"one",
        "nothing changed"
    );
    let again = install(&r.root(), &src, true).unwrap();
    assert_ne!(again.hash, got.hash);
    assert_eq!(std::fs::read(dest.join("plugin.wasm")).unwrap(), b"two");
    assert_eq!(
        state(&r.plugins.sync().await.unwrap().rows, "alpha"),
        PluginState::Changed
    );
    // no staging folder is left beside the plugins
    let left: Vec<_> = std::fs::read_dir(r.dir.path().join("data"))
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    assert_eq!(left, ["plugins"]);
}

// [D] pure: a manifest that does not read, a missing component and a link copy nothing
#[test]
fn install_refuses_what_does_not_read() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("data").join("plugins");
    let src = source(dir.path(), "{not json", b"x");
    assert!(
        install(&root, &src, false)
            .unwrap_err()
            .contains("plugin.json")
    );
    std::fs::write(src.join("plugin.json"), manifest("alpha", "")).unwrap();
    std::fs::remove_file(src.join("plugin.wasm")).unwrap();
    assert!(
        install(&root, &src, false)
            .unwrap_err()
            .contains("plugin.wasm")
    );
    std::fs::write(dir.path().join("elsewhere"), b"x").unwrap();
    std::os::unix::fs::symlink(dir.path().join("elsewhere"), src.join("plugin.wasm")).unwrap();
    assert!(
        install(&root, &src, false).is_err(),
        "a link is never followed"
    );
    assert!(!root.join("alpha").exists());
    assert!(install(&root, &dir.path().join("none"), false).is_err());
}

// [D] pure: remove deletes the folder; a name that is no plugin's is refused
#[test]
fn remove_deletes_the_folder() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("plugins");
    let src = source(dir.path(), &manifest("alpha", ""), b"x");
    install(&root, &src, false).unwrap();
    assert!(remove(&root, "../alpha").is_err());
    assert!(remove(&root, "beta").is_err());
    remove(&root, "alpha").unwrap();
    assert!(!root.join("alpha").exists());
}
