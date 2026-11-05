//! A job's network in the job helper: Gleipnir's CONNECT proxy (`gleipnir::net::proxy`) on `D/proxy.sock`, with the
//! hub's allow-list. The job reaches it through `drgnx-fwd` on its own loopback; it has no other network.
//!
//! The allow-list never holds a cloud metadata service or a link-local address: an entry naming
//! `metadata.google.internal`, `169.254.169.254`, `fd00:ec2::254` or any address that isn't public is refused, and
//! the proxy itself connects only to public addresses, so a listed name that resolves to `169.254.x` is refused at
//! connect time too. No name is pinned.

use std::io;
use std::net::IpAddr;
use std::path::Path;
use std::sync::Arc;

use gleipnir::net::host::{Host, Target, is_public, parse_target};
use gleipnir::net::proxy::{self, Listener, ProxyConfig, ProxyEvent, Resolver, SystemResolver};

/// Names that reach a cloud's metadata service (the design's list; the agent browser's `METADATA_NEVER` replaces it
/// once both are on one line).
pub const METADATA_NAMES: &[&str] = &["metadata.google.internal"];
/// The metadata services' addresses.
pub const METADATA_ADDRS: &[&str] = &["169.254.169.254", "fd00:ec2::254"];

/// The hub's allow-list (`host:port` per line, `#` comments) as the proxy's targets. An entry that is malformed, a
/// metadata name or address, or an address that isn't public is refused, naming it.
pub fn allow_list(text: &str) -> Result<Vec<Target>, String> {
    let mut out = Vec::new();
    for raw in text.lines() {
        let entry = raw.trim();
        if entry.is_empty() || entry.starts_with('#') {
            continue;
        }
        let t = parse_target(entry).map_err(|e| format!("the allow-list entry {entry:?}: {e}"))?;
        let never = match &t.host {
            Host::Name(n) => METADATA_NAMES.contains(&n.as_str()),
            Host::V4(a) => {
                !is_public(IpAddr::V4(*a)) || METADATA_ADDRS.contains(&a.to_string().as_str())
            }
            Host::V6(a) => {
                !is_public(IpAddr::V6(*a)) || METADATA_ADDRS.contains(&a.to_string().as_str())
            }
        };
        if never {
            return Err(format!(
                "the allow-list entry {entry:?}: a metadata service or an address that isn't public is never reached"
            ));
        }
        out.push(t);
    }
    Ok(out)
}

/// The running proxy: its own runtime on its own thread. Dropping it stops both.
pub struct Proxy {
    _handle: proxy::ProxyHandle,
    runtime: Option<tokio::runtime::Runtime>,
}

impl Drop for Proxy {
    fn drop(&mut self) {
        if let Some(rt) = self.runtime.take() {
            rt.shutdown_background();
        }
    }
}

/// Starts the proxy for ALLOW on the socket SOCK (mode 0600, there at once), resolving with RESOLVER (the system's
/// when none). Refusals are said on stderr, which is the helper's log.
pub fn start(
    sock: &Path,
    allow: Vec<Target>,
    resolver: Option<Arc<dyn Resolver>>,
) -> io::Result<Proxy> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build()?;
    let dir = sock.parent().unwrap_or(Path::new("."));
    let name = sock
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "the proxy socket's name"))?;
    let std_l = super::keys::bind(dir, name)?;
    std_l.set_nonblocking(true)?;
    let (tx, mut rx) = tokio::sync::mpsc::channel::<ProxyEvent>(64);
    let handle = {
        let _g = rt.enter();
        let l = tokio::net::UnixListener::from_std(std_l)?;
        let h = proxy::start(
            ProxyConfig {
                allow,
                ..ProxyConfig::default()
            },
            resolver.unwrap_or_else(|| Arc::new(SystemResolver)),
            tx,
        );
        h.listen(Listener::Unix(l), 0);
        h
    };
    rt.spawn(async move {
        while let Some(e) = rx.recv().await {
            eprintln!("sleipnir job-helper: the proxy refused {e:?}");
        }
    });
    Ok(Proxy {
        _handle: handle,
        runtime: Some(rt),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::future::Future;
    use std::io::{Read, Write};
    use std::net::SocketAddr;
    use std::os::unix::net::UnixStream;
    use std::pin::Pin;

    /// Every name resolves to one link-local address.
    struct LinkLocal;
    impl Resolver for LinkLocal {
        fn resolve(
            &self,
            _: &str,
            port: u16,
        ) -> Pin<Box<dyn Future<Output = io::Result<Vec<SocketAddr>>> + Send>> {
            Box::pin(async move { Ok(vec![SocketAddr::from(([169, 254, 10, 1], port))]) })
        }
    }

    /// [D] The metadata names and addresses and every link-local entry are refused in the allow-list; a listed name
    /// that resolves to a link-local address gets the proxy's 403, never a connection.
    #[test]
    fn the_proxy_denies_metadata_and_link_local() {
        for bad in [
            "169.254.169.254:80",
            "[fd00:ec2::254]:80",
            "metadata.google.internal:80",
            "Metadata.Google.Internal.:80",
            "169.254.1.1:443",
            "[fe80::1]:443",
            "10.0.0.1:443",
        ] {
            assert!(allow_list(bad).is_err(), "{bad} was allowed");
        }
        let ok = allow_list("# packages\ncrates.io:443\n\nstatic.crates.io:443\n").unwrap();
        assert_eq!(ok.len(), 2);

        let d = tempfile::tempdir().unwrap();
        let sock = d.path().join("proxy.sock");
        let _p = start(
            &sock,
            allow_list("meta.example.test:80").unwrap(),
            Some(Arc::new(LinkLocal)),
        )
        .unwrap();
        let mut s = UnixStream::connect(&sock).unwrap();
        s.write_all(b"CONNECT meta.example.test:80 HTTP/1.1\r\nHost: meta.example.test:80\r\n\r\n")
            .unwrap();
        let mut answer = String::new();
        s.read_to_string(&mut answer).unwrap();
        assert!(answer.starts_with("HTTP/1.1 403"), "{answer:?}");
        // and a name not on the list is refused too
        let mut s = UnixStream::connect(&sock).unwrap();
        s.write_all(b"CONNECT other.example.test:80 HTTP/1.1\r\n\r\n")
            .unwrap();
        let mut answer = String::new();
        s.read_to_string(&mut answer).unwrap();
        assert!(answer.starts_with("HTTP/1.1 403"), "{answer:?}");
    }
}
