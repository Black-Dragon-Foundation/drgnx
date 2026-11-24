//! The crate's integration tests, one binary (`cargo test -p norn --test it`; a file's rows are `<file>::<test>`).
//! Each `tests/<name>.rs` is a module below, so the lib links once, not once per file. A file that needs a
//! process of its own is a `[[test]]` of its own in Cargo.toml, with the reason there, and is named in `APART`.

mod canary;
mod entity_vec_fingerprint;
mod entity_vec_schema8;
mod parity;
mod parsed;
mod plugin_hooks;
mod tools;
mod tools_schema;
mod tracker_tools;

/// The test files that are binaries of their own (Cargo.toml says why).
const APART: &[&str] = &[];

/// `autotests = false` means a file nobody lists never runs, and nothing says so: a new `tests/*.rs` must be a `mod`
/// line above, or (process of its own) a `[[test]]` in Cargo.toml and a name in `APART`.
#[test]
fn every_test_file_is_a_module_here_or_a_declared_binary() {
    let main = include_str!("main.rs");
    let manifest = include_str!("../Cargo.toml");
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests");
    let mut unlisted = Vec::new();
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_none_or(|e| e != "rs") {
            continue;
        }
        let name = path.file_stem().unwrap().to_str().unwrap().to_owned();
        if name == "main" {
            continue;
        }
        let listed = if APART.contains(&name.as_str()) {
            manifest.contains(&format!("name = \"{name}\""))
        } else {
            main.lines().any(|l| l.trim() == format!("mod {name};"))
        };
        if !listed {
            unlisted.push(format!("tests/{name}.rs"));
        }
    }
    unlisted.sort();
    assert!(
        unlisted.is_empty(),
        "no `mod` line in tests/main.rs (or no [[test]] for an APART file): {unlisted:?}"
    );
}

/// TEXT as the file at PATH, written through eitri (the files standard); the test's failure otherwise.
pub(crate) fn put_file(path: impl AsRef<std::path::Path>, text: impl AsRef<[u8]>) {
    eitri::replace_file(path.as_ref(), text.as_ref()).unwrap();
}

/// The text of the file at PATH, read through eitri (a regular file, no link in the path); the test's failure
/// otherwise.
pub(crate) fn read_file(path: impl AsRef<std::path::Path>) -> String {
    eitri::read_string(path.as_ref(), 16 << 20).unwrap()
}

/// The repository's `test/fixtures`, its checkout's own links resolved first (eitri refuses a link in any component).
pub(crate) fn fixtures() -> std::path::PathBuf {
    std::fs::canonicalize(env!("CARGO_MANIFEST_DIR"))
        .unwrap()
        .join("../../../test/fixtures")
}

/// PROGRAM run with ARGS in CWD and exactly the environment ENV, to its end (a minute at most): through draugr, on a
/// thread of its own, since a test that calls this may already run inside a runtime.
pub(crate) fn run_child(
    program: impl Into<std::path::PathBuf>,
    args: &[&str],
    cwd: &std::path::Path,
    env: Vec<(std::ffi::OsString, std::ffi::OsString)>,
) -> draugr::Output {
    let spec = draugr::Spec {
        program: program.into(),
        args: args.iter().map(std::ffi::OsString::from).collect(),
        env,
        cwd: Some(cwd.to_path_buf()),
        stdin_null: true,
        pass_fds: Vec::new(),
        new_session: false,
    };
    saman::spawn_thread("test-child", move || {
        draugr::run(spec, std::time::Duration::from_secs(60))
    })
    .unwrap()
    .join()
    .unwrap()
    .unwrap()
}
