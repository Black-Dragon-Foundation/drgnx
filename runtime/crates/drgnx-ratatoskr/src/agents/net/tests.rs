use super::*;
use std::net::Ipv4Addr;
use std::os::unix::fs::PermissionsExt;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn t(s: &str) -> Target {
    parse_target(s).unwrap()
}

fn profile(command: &str, ai: Option<&str>) -> AgentProfile {
    AgentProfile {
        name: "p".into(),
        command: vec![command.into()],
        env: vec![],
        mode: None,
        ai: ai.map(str::to_string),
        model: None,
        tracker_tools: None,
        doc: None,
        provider: None,
        job_safe: false,
    }
}

fn hosts() -> NetHosts {
    vec![
        (
            "provider-only".into(),
            vec!["extra.test:443".into(), "api.anthropic.com:443".into()],
        ),
        ("packages".into(), vec!["crates.io:443".into()]),
    ]
}

/// OD2's union: the providers' base hosts, the CLI's own hosts and the cell's tier, each once; `Open` gets none.
#[test]
fn provider_hosts_union() {
    let none: &[ProviderConfig] = &[];
    let names = |v: Vec<Target>| v.iter().map(Target::to_string).collect::<Vec<_>>();
    assert_eq!(
        names(provider_hosts(
            &profile("/usr/bin/claude-code-acp", None),
            none,
            &hosts(),
            NetCell::ProviderOnly
        )),
        [
            "api.anthropic.com:443",
            "platform.claude.com:443",
            "extra.test:443"
        ]
    );
    assert_eq!(
        names(provider_hosts(
            &profile("codex-acp", None),
            none,
            &hosts(),
            NetCell::ProviderAndPackages
        )),
        [
            "api.openai.com:443",
            "chatgpt.com:443",
            "auth.openai.com:443",
            "crates.io:443"
        ]
    );
    assert_eq!(
        names(provider_hosts(
            &profile("gemini", None),
            none,
            &NetHosts::new(),
            NetCell::ProviderOnly
        )),
        [
            "generativelanguage.googleapis.com:443",
            "oauth2.googleapis.com:443",
            "cloudcode-pa.googleapis.com:443"
        ]
    );
    // a gateway profile: its chain's providers' base hosts (the scheme's port, or the URL's) come first
    let providers: Vec<ProviderConfig> = [
        ("openrouter", "https://openrouter.ai/api/v1"),
        ("local", "http://llm.lan:8080/v1"),
    ]
    .iter()
    .map(|(id, base)| {
        serde_json::from_value(serde_json::json!({
            "id": id, "kind": "openai", "base": base, "auth": "bearer", "messages": true, "caps": ["chat"]
        }))
        .unwrap()
    })
    .collect();
    assert_eq!(
        names(provider_hosts(
            &profile("claude", Some("claude-openrouter")),
            &providers,
            &hosts(),
            NetCell::ProviderOnly
        )),
        [
            "openrouter.ai:443",
            "llm.lan:8080",
            "api.anthropic.com:443",
            "platform.claude.com:443",
            "extra.test:443"
        ]
    );
    // a profile whose CLI is none of the three: only its tier
    assert_eq!(
        names(provider_hosts(
            &profile("/bin/sh", None),
            none,
            &hosts(),
            NetCell::ProviderOnly
        )),
        ["extra.test:443", "api.anthropic.com:443"]
    );
    for p in [profile("claude", None), profile("/bin/sh", None)] {
        assert!(provider_hosts(&p, &providers, &hosts(), NetCell::Open).is_empty());
    }
}

#[test]
fn a_base_url_is_its_host_and_port() {
    for (url, want) in [
        ("https://api.example.com/v1", Some("api.example.com:443")),
        ("http://Example.COM", Some("example.com:80")),
        ("https://h.test:8443/x?y=1", Some("h.test:8443")),
        ("http://[::1]:8080/v1", Some("[::1]:8080")),
        ("https://[2001:db8::1]/v1", Some("[2001:db8::1]:443")),
        ("ftp://h.test/x", None),
        ("h.test:443", None),
    ] {
        assert_eq!(
            base_target(url).map(|t| t.to_string()).as_deref(),
            want,
            "{url}"
        );
    }
}

/// The socket is 0600 and serves CONNECT to an allowed (pinned) host; the drop closes its listener and its open
/// tunnels and removes the socket, never a newer session's on the same path; a stale file is replaced.
#[tokio::test]
async fn socket_is_0600_and_closed_with_the_session() {
    let d = tempfile::tempdir_in("/tmp").unwrap();
    let dir = d.path();
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    let sock = dir.join(runstav::paths::SESSION_PROXY_SOCKET);
    std::fs::write(&sock, b"stale").unwrap();

    let upstream = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = upstream.local_addr().unwrap().port();
    let host = format!("allowed.test:{port}");
    let pinned = vec![("allowed.test".to_string(), IpAddr::V4(Ipv4Addr::LOCALHOST))];
    let net = SessionNet::start(dir, "s1", vec![t(&host)], pinned.clone(), None).unwrap();
    assert_eq!(net.socket(), sock.as_path());
    let mode = std::fs::symlink_metadata(&sock)
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600, "{mode:o}");

    let mut c = tokio::net::UnixStream::connect(&sock).await.unwrap();
    c.write_all(format!("CONNECT {host} HTTP/1.1\r\n\r\n").as_bytes())
        .await
        .unwrap();
    let (mut up, _) = tokio::time::timeout(Duration::from_secs(5), upstream.accept())
        .await
        .unwrap()
        .unwrap();
    let mut head = [0u8; 39];
    c.read_exact(&mut head).await.unwrap();
    assert!(
        head.starts_with(b"HTTP/1.1 200"),
        "{:?}",
        head.escape_ascii()
    );
    c.write_all(b"ping").await.unwrap();
    let mut got = [0u8; 4];
    up.read_exact(&mut got).await.unwrap();
    assert_eq!(&got, b"ping");

    drop(net);
    assert!(
        std::fs::symlink_metadata(&sock).is_err(),
        "the socket stays"
    );
    assert!(tokio::net::UnixStream::connect(&sock).await.is_err());
    // the open tunnel ends with it
    let mut rest = Vec::new();
    let end = tokio::time::timeout(Duration::from_secs(5), c.read_to_end(&mut rest)).await;
    assert!(end.is_ok(), "the tunnel outlived the session");

    // a session bound again on the same path keeps its socket when the older one goes
    let old = SessionNet::start(dir, "s1", vec![], vec![], None).unwrap();
    let new = SessionNet::start(dir, "s1", vec![], vec![], None).unwrap();
    drop(old);
    assert!(
        std::fs::symlink_metadata(&sock).is_ok(),
        "the newer socket went"
    );
    drop(new);
    assert!(std::fs::symlink_metadata(&sock).is_err());
}
