//! Shared test helper for the TLS cases (Task 19; Tasks 21 and 24 reuse it): certificates made at run time with
//! `rcgen` (no key files are committed) and an in-test TLS server that counts the requests it was given.
#![allow(dead_code)]

use std::net::IpAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use rcgen::{
    BasicConstraints, CertificateParams, DnType, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair, KeyUsagePurpose,
    SanType, date_time_ymd,
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;

/// A certificate authority, valid 2020 to 2046.
pub struct Ca {
    issuer: Issuer<'static, KeyPair>,
    /// The CA certificate, PEM: what `SSL_CERT_FILE` points at.
    pub pem: String,
}

pub fn make_ca(name: &str) -> Ca {
    let key = KeyPair::generate().unwrap();
    let mut p = CertificateParams::new(Vec::<String>::new()).unwrap();
    p.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    p.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    p.distinguished_name.push(DnType::CommonName, name);
    p.not_before = date_time_ymd(2020, 1, 1);
    p.not_after = date_time_ymd(2046, 1, 1);
    let pem = p.self_signed(&key).unwrap().pem();
    Ca { issuer: Issuer::new(p, key), pem }
}

/// A server certificate and its key, ready for a rustls server config.
pub struct Leaf {
    pub chain: Vec<CertificateDer<'static>>,
    pub key: PrivateKeyDer<'static>,
}

/// A leaf signed by `ca` for the DNS `names` (and 127.0.0.1 when `loopback`), valid from `from` to `to` (y, m, d).
pub fn make_leaf(ca: &Ca, names: &[&str], loopback: bool, from: (i32, u8, u8), to: (i32, u8, u8)) -> Leaf {
    let key = KeyPair::generate().unwrap();
    let mut p = CertificateParams::new(Vec::<String>::new()).unwrap();
    for n in names {
        p.subject_alt_names.push(SanType::DnsName((*n).try_into().unwrap()));
    }
    if loopback {
        p.subject_alt_names.push(SanType::IpAddress(IpAddr::from([127, 0, 0, 1])));
    }
    p.distinguished_name.push(DnType::CommonName, names[0]);
    p.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    p.not_before = date_time_ymd(from.0, from.1, from.2);
    p.not_after = date_time_ymd(to.0, to.1, to.2);
    let cert = p.signed_by(&key, &ca.issuer).unwrap();
    Leaf {
        chain: vec![cert.der().clone()],
        key: PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der())),
    }
}

/// The ordinary good leaf: `localhost` and 127.0.0.1, 2020 to 2046.
pub fn localhost_leaf(ca: &Ca) -> Leaf {
    make_leaf(ca, &["localhost"], true, (2020, 1, 1), (2046, 1, 1))
}

/// An in-test HTTPS server on 127.0.0.1. `requests` counts the requests whose bytes reached it after a completed
/// handshake; a refused handshake leaves it at 0.
pub struct TlsServer {
    pub port: u16,
    pub requests: Arc<AtomicUsize>,
}

pub async fn tls_server(leaf: Leaf) -> TlsServer {
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(leaf.chain, leaf.key)
        .unwrap();
    let acceptor = TlsAcceptor::from(Arc::new(config));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let requests = Arc::new(AtomicUsize::new(0));
    let counter = requests.clone();
    tokio::spawn(async move {
        loop {
            let Ok((tcp, _)) = listener.accept().await else { return };
            let acceptor = acceptor.clone();
            let counter = counter.clone();
            tokio::spawn(async move {
                let Ok(mut tls) = acceptor.accept(tcp).await else { return };
                let mut buf = [0u8; 4096];
                if matches!(tls.read(&mut buf).await, Ok(n) if n > 0) {
                    counter.fetch_add(1, Ordering::SeqCst);
                    let _ = tls
                        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                        .await;
                    let _ = tls.shutdown().await;
                }
            });
        }
    });
    TlsServer { port, requests }
}
