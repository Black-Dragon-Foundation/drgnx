use super::*;
use crate::dispatch::Caller;
use crate::front::Front;
use gleipnir::net::host::parse_target;
use gleipnir::net::policy::Class;
use gleipnir::net::proxy;
use norn::matrix::Role;
use norn::store::CoordDb;
use norn::write::cards::card_settle;
use serde_json::Value;
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::time::timeout;

/// A failure guard only: each wait ends as soon as what it waits for happened.
const WAIT: Duration = Duration::from_secs(10);

fn t(s: &str) -> Target {
    parse_target(s).unwrap()
}

fn port(p: u16) -> Target {
    t(&format!("host.drgnx.internal:{p}"))
}

fn grant(target: Target) -> PrivateGrant {
    PrivateGrant {
        target: PrivateTarget::HostPort(target),
        expires: None,
    }
}

/// Every order of EVS, each its own sequence.
fn orders(evs: &[Ev]) -> Vec<Vec<Ev>> {
    if evs.len() <= 1 {
        return vec![evs.to_vec()];
    }
    let mut out = Vec::new();
    for i in 0..evs.len() {
        let mut rest = evs.to_vec();
        let first = rest.remove(i);
        for mut tail in orders(&rest) {
            tail.insert(0, first.clone());
            out.push(tail);
        }
    }
    out
}

#[test]
fn every_order_one_card_per_port_and_none_after_the_job() {
    let evs = [
        Ev::Private { target: port(8080) },
        Ev::Private { target: port(8080) },
        Ev::Private { target: port(9090) },
        Ev::Settled {
            target: port(8080),
            allow: false,
        },
        Ev::GrantsRead(vec![grant(port(9090))]),
        Ev::JobEnded,
    ];
    let all = orders(&evs);
    assert_eq!(all.len(), 720);
    for order in all {
        let mut core = Core::new(true);
        let mut asked: Vec<Target> = Vec::new();
        let mut ended = false;
        for ev in order.clone() {
            let before_end = !ended;
            ended |= ev == Ev::JobEnded;
            let effects = core.step(ev.clone());
            if !before_end {
                assert!(effects.is_empty(), "{order:?}: {effects:?} after the job");
            }
            for e in effects {
                if let Effect::AskCard { target } = e {
                    assert!(
                        !asked.contains(&target),
                        "{order:?}: two cards for {target}"
                    );
                    asked.push(target);
                }
            }
        }
        // every port the job asked for before it ended has its card
        let end = order.iter().position(|e| *e == Ev::JobEnded).unwrap();
        for p in [8080, 9090] {
            let before = order[..end]
                .iter()
                .any(|e| *e == Ev::Private { target: port(p) });
            assert_eq!(asked.contains(&port(p)), before, "{order:?}: port {p}");
        }
    }
}

#[test]
fn every_order_a_revoke_refuses_the_next_request_only() {
    let lan = PrivateGrant {
        target: PrivateTarget::HostPort(t("192.168.1.5:80")),
        expires: None,
    };
    let prefix = [
        Ev::Private { target: port(8080) },
        Ev::Settled {
            target: port(8080),
            allow: true,
        },
        Ev::Private { target: port(9090) },
        Ev::GrantsRead(vec![grant(port(8080)), grant(port(9090)), lan.clone()]),
    ];
    for order in orders(&prefix) {
        let mut core = Core::new(true);
        for ev in order.clone() {
            core.step(ev);
        }
        // the port's grant is gone: the proxy's grants without it, nothing else
        let effects = core.step(Ev::GrantsRead(vec![grant(port(9090)), lan.clone()]));
        assert_eq!(
            effects,
            [Effect::SetGrants(vec![grant(port(9090))])],
            "{order:?}"
        );
        // its next request is refused, and asks nothing
        assert!(core.step(Ev::Private { target: port(8080) }).is_empty());
        // the same grants again: nothing to set
        assert!(
            core.step(Ev::GrantsRead(vec![grant(port(9090))]))
                .is_empty()
        );
    }
}

#[test]
fn a_job_without_a_session_asks_nothing() {
    let mut core = Core::new(false);
    assert!(core.step(Ev::Private { target: port(8080) }).is_empty());
}

fn front(dir: &Path) -> Front {
    Front::new(
        runstav::proof::Cap::generate().unwrap(),
        dir.join("hub-x.sock"),
        crate::store::WorkDb::spawn(dir.join("work.db")).unwrap(),
        CoordDb::spawn(dir.join("work.db")),
    )
}

fn hub(f: &Front, held: bool) -> Hub {
    Hub {
        settings: f.settings.clone(),
        writer: f.writer.clone(),
        gate: f.core.matrix.clone(),
        session: Arc::new(move |_| {
            held.then(|| {
                (
                    Who {
                        role: Some(Role::Worker),
                        ..Who::default()
                    },
                    ActionCtx::default(),
                )
            })
        }),
    }
}

/// The matrix `browser.private` cards: (id, state, data), oldest first.
async fn cards(f: &Front) -> Vec<(i64, String, Value)> {
    f.writer
        .db
        .read(|c| {
            let mut st = c.prepare(
                "select id, state, data from card where kind = 'matrix' \
                 and json_extract(data, '$.action') = 'browser.private' order by id",
            )?;
            let rows = st.query_map([], |r| {
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

/// Until the loop has handled N steps in all.
async fn steps(s: &mut watch::Receiver<u64>, n: u64) {
    timeout(WAIT, s.wait_for(|v| *v >= n))
        .await
        .unwrap_or_else(|_| panic!("the loop never reached {n} steps"))
        .unwrap();
}

fn private(target: &str) -> ProxyEvent {
    ProxyEvent::Private {
        tag: 1,
        asked: t(target),
        addr: "127.0.0.1:8080".parse().unwrap(),
        class: Class::Loopback,
    }
}

/// A job's loop for session s1 on a fresh web state; answers the event sender and the step count.
async fn job_loop(f: &Front, held: bool) -> (mpsc::Sender<ProxyEvent>, watch::Receiver<u64>) {
    let (tx, rx) = mpsc::channel(16);
    let web = crate::exec::net::job_web(Some(&f.browser_nevers));
    let (_task, steps) = start(hub(f, held), "j1", "s1", web, rx).await;
    (tx, steps)
}

#[tokio::test]
async fn the_card_says_the_grant_is_the_sessions() {
    let dir = tempfile::tempdir().unwrap();
    let f = front(dir.path());
    let (tx, mut s) = job_loop(&f, true).await;
    tx.send(private("host.drgnx.internal:8080")).await.unwrap();
    steps(&mut s, 1).await;
    let c = cards(&f).await;
    assert_eq!(c.len(), 1, "{c:?}");
    let d = &c[0].2;
    assert_eq!(c[0].1, "open");
    assert_eq!(d["session"], "s1");
    let title = f
        .writer
        .db
        .read({
            let id = c[0].0;
            move |c| {
                Ok(
                    c.query_row("select title from card where id = ?1", [id], |r| {
                        r.get::<_, String>(0)
                    })?,
                )
            }
        })
        .await
        .unwrap();
    assert_eq!(
        title,
        "Job j1 wants your port 8080 (`host.drgnx.internal:8080`)"
    );
    let body = d["body"].as_str().unwrap();
    assert!(
        body.starts_with(
            "Allowing it opens the port for this session: its browser and its other jobs too."
        ),
        "{body}"
    );
    assert!(
        body.ends_with("Connections already open stay until they end; end the job to cut them."),
        "{body}"
    );
}

#[tokio::test]
async fn the_card_offers_only_the_reserved_host_port() {
    let dir = tempfile::tempdir().unwrap();
    let f = front(dir.path());
    let (tx, mut s) = job_loop(&f, true).await;
    // a LAN literal is the allow-list's: no card
    tx.send(private("192.168.1.5:80")).await.unwrap();
    tx.send(private("host.drgnx.internal:8080")).await.unwrap();
    steps(&mut s, 2).await;
    let c = cards(&f).await;
    assert_eq!(c.len(), 1, "{c:?}");
    let d = &c[0].2;
    assert_eq!(
        d["facts"]["target"],
        json!({"host_port": "host.drgnx.internal:8080"})
    );
    assert_eq!(d["facts"]["job"], "j1");
    let ids: Vec<&str> = d["choices"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["id"].as_str().unwrap())
        .collect();
    // the browser's scopes, never a CIDR or "all private"
    assert_eq!(ids, ["once", "session", "refuse"]);
}

#[tokio::test]
async fn a_session_that_cannot_be_read_asks_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let f = front(dir.path());
    let (tx, _s) = job_loop(&f, false).await;
    tx.send(private("host.drgnx.internal:8080")).await.unwrap();
    // the drain took it (a full channel would not take 16 more)
    for _ in 0..32 {
        timeout(WAIT, tx.send(private("host.drgnx.internal:8081")))
            .await
            .unwrap()
            .unwrap();
    }
    assert!(cards(&f).await.is_empty());
}

fn user() -> Caller {
    Caller {
        class: runstav::registry::Class::User,
        sid: None,
        job: None,
        conn_id: 1,
    }
}

/// A loopback upstream that echoes every connection.
async fn echo() -> std::net::SocketAddr {
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

async fn connect_to(path: &Path, target: &str) -> (UnixStream, u16) {
    let mut s = UnixStream::connect(path).await.unwrap();
    s.write_all(format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n").as_bytes())
        .await
        .unwrap();
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

#[tokio::test]
async fn a_settled_card_opens_the_port_for_the_next_request() {
    let dir = tempfile::tempdir().unwrap();
    let f = front(dir.path());
    let up = echo().await;
    let target = format!("host.drgnx.internal:{}", up.port());
    // the job's proxy under the job policy, on a socket in place of the relay's streams
    let web = crate::exec::net::job_web(Some(&f.browser_nevers));
    let (ptx, prx) = mpsc::channel(16);
    let handle = proxy::start(
        crate::exec::net::proxy_config(vec![], &[], web.clone()),
        Arc::new(proxy::SystemResolver),
        ptx,
    );
    let sock = dir.path().join("job.sock");
    handle.listen(
        proxy::Listener::Unix(crate::sessions::bind_socket(&sock).unwrap()),
        1,
    );
    let (_task, mut s) = start(hub(&f, true), "j1", "s1", web, prx).await;
    let (_c, code) = connect_to(&sock, &target).await;
    assert_eq!(code, 403);
    steps(&mut s, 1).await;
    let c = cards(&f).await;
    assert_eq!(c.len(), 1, "{c:?}");
    let (card, _, d) = c[0].clone();
    let wire = d["facts"]["target"].clone();
    // the user's yes for the session, as settling the card writes it
    f.writer
        .write(&user(), "cards/settle", move |tx| {
            assert!(card_settle(tx, card, "session", crate::clock::wall_secs())?);
            grants::create_matrix(
                tx,
                grants::Who::Session("s1".into()),
                "browser.private",
                Some(wire),
                None,
                None,
                card,
            )?;
            Ok(())
        })
        .await
        .unwrap();
    // the barrier: the loop has read the settle
    steps(&mut s, 2).await;
    let (mut conn, code) = connect_to(&sock, &target).await;
    assert_eq!(code, 200);
    conn.write_all(b"port").await.unwrap();
    let mut got = [0u8; 4];
    timeout(WAIT, conn.read_exact(&mut got))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&got, b"port");
    handle.shutdown();
}
