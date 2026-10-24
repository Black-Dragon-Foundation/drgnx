//! The gateway's listeners (design §5.6; the plan's call 11): the loopback TCP listener and a session's own Unix
//! socket, each serving HTTP/1.1 through [`Gateway::handle`].
//!
//! - hyper's http1 server, keep-alive on (the token is checked on every request), a 30 s header-read timeout, and a
//!   64 KiB cap on the request head (a longer one is 431, as the Lisp's 64 KiB rule);
//! - at most [`TCP_CONNECTIONS`] connections on the TCP listener and [`SESSION_CONNECTIONS`] on a session socket; past
//!   that a connection is accepted and closed at once, and logged.
//!
//! The listeners are made by the caller (its port, its socket path and mode); these serve them until the task is
//! dropped.

use std::convert::Infallible;
use std::io;
use std::sync::Arc;
use std::time::Duration;

use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpListener, UnixListener};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use crate::ListenerId;
use crate::engine::Gateway;

/// Connections at once on the loopback listener.
pub const TCP_CONNECTIONS: usize = 64;
/// Connections at once on one session's socket.
pub const SESSION_CONNECTIONS: usize = 8;
/// How long a client may take to send a request head.
pub const HEADER_READ_TIMEOUT: Duration = Duration::from_secs(30);
/// The largest request head (and hyper's read buffer).
pub const MAX_HEAD: usize = 64 * 1024;

/// Serve the loopback listener; `port` is its port, which a request's `Host` must name.
pub async fn serve_tcp(gw: Arc<Gateway>, listener: TcpListener, port: u16) {
    let slots = Arc::new(Semaphore::new(TCP_CONNECTIONS));
    loop {
        let stream = match listener.accept().await {
            Ok((stream, _)) => stream,
            Err(e) => {
                accept_failed(&e).await;
                continue;
            }
        };
        let Ok(slot) = slots.clone().try_acquire_owned() else {
            tracing::warn!(
                "gateway: {TCP_CONNECTIONS} connections on the loopback listener; one more was closed"
            );
            continue;
        };
        let _ = stream.set_nodelay(true);
        tokio::spawn(connection(
            gw.clone(),
            stream,
            ListenerId::Loopback,
            port,
            slot,
        ));
    }
}

/// Serve a session's socket; `id` is the listener its tokens were issued for.
pub async fn serve_unix(gw: Arc<Gateway>, listener: UnixListener, id: ListenerId) {
    let slots = Arc::new(Semaphore::new(SESSION_CONNECTIONS));
    loop {
        let stream = match listener.accept().await {
            Ok((stream, _)) => stream,
            Err(e) => {
                accept_failed(&e).await;
                continue;
            }
        };
        let Ok(slot) = slots.clone().try_acquire_owned() else {
            tracing::warn!(
                "gateway: {SESSION_CONNECTIONS} connections on a session socket; one more was closed"
            );
            continue;
        };
        tokio::spawn(connection(gw.clone(), stream, id.clone(), 0, slot));
    }
}

/// A failed accept (out of descriptors, say): logged, and a pause so the loop does not spin.
async fn accept_failed(e: &io::Error) {
    tracing::warn!("gateway: accept failed: {e}");
    tokio::time::sleep(Duration::from_millis(50)).await;
}

/// One connection, holding its `slot` until it ends.
async fn connection<S>(
    gw: Arc<Gateway>,
    io: S,
    on: ListenerId,
    port: u16,
    slot: OwnedSemaphorePermit,
) where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let service = service_fn(move |req| {
        let (gw, on) = (gw.clone(), on.clone());
        async move { Ok::<_, Infallible>(gw.handle(req, on, port).await) }
    });
    let served = {
        let mut builder = http1::Builder::new();
        builder
            .timer(TokioTimer::new())
            .header_read_timeout(HEADER_READ_TIMEOUT)
            .max_buf_size(MAX_HEAD)
            .max_header_size(MAX_HEAD)
            .keep_alive(true);
        builder.serve_connection(TokioIo::new(io), service)
    };
    if let Err(e) = served.await {
        tracing::debug!("gateway: a connection ended: {e}");
    }
    drop(slot);
}
