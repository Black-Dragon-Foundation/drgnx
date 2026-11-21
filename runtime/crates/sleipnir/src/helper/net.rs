//! A job's network in the job helper: Gleipnir's CONNECT proxy (`gleipnir::net::proxy`) with the hub's allow-list, on
//! the streams of the job's relay sidecar (`drgnx-px`, [`Relay`]). The job shares the sidecar's network namespace and
//! reaches the proxy only through it, at `127.0.0.1:3128`; it has no other network.
//!
//! The allow-list and the proxy's settings are [`crate::net`]'s, shared with a Mac's job-exec.
//!
//! The relay carries a keyed job's keys too ([`KeyServer`]): every keyed job has a sidecar, networked or not (an
//! unnetworked one's proxy has an empty allow-list), and its key streams are answered from the helper's store.

use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use drgnx_px::owner::{AnswerFuture, KeyAnswer, KeySource};

use super::keys::{self, KeyStore};

use gleipnir::net::host::Target;
use gleipnir::net::proxy::{self, Listener, ProxyEvent, Resolver, SystemResolver};

pub use crate::net::{METADATA_ADDRS, METADATA_NAMES, allow_list, proxy_config};

/// Where the sidecar listens inside the job's namespace (its `READY` names it).
pub const LISTEN: std::net::SocketAddr =
    std::net::SocketAddr::new(IpAddr::V4(std::net::Ipv4Addr::LOCALHOST), 3128);

/// Starts the proxy for ALLOW on the relayed STREAMS, resolving with RESOLVER (the system's when none). Refusals are
/// said on stderr, which is the helper's log. Inside a tokio runtime.
pub fn start_proxy(
    allow: Vec<Target>,
    resolver: Option<Arc<dyn Resolver>>,
    streams: tokio::sync::mpsc::Receiver<proxy::Relayed>,
) -> proxy::ProxyHandle {
    let (tx, mut rx) = tokio::sync::mpsc::channel::<ProxyEvent>(64);
    let h = proxy::start(
        proxy_config(allow),
        resolver.unwrap_or_else(|| Arc::new(SystemResolver)),
        tx,
    );
    h.listen(Listener::Streams(streams), 0);
    tokio::spawn(async move {
        while let Some(e) = rx.recv().await {
            eprintln!("sleipnir job-helper: the proxy refused {e:?}");
        }
    });
    h
}

/// A keyed job's key streams, answered from the helper's store ([`keys::answer`]) on the blocking pool, since a
/// request waits for its key.
pub struct KeyServer {
    pub store: Arc<KeyStore>,
    pub dir: PathBuf,
    pub wait: Duration,
}

impl KeyAnswer for keys::Answer {
    fn bytes(&self) -> &[u8] {
        keys::Answer::bytes(self)
    }
}

impl KeySource for KeyServer {
    fn answer(&self, request: &str) -> AnswerFuture {
        let (store, dir, wait, req) = (
            self.store.clone(),
            self.dir.clone(),
            self.wait,
            request.to_string(),
        );
        Box::pin(async move {
            let a = tokio::task::spawn_blocking(move || keys::answer(&store, &dir, wait, &req))
                .await
                .unwrap_or_else(|_| keys::Answer::Text(b"no the helper failed\n".to_vec()));
            Box::new(a) as Box<dyn KeyAnswer>
        })
    }
}

/// A job's relay in its helper: the sidecar, the channel and the proxy on their own runtime. The helper starts it
/// before its `ready` line and ends it ([`Relay::end`]) when the job has ended.
pub struct Relay {
    runtime: tokio::runtime::Runtime,
    watch: tokio::task::JoinHandle<()>,
    job_ended: Option<tokio::sync::oneshot::Sender<()>>,
}

/// How the relay's end goes: the job's container, then the sidecar (podman records the job's dependency on it).
async fn take_down(
    container: Option<&str>,
    sidecar: drgnx_px::owner::Sidecar,
    name: &str,
) -> Option<i32> {
    if let Some(c) = container {
        let _ = tokio::process::Command::new("podman")
            .args(["rm", "-f", c])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .await;
    }
    sidecar.stop(Path::new("podman"), name, &[]).await
}

impl Relay {
    /// Starts the sidecar (`podman` with SIDECAR_ARGV, named NAME), waits for its `READY`, and puts the proxy for
    /// ALLOW on its streams, and KEYS (a keyed job) on its key streams. When the channel ends before the job, the job
    /// (CONTAINER) is ended `infra: proxy` with the reason in DIR's `kill_reason`, the container removed before the
    /// sidecar.
    pub fn start(
        dir: &Path,
        allow: Vec<Target>,
        sidecar_argv: &[String],
        name: &str,
        container: Option<String>,
        keys: Option<Arc<dyn KeySource>>,
    ) -> Result<Relay, String> {
        use drgnx_px::owner;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .map_err(|e| format!("the relay's runtime: {e}"))?;
        let name = name.to_string();
        let dir = dir.to_path_buf();
        let (job_ended, ended) = tokio::sync::oneshot::channel::<()>();
        let watch = runtime.block_on(async move {
            let argv = sidecar_argv.iter().map(std::ffi::OsString::from).collect();
            let mut sidecar = owner::Sidecar::start(Path::new("podman"), argv, &[]).await?;
            let Some((inp, mut out)) = sidecar.take_io() else {
                unreachable!("a sidecar just started has its stdio")
            };
            if let Err(e) = owner::wait_ready(&mut out, LISTEN, owner::READY_LIMIT).await {
                let stderr = sidecar.stderr();
                sidecar.stop(Path::new("podman"), &name, &[]).await;
                return Err(format!(
                    "The job's proxy did not start within 10 s: {e:?}: {}",
                    stderr.trim()
                ));
            }
            let (streams_tx, streams_rx) = tokio::sync::mpsc::channel(owner::STREAMS_ROOM);
            let (events_tx, mut events_rx) = tokio::sync::mpsc::channel(16);
            let proxy = start_proxy(allow, None, streams_rx);
            tokio::spawn(async move {
                while let Some(e) = events_rx.recv().await {
                    eprintln!("sleipnir job-helper: the relay reports {e:?}");
                }
            });
            let log = drgnx_px::shell::Log::default();
            let drained = log.clone();
            tokio::spawn(async move { drained.drain_to(tokio::io::stderr()).await });
            let mut channel = match keys {
                Some(k) => tokio::spawn(owner::run_keyed(
                    out,
                    inp,
                    streams_tx,
                    k,
                    events_tx,
                    owner::BEAT,
                    drgnx_px::shell::STALL,
                    log,
                )),
                None => tokio::spawn(owner::run(
                    out,
                    inp,
                    streams_tx,
                    events_tx,
                    owner::BEAT,
                    drgnx_px::shell::STALL,
                    log,
                )),
            };
            Ok(tokio::spawn(async move {
                let _proxy = proxy;
                tokio::select! {
                    end = &mut channel => {
                        let end = end.unwrap_or(owner::End::Eof);
                        // the sidecar's stderr before it is stopped; the reason is there before the job is ended
                        let stderr = sidecar.stderr();
                        let first = format!("infra: proxy: {}", owner::end_reason(&end, None, &stderr));
                        let _ = crate::linux::jobexec::kill_reason(&dir, &first);
                        let code = take_down(container.as_deref(), sidecar, &name).await;
                        let full = format!("infra: proxy: {}", owner::end_reason(&end, code, &stderr));
                        let _ = crate::linux::jobexec::kill_reason(&dir, &full);
                        eprintln!("sleipnir job-helper: {full}");
                    }
                    _ = ended => {
                        take_down(container.as_deref(), sidecar, &name).await;
                        channel.abort();
                    }
                }
            }))
        })?;
        Ok(Relay {
            runtime,
            watch,
            job_ended: Some(job_ended),
        })
    }

    /// After the job: the job's container, then the sidecar, then the runtime.
    pub fn end(mut self) {
        if let Some(tx) = self.job_ended.take() {
            let _ = tx.send(());
        }
        let watch = self.watch;
        let _ = self.runtime.block_on(watch);
        self.runtime.shutdown_background();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::future::Future;
    use std::io;
    use std::net::SocketAddr;
    use std::pin::Pin;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

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

        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (tx, rx) = tokio::sync::mpsc::channel(4);
            let _p = start_proxy(
                allow_list("meta.example.test:80").unwrap(),
                Some(Arc::new(LinkLocal)),
                rx,
            );
            for req in [
                &b"CONNECT meta.example.test:80 HTTP/1.1\r\nHost: meta.example.test:80\r\n\r\n"[..],
                // and a name not on the list is refused too
                &b"CONNECT other.example.test:80 HTTP/1.1\r\n\r\n"[..],
            ] {
                let (mut ours, theirs) = tokio::io::duplex(4096);
                let (_gone_tx, gone) = tokio::sync::oneshot::channel();
                tx.send(proxy::Relayed { io: theirs, gone }).await.unwrap();
                ours.write_all(req).await.unwrap();
                let mut answer = String::new();
                ours.read_to_string(&mut answer).await.unwrap();
                assert!(answer.starts_with("HTTP/1.1 403"), "{answer:?}");
            }
        });
    }

    /// [D] The helper's proxy takes twice the relay's streams before it holds a connection back.
    #[test]
    fn the_helpers_proxy_cap_is_twice_the_streams() {
        assert_eq!(proxy_config(vec![]).max_conns, 128);
    }
}
