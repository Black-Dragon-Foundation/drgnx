//! A session's network on the hub's side (`docs/develop/hub.md`, "Sessions and their sockets"): every session whose
//! network cell is provider-only or provider-and-packages gets its own provider proxy, Gleipnir's CONNECT-only
//! allowlist proxy (`gleipnir::net::proxy`), on `<session dir>/proxy.sock`, which the sandbox's relay port reaches.
//! The allowlist is [`provider_hosts`]: the hosts of the profile's providers, its CLI's own hosts ([`CLI_HOSTS`]) and
//! the `agents-net-hosts` tier of its cell.  A host the proxy denies becomes a store event (`proxy-denied`, once per
//! host per session), never a card.  The proxy is bound before the agent spawns and goes with the session
//! ([`SessionNet`]'s drop), a failed start included.

use crate::agents::launch::NetCell;
use crate::coord::Writer;
use crate::settings::AgentProfile;
use crate::settings::NetHosts;
use crate::settings::profiles::Provider;
use gleipnir::net::host::{Target, parse_target};
use gleipnir::net::proxy::{self, ProxyEvent, ProxyHandle};
use runstav::methods::gateway::ProviderConfig;
use std::io;
use std::net::IpAddr;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use tokio::sync::mpsc;
use tokio::task::JoinSet;

/// The hosts each subscription CLI reaches on its own, whatever its profile says:
/// - claude: the API, and `platform.claude.com`, where the OAuth token of a claude.ai or Console login is refreshed
///   (Claude Code's "Network access requirements", code.claude.com/docs/en/network-config);
/// - codex: the API, `chatgpt.com` (a ChatGPT login's backend), and `auth.openai.com`, where that login's token is
///   refreshed (`REFRESH_TOKEN_URL` in codex-rs/login/src/auth/manager.rs);
/// - gemini: the API (an API key), `oauth2.googleapis.com` (the token refresh) and `cloudcode-pa.googleapis.com`, the
///   Code Assist API a "Login with Google" session talks to (`CODE_ASSIST_ENDPOINT` in
///   packages/core/src/code_assist/server.ts).
///
/// Optional traffic (telemetry, error reports, updates, the login pages a browser opens) is left out: it is denied and
/// shows as a `proxy-denied` event.
pub const CLI_HOSTS: &[(Provider, &[&str])] = &[
    (
        Provider::Claude,
        &["api.anthropic.com:443", "platform.claude.com:443"],
    ),
    (
        Provider::Codex,
        &[
            "api.openai.com:443",
            "chatgpt.com:443",
            "auth.openai.com:443",
        ],
    ),
    (
        Provider::Gemini,
        &[
            "generativelanguage.googleapis.com:443",
            "oauth2.googleapis.com:443",
            "cloudcode-pa.googleapis.com:443",
        ],
    ),
];

/// What session P's provider proxy allows under the network cell NET: the base `host:port` of each of PROVIDERS (the
/// `config/providers` entries the profile's gateway chain names; none for a profile without `:ai`), the hosts of the
/// CLI it starts ([`CLI_HOSTS`]), and the `agents-net-hosts` tier of NET in HOSTS (`sandbox::allowed_hosts`).  Each
/// once, in that order; an entry that is not an exact `host:port` is left out.  `NetCell::Open` gets none: such a
/// session shares the host's network and has no proxy.
pub fn provider_hosts(
    p: &AgentProfile,
    providers: &[ProviderConfig],
    hosts: &NetHosts,
    net: NetCell,
) -> Vec<Target> {
    if net == NetCell::Open {
        return Vec::new();
    }
    let mut out: Vec<Target> = Vec::new();
    let mut add = |t: Option<Target>| {
        if let Some(t) = t
            && !out.contains(&t)
        {
            out.push(t);
        }
    };
    for c in providers {
        add(base_target(c.base.as_str()));
    }
    let cli = p
        .provider()
        .and_then(|k| CLI_HOSTS.iter().find(|(c, _)| *c == k));
    for h in cli.map(|(_, h)| *h).unwrap_or_default() {
        add(parse_target(h).ok());
    }
    for h in crate::sandbox::allowed_hosts(net, hosts) {
        add(parse_target(&h).ok());
    }
    out
}

/// Session SID's network for PROFILE under the cell NET, bound in its session dir (made when it is not there, as the
/// sandbox spec makes it, so the relay's socket is this one): none for `NetCell::Open`.  The providers are those the
/// profile's gateway chain names in the provider table in effect.
pub(crate) fn start_session(
    front: &crate::front::Front,
    profile: &AgentProfile,
    sid: &str,
    net: NetCell,
) -> io::Result<Option<SessionNet>> {
    if net == NetCell::Open {
        return Ok(None);
    }
    let chain: Vec<String> = super::session::gateway_chain(front, profile)
        .into_iter()
        .map(|(id, _)| id)
        .collect();
    let cur = front.settings.current();
    let providers: Vec<ProviderConfig> = cur
        .loaded
        .providers
        .iter()
        .filter(|c| chain.iter().any(|id| id == c.id.as_str()))
        .cloned()
        .collect();
    let allow = provider_hosts(
        profile,
        &providers,
        &cur.loaded.values.agents_net_hosts,
        net,
    );
    let env = front.shell_env.paths_env();
    let dir = runstav::paths::make_session_dir(&env, &runstav::paths::socket_path(&env), sid)?;
    let pinned = pins(&cur.loaded.values);
    SessionNet::start(&dir, sid, allow, pinned, Some(front.writer.clone())).map(Some)
}

/// A provider's base URL as the `host:port` a CONNECT names: the URL's host, and its port or the scheme's (443 for
/// https, 80 for http).
fn base_target(url: &str) -> Option<Target> {
    let (scheme, rest) = url.split_once("://")?;
    let default = match scheme.to_ascii_lowercase().as_str() {
        "https" => 443,
        "http" => 80,
        _ => return None,
    };
    let auth = rest.split(['/', '?']).next()?;
    let has_port = match auth.rfind(']') {
        Some(i) => auth[i..].contains(':'),
        None => auth.contains(':'),
    };
    let t = if has_port {
        auth.to_string()
    } else {
        format!("{auth}:{default}")
    };
    parse_target(&t).ok()
}

/// One session's network: its provider proxy, the socket it listens on, and the task that records what it denies.
/// Dropping it closes the listener and every connection and removes the socket (when it is still this one's).  The
/// browser's web proxy and CDP broker join it later.
pub struct SessionNet {
    provider: ProxyHandle,
    socket: PathBuf,
    /// The socket's (dev, inode), so a drop never removes a later session's socket on the same path.
    bound: (u64, u64),
    tasks: JoinSet<()>,
}

impl SessionNet {
    /// Session SID's provider proxy in its session dir DIR, allowing ALLOW, with PINNED names resolved to a fixed
    /// address (none in a shipped build).  Each denied host is written once as a `proxy-denied` store event through
    /// WRITER (none: only logged).  Call it inside a tokio runtime.
    pub fn start(
        dir: &Path,
        sid: &str,
        allow: Vec<Target>,
        pinned: Vec<(String, IpAddr)>,
        writer: Option<Writer>,
    ) -> io::Result<SessionNet> {
        let (tx, rx) = mpsc::channel(16);
        let provider = bind_provider(dir, allow, pinned, tx)?;
        let socket = dir.join(runstav::paths::SESSION_PROXY_SOCKET);
        let m = std::fs::symlink_metadata(&socket)?;
        let mut tasks = JoinSet::new();
        tasks.spawn(record(rx, sid.to_string(), writer));
        Ok(SessionNet {
            provider,
            socket,
            bound: (m.dev(), m.ino()),
            tasks,
        })
    }

    /// The socket the session's relay reaches.
    pub fn socket(&self) -> &Path {
        &self.socket
    }
}

impl Drop for SessionNet {
    fn drop(&mut self) {
        self.provider.shutdown();
        self.tasks.abort_all();
        if std::fs::symlink_metadata(&self.socket).is_ok_and(|m| (m.dev(), m.ino()) == self.bound) {
            let _ = std::fs::remove_file(&self.socket);
        }
    }
}

/// A provider proxy on `DIR/proxy.sock` (a stale file removed first, then 0600; the dir is the session's, 0700),
/// allowing ALLOW with PINNED resolved to fixed addresses; what it refuses goes to EVENTS.  The caller removes the
/// socket ([`SessionNet`] does).
pub fn bind_provider(
    dir: &Path,
    allow: Vec<Target>,
    pinned: Vec<(String, IpAddr)>,
    events: mpsc::Sender<ProxyEvent>,
) -> io::Result<ProxyHandle> {
    let listener = crate::sessions::bind_socket(&dir.join(runstav::paths::SESSION_PROXY_SOCKET))?;
    let handle = proxy::start(
        proxy::ProxyConfig {
            allow,
            pinned,
            ..Default::default()
        },
        std::sync::Arc::new(proxy::SystemResolver),
        events,
    );
    handle.listen(proxy::Listener::Unix(listener), 1);
    Ok(handle)
}

/// The proxy's events for session SID: a denied host as a store event (the proxy says each once per target), and a
/// refusal (a private address, a malformed request) in the log only.
async fn record(mut rx: mpsc::Receiver<ProxyEvent>, sid: String, writer: Option<Writer>) {
    while let Some(ev) = rx.recv().await {
        match ev {
            ProxyEvent::Denied { target, .. } => {
                let host = target.to_string();
                tracing::info!(sid = %sid, host = %host, "the provider proxy denied a host not on its allowlist");
                if let Some(w) = &writer {
                    denied_event(w, &sid, host).await;
                }
            }
            ProxyEvent::Refused { target, why, .. } => {
                tracing::info!(sid = %sid, request = %target, ?why, "the provider proxy refused a request");
            }
        }
    }
}

/// The `proxy-denied` event: kind `status`, the session as its agent, data `{"proxy-denied": true, session, host}`.
async fn denied_event(w: &Writer, sid: &str, host: String) {
    use norn::write::event::{Event, EventKind, event};
    let sid = sid.to_string();
    let caller = crate::runner::service();
    let r = w
        .write(&caller, "agents/proxy-denied", move |tx| {
            event(
                tx,
                Event {
                    at: crate::clock::wall_secs(),
                    agent: Some(sid.clone()),
                    job: None,
                    task: None,
                    kind: EventKind::Status,
                    summary: format!(
                        "the provider proxy denied {host}: not on the session's allowlist"
                    ),
                    data: Some(
                        serde_json::json!({"proxy-denied": true, "session": sid, "host": host}),
                    ),
                    turn: false,
                },
            )
            .map(|_| ())
        })
        .await;
    if let Err(e) = r {
        tracing::debug!("the proxy-denied event was not written: {e:?}");
    }
}

/// Names the provider proxy resolves to a fixed address: those of `drgnx-sandbox-proxy-pinned-addresses` in VALUES;
/// a test build adds `DRGNX_TEST_PROXY_PINS` (`NAME=ADDR,…`), so a row can reach the mock LLM on loopback under a name.
pub fn pins(values: &crate::settings::RuntimeValues) -> Vec<(String, IpAddr)> {
    #[allow(unused_mut)] // a shipped build adds nothing
    let mut out = values.sandbox_proxy_pins.clone();
    #[cfg(any(test, feature = "test-hooks"))]
    if let Ok(v) = std::env::var("DRGNX_TEST_PROXY_PINS") {
        out.extend(
            v.split(',')
                .filter_map(|p| p.split_once('='))
                .filter_map(|(n, a)| Some((n.to_string(), a.parse().ok()?))),
        );
    }
    out
}

#[cfg(test)]
mod tests;
