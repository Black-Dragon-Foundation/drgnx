//! The static runner bundle in an image of another libc. It runs where the bundle was built
//! (`bin/drgnx build runner-bundle`, CI's container lane), with podman and a musl image:
//!
//! ```text
//! DRGNX_TEST_BUNDLE=runtime/target/bundle/x86_64 DRGNX_TEST_FOREIGN_IMAGE=docker.io/library/alpine@sha256:… \
//!   cargo test -p sleipnir --test bundle_host -- --ignored
//! ```
#![cfg(target_os = "linux")]

use std::path::PathBuf;
use std::process::Command;

fn need(var: &str) -> String {
    std::env::var(var)
        .unwrap_or_else(|_| panic!("{var} is not set: this row runs only beside a built bundle"))
}

/// [D] Each of the bundle's binaries is static, and the forwarder starts in a musl image and runs `drgnx-key` in its
/// place there: with no key socket mounted, drgnx-key exits 75 (not delivered), which the forwarder's exec passes on.
#[test]
#[ignore = "bundle"]
fn drgnx_fwd_static_runs_in_a_foreign_libc_image() {
    let bundle = PathBuf::from(need("DRGNX_TEST_BUNDLE"));
    let image = need("DRGNX_TEST_FOREIGN_IMAGE");
    for b in ["sleipnir", "drgnx-key", "drgnx-fwd"] {
        let out = Command::new("file")
            .arg("-L")
            .arg(bundle.join(b))
            .output()
            .unwrap();
        let text = String::from_utf8_lossy(&out.stdout);
        assert!(
            text.contains("statically linked") || text.contains("static-pie linked"),
            "{b}: {text}"
        );
    }
    let mount = |b: &str, at: &str| format!("{}:{at}:ro,Z", bundle.join(b).display());
    let out = Command::new("podman")
        .args(["run", "--rm", "--pull=never", "--network=none", "-v"])
        .arg(mount("drgnx-fwd", "/run/drgnx/fwd"))
        .arg("-v")
        .arg(mount("drgnx-key", "/run/drgnx/key"))
        .args(["--entrypoint", "/run/drgnx/fwd", &image])
        .args([
            "3128",
            "/run/drgnx/proxy.sock",
            "--",
            "/run/drgnx/key",
            "get",
            "NONE",
        ])
        .output()
        .unwrap();
    let err = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(75), "{err}");
    assert!(err.contains("drgnx-key: the key socket"), "{err}");
}
