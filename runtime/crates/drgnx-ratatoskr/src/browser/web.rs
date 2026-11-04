//! A browser session's web proxy (docs/develop/hub.md, "The web proxy"): its own `gleipnir` proxy under the web policy
//! on `<session dir>/web.sock`, which the sandbox's web relay reaches, and the loop that turns what it refuses into
//! cards and what the user grants into its state.
//!
//! - **At the start** the state is read: `browser.web` is on when its cell allows it or a grant with no host covers the
//!   session; a once grant names one `host:port`, which alone is open until it expires; the `browser.private` grants
//!   go to the proxy, which matches the targets; the deny list is `agents-browser-deny-hosts`.  A Never cell ignores
//!   every grant.
//! - **`WebOff`** (a public target while the web is off): one card per session at a time, and none once the user
//!   refused one.  Its facts are the first `host:port`; the matrix gate's Allow (the cell, or a grant) turns the web
//!   on without a card.
//! - **`Private`** (a private target no grant opens): one card per target, with the target as a grant names it
//!   (`{"host_port": "H:P"}`, what was asked), the address it led to and its class.  None for a refused target.
//! - **Any change to an answer** (`coord::Signals::answers_changed`: a user's write such as a settled card or a grant,
//!   the settings in effect, the away flag), **a grant's expiry** and, with time presets, **each minute's turn**: the
//!   state is read again at once, so a narrowed cell refuses the next request.  When the state changed, a store
//!   event `browser-net` `{session, web, hosts, private}` says what the browser may now reach, and the proxy asks its
//!   questions anew (so does a settled card).
//! - **`Reached`**: a store event `browser-host` `{session, host}`, once per host.  **`Refused`**: the log only.
//!
//! Each session has its own proxy, so its own connection cap, and its own loop: one session's flood never waits on
//! another's.

use crate::browser::nevers::Nevers;
use crate::coord::Writer;
use crate::front::Front;
use crate::matrix_gate::{ActionCtx, Gate, MatrixGate};
use crate::settings::Settings;
use gleipnir::net::host::{Target, parse_target};
use gleipnir::net::policy::{PrivateGrant, PrivateTarget};
use gleipnir::net::proxy::{self, Policy, ProxyConfig, ProxyEvent, ProxyHandle, WebState};
use norn::grants;
use norn::matrix::{Action, Verdict, Who};
use norn::store::CoordError;
use norn::write::cards::matrix_card_get;
use runstav::methods::matrix::Facts;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::net::SocketAddr;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinSet;

/// The tag of a web proxy's one listener.
const TAG: u64 = 1;

/// One session's web proxy and its loop.  Dropping it closes the listener and every connection, ends the loop, and
/// removes the socket (when it is still this one's).
pub struct WebProxy {
    handle: Arc<ProxyHandle>,
    socket: PathBuf,
    /// The socket's (dev, inode), so a drop never removes a later session's socket on the same path.
    bound: (u64, u64),
    tasks: JoinSet<()>,
    /// What the loop has handled: events and re-reads, counted (the tests wait on it).
    #[cfg_attr(not(test), allow(dead_code))]
    steps: watch::Receiver<u64>,
}

impl WebProxy {
    /// The socket the session's web relay reaches.
    pub fn socket(&self) -> &Path {
        &self.socket
    }
}

impl Drop for WebProxy {
    fn drop(&mut self) {
        self.handle.shutdown();
        self.tasks.abort_all();
        if std::fs::symlink_metadata(&self.socket).is_ok_and(|m| (m.dev(), m.ino()) == self.bound) {
            let _ = std::fs::remove_file(&self.socket);
        }
    }
}

/// What the loop needs of the hub.
#[derive(Clone)]
struct Hub {
    settings: Arc<Settings>,
    writer: Writer,
    gate: MatrixGate,
    nevers: Nevers,
}

impl Hub {
    fn of(front: &Front) -> Hub {
        Hub {
            settings: front.settings.clone(),
            writer: front.writer.clone(),
            gate: front.core.matrix.clone(),
            nevers: front.browser_nevers.clone(),
        }
    }
}

/// Session SID's web proxy on `DIR/web.sock` (a stale file removed first, then 0600; DIR is the session's dir), for
/// WHO acting in CTX (the session's plan and project; its `session` is set to SID).  The state is read before this
/// returns, so a session whose `browser.web` cell allows it reaches the web from its first request.  Call it inside a
/// tokio runtime.
///
/// A test-hooks build sends every upstream but the host's loopback to `DRGNX_TEST_WEB_REDIRECT` (an `ADDR:PORT`) when
/// it is set, and resolves the names `DRGNX_TEST_PROXY_PINS` lists to their addresses, so a row reaches a local
/// fixture in place of the web or a LAN host.
pub async fn start_web(
    sid: &str,
    dir: &Path,
    ctx: ActionCtx,
    who: Who,
    front: &Front,
) -> io::Result<WebProxy> {
    #[cfg(feature = "test-hooks")]
    let redirect = std::env::var("DRGNX_TEST_WEB_REDIRECT")
        .ok()
        .and_then(|v| v.parse().ok());
    #[cfg(not(feature = "test-hooks"))]
    let redirect = None;
    start(sid, dir, ctx, who, Hub::of(front), redirect).await
}

async fn start(
    sid: &str,
    dir: &Path,
    mut ctx: ActionCtx,
    who: Who,
    hub: Hub,
    redirect: Option<SocketAddr>,
) -> io::Result<WebProxy> {
    ctx.session = Some(sid.to_string());
    let state = Arc::new(WebState::new(
        hub.nevers.host_addrs.shared(),
        hub.nevers.never.shared(),
    ));
    let cfg = ProxyConfig {
        policy: Policy::Web(state.clone()),
        ..ProxyConfig::default()
    };
    let (tx, rx) = mpsc::channel(64);
    let handle = Arc::new(spawn_proxy(cfg, tx, redirect));
    let socket = dir.join(runstav::paths::SESSION_WEB_SOCKET);
    let listener = crate::sessions::bind_socket(&socket)?;
    let m = std::fs::symlink_metadata(&socket)?;
    let (step_tx, steps) = watch::channel(0);
    // a new receiver has seen the count as it is: a later change wakes the loop
    let answers = hub.writer.signals.answers.subscribe();
    let mut asker = Asker {
        sid: sid.to_string(),
        ctx,
        who,
        hub,
        state,
        handle: handle.clone(),
        web_on: false,
        web_hosts: Vec::new(),
        private: Vec::new(),
        web_card: None,
        private_cards: BTreeMap::new(),
        web_refused: false,
        private_refused: BTreeSet::new(),
        next_expiry: None,
        steps: step_tx,
    };
    asker.reload().await;
    // listening only once the state is read: no request is judged on an empty state
    handle.listen(proxy::Listener::Unix(listener), TAG);
    let mut tasks = JoinSet::new();
    tasks.spawn(run(asker, rx, answers));
    Ok(WebProxy {
        handle,
        socket,
        bound: (m.dev(), m.ino()),
        tasks,
        steps,
    })
}

/// A test-hooks resolver: the names `DRGNX_TEST_PROXY_PINS` lists (`crate::agents::net::pins`) answer their address,
/// any other name the system's.
#[cfg(feature = "test-hooks")]
struct Pinned(Vec<(String, std::net::IpAddr)>);

#[cfg(feature = "test-hooks")]
impl proxy::Resolver for Pinned {
    fn resolve(
        &self,
        host: &str,
        port: u16,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<Vec<SocketAddr>>> + Send>>
    {
        match self.0.iter().find(|(n, _)| n.eq_ignore_ascii_case(host)) {
            Some((_, ip)) => {
                let a = SocketAddr::new(*ip, port);
                Box::pin(async move { Ok(vec![a]) })
            }
            None => proxy::Resolver::resolve(&proxy::SystemResolver, host, port),
        }
    }
}

#[cfg(feature = "test-hooks")]
fn spawn_proxy(
    cfg: ProxyConfig,
    tx: mpsc::Sender<ProxyEvent>,
    redirect: Option<SocketAddr>,
) -> ProxyHandle {
    let resolver = Arc::new(Pinned(crate::agents::net::pins()));
    match redirect {
        Some(to) => {
            // the host's loopback (`host.drgnx.internal`) is reached as it is; any other upstream goes to TO
            let connect: proxy::Connect = Arc::new(move |a: SocketAddr| -> proxy::Connecting {
                let a = if a.ip().is_loopback() { a } else { to };
                Box::pin(tokio::net::TcpStream::connect(a))
            });
            proxy::start_for_tests(cfg, resolver, tx, connect)
        }
        None => proxy::start(cfg, resolver, tx),
    }
}

#[cfg(not(feature = "test-hooks"))]
fn spawn_proxy(
    cfg: ProxyConfig,
    tx: mpsc::Sender<ProxyEvent>,
    _redirect: Option<SocketAddr>,
) -> ProxyHandle {
    proxy::start(cfg, Arc::new(proxy::SystemResolver), tx)
}

/// The loop's state: what it asked and what the user answered.
struct Asker {
    sid: String,
    ctx: ActionCtx,
    who: Who,
    hub: Hub,
    state: Arc<WebState>,
    handle: Arc<ProxyHandle>,
    /// Whether `browser.web` is on, as last set.
    web_on: bool,
    /// The once-granted `host:port`s, as last set, with their expiry.
    web_hosts: Vec<(Target, Option<f64>)>,
    /// The private grants, as last set.
    private: Vec<PrivateGrant>,
    /// The open `browser.web` card: at most one per session.
    web_card: Option<i64>,
    /// The open `browser.private` cards, each with its target's JSON text.
    private_cards: BTreeMap<i64, String>,
    /// The user refused a `browser.web` card of this session: no more cards.
    web_refused: bool,
    /// The private targets (JSON text) whose card the user refused.
    private_refused: BTreeSet<String>,
    /// The earliest expiry of a grant in force: the state is read again then.
    next_expiry: Option<f64>,
    steps: watch::Sender<u64>,
}

/// What [`Asker::reload`] reads in one go.
struct Read {
    cell_web: Verdict,
    cell_private: Verdict,
    web: Vec<grants::Grant>,
    private: Vec<grants::Grant>,
    web_refused: bool,
    private_refused: BTreeSet<String>,
    /// The cards that were open and are not any more.
    settled: Vec<i64>,
}

async fn run(mut a: Asker, mut rx: mpsc::Receiver<ProxyEvent>, mut answers: watch::Receiver<u64>) {
    loop {
        // a grant's expiry, and with time presets the minute's turn, when the preset in force may change
        let now = now_secs();
        let minute = a
            .hub
            .gate
            .has_time_presets()
            .then(|| (now / 60.0).floor() * 60.0 + 60.0);
        let wake = [a.next_expiry, minute]
            .into_iter()
            .flatten()
            .reduce(f64::min)
            .map(|e| Duration::from_secs_f64((e - now).clamp(0.0, 86_400.0) + 0.05));
        let expired = async {
            match wake {
                Some(d) => tokio::time::sleep(d).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            ev = rx.recv() => match ev {
                Some(ev) => a.on_event(ev).await,
                None => return,
            },
            changed = answers.changed() => {
                if changed.is_err() {
                    return;
                }
                a.on_change().await;
            }
            () = expired => a.on_change().await,
        }
        a.steps.send_modify(|n| *n += 1);
    }
}

impl Asker {
    async fn on_event(&mut self, ev: ProxyEvent) {
        match ev {
            ProxyEvent::WebOff { target, .. } => self.web_off(target).await,
            ProxyEvent::Private {
                asked, addr, class, ..
            } => {
                let target =
                    serde_json::to_value(PrivateTarget::HostPort(asked)).unwrap_or_default();
                let class = serde_json::to_value(class).unwrap_or_default();
                self.private(target, addr, class).await;
            }
            ProxyEvent::Reached { host, .. } => {
                host_event(&self.hub.writer, &self.sid, host).await;
            }
            ProxyEvent::Refused { target, why, .. } => {
                tracing::info!(sid = %self.sid, request = %target, ?why, "the web proxy refused a request");
            }
            ProxyEvent::Denied { target, .. } => {
                tracing::info!(sid = %self.sid, host = %target, "the web proxy denied a host");
            }
        }
    }

    /// A public target while the web is off: the session's one card, unless it has one open, the user refused one,
    /// or the web opened meanwhile.
    async fn web_off(&mut self, target: Target) {
        let now = now_secs();
        let open = self.web_on
            || self
                .web_hosts
                .iter()
                .any(|(t, e)| *t == target && e.is_none_or(|e| now < e));
        if open || self.web_refused || self.web_card.is_some() {
            return;
        }
        let facts = facts(json!({"host": target.to_string()}));
        match self.decide(Action::BrowserWeb, facts).await {
            Gate::Allow => {
                self.reload().await;
            }
            Gate::Ask(id) if id > 0 => self.web_card = Some(id),
            Gate::Ask(_) => {
                tracing::warn!(sid = %self.sid, "no browser.web card: the store did not take it");
            }
            Gate::Never(why) => {
                tracing::info!(sid = %self.sid, host = %target, "browser.web: {why}");
            }
        }
    }

    /// A private target no grant opens: its card, unless one is open for it or the user refused it.
    async fn private(&mut self, target: Value, addr: SocketAddr, class: Value) {
        let key = target.to_string();
        if self.private_refused.contains(&key) || self.private_cards.values().any(|k| *k == key) {
            return;
        }
        let facts = facts(json!({"target": target, "addr": addr.to_string(), "class": class}));
        match self.decide(Action::BrowserPrivate, facts).await {
            Gate::Allow => {
                self.reload().await;
            }
            Gate::Ask(id) if id > 0 => {
                self.private_cards.insert(id, key);
            }
            Gate::Ask(_) => {
                tracing::warn!(sid = %self.sid, "no browser.private card: the store did not take it");
            }
            Gate::Never(why) => {
                tracing::info!(sid = %self.sid, target = %key, "browser.private: {why}");
            }
        }
    }

    async fn decide(&self, a: Action, facts: Facts) -> Gate {
        let ctx = ActionCtx {
            facts,
            ..self.ctx.clone()
        };
        self.hub
            .gate
            .decide(
                &self.hub.settings,
                &self.hub.writer,
                self.who.clone(),
                a,
                ctx,
            )
            .await
    }

    /// A card may have settled, a grant, a cell or a setting changed, a grant ended: the state again, and when it
    /// changed or a card settled, the proxy's questions asked anew.
    async fn on_change(&mut self) {
        if self.reload().await {
            self.handle.forget_questions(TAG);
        }
    }

    /// Reads the cells, the grants, the refusals and the open cards, and sets the proxy's state from them: whether
    /// the state changed (then a `browser-net` event says so) or a card it asked settled.  A store that cannot be
    /// read keeps the state as it is.
    async fn reload(&mut self) -> bool {
        self.hub.gate.refresh_from(&self.hub.settings);
        let (g, who, ctx, now) = (
            self.hub.gate.clone(),
            self.who.clone(),
            self.ctx.clone(),
            now_secs(),
        );
        let open: Vec<i64> = self
            .web_card
            .into_iter()
            .chain(self.private_cards.keys().copied())
            .collect();
        let read = self
            .hub
            .writer
            .db
            .read(move |c| {
                let (sid, plan) = (ctx.session.as_deref(), ctx.plan.as_deref());
                let cell = |a| g.dry(c, &who, a, &ctx, now).verdict;
                let (web_refused, private_refused) = refusals(c, sid.unwrap_or_default())?;
                let mut settled = Vec::new();
                for id in open {
                    if !matches!(matrix_card_get(c, id)?, Some(card) if card.state == "open") {
                        settled.push(id);
                    }
                }
                Ok(Read {
                    cell_web: cell(Action::BrowserWeb),
                    cell_private: cell(Action::BrowserPrivate),
                    web: grants::matrix_grants_for(c, Action::BrowserWeb.id(), sid, plan, now)?,
                    private: grants::matrix_grants_for(
                        c,
                        Action::BrowserPrivate.id(),
                        sid,
                        plan,
                        now,
                    )?,
                    web_refused,
                    private_refused,
                    settled,
                })
            })
            .await;
        let r = match read {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!(sid = %self.sid, "the web proxy's grants were not read: {e}");
                return false;
            }
        };
        for id in &r.settled {
            if self.web_card == Some(*id) {
                self.web_card = None;
            }
            self.private_cards.remove(id);
        }
        self.web_refused = r.web_refused;
        self.private_refused = r.private_refused;
        let (web_on, web_hosts) = web_state(r.cell_web, &r.web);
        let private = private_state(r.cell_private, &r.private);
        self.next_expiry = r
            .web
            .iter()
            .chain(&r.private)
            .filter_map(|g| g.expires)
            .reduce(f64::min);
        self.state.set_web(web_on);
        self.state.set_web_hosts(web_hosts.clone());
        self.state.set_grants(private.clone());
        let deny = self
            .hub
            .settings
            .current()
            .loaded
            .values
            .agents_browser_deny_hosts
            .clone();
        self.state.set_deny_hosts(deny);
        let changed =
            (web_on, &web_hosts, &private) != (self.web_on, &self.web_hosts, &self.private);
        self.web_on = web_on;
        self.web_hosts = web_hosts;
        self.private = private;
        if changed {
            net_event(
                &self.hub.writer,
                &self.sid,
                self.web_on,
                &self.web_hosts,
                &self.private,
            )
            .await;
        }
        changed || !r.settled.is_empty()
    }
}

/// Whether the web is on under the cell CELL and the grants WEB, and the `host:port`s once grants open.  A Never cell
/// ignores every grant; an Allow cell or a grant with no host opens the web; a grant with a host opens that one.
fn web_state(cell: Verdict, web: &[grants::Grant]) -> (bool, Vec<(Target, Option<f64>)>) {
    if cell == Verdict::Never {
        return (false, Vec::new());
    }
    let mut on = cell == Verdict::Allow;
    let mut hosts = Vec::new();
    for g in web {
        let grants::What::Matrix { host, .. } = &g.what else {
            continue;
        };
        match host.as_deref().map(parse_target) {
            None => on = true,
            Some(Ok(t)) => hosts.push((t, g.expires)),
            Some(Err(_)) => tracing::warn!(grant = %g.id, "a browser.web grant names no host:port"),
        }
    }
    (on, hosts)
}

/// The proxy's private grants under the cell CELL (none when it is Never): each grant's target in its wire form.
fn private_state(cell: Verdict, private: &[grants::Grant]) -> Vec<PrivateGrant> {
    if cell == Verdict::Never {
        return Vec::new();
    }
    private
        .iter()
        .filter_map(|g| {
            let grants::What::Matrix {
                target: Some(t), ..
            } = &g.what
            else {
                return None;
            };
            match serde_json::from_value::<PrivateTarget>(t.clone()) {
                Ok(target) => Some(PrivateGrant {
                    target,
                    expires: g.expires,
                }),
                Err(e) => {
                    tracing::warn!(grant = %g.id, "a browser.private grant's target is not one: {e}");
                    None
                }
            }
        })
        .collect()
}

/// Whether the user refused a `browser.web` card of session SID, and the private targets (JSON text) whose cards
/// they refused: a settled matrix card with the choice `refuse` or `deny`, or one marked `refused`.
fn refusals(c: &urdr::Connection, sid: &str) -> Result<(bool, BTreeSet<String>), CoordError> {
    let mut st = c.prepare(
        "select json_extract(data, '$.action'), json_extract(data, '$.facts.target') from card \
         where kind = 'matrix' and state = 'settled' and json_extract(data, '$.session') = ?1 \
         and (choice in ('refuse', 'deny') or json_extract(data, '$.refused') = 1)",
    )?;
    let rows = st.query_map([sid], |r| {
        Ok((
            r.get::<_, Option<String>>(0)?,
            r.get::<_, Option<String>>(1)?,
        ))
    })?;
    let (mut web, mut private) = (false, BTreeSet::new());
    for row in rows {
        match row? {
            (Some(a), _) if a == Action::BrowserWeb.id() => web = true,
            (Some(a), Some(t)) if a == Action::BrowserPrivate.id() => {
                if let Ok(v) = serde_json::from_str::<Value>(&t) {
                    private.insert(v.to_string());
                }
            }
            _ => {}
        }
    }
    Ok((web, private))
}

/// The hub's facts V (never an agent's words) as the card's; facts that do not fit are none.
fn facts(v: Value) -> Facts {
    serde_json::from_value(v).unwrap_or_default()
}

/// The `browser-host` event: kind `status`, the session as its agent, data `{"browser-host": true, session, host}`.
async fn host_event(w: &Writer, sid: &str, host: String) {
    let summary = format!("the session's browser reached {host}");
    let data = json!({"browser-host": true, "session": sid, "host": host});
    status_event(w, sid, "agents/browser-host", summary, data).await;
}

/// The `browser-net` event, when what session SID's browser may reach changed: kind `status`, the session as its
/// agent, data `{"browser-net": true, session, web, hosts: ["H:P", …], private: [TARGET, …]}` (the targets in their
/// wire form).
async fn net_event(
    w: &Writer,
    sid: &str,
    web: bool,
    hosts: &[(Target, Option<f64>)],
    private: &[PrivateGrant],
) {
    let hosts: Vec<String> = hosts.iter().map(|(t, _)| t.to_string()).collect();
    let private: Vec<&PrivateTarget> = private.iter().map(|g| &g.target).collect();
    let summary = format!(
        "the session's browser: the web {}, {} host(s) once, {} private target(s)",
        if web { "on" } else { "off" },
        hosts.len(),
        private.len()
    );
    let data = json!({"browser-net": true, "session": sid, "web": web, "hosts": hosts, "private": private});
    status_event(w, sid, "agents/browser-net", summary, data).await;
}

async fn status_event(w: &Writer, sid: &str, method: &'static str, summary: String, data: Value) {
    use norn::write::event::{Event, EventKind, event};
    let sid = sid.to_string();
    let caller = crate::runner::service();
    let r = w
        .write(&caller, method, move |tx| {
            event(
                tx,
                Event {
                    at: now_secs(),
                    agent: Some(sid),
                    job: None,
                    task: None,
                    kind: EventKind::Status,
                    summary,
                    data: Some(data),
                    turn: false,
                },
            )
            .map(|_| ())
        })
        .await;
    if let Err(e) = r {
        tracing::debug!("the {method} event was not written: {e:?}");
    }
}

fn now_secs() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

#[cfg(test)]
mod tests;
