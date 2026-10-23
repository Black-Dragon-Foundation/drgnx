//! TLS through the platform verifier (Task 19). A test binary of its own: `SSL_CERT_FILE` is set once, before any
//! `Upstream::new`, because rustls-platform-verifier finds the Linux store through rustls-native-certs, which loads
//! only from `SSL_CERT_FILE`/`SSL_CERT_DIR` when they are set. The tests are Linux-only for that reason.
#![cfg(target_os = "linux")]

mod common;

use std::sync::OnceLock;
use std::sync::atomic::Ordering;

use bifrost::upstream::{Upstream, UpstreamError, UpstreamOpts};
use bytes::Bytes;
use common::{Ca, localhost_leaf, make_ca, make_leaf, tls_server};
use http_body_util::{BodyExt, Full};
use hyper_util::client::proxy::matcher::Matcher;

struct Fixture {
    ca: Ca,
    _dir: tempfile::TempDir,
}

/// The trusted CA, written to a temp dir and named by `SSL_CERT_FILE`. Built once, before the first client.
fn fixture() -> &'static Fixture {
    static FIXTURE: OnceLock<Fixture> = OnceLock::new();
    FIXTURE.get_or_init(|| {
        let ca = make_ca("bifrost test ca");
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ca.pem");
        std::fs::write(&path, &ca.pem).unwrap();
        // SAFETY: every test calls `fixture()` before it reads the environment or builds a client, and
        // `get_or_init` blocks them until this has run.
        unsafe { std::env::set_var("SSL_CERT_FILE", &path) };
        Fixture { ca, _dir: dir }
    })
}

fn client() -> Upstream {
    fixture();
    // An empty matcher: the environment's proxy settings must not matter here.
    Upstream::with_proxy(UpstreamOpts::default(), Matcher::builder().build()).unwrap()
}

fn get(port: u16) -> http::Request<Full<Bytes>> {
    http::Request::get(format!("https://localhost:{port}/"))
        .body(Full::new(Bytes::new()))
        .unwrap()
}

#[tokio::test]
async fn https_with_the_fixture_ca_through_ssl_cert_file() {
    let srv = tls_server(localhost_leaf(&fixture().ca)).await;
    let resp = client().send(get(srv.port)).await.unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(
        &resp.into_body().collect().await.unwrap().to_bytes()[..],
        b"ok"
    );
    assert_eq!(srv.requests.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn an_unknown_ca_is_refused() {
    let other = make_ca("some other ca");
    let srv = tls_server(localhost_leaf(&other)).await;
    let err = client().send(get(srv.port)).await.unwrap_err();
    assert!(matches!(err, UpstreamError::Tls(_)), "{err}");
    assert_eq!(
        srv.requests.load(Ordering::SeqCst),
        0,
        "no request bytes may reach an unverified server"
    );
}

#[tokio::test]
async fn a_wrong_hostname_is_refused() {
    let leaf = make_leaf(
        &fixture().ca,
        &["wrong.test"],
        false,
        (2020, 1, 1),
        (2046, 1, 1),
    );
    let srv = tls_server(leaf).await;
    let err = client().send(get(srv.port)).await.unwrap_err();
    assert!(matches!(err, UpstreamError::Tls(_)), "{err}");
    assert_eq!(srv.requests.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn an_expired_leaf_is_refused() {
    let leaf = make_leaf(
        &fixture().ca,
        &["localhost"],
        true,
        (2019, 1, 1),
        (2020, 1, 1),
    );
    let srv = tls_server(leaf).await;
    let err = client().send(get(srv.port)).await.unwrap_err();
    assert!(matches!(err, UpstreamError::Tls(_)), "{err}");
    assert_eq!(srv.requests.load(Ordering::SeqCst), 0);
}
