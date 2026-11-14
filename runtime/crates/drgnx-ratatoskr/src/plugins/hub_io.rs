//! The plugin host's I/O in the hub: `brokkr::HostIo` over [`super::io`]'s decisions (`docs/develop/plugins.md`,
//! "Plugins in the hub").
//!
//! - One [`HubIo`] serves one session's or one job's plugin calls ([`IoCtx`] and the network cell it launched with),
//!   over the manifests of the plugins it runs; the host is handed it as `Arc<dyn HostIo>` at each call.
//! - HTTP: [`judge_http`] on the settings as they are at the request (the `plugin` tier of `drgnx-agents-net-hosts`,
//!   `drgnx-sandbox-proxy-pinned-addresses`) and the host's own addresses, with one lookup on a blocking thread after
//!   the other checks. The hub then connects to a judged address itself: TCP, TLS verified by the platform's verifier
//!   for the request's name, HTTP/1.1, no redirect followed, the response body read up to the host's cap. The name is
//!   never looked up again, so it cannot be pointed elsewhere between the judgement and the connection.
//! - A refusal, the hub's or the host's (a host the manifest does not name, [`brokkr::HostIo::denied`]), is the
//!   import's `Err` and a `status` event `{"proxy-denied": true, session | job, host, plugin}`, once per host per
//!   [`HubIo`]; every one is logged.
//! - KV: `plugin_kv` in `runtime.db` with the manifest's `kv_bytes` as the quota ([`super::io::kv_put`]). The host
//!   calls it on its guest runtime's thread, which waits for the store there (`block_in_place`), never on the hub's
//!   workers.
//! - Logs: the hub's log, with the plugin's name.

use std::collections::HashSet;
use std::future::Future;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use brokkr::limits::MAX_BODY_BYTES;
use brokkr::manifest::MAX_KV_BYTES;
use brokkr::{BoxFuture, HttpReq, HttpResp, Kv, Level, Manifest, Method};
use bytes::Bytes;
use gleipnir::net::policy::HostAddrs;
use http_body_util::{BodyExt, Full, Limited};
use serde_json::json;
use tokio::net::TcpStream;

use super::io::{HttpPolicy, IoCtx, KvError, judge_http, kv_delete, kv_get, kv_put};
use crate::agents::launch::NetCell;
use crate::coord::Writer;
use crate::settings::Settings;

#[cfg(test)]
mod tests;

/// The tier of `drgnx-agents-net-hosts` a plugin's hosts must be on, outside the `open` cell.
pub const PLUGIN_TIER: &str = "plugin";

/// How long one address's TCP connect may take.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// A name's addresses; called on a blocking thread, once per request, after the policy's other checks.
pub type Resolve = Arc<dyn Fn(&str) -> Vec<IpAddr> + Send + Sync>;
/// A TCP connection to a judged address.
pub type Connect = Arc<dyn Fn(SocketAddr) -> Connecting + Send + Sync>;
/// A connection being opened.
pub type Connecting = Pin<Box<dyn Future<Output = io::Result<TcpStream>> + Send>>;

/// How the hub reaches the network for plugins.
#[derive(Clone)]
pub struct Net {
    resolve: Resolve,
    connect: Connect,
    tls: Result<Arc<rustls::ClientConfig>, String>,
}

impl Net {
    /// The system's resolver, TCP, and TLS verified by the platform's verifier (when this host has none, every
    /// request fails and says so).
    pub fn system() -> Net {
        Net {
            resolve: Arc::new(|name: &str| {
                use std::net::ToSocketAddrs;
                (name, 0)
                    .to_socket_addrs()
                    .map(|a| a.map(|a| a.ip()).collect())
                    .unwrap_or_default()
            }),
            connect: Arc::new(|a| Box::pin(TcpStream::connect(a))),
            tls: platform_tls(),
        }
    }
}

fn platform_tls() -> Result<Arc<rustls::ClientConfig>, String> {
    use rustls_platform_verifier::BuilderVerifierExt;
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .and_then(|b| b.with_platform_verifier())
        .map_err(|e| format!("no certificate verifier: {e}"))?
        .with_no_client_auth();
    Ok(Arc::new(config))
}

/// What every [`HubIo`] reaches in the hub.
#[derive(Clone)]
pub struct HubParts {
    /// `runtime.db`: `plugin_kv`.
    pub db: urdr::Handle,
    /// The `plugin` tier and the pins, read at each request.
    pub settings: Arc<Settings>,
    /// The host's own addresses (`browser::nevers`), which count as loopback.
    pub host_addrs: Arc<RwLock<HostAddrs>>,
    /// Where the `proxy-denied` events go.
    pub writer: Writer,
    pub net: Arc<Net>,
}

/// A store that refuses: for a name that is not one of the call's plugins.
struct NoKv;

impl Kv for NoKv {
    fn get(&self, _: &str) -> Option<Vec<u8>> {
        None
    }
    fn put(&self, _: &str, _: &[u8]) -> Result<(), String> {
        Err("not a plugin of this call".into())
    }
    fn delete(&self, _: &str) -> Result<(), String> {
        Err("not a plugin of this call".into())
    }
}

/// One plugin's rows of `plugin_kv`, at most `quota` bytes of keys and values.
struct PluginKv {
    db: urdr::Handle,
    plugin: String,
    quota: u64,
    /// The hub's runtime, where the store's answer is awaited.
    hub: tokio::runtime::Handle,
}

impl PluginKv {
    /// F's answer, waited for on this thread: the guest runtime's (a multi-thread worker, which `block_in_place`
    /// hands its other tasks to another thread first) or one outside any runtime.
    fn wait<T>(&self, f: impl Future<Output = Result<T, KvError>>) -> Result<T, String> {
        use tokio::runtime::{Handle, RuntimeFlavor};
        let r = match Handle::try_current().map(|h| h.runtime_flavor()) {
            Ok(RuntimeFlavor::MultiThread) => tokio::task::block_in_place(|| self.hub.block_on(f)),
            Err(_) => self.hub.block_on(f),
            Ok(_) => return Err("the store cannot be waited for on this thread".into()),
        };
        r.map_err(|e| e.to_string())
    }
}

impl Kv for PluginKv {
    fn get(&self, key: &str) -> Option<Vec<u8>> {
        self.wait(kv_get(&self.db, &self.plugin, key))
            .unwrap_or_else(|e| {
                tracing::warn!(plugin = %self.plugin, "a plugin's key-value read failed: {e}");
                None
            })
    }
    fn put(&self, key: &str, value: &[u8]) -> Result<(), String> {
        self.wait(kv_put(&self.db, &self.plugin, key, value, self.quota))
    }
    fn delete(&self, key: &str) -> Result<(), String> {
        self.wait(kv_delete(&self.db, &self.plugin, key))
    }
}

/// What a call's plugin may reach: its manifest's hosts (`host:port`) and its store.
struct PluginIo {
    name: String,
    hosts: Vec<String>,
    kv: PluginKv,
}

/// The I/O of one session's or one job's plugin calls.
pub struct HubIo {
    ctx: Option<(IoCtx, NetCell)>,
    plugins: Vec<PluginIo>,
    parts: HubParts,
    /// The hosts a `proxy-denied` event was written for.
    denied: Mutex<HashSet<String>>,
}

/// Aborts the connection's task when the request is done or dropped (the host aborts a request past its deadline).
struct Abort(tokio::task::JoinHandle<()>);

impl Drop for Abort {
    fn drop(&mut self) {
        self.0.abort();
    }
}

impl HubIo {
    /// The I/O of CTX's calls (none: every request is refused) of the plugins with MANIFESTS. Call it inside the hub's
    /// runtime: the store's answers are awaited on it.
    pub fn new(ctx: Option<(IoCtx, NetCell)>, manifests: &[&Manifest], parts: HubParts) -> HubIo {
        let hub = tokio::runtime::Handle::current();
        let plugins = manifests
            .iter()
            .map(|m| {
                let name = m.name.as_str().to_owned();
                PluginIo {
                    hosts: m
                        .hosts
                        .iter()
                        .map(|h| format!("{}:{}", h.host(), h.port()))
                        .collect(),
                    kv: PluginKv {
                        db: parts.db.clone(),
                        plugin: name.clone(),
                        quota: u64::from(m.kv_bytes.unwrap_or(MAX_KV_BYTES)),
                        hub: hub.clone(),
                    },
                    name,
                }
            })
            .collect();
        HubIo {
            ctx,
            plugins,
            parts,
            denied: Mutex::default(),
        }
    }

    fn plugin(&self, name: &str) -> Option<&PluginIo> {
        self.plugins.iter().find(|p| p.name == name)
    }

    /// PLUGIN's request, judged, then sent to a judged address; a refusal is recorded first.
    async fn fetch(&self, plugin: &str, req: HttpReq) -> Result<HttpResp, String> {
        let target = format!("{}:{}", req.host, req.port);
        let Some(p) = self.plugin(plugin) else {
            let why = format!("{plugin} is not a plugin of this call");
            self.record(plugin, &target, &why).await;
            return Err(why);
        };
        let cur = self.parts.settings.current();
        let values = &cur.loaded.values;
        let tier: Vec<String> = values
            .agents_net_hosts
            .iter()
            .filter(|(t, _)| t == PLUGIN_TIER)
            .flat_map(|(_, h)| h.iter().cloned())
            .collect();
        let pins = crate::agents::net::pins(values);
        let own = self
            .parts
            .host_addrs
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        let (ctx, hosts, resolve, t) = (
            self.ctx.clone(),
            p.hosts.clone(),
            self.parts.net.resolve.clone(),
            target.clone(),
        );
        let judged = crate::clock::blocking(move || {
            let policy = HttpPolicy {
                ctx: ctx.as_ref().map(|(c, n)| (c, *n)),
                manifest_hosts: &hosts,
                plugin_tier: &tier,
                pins: &pins,
                host_addrs: &own,
            };
            judge_http(&t, &policy, &*resolve)
        })
        .await;
        let addrs = match judged {
            Ok(Ok(addrs)) => addrs,
            Ok(Err(denied)) => {
                let why = denied.to_string();
                self.record(plugin, &target, &why).await;
                return Err(why);
            }
            Err(e) => return Err(format!("the request was not judged: {e}")),
        };
        self.send(req, &addrs).await
    }

    /// REQ over TLS to the first of ADDRS that answers, as `req.host`.
    async fn send(&self, req: HttpReq, addrs: &[SocketAddr]) -> Result<HttpResp, String> {
        let tls = self.parts.net.tls.clone()?;
        let name = rustls::pki_types::ServerName::try_from(req.host.clone())
            .map_err(|e| format!("{}: {e}", req.host))?;
        let mut last = String::from("no address");
        let mut tcp = None;
        for a in addrs {
            let connecting = (self.parts.net.connect)(*a);
            match crate::clock::timeout(CONNECT_TIMEOUT, crate::clock::real(connecting)).await {
                Ok(Ok(s)) => {
                    tcp = Some(s);
                    break;
                }
                Ok(Err(e)) => last = e.to_string(),
                Err(_) => last = "timed out".into(),
            }
        }
        let tcp =
            tcp.ok_or_else(|| format!("cannot connect to {}:{}: {last}", req.host, req.port))?;
        let tls = crate::clock::real(tokio_rustls::TlsConnector::from(tls).connect(name, tcp))
            .await
            .map_err(|e| format!("TLS with {}: {e}", req.host))?;
        let (mut sender, conn) =
            hyper::client::conn::http1::handshake(hyper_util::rt::TokioIo::new(tls))
                .await
                .map_err(|e| format!("HTTP: {e}"))?;
        let _conn = Abort(crate::clock::spawn("plugins/http", async move {
            let _ = conn.await;
        }));
        let resp = crate::clock::real(sender.send_request(request(req)?))
            .await
            .map_err(|e| format!("HTTP: {e}"))?;
        let (head, body) = resp.into_parts();
        let body = crate::clock::real(Limited::new(body, MAX_BODY_BYTES).collect())
            .await
            .map_err(|e| {
                if e.is::<http_body_util::LengthLimitError>() {
                    format!("a response body is at most {} MiB", MAX_BODY_BYTES >> 20)
                } else {
                    format!("the response broke off: {e}")
                }
            })?
            .to_bytes();
        Ok(HttpResp {
            status: head.status.as_u16(),
            headers: head
                .headers
                .iter()
                .filter_map(|(n, v)| Some((n.as_str().to_owned(), v.to_str().ok()?.to_owned())))
                .collect(),
            body: body.to_vec(),
        })
    }

    /// A refusal of PLUGIN's request to HOST (WHY): logged, and a `proxy-denied` event once per host.
    async fn record(&self, plugin: &str, host: &str, why: &str) {
        tracing::info!(plugin, host, why, "a plugin's request was refused");
        let first = self
            .denied
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(host.to_owned());
        if !first {
            return;
        }
        let mut data = json!({"proxy-denied": true, "host": host, "plugin": plugin});
        let (agent, job) = match &self.ctx {
            Some((IoCtx::Session(s), _)) => {
                data["session"] = json!(s);
                (Some(s.clone()), None)
            }
            Some((IoCtx::Job(j), _)) => {
                data["job"] = json!(j);
                (None, Some(j.clone()))
            }
            None => (None, None),
        };
        let summary = format!("plugin {plugin}'s request to {host} was refused: {why}");
        let r = self
            .parts
            .writer
            .write(
                &crate::runner::service(),
                "plugins/proxy-denied",
                move |tx| {
                    use norn::write::event::{Event, EventKind, event};
                    event(
                        tx,
                        Event {
                            at: crate::clock::wall_secs(),
                            agent,
                            job,
                            task: None,
                            kind: EventKind::Status,
                            summary,
                            data: Some(data),
                            turn: false,
                        },
                    )
                    .map(|_| ())
                },
            )
            .await;
        if let Err(e) = r {
            tracing::warn!("the proxy-denied event was not written: {e:?}");
        }
    }
}

/// REQ as an origin-form HTTP/1.1 request: the URL's path and query (no fragment), `host` from the checked name.
fn request(req: HttpReq) -> Result<http::Request<Full<Bytes>>, String> {
    // the host checked the URL: `https://` (any case) and printable ASCII
    let rest = req.url.get(8..).unwrap_or("");
    let path = rest.find(['/', '?', '#']).map_or("", |i| &rest[i..]);
    let path = path.split('#').next().unwrap_or("");
    let path = if path.starts_with('/') {
        path.to_owned()
    } else {
        format!("/{path}")
    };
    let authority = if req.port == 443 {
        req.host.clone()
    } else {
        format!("{}:{}", req.host, req.port)
    };
    let method = match req.method {
        Method::Get => http::Method::GET,
        Method::Post => http::Method::POST,
    };
    let mut b = http::Request::builder()
        .method(method)
        .uri(path)
        .header(http::header::HOST, authority);
    for (n, v) in &req.headers {
        b = b.header(n.as_str(), v.as_str());
    }
    b.body(Full::new(Bytes::from(req.body)))
        .map_err(|e| format!("not a request: {e}"))
}

impl brokkr::HostIo for HubIo {
    fn http(&self, plugin: &str, req: HttpReq) -> BoxFuture<'_, Result<HttpResp, String>> {
        let plugin = plugin.to_owned();
        Box::pin(async move { self.fetch(&plugin, req).await })
    }

    fn denied(&self, plugin: &str, host: &str, why: &str) -> BoxFuture<'_, ()> {
        let (plugin, host, why) = (plugin.to_owned(), host.to_owned(), why.to_owned());
        Box::pin(async move { self.record(&plugin, &host, &why).await })
    }

    fn kv(&self, plugin: &str) -> &dyn Kv {
        match self.plugin(plugin) {
            Some(p) => &p.kv,
            None => &NoKv,
        }
    }

    fn log(&self, plugin: &str, level: Level, text: &str) {
        match level {
            Level::Debug => tracing::debug!(plugin, "{text}"),
            Level::Info => tracing::info!(plugin, "{text}"),
            Level::Warn => tracing::warn!(plugin, "{text}"),
            Level::Error => tracing::error!(plugin, "{text}"),
        }
    }
}
