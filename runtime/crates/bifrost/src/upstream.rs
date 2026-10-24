//! The upstream client: HTTP/1.1 over rustls, the proxy tunnel (Task 19).
//!
//! One [`Upstream`] is built per gateway. It is hyper-util's legacy client over a connector chain:
//! [`HttpConnector`] (timeouts, no delay, any scheme) -> [`Dial`] (a CONNECT tunnel through the proxy the environment
//! names, when one matches the destination) -> hyper-rustls (TLS on the ring provider, verified by the platform's
//! verifier; plain http for the loopback and LAN providers the URL rule allows). HTTP/1.1 only: no `http2` feature is
//! on anywhere and `cargo deny` bans `h2`. There is no SOCKS and no PAC.
//!
//! Request URIs must be absolute (`https://host:port/path`): the connector reads the scheme, host and port from them.

use std::error::Error as StdError;
use std::fmt;
use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use bytes::Bytes;
use http::Uri;
use http_body_util::Full;
use hyper::body::Incoming;
use hyper_rustls::HttpsConnector;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::connect::proxy::Tunnel;
use hyper_util::client::legacy::{self, Client};
use hyper_util::client::proxy::matcher::Matcher;
use hyper_util::rt::{TokioExecutor, TokioIo};
use tokio::net::TcpStream;
use tower_service::Service;

type BoxError = Box<dyn StdError + Send + Sync>;

/// The knobs of [`Upstream::new`].
#[derive(Debug, Clone, Copy)]
pub struct UpstreamOpts {
    /// How long a TCP connect may take (per address) before it is an error.
    pub connect_timeout: Duration,
}

impl Default for UpstreamOpts {
    fn default() -> Self {
        Self {
            connect_timeout: Duration::from_secs(10),
        }
    }
}

/// Why a request did not get a response head. The text is for the fallback reason ("no answer", "cannot send (...)").
#[derive(Debug)]
pub enum UpstreamError {
    /// No TCP connection (refused, unreachable, timed out, name not found).
    Connect(String),
    /// The TLS handshake or the certificate check failed.
    Tls(String),
    /// The proxy refused or broke the CONNECT tunnel.
    Proxy(String),
    /// A connection existed, but the exchange failed (a reset, a bad response head, a send error).
    Protocol(String),
    /// This build cannot do it (no certificate verifier).
    Unsupported(&'static str),
}

impl fmt::Display for UpstreamError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Connect(d) => write!(f, "cannot connect: {d}"),
            Self::Tls(d) => write!(f, "TLS failed: {d}"),
            Self::Proxy(d) => write!(f, "proxy failed: {d}"),
            Self::Protocol(d) => write!(f, "protocol error: {d}"),
            Self::Unsupported(d) => write!(f, "unsupported: {d}"),
        }
    }
}

impl StdError for UpstreamError {}

/// A CONNECT tunnel that did not come up. Our own type, because hyper-util's `TunnelError` cannot be named.
#[derive(Debug)]
struct ProxyFailure(String);

impl fmt::Display for ProxyFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl StdError for ProxyFailure {}

/// The connector under TLS: dials the destination directly, or through a CONNECT tunnel when the proxy rules match.
#[derive(Clone)]
struct Dial {
    http: HttpConnector,
    proxy: Arc<Matcher>,
}

type DialFuture = Pin<Box<dyn Future<Output = Result<TokioIo<TcpStream>, BoxError>> + Send>>;

impl Service<Uri> for Dial {
    type Response = TokioIo<TcpStream>;
    type Error = BoxError;
    type Future = DialFuture;

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        self.http.poll_ready(cx).map_err(Into::into)
    }

    fn call(&mut self, dst: Uri) -> Self::Future {
        let mut http = self.http.clone();
        match self.proxy.intercept(&dst) {
            None => {
                Box::pin(async move { http.call(dst).await.map_err(|e| Box::new(e) as BoxError) })
            }
            Some(hop) => {
                let mut tunnel = Tunnel::new(hop.uri().clone(), http);
                if let Some(auth) = hop.basic_auth() {
                    tunnel = tunnel.with_auth(auth.clone());
                }
                Box::pin(async move {
                    tunnel
                        .call(dst)
                        .await
                        .map_err(|e| Box::new(ProxyFailure(e.to_string())) as BoxError)
                })
            }
        }
    }
}

type Connector = HttpsConnector<Dial>;

/// TLS over `dial`, verified by the platform verifier on the ring provider; http stays plain.
#[cfg(feature = "platform-verifier")]
fn tls_connector(dial: Dial) -> Result<Connector, UpstreamError> {
    use hyper_rustls::HttpsConnectorBuilder;
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let builder = HttpsConnectorBuilder::new()
        .with_provider_and_platform_verifier(provider)
        .map_err(|e| UpstreamError::Tls(format!("platform verifier: {e}")))?;
    Ok(builder.https_or_http().enable_http1().wrap_connector(dial))
}

#[cfg(not(feature = "platform-verifier"))]
fn tls_connector(_dial: Dial) -> Result<Connector, UpstreamError> {
    Err(UpstreamError::Unsupported(
        "no certificate verifier in this build",
    ))
}

/// The gateway's HTTP/1.1 client. Cheap to share behind an `Arc`; connections are pooled.
pub struct Upstream {
    client: Client<Connector, Full<Bytes>>,
}

impl Upstream {
    /// A client whose proxy rules are read once from the environment (`HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`,
    /// `NO_PROXY`, upper and lower case).
    pub fn new(opts: UpstreamOpts) -> Result<Self, UpstreamError> {
        Self::with_proxy(opts, Matcher::from_env())
    }

    /// As [`Upstream::new`], with the proxy rules given (tests, and a caller that has its own).
    pub fn with_proxy(opts: UpstreamOpts, proxy: Matcher) -> Result<Self, UpstreamError> {
        let mut http = HttpConnector::new();
        http.set_connect_timeout(Some(opts.connect_timeout));
        http.set_nodelay(true);
        http.enforce_http(false);
        let connector = tls_connector(Dial {
            http,
            proxy: Arc::new(proxy),
        })?;
        Ok(Self {
            client: Client::builder(TokioExecutor::new()).build(connector),
        })
    }

    /// Send `req` (an absolute URI) and return the response as soon as its head is read; the body streams.
    pub async fn send(
        &self,
        req: http::Request<Full<Bytes>>,
    ) -> Result<http::Response<Incoming>, UpstreamError> {
        self.client.request(req).await.map_err(|e| classify(&e))
    }
}

#[derive(Clone, Copy)]
enum Kind {
    Tls,
    Proxy,
}

/// The first TLS or proxy error in the chain, looking inside `io::Error` wrappers (hyper-rustls wraps the handshake
/// error in one, and `io::Error::source` skips what it wraps).
fn kind_of(e: &(dyn StdError + 'static)) -> Option<Kind> {
    if e.is::<rustls::Error>() {
        return Some(Kind::Tls);
    }
    if e.is::<ProxyFailure>() {
        return Some(Kind::Proxy);
    }
    if let Some(inner) = e.downcast_ref::<io::Error>().and_then(io::Error::get_ref)
        && let Some(k) = kind_of(inner)
    {
        return Some(k);
    }
    e.source().and_then(kind_of)
}

/// The messages of the whole chain, outermost first.
fn chain_text(e: &(dyn StdError + 'static)) -> String {
    let mut out = e.to_string();
    let mut cur = e.source();
    while let Some(c) = cur {
        out.push_str(": ");
        out.push_str(&c.to_string());
        cur = c.source();
    }
    out
}

fn classify(e: &legacy::Error) -> UpstreamError {
    let text = chain_text(e);
    match kind_of(e) {
        Some(Kind::Tls) => UpstreamError::Tls(text),
        Some(Kind::Proxy) => UpstreamError::Proxy(text),
        None if e.is_connect() => UpstreamError::Connect(text),
        None => UpstreamError::Protocol(text),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use http_body_util::BodyExt;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;
    use tokio::sync::oneshot;

    use super::*;

    fn get(url: &str) -> http::Request<Full<Bytes>> {
        http::Request::get(url)
            .body(Full::new(Bytes::new()))
            .unwrap()
    }

    /// Read until the blank line that ends a request head; returns the head.
    async fn read_head(s: &mut TcpStream) -> String {
        let mut buf = Vec::new();
        let mut b = [0u8; 1024];
        while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
            let n = s.read(&mut b).await.unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&b[..n]);
        }
        String::from_utf8_lossy(&buf).into_owned()
    }

    fn direct() -> Upstream {
        Upstream::with_proxy(UpstreamOpts::default(), Matcher::builder().build()).unwrap()
    }

    #[tokio::test]
    async fn plain_http_to_a_local_server() {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        tokio::spawn(async move {
            let (mut s, _) = l.accept().await.unwrap();
            read_head(&mut s).await;
            s.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
                .await
                .unwrap();
        });
        let resp = direct()
            .send(get(&format!("http://127.0.0.1:{port}/x")))
            .await
            .unwrap();
        assert_eq!(resp.status(), 200);
        let body = resp.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(&body[..], b"hello");
    }

    #[tokio::test]
    async fn a_connect_failure_ends_within_the_timeout() {
        // A port nothing listens on: bind, note the port, drop.
        let port = {
            let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
            l.local_addr().unwrap().port()
        };
        let up = Upstream::with_proxy(
            UpstreamOpts {
                connect_timeout: Duration::from_millis(100),
            },
            Matcher::builder().build(),
        )
        .unwrap();
        let t = std::time::Instant::now();
        let err = tokio::time::timeout(
            Duration::from_millis(200),
            up.send(get(&format!("http://127.0.0.1:{port}/"))),
        )
        .await
        .expect("the connect error arrives within the test timeout")
        .unwrap_err();
        assert!(matches!(err, UpstreamError::Connect(_)), "{err}");
        assert!(t.elapsed() < Duration::from_millis(200));
    }

    #[tokio::test]
    async fn https_proxy_from_the_environment_goes_through_connect() {
        // The matcher is what `Matcher::from_env` builds from HTTPS_PROXY; the test builds it directly so that it
        // does not touch the process environment.
        let proxy = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let pport = proxy.local_addr().unwrap().port();
        let (tx, rx) = oneshot::channel();
        tokio::spawn(async move {
            let (mut s, _) = proxy.accept().await.unwrap();
            let head = read_head(&mut s).await;
            let _ = tx.send(head);
            let _ = s.write_all(b"HTTP/1.1 403 Forbidden\r\n\r\n").await;
        });
        let m = Matcher::builder()
            .https(format!("http://127.0.0.1:{pport}"))
            .build();
        let up = Upstream::with_proxy(UpstreamOpts::default(), m).unwrap();
        let err = up
            .send(get("https://localhost:4443/v1/messages"))
            .await
            .unwrap_err();
        assert!(matches!(err, UpstreamError::Proxy(_)), "{err}");
        let head = rx.await.unwrap();
        assert!(head.starts_with("CONNECT localhost:4443 "), "{head}");
    }

    #[tokio::test]
    async fn no_proxy_is_respected() {
        let proxy = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let pport = proxy.local_addr().unwrap().port();
        let seen = Arc::new(AtomicUsize::new(0));
        let seen2 = seen.clone();
        tokio::spawn(async move {
            while proxy.accept().await.is_ok() {
                seen2.fetch_add(1, Ordering::SeqCst);
            }
        });
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        tokio::spawn(async move {
            let (mut s, _) = l.accept().await.unwrap();
            read_head(&mut s).await;
            s.write_all(b"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
                .await
                .unwrap();
        });
        let m = Matcher::builder()
            .http(format!("http://127.0.0.1:{pport}"))
            .no("127.0.0.1")
            .build();
        let up = Upstream::with_proxy(UpstreamOpts::default(), m).unwrap();
        let resp = up
            .send(get(&format!("http://127.0.0.1:{port}/")))
            .await
            .unwrap();
        assert_eq!(resp.status(), 204);
        assert_eq!(
            seen.load(Ordering::SeqCst),
            0,
            "the proxy must not be dialled for a NO_PROXY host"
        );
    }

    #[tokio::test]
    async fn the_response_streams() {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        let (go, wait) = oneshot::channel::<()>();
        tokio::spawn(async move {
            let (mut s, _) = l.accept().await.unwrap();
            read_head(&mut s).await;
            s.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\none\r\n")
                .await
                .unwrap();
            // The second chunk is written only after the client has read the first.
            wait.await.unwrap();
            s.write_all(b"3\r\ntwo\r\n0\r\n\r\n").await.unwrap();
        });
        let resp = direct()
            .send(get(&format!("http://127.0.0.1:{port}/")))
            .await
            .unwrap();
        let mut body = resp.into_body();
        let first = body.frame().await.unwrap().unwrap().into_data().unwrap();
        assert_eq!(&first[..], b"one");
        go.send(()).unwrap();
        let second = body.frame().await.unwrap().unwrap().into_data().unwrap();
        assert_eq!(&second[..], b"two");
    }
}
