//! `cargo xtask standards` against a fixture workspace (fixtures/ws): one planted violation per rule, each shown
//! rejected, and the owner's silencing shown accepted. Each test runs the xtask binary on its own copy of the fixture.

use std::path::Path;
use std::process::Command;

fn copy(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for e in std::fs::read_dir(from).unwrap().flatten() {
        let (src, dst) = (e.path(), to.join(e.file_name()));
        if src.is_dir() {
            copy(&src, &dst);
        } else {
            std::fs::copy(&src, &dst).unwrap();
        }
    }
}

/// A fresh copy of the fixture, its clippy.toml files written (`--write`).
fn fixture() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    copy(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/ws"),
        dir.path(),
    );
    run(dir.path(), &["--write"]);
    dir
}

/// The exit code and stdout of `xtask standards --root DIR ARGS`.
fn run(dir: &Path, args: &[&str]) -> (i32, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_xtask"))
        .arg("standards")
        .arg("--root")
        .arg(dir)
        .args(args)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr);
    (out.status.code().unwrap_or(-1), format!("{stdout}{stderr}"))
}

fn lines<'a>(out: &'a str, file: &str, tag: &str) -> Vec<&'a str> {
    out.lines()
        .filter(|l| l.starts_with(&format!("{file}:")) && l.contains(tag))
        .collect()
}

#[test]
fn table_row_missing_doc_fails() {
    let ws = fixture();
    std::fs::remove_file(ws.path().join("docs/develop/standards/logging.md")).unwrap();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    assert!(
        out.contains("standards.toml:1: [standards/table] `logging`: its doc page docs/develop/standards/logging.md is missing"),
        "{out}"
    );
}

#[test]
fn allow_outside_owner_fails() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    let allows = lines(&out, "crates/bad/src/allow.rs", "/allow]");
    // the allow of disallowed_methods, and the expect of print_stdout inside a cfg_attr
    assert_eq!(allows.len(), 2, "{out}");
    assert!(allows[1].contains("[logging/allow]"), "{out}");
}

#[test]
fn allow_inside_owner_passes() {
    let ws = fixture();
    let (_, out) = run(ws.path(), &[]);
    assert!(out.contains("enforced finding(s)"), "{out}");
    assert!(
        !out.lines().any(|l| l.starts_with("crates/owner/")),
        "{out}"
    );
    assert!(
        !out.lines().any(|l| l.starts_with("crates/villa/")),
        "{out}"
    );
}

#[test]
fn string_error_in_pub_fn_fails() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    let hits = lines(
        &out,
        "crates/bad/src/strings.rs",
        "[errors/no-string-error]",
    );
    // `pub fn f`, not the private one
    assert_eq!(hits.len(), 1, "{out}");
    assert!(hits[0].starts_with("crates/bad/src/strings.rs:1:"), "{out}");
    assert!(
        hits[0].ends_with("(docs/develop/standards/errors.md)"),
        "{out}"
    );
}

#[test]
fn let_underscore_result_fails() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    let hits = lines(
        &out,
        "crates/bad/src/underscore.rs",
        "[errors/no-let-underscore-result]",
    );
    assert_eq!(hits.len(), 1, "{out}");
    assert!(
        hits[0].starts_with("crates/bad/src/underscore.rs:2:"),
        "{out}"
    );
}

#[test]
fn lint_catches_reexport_and_alias() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    // `C::new` through `use … as`, `Command::new` through a glob, and one inside `vec![…]`
    let paths = lines(
        &out,
        "crates/bad/src/alias.rs",
        "[processes/disallowed-path]",
    );
    let at: Vec<&str> = paths.iter().map(|l| l.split(':').nth(1).unwrap()).collect();
    assert_eq!(at, ["6", "14", "19"], "{out}");
    // `type R<T> = Result<T, String>`
    assert_eq!(
        lines(&out, "crates/bad/src/alias.rs", "[errors/no-string-error]").len(),
        1,
        "{out}"
    );
}

#[test]
fn layer_violation_fails() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    assert!(
        out.contains(
            "crates/app/Cargo.toml:7: [standards/layer] `app` may not depend on `glitnir`"
        ),
        "{out}"
    );
}

#[test]
fn cli_out_is_the_only_printer() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    assert_eq!(
        lines(&out, "crates/bad/src/print.rs", "[logging/no-print]").len(),
        1,
        "{out}"
    );
}

#[test]
fn env_home_literal_fails() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    assert_eq!(
        lines(&out, "crates/bad/src/home.rs", "[paths/no-env-home]").len(),
        1,
        "{out}"
    );
}

#[test]
fn blocking_recv_on_ui_fails() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    // the blocking recv only: not the awaited one, not try_recv
    let hits = lines(
        &out,
        "crates/uiapp/src/lib.rs",
        "[concurrency/no-blocking-recv-on-ui]",
    );
    assert_eq!(hits.len(), 1, "{out}");
    assert!(hits[0].starts_with("crates/uiapp/src/lib.rs:2:"), "{out}");
}

#[test]
fn derive_debug_on_token_type_fails_scan() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    // ApiToken; not WrappedToken (every field a Secret), not PlainKey (no Debug), not CacheKey (numbers only)
    let hits = lines(
        &out,
        "crates/bad/src/secret.rs",
        "[data-hygiene/secret-has-redact]",
    );
    assert_eq!(hits.len(), 1, "{out}");
    assert!(hits[0].contains("`ApiToken`"), "{out}");
}

#[test]
fn generated_clippy_config_is_checked() {
    let ws = fixture();
    let bad = std::fs::read_to_string(ws.path().join("crates/bad/clippy.toml")).unwrap();
    let owner = std::fs::read_to_string(ws.path().join("crates/owner/clippy.toml")).unwrap();
    assert!(bad.contains("std::process::Command::new"), "{bad}");
    // the owner's own rows are not in its file
    assert!(!owner.contains("std::process::Command::new"), "{owner}");
    std::fs::write(
        ws.path().join("crates/bad/clippy.toml"),
        "disallowed-methods = []\n",
    )
    .unwrap();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    assert!(
        out.contains("crates/bad/clippy.toml:1: [standards/clippy-config]"),
        "{out}"
    );
}

#[test]
fn changed_scans_only_the_named_files() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &["--changed", "crates/bad/src/print.rs"]);
    assert_eq!(code, 1, "{out}");
    assert!(out.contains("crates/bad/src/print.rs:2:"), "{out}");
    assert!(!out.contains("crates/bad/src/alias.rs"), "{out}");
}

#[test]
fn commit_msg_freezes_a_crate_not_clean() {
    let ws = fixture();
    let table = ws.path().join("standards.toml");
    let text = std::fs::read_to_string(&table).unwrap();
    std::fs::write(&table, text.replace("bad = { clean = true }", "bad = {}")).unwrap();
    let msg = ws.path().join("MSG");
    std::fs::write(&msg, "bad: a feature\n").unwrap();
    let file = "crates/bad/src/print.rs";
    let (code, out) = run(ws.path(), &["--commit-msg", msg.to_str().unwrap(), file]);
    assert_eq!(code, 1, "{out}");
    assert!(out.contains("touches bad, not clean yet"), "{out}");
    std::fs::write(&msg, "migrate(bad): prints through the owner\n").unwrap();
    assert_eq!(
        run(ws.path(), &["--commit-msg", msg.to_str().unwrap(), file]).0,
        0
    );
    std::fs::write(&msg, "owner: a feature\n").unwrap();
    assert_eq!(
        run(
            ws.path(),
            &[
                "--commit-msg",
                msg.to_str().unwrap(),
                "crates/owner/src/lib.rs"
            ]
        )
        .0,
        0
    );
}

#[test]
fn raw_key_event_outside_lykill_fails() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    let hits = lines(&out, "crates/bad/src/keys.rs", "[keys/no-raw-key-event]");
    // the type in the signature (line 3) and the `Event::Key` pattern (line 7); not `Event` alone
    let at: Vec<&str> = hits.iter().map(|l| l.split(':').nth(1).unwrap()).collect();
    assert_eq!(at, ["3", "7"], "{out}");
    // the owner may read them
    assert!(
        !out.lines()
            .any(|l| l.starts_with("crates/villa/") && l.contains("no-raw-key-event")),
        "{out}"
    );
}

#[test]
fn colour_literal_fails() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    let hits = lines(&out, "crates/bad/src/colour.rs", "[kit/no-colour-literal]");
    // the hex string and `rgb(1, 2, 3)`; not "#hashtag"; then the hex numbers used as colours: a const named for a colour,
    // `paint(0xff8800aa)` is not (it names no colour), `Rgba::new(1, 2, 3, 4)`, a field named `color`; not a mask or `0x0f0f`,
    // not `Colour::Ansi(1)` (a palette index)
    let at: Vec<&str> = hits.iter().map(|l| l.split(':').nth(1).unwrap()).collect();
    assert_eq!(at, ["1", "5", "8", "13", "15", "18"], "{out}");
    assert!(
        !out.lines()
            .any(|l| l.starts_with("crates/villa/") && l.contains("no-colour-literal")),
        "{out}"
    );
}

#[test]
fn hand_written_luau_binding_fails() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    let hits = lines(
        &out,
        "crates/bad/src/luau.rs",
        "[api-versioning/no-hand-luau-binding]",
    );
    assert_eq!(hits.len(), 1, "{out}");
    assert!(hits[0].starts_with("crates/bad/src/luau.rs:3:"), "{out}");
    assert!(
        !out.lines()
            .any(|l| l.starts_with("crates/villa/") && l.contains("no-hand-luau-binding")),
        "{out}"
    );
}

#[test]
fn command_without_a_doc_fails() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    // the empty doc (line 1) and the missing one (line 3); not the one with text, not the owner's own
    let hits = lines(
        &out,
        "crates/bad/src/command.rs",
        "[commands/command-has-doc]",
    );
    let at: Vec<&str> = hits.iter().map(|l| l.split(':').nth(1).unwrap()).collect();
    assert_eq!(at, ["1", "3"], "{out}");
    assert!(
        !out.lines()
            .any(|l| l.starts_with("crates/villa/") && l.contains("command-has-doc")),
        "{out}"
    );
}

#[test]
fn a_hand_made_scale_multiplication_fails() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    // `x * scale`, `… * s.scale_factor`, `s.zoom_scale() * 2.0`, `d *= scale` and `scale as f32 * x`; not `x * 2.0`.
    // The rule is for UI crates: a non-UI crate's `sum * scale` (villa's quantiser step) is no finding.
    let hits = lines(
        &out,
        "crates/uiapp/src/scale.rs",
        "[scale-zoom/no-raw-scale-mul]",
    );
    let at: Vec<&str> = hits.iter().map(|l| l.split(':').nth(1).unwrap()).collect();
    assert_eq!(at, ["2", "3", "4", "6", "7"], "{out}");
    assert!(
        !out.lines().any(|l| !l.starts_with("crates/uiapp/")
            && !l.starts_with("crates/ui/")
            && l.contains("no-raw-scale-mul")),
        "{out}"
    );
}

/// A drawing crate under `crates/ui/` that is not marked `ui = true` (glitnir is one) is still a UI crate for the scale
/// rule: its raw `x * scale` is a finding.
#[test]
fn a_raw_scale_multiply_under_crates_ui_fails_without_the_ui_mark() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    let hits = lines(
        &out,
        "crates/ui/canvas/src/lib.rs",
        "[scale-zoom/no-raw-scale-mul]",
    );
    assert_eq!(hits.len(), 1, "{out}");
}

/// Review Focus 1: a closure given to a formula or registered as a callback that captures a shared cell, a lock or a
/// channel is an observer outside tafl, and so is a channel held as UI state; a plain capture and an iterator's closure
/// are not.
#[test]
fn a_formula_capturing_a_mutex_fails_the_scan() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    let hits = lines(
        &out,
        "crates/reactive/src/lib.rs",
        "[ui-reactivity/no-ui-observer]",
    );
    let at: Vec<&str> = hits.iter().map(|l| l.split(':').nth(1).unwrap()).collect();
    // Rc<RefCell>, an Arc<Mutex>'s clone in a callback, a channel's end, a typed Rc<RefCell>, a channel as state
    assert_eq!(at, ["7", "10", "12", "14", "21"], "{out}");
    // the owner (villa in the fixture) is not scanned for its own standard
    assert!(
        !out.lines()
            .any(|l| l.starts_with("crates/villa/") && l.contains("ui-reactivity")),
        "{out}"
    );
}

/// G8's lint: a hook, signal or dependency-list API does not exist in UI code; a Unix `signal` or a `use_store` setter
/// is not one.
#[test]
fn use_effect_named_api_fails_the_scan() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    let hits = lines(
        &out,
        "crates/reactive/src/lib.rs",
        "[ui-reactivity/no-dependency-list-api]",
    );
    let at: Vec<&str> = hits.iter().map(|l| l.split(':').nth(1).unwrap()).collect();
    assert_eq!(at, ["25", "27", "31"], "{out}");
}

#[test]
fn open_options_open_fails_scan_like_clippy_does() {
    let ws = fixture();
    let (code, out) = run(ws.path(), &[]);
    assert_eq!(code, 1, "{out}");
    // `OpenOptions::new()….open(p)` and `File::options()….open(p)`; not `File::open(p)`
    let hits = lines(
        &out,
        "crates/bad/src/open.rs",
        "[processes/disallowed-path]",
    );
    let at: Vec<&str> = hits.iter().map(|l| l.split(':').nth(1).unwrap()).collect();
    assert_eq!(at, ["4", "5"], "{out}");
}
