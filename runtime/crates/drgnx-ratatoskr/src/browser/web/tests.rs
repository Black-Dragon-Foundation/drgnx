use super::*;
use crate::dispatch::Caller;
use norn::matrix::Role;
use norn::store::CoordDb;
use norn::write::cards::card_settle;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::time::timeout;

/// A failure guard only: each wait ends as soon as what it waits for happened.
const WAIT: Duration = Duration::from_secs(10);

fn front(dir: &Path) -> Front {
    Front::new(
        runstav::proof::Cap::generate().unwrap(),
        dir.join("hub-x.sock"),
        crate::store::WorkDb::spawn(dir.join("work.db")).unwrap(),
        CoordDb::spawn(dir.join("work.db")),
    )
}

async fn preset(f: &Front, name: &str) {
    f.settings
        .set_overrides(
            None,
            vec![crate::settings::overrides::Override {
                name: "drgnx-agents-matrix".into(),
                value: json!({"preset": name}),
                source: "test".into(),
            }],
        )
        .await
        .unwrap();
}

fn worker() -> Who {
    Who {
        role: Some(Role::Worker),
        ..Who::default()
    }
}

/// Session SID's web proxy in its own dir under DIR, upstreams sent to REDIRECT when given.
async fn web(f: &Front, dir: &Path, sid: &str, redirect: Option<SocketAddr>) -> WebProxy {
    let sdir = dir.join(sid);
    std::fs::create_dir_all(&sdir).unwrap();
    start(
        sid,
        &sdir,
        ActionCtx::default(),
        worker(),
        Hub::of(f),
        redirect,
    )
    .await
    .unwrap()
}

/// Until the loop has handled N steps (events and re-reads) in all.
async fn steps(w: &mut WebProxy, n: u64) {
    timeout(WAIT, w.steps.wait_for(|s| *s >= n))
        .await
        .unwrap_or_else(|_| panic!("the loop never reached {n} steps"))
        .unwrap();
}

async fn ask(path: &Path, bytes: &[u8]) -> (UnixStream, u16) {
    let mut s = UnixStream::connect(path).await.unwrap();
    s.write_all(bytes).await.unwrap();
    let mut head = Vec::new();
    let mut b = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        match timeout(WAIT, s.read(&mut b)).await.expect("no answer") {
            Ok(1) => head.push(b[0]),
            _ => break,
        }
    }
    let head = String::from_utf8_lossy(&head).into_owned();
    let code = head
        .strip_prefix("HTTP/1.1 ")
        .and_then(|r| r.get(..3))
        .and_then(|c| c.parse().ok())
        .unwrap_or_else(|| panic!("not a response: {head:?}"));
    (s, code)
}

async fn connect_to(path: &Path, target: &str) -> (UnixStream, u16) {
    ask(
        path,
        format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n").as_bytes(),
    )
    .await
}

async fn echoes(s: &mut UnixStream, text: &[u8]) -> bool {
    s.write_all(text).await.unwrap();
    let mut got = vec![0u8; text.len()];
    matches!(timeout(WAIT, s.read_exact(&mut got)).await, Ok(Ok(_))) && got == text
}

/// A loopback upstream that echoes every connection.
async fn echo() -> SocketAddr {
    let l = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let a = l.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut c, _)) = l.accept().await {
            tokio::spawn(async move {
                let (mut r, mut w) = c.split();
                let _ = tokio::io::copy(&mut r, &mut w).await;
            });
        }
    });
    a
}

/// The matrix cards of ACTION: (id, state, data), oldest first.
async fn cards(f: &Front, action: &'static str) -> Vec<(i64, String, Value)> {
    f.writer
        .db
        .read(move |c| {
            let mut st = c.prepare(
                "select id, state, data from card where kind = 'matrix' \
                 and json_extract(data, '$.action') = ?1 order by id",
            )?;
            let rows = st.query_map([action], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                ))
            })?;
            let mut out = Vec::new();
            for row in rows {
                let (id, state, data) = row?;
                out.push((id, state, serde_json::from_str(&data).unwrap()));
            }
            Ok(out)
        })
        .await
        .unwrap()
}

fn user() -> Caller {
    Caller {
        class: runstav::registry::Class::User,
        sid: None,
        job: None,
        conn_id: 1,
    }
}

/// A grant as settling a browser card writes it: (session, action, target, host, expires).
type Grant = (
    &'static str,
    &'static str,
    Option<Value>,
    Option<String>,
    Option<f64>,
);

/// The user settles CARD with CHOICE through `cards/settle`, writing GRANT in the same tx (as the card's own
/// settling does).
async fn settle(f: &Front, card: i64, choice: &'static str, grant: Option<Grant>) {
    f.writer
        .write(&user(), "cards/settle", move |tx| {
            assert!(card_settle(tx, card, choice, now_secs())?);
            if let Some((sid, action, target, host, expires)) = grant {
                grants::create_matrix(
                    tx,
                    grants::Who::Session(sid.into()),
                    action,
                    target,
                    host,
                    expires,
                    card,
                )?;
            }
            Ok(())
        })
        .await
        .unwrap();
}

#[tokio::test]
async fn thirty_hosts_make_one_card() {
    let dir = tempfile::tempdir().unwrap();
    let f = front(dir.path());
    preset(&f, "balanced").await;
    let mut w = web(&f, dir.path(), "s1", None).await;
    // a page with thirty hosts, the web not granted: each refused, one card, its facts the first host:port
    for i in 1..=30 {
        let (_s, code) = connect_to(w.socket(), &format!("93.184.215.{i}:443")).await;
        assert_eq!(code, 403);
    }
    steps(&mut w, 30).await;
    let c = cards(&f, "browser.web").await;
    assert_eq!(c.len(), 1, "{c:?}");
    let (_, state, data) = &c[0];
    assert_eq!(state, "open");
    assert_eq!(data["session"], "s1");
    assert_eq!(data["facts"]["host"], "93.184.215.1:443");
    assert!(data["facts"].get("target").is_none(), "{data}");
    // plain HTTP asks the same question, still under the open card
    let (_s, code) = ask(w.socket(), b"GET http://93.184.215.40/ HTTP/1.1\r\n\r\n").await;
    assert_eq!(code, 403);
    steps(&mut w, 31).await;
    assert_eq!(cards(&f, "browser.web").await.len(), 1);
}

#[tokio::test]
async fn refuse_stops_further_cards() {
    let dir = tempfile::tempdir().unwrap();
    let f = front(dir.path());
    preset(&f, "balanced").await;
    let mut w = web(&f, dir.path(), "s1", None).await;
    let _ = connect_to(w.socket(), "93.184.215.1:443").await;
    steps(&mut w, 1).await;
    let card = cards(&f, "browser.web").await[0].0;
    settle(&f, card, "deny", None).await;
    steps(&mut w, 2).await;
    // after the refusal, later hosts are refused with no card
    let (_s, code) = connect_to(w.socket(), "93.184.215.2:443").await;
    assert_eq!(code, 403);
    steps(&mut w, 3).await;
    assert_eq!(cards(&f, "browser.web").await.len(), 1);
    // and so for the session's next web proxy (a hub restart): the refusal is read from the store
    drop(w);
    let mut again = web(&f, dir.path(), "s1", None).await;
    let _ = connect_to(again.socket(), "93.184.215.3:443").await;
    steps(&mut again, 1).await;
    assert_eq!(cards(&f, "browser.web").await.len(), 1);
    // another session still asks
    let mut other = web(&f, dir.path(), "s2", None).await;
    let _ = connect_to(other.socket(), "93.184.215.3:443").await;
    steps(&mut other, 1).await;
    let c = cards(&f, "browser.web").await;
    assert_eq!(c.len(), 2, "{c:?}");
    assert_eq!(c[1].2["session"], "s2");
}

#[cfg(feature = "test-hooks")]
#[tokio::test]
async fn web_allow_at_launch_needs_no_card() {
    let dir = tempfile::tempdir().unwrap();
    let f = front(dir.path());
    preset(&f, "autonomous").await;
    let up = echo().await;
    let mut w = web(&f, dir.path(), "s1", Some(up)).await;
    // the cell allows the web: the first request goes through (to the fixture standing for the site)
    let (mut s, code) = connect_to(w.socket(), "93.184.215.14:443").await;
    assert_eq!(code, 200);
    assert!(echoes(&mut s, b"hello").await);
    steps(&mut w, 1).await;
    assert!(cards(&f, "browser.web").await.is_empty());
    // the host it reached is an event, not a card
    let hosts: Vec<String> = f
        .writer
        .db
        .read(|c| {
            let mut st = c.prepare(
                "select json_extract(data, '$.host') from event \
                 where json_extract(data, '$.\"browser-host\"') = 1 and agent = 's1'",
            )?;
            let rows = st.query_map([], |r| r.get::<_, String>(0))?;
            Ok(rows.collect::<Result<Vec<_>, _>>()?)
        })
        .await
        .unwrap();
    assert_eq!(hosts, ["93.184.215.14"]);
    // the hard nevers stay refused with the web on
    let (_s, code) = connect_to(w.socket(), "169.254.169.254:80").await;
    assert_eq!(code, 403);
}

#[cfg(feature = "test-hooks")]
#[tokio::test]
async fn a_once_yes_opens_its_host_and_the_next_host_asks_again() {
    let dir = tempfile::tempdir().unwrap();
    let f = front(dir.path());
    preset(&f, "balanced").await;
    let up = echo().await;
    let mut w = web(&f, dir.path(), "s1", Some(up)).await;
    for host in ["93.184.215.1:443", "93.184.215.2:443"] {
        let (_s, code) = connect_to(w.socket(), host).await;
        assert_eq!(code, 403);
    }
    steps(&mut w, 2).await;
    let card = cards(&f, "browser.web").await[0].0;
    // "once" names the card's host: that one opens, until the grant ends
    let grant = (
        "s1",
        "browser.web",
        None,
        Some("93.184.215.1:443".to_string()),
        Some(now_secs() + 600.0),
    );
    settle(&f, card, "allow", Some(grant)).await;
    steps(&mut w, 3).await;
    let (mut s, code) = connect_to(w.socket(), "93.184.215.1:443").await;
    assert_eq!(code, 200);
    assert!(echoes(&mut s, b"once").await);
    // the second host, refused while the first card was open, asks again on its retry
    let (_s, code) = connect_to(w.socket(), "93.184.215.2:443").await;
    assert_eq!(code, 403);
    steps(&mut w, 5).await;
    let c = cards(&f, "browser.web").await;
    assert_eq!(c.len(), 2, "{c:?}");
    assert_eq!(c[1].2["facts"]["host"], "93.184.215.2:443");
}

#[tokio::test]
async fn private_card_then_grant_reaches_the_target() {
    let dir = tempfile::tempdir().unwrap();
    let f = front(dir.path());
    preset(&f, "autonomous").await;
    let up = echo().await;
    let port = up.port();
    let mut w = web(&f, dir.path(), "s1", None).await;
    // the host's loopback, by its one name: a card even under Autonomous (browser.private always asks)
    let target = format!("host.drgnx.internal:{port}");
    let (_s, code) = connect_to(w.socket(), &target).await;
    assert_eq!(code, 403);
    steps(&mut w, 1).await;
    let c = cards(&f, "browser.private").await;
    assert_eq!(c.len(), 1, "{c:?}");
    let (card, _, data) = &c[0];
    let facts = &data["facts"];
    assert_eq!(facts["target"], json!({"host_port": target}), "{data}");
    assert_eq!(facts["addr"], format!("127.0.0.1:{port}"));
    assert_eq!(facts["class"], "loopback");
    assert!(facts.get("host").is_none(), "{data}");
    // the user's yes for this target, in its wire form: the retry reaches it
    let grant = (
        "s1",
        "browser.private",
        Some(data["facts"]["target"].clone()),
        None,
        Some(now_secs() + 600.0),
    );
    settle(&f, *card, "allow", Some(grant)).await;
    steps(&mut w, 2).await;
    let (mut s, code) = connect_to(w.socket(), &target).await;
    assert_eq!(code, 200);
    assert!(echoes(&mut s, b"private").await);
    // the gate agrees: a card for exactly that target needs no yes
    let gate = f.core.matrix.clone();
    let id = *card;
    let again = f
        .writer
        .db
        .read(move |c| Ok(gate.recheck(c, id, now_secs())))
        .await
        .unwrap();
    assert_eq!(again, Gate::Allow);
    // a neighbour port is another target: refused, its own card
    let other = format!("host.drgnx.internal:{}", port.wrapping_add(1).max(1));
    let (_s, code) = connect_to(w.socket(), &other).await;
    assert_eq!(code, 403);
    steps(&mut w, 4).await;
    assert_eq!(cards(&f, "browser.private").await.len(), 2);
}

/// The `browser-net` events of session SID, oldest first: (web, hosts, private).
async fn net_events(f: &Front, sid: &'static str) -> Vec<(bool, Value, Value)> {
    f.writer
        .db
        .read(move |c| {
            let mut st = c.prepare(
                "select data from event where json_extract(data, '$.\"browser-net\"') = 1 \
                 and agent = ?1 order by id",
            )?;
            let rows = st.query_map([sid], |r| r.get::<_, String>(0))?;
            let mut out = Vec::new();
            for row in rows {
                let d: Value = serde_json::from_str(&row?).unwrap();
                out.push((
                    d["web"].as_bool().unwrap(),
                    d["hosts"].clone(),
                    d["private"].clone(),
                ));
            }
            Ok(out)
        })
        .await
        .unwrap()
}

#[tokio::test]
async fn a_narrowed_cell_refuses_the_next_request() {
    let dir = tempfile::tempdir().unwrap();
    let f = front(dir.path());
    preset(&f, "autonomous").await;
    let mut w = web(&f, dir.path(), "s1", None).await;
    // Autonomous allows the web: on from the start, and said
    assert_eq!(net_events(&f, "s1").await, [(true, json!([]), json!([]))]);
    // the user narrows the matrix (`config/settings`): the proxy reads it at once, with no request in between
    let p = serde_json::from_value(json!({"overrides": [
        {"name": "drgnx-agents-matrix", "source": "test", "value": {"preset": "balanced"}}]}))
    .unwrap();
    f.config_settings(p).await.unwrap();
    steps(&mut w, 1).await;
    assert_eq!(
        net_events(&f, "s1").await,
        [(true, json!([]), json!([])), (false, json!([]), json!([]))]
    );
    // so the next request is refused and asks
    let (_s, code) = connect_to(w.socket(), "93.184.215.1:443").await;
    assert_eq!(code, 403);
    steps(&mut w, 2).await;
    assert_eq!(cards(&f, "browser.web").await.len(), 1);
    // and a settings change that leaves the cells as they are changes nothing and says nothing
    let p = serde_json::from_value(json!({"overrides": [
        {"name": "drgnx-agents-matrix", "source": "test", "value": {"preset": "balanced"}}]}))
    .unwrap();
    f.config_settings(p).await.unwrap();
    steps(&mut w, 3).await;
    assert_eq!(net_events(&f, "s1").await.len(), 2);
}

#[tokio::test]
async fn one_sessions_flood_does_not_block_another() {
    let dir = tempfile::tempdir().unwrap();
    let f = front(dir.path());
    preset(&f, "balanced").await;
    let one = web(&f, dir.path(), "s1", None).await;
    let two = web(&f, dir.path(), "s2", None).await;
    // session one holds every connection place of its own proxy (clients that never send a head)
    let cap = ProxyConfig::default().max_conns;
    let mut held = Vec::new();
    for _ in 0..cap {
        held.push(UnixStream::connect(one.socket()).await.unwrap());
    }
    let (_s, code) = ask(one.socket(), b"GET / HTTP/1.1\r\n\r\n").await;
    assert_eq!(code, 403, "session one is full");
    // session two's proxy has its own places: its request is judged at once
    let (_s, code) = ask(two.socket(), b"GET / HTTP/1.1\r\n\r\n").await;
    assert_eq!(code, 400);
    drop(held);
}

#[tokio::test]
async fn the_socket_is_0600_and_goes_with_the_proxy() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let f = front(dir.path());
    let w = web(&f, dir.path(), "s1", None).await;
    let path = w.socket().to_path_buf();
    assert_eq!(path, dir.path().join("s1").join("web.sock"));
    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    drop(w);
    assert!(!path.exists());
}
