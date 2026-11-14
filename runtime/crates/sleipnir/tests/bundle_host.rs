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

/// [D] Each of the bundle's binaries is static (the relay sidecar `drgnx-px` among them), and `drgnx-key` runs in a
/// musl image: with no key socket mounted it exits 75 (not delivered).
#[test]
#[ignore = "bundle"]
fn bundle_binaries_are_static_and_run_in_a_foreign_libc_image() {
    let bundle = PathBuf::from(need("DRGNX_TEST_BUNDLE"));
    let image = need("DRGNX_TEST_FOREIGN_IMAGE");
    let px = format!("drgnx-px-{}-linux-musl", std::env::consts::ARCH);
    for b in ["sleipnir", "drgnx-key", px.as_str()] {
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
    let out = Command::new("podman")
        .args(["run", "--rm", "--pull=never", "--network=none", "-v"])
        .arg(format!(
            "{}:/run/drgnx/key:ro,Z",
            bundle.join("drgnx-key").display()
        ))
        .args(["--entrypoint", "/run/drgnx/key", &image, "get", "NONE"])
        .output()
        .unwrap();
    let err = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(75), "{err}");
    assert!(err.contains("drgnx-key: the key socket"), "{err}");
}
