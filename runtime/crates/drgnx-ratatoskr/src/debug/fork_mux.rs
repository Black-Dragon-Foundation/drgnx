//! The hub's side of a sealed fork's stdio shim (`etc/debug-fork-shim.js`, `etc/debug-fork-shim.py`): several DAP
//! connections on one pipe. Each message carries `Drgnx-Conn: N` beside its `Content-Length`; the shim opens
//! connection N on its first message and says `Drgnx-Close: N` (an empty body) when the adapter closes it. Each
//! [`Mux::open`] is one more connection, as a byte stream `vor::Client` reads and writes.

use std::collections::HashMap;
use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::io::{
    AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader,
};
use tokio::sync::mpsc;

/// The largest message the mux passes on.
pub const MAX_BODY: usize = 64 << 20;

/// One frame's headers (lower-cased names) and body; none at the end of the stream.
pub async fn read_frame<R: AsyncBufRead + Unpin>(
    r: &mut R,
) -> io::Result<Option<(HashMap<String, String>, Vec<u8>)>> {
    let mut head = HashMap::new();
    let mut line = String::new();
    loop {
        line.clear();
        if r.read_line(&mut line).await? == 0 {
            return Ok(None);
        }
        let l = line.trim_end_matches(['\r', '\n']);
        if l.is_empty() {
            if head.is_empty() {
                continue;
            }
            break;
        }
        if let Some((k, v)) = l.split_once(':') {
            head.insert(k.trim().to_ascii_lowercase(), v.trim().to_owned());
        }
    }
    let len: usize = head
        .get("content-length")
        .and_then(|v| v.parse().ok())
        .ok_or_else(|| io::Error::other("a frame with no Content-Length"))?;
    if len > MAX_BODY {
        return Err(io::Error::other(format!("a frame of {len} bytes")));
    }
    let mut body = vec![0; len];
    r.read_exact(&mut body).await?;
    Ok(Some((head, body)))
}

type Writer = tokio::sync::Mutex<Box<dyn AsyncWrite + Send + Unpin>>;
/// Each open connection's way to its reader: a body, or `None` at its close.
type Routes = Arc<Mutex<HashMap<String, mpsc::UnboundedSender<Option<Vec<u8>>>>>>;

/// Connections over one shim.
#[derive(Clone)]
pub struct Mux {
    write: Arc<Writer>,
    routes: Routes,
    next: Arc<AtomicU64>,
}

/// One connection's two halves, for `vor::Client::new`.
pub type Halves = (
    tokio::io::ReadHalf<tokio::io::DuplexStream>,
    tokio::io::WriteHalf<tokio::io::DuplexStream>,
);

impl Mux {
    /// The mux over the shim's stdout R and stdin W.
    pub fn new<R, W>(r: R, w: W) -> Mux
    where
        R: AsyncRead + Send + Unpin + 'static,
        W: AsyncWrite + Send + Unpin + 'static,
    {
        let m = Mux {
            write: Arc::new(tokio::sync::Mutex::new(Box::new(w))),
            routes: Arc::default(),
            next: Arc::default(),
        };
        let routes = m.routes.clone();
        crate::clock::spawn("debug:fork-mux-read", async move {
            let mut r = BufReader::new(r);
            loop {
                let (head, body) = match read_frame(&mut r).await {
                    Ok(Some(f)) => f,
                    Ok(None) => break,
                    Err(e) => {
                        tracing::debug!(target: "drgnx::debug", "the fork's shim: {e}");
                        break;
                    }
                };
                let id = head.get("drgnx-conn").cloned().unwrap_or_default();
                let mut routes = routes.lock().unwrap_or_else(|e| e.into_inner());
                if head.contains_key("drgnx-close") {
                    if let Some(tx) = routes.remove(&id) {
                        let _ = tx.send(None);
                    }
                } else if let Some(tx) = routes.get(&id) {
                    let _ = tx.send(Some(body));
                }
            }
            // the shim is gone: every connection ends
            for (_, tx) in routes.lock().unwrap_or_else(|e| e.into_inner()).drain() {
                let _ = tx.send(None);
            }
        });
        m
    }

    /// A new connection.
    pub fn open(&self) -> Halves {
        let id = self.next.fetch_add(1, Ordering::Relaxed).to_string();
        let (client, mine) = tokio::io::duplex(1 << 20);
        let (mut mr, mut mw) = tokio::io::split(mine);
        let (tx, mut rx) = mpsc::unbounded_channel::<Option<Vec<u8>>>();
        self.routes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id.clone(), tx);
        // the adapter's messages to the client
        crate::clock::spawn("debug:fork-mux-in", async move {
            while let Some(Some(body)) = rx.recv().await {
                let head = format!("Content-Length: {}\r\n\r\n", body.len());
                if mw.write_all(head.as_bytes()).await.is_err()
                    || mw.write_all(&body).await.is_err()
                {
                    return;
                }
            }
            let _ = mw.shutdown().await;
        });
        // the client's messages to the adapter, with the connection's id
        let write = self.write.clone();
        crate::clock::spawn("debug:fork-mux-out", async move {
            let mut r = BufReader::new(&mut mr);
            while let Ok(Some((_, body))) = read_frame(&mut r).await {
                let head = format!("Drgnx-Conn: {id}\r\nContent-Length: {}\r\n\r\n", body.len());
                let mut w = write.lock().await;
                if w.write_all(head.as_bytes()).await.is_err()
                    || w.write_all(&body).await.is_err()
                    || w.flush().await.is_err()
                {
                    return;
                }
            }
        });
        tokio::io::split(client)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn frame_of<R: AsyncBufRead + Unpin>(r: &mut R) -> (HashMap<String, String>, String) {
        let (h, b) = read_frame(r).await.unwrap().unwrap();
        (h, String::from_utf8(b).unwrap())
    }

    /// Two connections on one pipe: each message goes out with its id, each answer back to its connection, and a
    /// close ends only that one.
    #[tokio::test]
    async fn connections_are_told_apart_by_their_id() {
        let (hub_out, shim_in) = tokio::io::duplex(1 << 16);
        let (shim_out, hub_in) = tokio::io::duplex(1 << 16);
        let m = Mux::new(hub_in, hub_out);
        let (mut r0, mut w0) = m.open();
        let (mut r1, mut w1) = m.open();
        w1.write_all(b"Content-Length: 3\r\n\r\none").await.unwrap();
        let mut shim_r = BufReader::new(shim_in);
        let (h, b) = frame_of(&mut shim_r).await;
        assert_eq!((h["drgnx-conn"].as_str(), b.as_str()), ("1", "one"));
        w0.write_all(b"Content-Length: 4\r\n\r\nzero")
            .await
            .unwrap();
        let (h, b) = frame_of(&mut shim_r).await;
        assert_eq!((h["drgnx-conn"].as_str(), b.as_str()), ("0", "zero"));
        let mut shim_w = shim_out;
        shim_w
            .write_all(b"Drgnx-Conn: 0\r\nContent-Length: 2\r\n\r\nhi")
            .await
            .unwrap();
        shim_w
            .write_all(b"Drgnx-Conn: 1\r\nDrgnx-Close: 1\r\nContent-Length: 0\r\n\r\n")
            .await
            .unwrap();
        let mut got = String::new();
        let mut buf = [0u8; 64];
        let n = r0.read(&mut buf).await.unwrap();
        got.push_str(std::str::from_utf8(&buf[..n]).unwrap());
        assert_eq!(got, "Content-Length: 2\r\n\r\nhi");
        // connection 1 is closed: its reader ends
        assert_eq!(r1.read(&mut buf).await.unwrap(), 0);
        // the shim going ends connection 0 too
        drop(shim_w);
        assert_eq!(r0.read(&mut buf).await.unwrap(), 0);
    }
}
