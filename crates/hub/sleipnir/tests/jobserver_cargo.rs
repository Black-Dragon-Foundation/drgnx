//! Task 10a: a real `cargo build` follows a jobserver whose pool grows while it runs. The fixture workspace has six
//! crates with no dependencies; each build script announces itself and waits for the test to let it go, so the test
//! counts how many run at once without timing anything: one while the pool holds none, and more once the pool is given
//! tokens mid-build. The build scripts are the gate, never a sleep in the test's own assertions.

#![cfg(all(target_os = "linux", feature = "linux"))]

use std::ffi::OsStr;
use std::path::Path;
use std::time::Duration;

use sleipnir::linux::jobserver::{FLAGS, INSIDE, Pool};

mod support;

const CRATES: usize = 6;

/// A build script that makes `$GATE/started/<crate>`, then waits for `$GATE/release`.
const BUILD_RS: &str = r#"
use std::path::PathBuf;
fn main() {
    let gate = PathBuf::from(std::env::var_os("GATE").expect("GATE"));
    let name = std::env::var("CARGO_PKG_NAME").unwrap();
    std::fs::write(gate.join("started").join(&name), b"").unwrap();
    while !gate.join("release").exists() {
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}
"#;

fn started(gate: &Path) -> usize {
    std::fs::read_dir(gate.join("started")).map_or(0, Iterator::count)
}

/// Waits until at least N build scripts have started; the build's own end is the only other way out.
fn wait_started(gate: &Path, n: usize, build: &mut std::process::Child) {
    let deadline = stund::now() + Duration::from_secs(120);
    while started(gate) < n {
        if let Some(status) = build.try_wait().unwrap() {
            panic!(
                "the build ended ({status}) with {} build scripts started, wanted {n}",
                started(gate)
            );
        }
        assert!(
            stund::now() < deadline,
            "only {} build scripts started, wanted {n}",
            started(gate)
        );
        stund::sleep_blocking(Duration::from_millis(25));
    }
}

// [D] a real build of a zero-dependency fixture: the pool's size when it wants a job is the parallelism it gets
#[test]
fn cargo_follows_a_jobserver_that_grows_mid_build() {
    let t = tempfile::tempdir().unwrap();
    let ws = t.path().join("ws");
    let gate = t.path().join("gate");
    for d in [&ws, &gate.join("started")] {
        std::fs::create_dir_all(d).unwrap();
    }
    let members: Vec<String> = (0..CRATES).map(|i| format!("\"c{i}\"")).collect();
    sleipnir::fsio::write(
        ws.join("Cargo.toml"),
        format!(
            "[workspace]\nresolver = \"2\"\nmembers = [{}]\n",
            members.join(", ")
        ),
    )
    .unwrap();
    for i in 0..CRATES {
        let c = ws.join(format!("c{i}"));
        std::fs::create_dir_all(c.join("src")).unwrap();
        sleipnir::fsio::write(
            c.join("Cargo.toml"),
            format!(
                "[package]\nname = \"c{i}\"\nversion = \"0.0.0\"\nedition = \"2021\"\nbuild = \"build.rs\"\n"
            ),
        )
        .unwrap();
        sleipnir::fsio::write(c.join("src/lib.rs"), "").unwrap();
        sleipnir::fsio::write(c.join("build.rs"), BUILD_RS).unwrap();
    }

    // an empty pool: the build has its own one job and no token to take
    let mut pool = Pool::open(&t.path().join("pool")).unwrap();
    assert_eq!(pool.set_target(0).unwrap(), 0);
    let flags = FLAGS.replace(INSIDE, &pool.path().display().to_string());
    let mut spec = support::spec(
        "cargo",
        &["build", "--offline", "--workspace"],
        &[
            ("CARGO_MAKEFLAGS", OsStr::new(&flags)),
            ("MAKEFLAGS", OsStr::new(&flags)),
            ("CARGO_HOME", t.path().join("cargo-home").as_os_str()),
            ("CARGO_TARGET_DIR", t.path().join("target").as_os_str()),
            ("GATE", gate.as_os_str()),
        ],
    );
    spec.cwd = Some(ws);
    spec.env.retain(|(k, _)| k != "CARGO_BUILD_JOBS");
    let mut build = support::start(&spec, false, draugr::Redirect::Null, draugr::Redirect::Null);

    wait_started(&gate, 1, &mut build);
    assert_eq!(started(&gate), 1, "no token: one build script at a time");
    // the budget grew: tokens appear in the fifo while the build waits for one
    assert_eq!(
        pool.set_target(CRATES as u32 - 1).unwrap(),
        CRATES as u32 - 1
    );
    wait_started(&gate, CRATES, &mut build);
    sleipnir::fsio::write(gate.join("release"), b"").unwrap();
    let status = build.wait().unwrap();
    assert!(status.success(), "{status}");
}
