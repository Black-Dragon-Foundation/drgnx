//! `HubIo` under the real plugin host: the `http-ability` fixture (built at test time) calls its imports, and the
//! hub answers them. Pattern C (handshake): each call's answer, and the store and events it wrote, are the only
//! waits. The runtimes are multi-thread on real time: the host's outer timeout runs on the caller's runtime, so a
//! paused clock would end every call at once.

use brokkr::test_support::fixture;
use brokkr::{CallError, Host, Limits, Plugin, scan};
use rcgen::{
    BasicConstraints, CertificateParams, DnType, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair,
    KeyUsagePurpose, SanType, date_time_ymd,
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use super::*;
use crate::settings::overrides::Override;

struct Rig {
    dir: tempfile::TempDir,
    _store: urdr::Store,
    db: urdr::Handle,
    settings: Arc<Settings>,
    writer: Writer,
}

/// A `runtime.db`, the settings with the `plugin` tier TIER of `drgnx-agents-net-hosts`, and a work.db for events.
async fn rig(tier: &[&str]) -> Rig {
    let dir = tempfile::tempdir().unwrap();
    let (store, db) = crate::runtime_db::open(dir.path()).unwrap();
    let settings = Arc::new(Settings::new());
    settings.open(dir.path().to_path_buf(), db.clone());
    settings.refresh().await;
    settings
        .set_overrides(
            None,
            vec![Override {
                name: "drgnx-agents-net-hosts".into(),
                value: json!({ "plugin": tier }),
                source: "test".into(),
            }],
        )
        .await
        .unwrap();
    let writer = Writer {
        db: norn::store::CoordDb::spawn(dir.path().join("work.db")),
        signals: Arc::new(crate::coord::Signals::default()),
    };
    Rig {
        dir,
        _store: store,
        db,
        settings,
        writer,
    }
}

/// What the network seam was asked: every name looked up and every address connected to.
#[derive(Default)]
struct Asked {
    resolved: Mutex<Vec<String>>,
    connected: Mutex<Vec<SocketAddr>>,
}

/// A network whose resolver answers ANSWER for every name, whose connections all go to the in-test server on
/// 127.0.0.1:PORT (none: refused), and whose TLS trusts ROOTS only.
fn net(
    answer: &str,
    port: Option<u16>,
    roots: Vec<CertificateDer<'static>>,
) -> (Arc<Net>, Arc<Asked>) {
    let asked = Arc::new(Asked::default());
    let (a, b) = (asked.clone(), asked.clone());
    let ip: IpAddr = answer.parse().unwrap();
    let mut store = rustls::RootCertStore::empty();
    for r in roots {
        store.add(r).unwrap();
    }
    let tls = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_root_certificates(store)
    .with_no_client_auth();
    let net = Net {
        resolve: Arc::new(move |name: &str| {
            a.resolved.lock().unwrap().push(name.to_string());
            vec![ip]
        }),
        connect: Arc::new(move |addr: SocketAddr| {
            b.connected.lock().unwrap().push(addr);
            Box::pin(async move {
                match port {
                    Some(p) => TcpStream::connect(("127.0.0.1", p)).await,
                    None => Err(io::Error::other("no server in this test")),
                }
            }) as Connecting
        }),
        tls: Ok(Arc::new(tls)),
    };
    (Arc::new(net), asked)
}

fn parts(r: &Rig, net: Arc<Net>) -> HubParts {
    HubParts {
        db: r.db.clone(),
        settings: r.settings.clone(),
        host_addrs: Arc::new(RwLock::new(HostAddrs::default())),
        writer: r.writer.clone(),
        net,
    }
}

fn session(sid: &str, cell: NetCell) -> Option<(IoCtx, NetCell)> {
    Some((IoCtx::Session(sid.into()), cell))
}

/// The fixture `http-ability`, or a copy of it under the rig's folder whose manifest adds EXTRA (`"kv_bytes": 16`).
fn plugin(host: &Host, r: &Rig, extra: Option<&str>) -> Plugin {
    let from = fixture("http-ability");
    let root = match extra {
        None => from.parent().unwrap().to_path_buf(),
        Some(extra) => {
            let root = r.dir.path().join("plugins");
            let dir = root.join("http-ability");
            std::fs::create_dir_all(&dir).unwrap();
            let manifest = std::fs::read_to_string(from.join("plugin.json"))
                .unwrap()
                .replace(
                    r#""hosts": ["api.example.com"]"#,
                    &format!(r#""hosts": ["api.example.com"], {extra}"#),
                );
            assert!(manifest.contains(extra), "the fixture's manifest moved");
            std::fs::write(dir.join("plugin.json"), manifest).unwrap();
            std::fs::copy(from.join("plugin.wasm"), dir.join("plugin.wasm")).unwrap();
            root
        }
    };
    let i = scan(&root)
        .into_iter()
        .filter_map(Result::ok)
        .find(|i| i.manifest.name.as_str() == "http-ability")
        .unwrap();
    host.load(&i, i.hash).unwrap()
}

async fn call(
    host: &Host,
    p: &Plugin,
    io: &Arc<HubIo>,
    tool: &str,
    args: Value,
) -> Result<Value, CallError> {
    host.call_ability(p, tool, args, io.clone()).await
}

/// The `proxy-denied` events in work.db, oldest first: (agent, data).
async fn denials(w: &Writer) -> Vec<(Option<String>, Value)> {
    let caller = crate::runner::service();
    let rows: Vec<(Option<String>, String, String)> = w
        .write(&caller, "test/read", |tx| {
            let mut q = tx.sql().prepare(
                "select agent, kind, data from event where data like '%proxy-denied%' order by id",
            )?;
            let it = q.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
            Ok(it.collect::<Result<Vec<_>, _>>()?)
        })
        .await
        .unwrap();
    rows.into_iter()
        .map(|(agent, kind, data)| {
            assert_eq!(kind, "status");
            (agent, serde_json::from_str(&data).unwrap())
        })
        .collect()
}

fn refused(r: Result<Value, CallError>, why: &str) {
    match r {
        Err(CallError::Plugin(m)) => assert!(m.contains(why), "{m}"),
        other => panic!("not refused with {why:?}: {other:?}"),
    }
}

// [C] handshake: hub_io_an_undeclared_host_is_denied_with_the_event
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_undeclared_host_is_denied_with_the_event_and_nothing_leaves() {
    let r = rig(&["other.example.com:443"]).await;
    let host = Host::new(Limits::default()).unwrap();
    let p = plugin(&host, &r, None);
    let (net, asked) = net("127.0.0.1", None, Vec::new());
    let io = Arc::new(HubIo::new(
        session("s1", NetCell::ProviderOnly),
        &[p.manifest()],
        parts(&r, net.clone()),
    ));
    // the manifest does not name it: the host refuses it before any I/O, and the hub records the denial
    refused(
        call(
            &host,
            &p,
            &io,
            "fetch",
            json!({"url": "https://evil.example.org/x"}),
        )
        .await,
        "not a host this plugin declared",
    );
    // the manifest names it, the `plugin` tier does not: refused before any lookup, twice, recorded once
    for _ in 0..2 {
        refused(
            call(
                &host,
                &p,
                &io,
                "fetch",
                json!({"url": "https://api.example.com/v1"}),
            )
            .await,
            "`plugin` tier",
        );
    }
    // in `open` no tier is needed, and the address is still judged: a name that resolves to loopback is refused
    let open = Arc::new(HubIo::new(
        session("s2", NetCell::Open),
        &[p.manifest()],
        parts(&r, net),
    ));
    refused(
        call(
            &host,
            &p,
            &open,
            "fetch",
            json!({"url": "https://api.example.com/v1"}),
        )
        .await,
        "Loopback",
    );
    let event = |sid: &str, host: &str| {
        (
            Some(sid.to_string()),
            json!({"proxy-denied": true, "session": sid, "host": host, "plugin": "http-ability"}),
        )
    };
    assert_eq!(
        denials(&r.writer).await,
        [
            event("s1", "evil.example.org:443"),
            event("s1", "api.example.com:443"),
            event("s2", "api.example.com:443"),
        ]
    );
    assert_eq!(
        *asked.resolved.lock().unwrap(),
        ["api.example.com"],
        "one lookup, in `open` only"
    );
    assert!(
        asked.connected.lock().unwrap().is_empty(),
        "a refused request connected"
    );
}

/// A CA, and a server certificate for `api.example.com` it signed.
fn certificates() -> (
    CertificateDer<'static>,
    Vec<CertificateDer<'static>>,
    PrivateKeyDer<'static>,
) {
    let ca_key = KeyPair::generate().unwrap();
    let mut ca = CertificateParams::new(Vec::<String>::new()).unwrap();
    ca.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    ca.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    ca.distinguished_name.push(DnType::CommonName, "test CA");
    ca.not_before = date_time_ymd(2020, 1, 1);
    ca.not_after = date_time_ymd(2046, 1, 1);
    let root = ca.self_signed(&ca_key).unwrap().der().clone();
    let issuer = Issuer::new(ca, ca_key);
    let key = KeyPair::generate().unwrap();
    let mut leaf = CertificateParams::new(Vec::<String>::new()).unwrap();
    leaf.subject_alt_names
        .push(SanType::DnsName("api.example.com".try_into().unwrap()));
    leaf.distinguished_name
        .push(DnType::CommonName, "api.example.com");
    leaf.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    leaf.not_before = date_time_ymd(2020, 1, 1);
    leaf.not_after = date_time_ymd(2046, 1, 1);
    let cert = leaf.signed_by(&key, &issuer).unwrap();
    (
        root,
        vec![cert.der().clone()],
        PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der())),
    )
}

/// An HTTPS server on 127.0.0.1 for one request: it sends back the request's head and answers `hello`.
async fn server(
    chain: Vec<CertificateDer<'static>>,
    key: PrivateKeyDer<'static>,
) -> (u16, tokio::sync::oneshot::Receiver<String>) {
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(chain, key)
    .unwrap();
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (tx, rx) = tokio::sync::oneshot::channel();
    tokio::spawn(async move {
        let (tcp, _) = listener.accept().await.unwrap();
        let mut tls = acceptor.accept(tcp).await.unwrap();
        let mut head = Vec::new();
        let mut b = [0u8; 1024];
        while !head.windows(4).any(|w| w == b"\r\n\r\n") {
            let n = tls.read(&mut b).await.unwrap();
            if n == 0 {
                break;
            }
            head.extend_from_slice(&b[..n]);
        }
        let _ = tx.send(String::from_utf8_lossy(&head).into_owned());
        tls.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
            .await
            .unwrap();
        let _ = tls.shutdown().await;
    });
    (port, rx)
}

// [C] handshake: hub_io_a_declared_host_is_fetched_through_the_hub
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_declared_host_is_fetched_at_the_address_the_hub_judged() {
    let r = rig(&["api.example.com:443"]).await;
    let host = Host::new(Limits::default()).unwrap();
    let p = plugin(&host, &r, None);
    let (root, chain, key) = certificates();
    let (port, head) = server(chain, key).await;
    let (net, asked) = net("93.184.216.34", Some(port), vec![root]);
    let io = Arc::new(HubIo::new(
        session("s1", NetCell::ProviderOnly),
        &[p.manifest()],
        parts(&r, net),
    ));
    let got = call(
        &host,
        &p,
        &io,
        "fetch",
        json!({"url": "https://API.example.com/v1?q=1#frag", "headers": [["Accept", "text/plain"]]}),
    )
    .await;
    assert_eq!(got, Ok(json!({"status": 200, "body": "hello"})));
    let head = head.await.unwrap().to_ascii_lowercase();
    assert!(head.starts_with("get /v1?q=1 http/1.1\r\n"), "{head}");
    assert!(head.contains("\r\nhost: api.example.com\r\n"), "{head}");
    assert!(head.contains("\r\naccept: text/plain\r\n"), "{head}");
    // the one lookup's public answer is the one address connected to
    assert_eq!(*asked.resolved.lock().unwrap(), ["api.example.com"]);
    assert_eq!(
        *asked.connected.lock().unwrap(),
        ["93.184.216.34:443".parse::<SocketAddr>().unwrap()]
    );
    assert!(denials(&r.writer).await.is_empty());
}

// [C] handshake: hub_io_the_kv_quota_holds_across_calls
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_kv_quota_holds_across_calls() {
    let r = rig(&[]).await;
    let host = Host::new(Limits::default()).unwrap();
    let p = plugin(&host, &r, Some(r#""kv_bytes": 16"#));
    let (net, _) = net("127.0.0.1", None, Vec::new());
    let io_for = |sid: &str| {
        Arc::new(HubIo::new(
            session(sid, NetCell::ProviderOnly),
            &[p.manifest()],
            parts(&r, net.clone()),
        ))
    };
    let (a, b) = (io_for("s1"), io_for("s2"));
    let put = |k: &str, v: &str| json!({"op": "put", "key": k, "value": v});
    // 2 + 8 bytes of 16
    assert_eq!(
        call(&host, &p, &a, "kv", put("k1", "12345678")).await,
        Ok(json!({}))
    );
    // another call, another session: 2 + 9 more is over, and nothing is written
    refused(
        call(&host, &p, &b, "kv", put("k2", "123456789")).await,
        "the plugin's store is full (16 bytes)",
    );
    let get = |k: &str| json!({"op": "get", "key": k});
    assert_eq!(call(&host, &p, &b, "kv", get("k2")).await, Ok(Value::Null));
    assert_eq!(
        call(&host, &p, &b, "kv", get("k1")).await,
        Ok(json!("12345678"))
    );
    // a replaced value counts at its new size
    assert_eq!(
        call(&host, &p, &a, "kv", put("k1", "12345678901234")).await,
        Ok(json!({}))
    );
    refused(
        call(&host, &p, &a, "kv", put("k1", "123456789012345")).await,
        "the plugin's store is full (16 bytes)",
    );
    assert_eq!(
        super::super::io::kv_get(&r.db, "http-ability", "k1").await,
        Ok(Some(b"12345678901234".to_vec()))
    );
    // a delete frees the room
    assert_eq!(
        call(&host, &p, &b, "kv", json!({"op": "delete", "key": "k1"})).await,
        Ok(json!({}))
    );
    assert_eq!(
        call(&host, &p, &b, "kv", put("k2", "123456789")).await,
        Ok(json!({}))
    );
}
