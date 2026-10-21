//! `ratatoskr sandbox check` and the doctor's `sandbox` section through the real binary, in the reduced tier (the
//! container has no bwrap that works; the full tier's real run is the row `any/works`, Task 14).
// Linux only: the reduced tier is Linux's (Android: no backend; fails closed).
#![cfg(target_os = "linux")]

use std::process::{Command, Output, Stdio};

const RATATOSKR: &str = env!("CARGO_BIN_EXE_ratatoskr");

fn abi_9(test: &str) -> bool {
    let abi = gleipnir::landlock::kernel_abi();
    if abi < 9 {
        eprintln!("SKIP {test}: the kernel's Landlock ABI is {abi}, the reduced tier needs 9");
    }
    abi >= 9
}

fn run(args: &[&str]) -> Output {
    let home = tempfile::tempdir().unwrap();
    Command::new(RATATOSKR)
        .args(args)
        .env_clear()
        .env("HOME", home.path())
        .env("XDG_STATE_HOME", home.path().join("s"))
        .env("XDG_RUNTIME_DIR", home.path().join("r"))
        .env("PATH", "/usr/bin:/bin")
        .stdin(Stdio::null())
        .output()
        .unwrap()
}

#[test]
fn the_reduced_tier_passes_the_real_probe() {
    if !abi_9("the_reduced_tier_passes_the_real_probe") {
        return;
    }
    let out = run(&["sandbox", "check", "--tier", "reduced", "--json"]);
    let stderr = String::from_utf8_lossy(&out.stderr);
    let v: serde_json::Value = serde_json::from_slice(&out.stdout)
        .unwrap_or_else(|e| panic!("{e}: {} {stderr}", String::from_utf8_lossy(&out.stdout)));
    assert_eq!(v["ok"], true, "{v} {stderr}");
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(v["backend"], "reduced");
    assert_eq!(v["reason"], serde_json::Value::Null);
    assert_eq!(v["layers"]["landlock"], "enforced", "{v}");
    assert_eq!(v["layers"]["seccomp"], true);
    assert!(v["landlock_abi"].as_u64().unwrap() >= 9);

    let out = run(&["sandbox", "check", "--tier", "reduced"]);
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(
        text.starts_with("backend reduced: ok (Landlock ABI "),
        "{text}"
    );
    assert!(text.trim_end().ends_with(", seccomp)"), "{text}");
}

/// The probe leaves nothing behind in the temp dir.
#[test]
fn the_probe_dir_is_removed() {
    if !abi_9("the_probe_dir_is_removed") {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let out = Command::new(RATATOSKR)
        .args(["sandbox", "check", "--tier", "reduced"])
        .env_clear()
        .env("TMPDIR", tmp.path())
        .env("PATH", "/usr/bin:/bin")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0), "{:?}", out);
    assert_eq!(std::fs::read_dir(tmp.path()).unwrap().count(), 0);
}

#[test]
fn doctor_json_has_the_sandbox_section() {
    let start = std::time::Instant::now();
    let out = run(&["doctor", "--json"]);
    // The editor waits 2 s for this. A start that fails at once (bwrap in a container cannot mount /proc) must not
    // wait out the kill grace for a child nobody has reaped.
    assert!(
        start.elapsed() < std::time::Duration::from_millis(2500),
        "doctor took {:?}",
        start.elapsed()
    );
    assert_eq!(out.status.code(), Some(0));
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    let s = &v["sandbox"];
    for key in [
        "backend",
        "version",
        "ok",
        "reason",
        "fix",
        "landlock_abi",
        "in_use",
    ] {
        assert!(s.get(key).is_some(), "{key} in {s}");
    }
    assert_eq!(s["in_use"], false);
    // full tier here: ok, or a reason (the container comes first); never both
    assert_eq!(s["reason"].is_null(), s["ok"] == true, "{s}");
    let text = String::from_utf8(run(&["doctor"]).stdout).unwrap();
    assert!(text.contains("job sandbox backend: "), "{text}");
}

/// A bwrap that is not there: the full tier is refused with a reason (and the exit says so), never the reduced tier.
#[cfg(feature = "test-hooks")]
#[test]
fn the_full_tier_without_a_trusted_bwrap_says_why() {
    let out = run(&["sandbox", "check", "--bwrap", "/nonexistent/bwrap"]);
    assert_eq!(out.status.code(), Some(1));
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.starts_with("not available: "), "{text}");
    let out = run(&[
        "sandbox",
        "check",
        "--bwrap",
        "/nonexistent/bwrap",
        "--json",
    ]);
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["ok"], false);
    assert_eq!(v["backend"], "none");
    assert!(v["reason"].as_str().is_some_and(|r| !r.is_empty()), "{v}");
}
