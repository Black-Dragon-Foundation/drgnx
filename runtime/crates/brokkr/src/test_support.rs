//! Test plugins, built from `runtime/plugins/fixtures` at test time (never committed as binaries).
//!
//! `fixture(name)` returns an install folder (`plugin.json` and `plugin.wasm`) that `scan` reads. The first call in
//! a process builds every fixture with one `cargo build --target wasm32-wasip2 --release`, under a lock file, so
//! parallel tests and parallel test binaries build once. The target must be installed (`rustup target add
//! wasm32-wasip2`).

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicUsize, Ordering};

use rustix::fs::{FlockOperation, flock};

/// How many times this process ran the fixtures' build.
static BUILDS: AtomicUsize = AtomicUsize::new(0);
static FIXTURES: OnceLock<Result<(), String>> = OnceLock::new();
static TEMPLATE: OnceLock<Result<(), String>> = OnceLock::new();

fn runtime_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn fixtures_dir() -> PathBuf {
    runtime_dir().join("plugins/fixtures")
}

fn out_dir() -> PathBuf {
    runtime_dir().join("target/plugin-fixtures")
}

/// The install folder of the fixture `name` (a file of `plugins/fixtures/manifests`, without `.json`).
pub fn fixture(name: &str) -> PathBuf {
    let manifest = fixtures_dir()
        .join("manifests")
        .join(format!("{name}.json"));
    assert!(manifest.is_file(), "no fixture {name}");
    FIXTURES
        .get_or_init(|| {
            BUILDS.fetch_add(1, Ordering::SeqCst);
            build(&fixtures_dir(), "fixtures", install_fixtures)
        })
        .as_ref()
        .unwrap_or_else(|e| panic!("building the fixtures: {e}"));
    out_dir().join("plugins").join(name)
}

/// The install folder of the template plugin (`plugins/template`), built the same way.
pub fn template() -> PathBuf {
    TEMPLATE
        .get_or_init(|| {
            build(&runtime_dir().join("plugins/template"), "template", |out| {
                let dir = out.join("plugins/my-plugin");
                let release = out.join("build/wasm32-wasip2/release");
                copy(
                    &runtime_dir().join("plugins/template/plugin.json"),
                    &dir.join("plugin.json"),
                )?;
                copy(&release.join("my_plugin.wasm"), &dir.join("plugin.wasm"))
            })
        })
        .as_ref()
        .unwrap_or_else(|e| panic!("building the template: {e}"));
    out_dir().join("template/plugins/my-plugin")
}

fn install_fixtures(out: &Path) -> Result<(), String> {
    let manifests = fixtures_dir().join("manifests");
    let release = out.join("build/wasm32-wasip2/release");
    let entries = fs::read_dir(&manifests).map_err(|e| format!("{}: {e}", manifests.display()))?;
    for entry in entries {
        let path = entry.map_err(|e| e.to_string())?.path();
        let Some(name) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        let dir = out.join("plugins").join(name);
        copy(&path, &dir.join("plugin.json"))?;
        copy(
            &release.join(format!("{name}.wasm")),
            &dir.join("plugin.wasm"),
        )?;
    }
    Ok(())
}

fn copy(from: &Path, to: &Path) -> Result<(), String> {
    if let Some(dir) = to.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    fs::copy(from, to)
        .map(drop)
        .map_err(|e| format!("copy {}: {e}", from.display()))
}

/// Builds the crate at `crate_dir` into `<out>/<label>`, then runs `install` on that folder, all under the lock.
fn build(
    crate_dir: &Path,
    label: &str,
    install: impl FnOnce(&Path) -> Result<(), String>,
) -> Result<(), String> {
    let root = out_dir();
    let out = if label == "fixtures" {
        root.clone()
    } else {
        root.join(label)
    };
    fs::create_dir_all(&root).map_err(|e| format!("{}: {e}", root.display()))?;
    let lock = fs::File::create(root.join(format!("{label}.lock"))).map_err(|e| e.to_string())?;
    flock(&lock, FlockOperation::LockExclusive).map_err(|e| format!("lock: {e}"))?;
    let mut cargo = Command::new(std::env::var_os("CARGO").unwrap_or_else(|| "cargo".into()));
    cargo
        .args([
            "build",
            "--release",
            "--target",
            "wasm32-wasip2",
            "--manifest-path",
        ])
        .arg(crate_dir.join("Cargo.toml"))
        .arg("--target-dir")
        .arg(out.join("build"));
    if crate_dir.join("Cargo.lock").is_file() {
        cargo.arg("--locked");
    }
    let run = cargo.output().map_err(|e| format!("running cargo: {e}"))?;
    if !run.status.success() {
        return Err(format!(
            "cargo build of {label} failed ({}); is the wasm32-wasip2 target installed?\n{}",
            run.status,
            String::from_utf8_lossy(&run.stderr)
        ));
    }
    install(&out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{parse, scan};

    // Pattern D (pure): reads files and parses them; no build, no clock.
    #[test]
    fn every_fixture_manifest_parses_and_has_its_binary() {
        let manifests = fixtures_dir().join("manifests");
        let mut seen = 0;
        for entry in fs::read_dir(&manifests).unwrap() {
            let path = entry.unwrap().path();
            let name = path.file_stem().unwrap().to_str().unwrap().to_string();
            let m = parse(&fs::read(&path).unwrap()).unwrap_or_else(|e| panic!("{name}: {e}"));
            assert_eq!(m.name.as_str(), name, "a manifest is named after its file");
            assert!(
                fixtures_dir().join(format!("src/bin/{name}.rs")).is_file(),
                "{name} has no source"
            );
            seen += 1;
        }
        assert_eq!(seen, 11, "the fixtures the plan names");
    }

    #[test]
    fn the_template_manifest_parses() {
        let raw = fs::read(runtime_dir().join("plugins/template/plugin.json")).unwrap();
        let m = parse(&raw).unwrap();
        assert_eq!((m.abilities.len(), m.hooks.len()), (1, 1));
    }

    // Pattern B (gate): the lock file and the per-process once decide who builds; every thread waits on the same
    // result.
    #[test]
    fn fixtures_build_once() {
        let folders: Vec<PathBuf> = std::thread::scope(|s| {
            let hs: Vec<_> = (0..8)
                .map(|i| {
                    s.spawn(move || {
                        fixture(if i % 2 == 0 {
                            "echo-ability"
                        } else {
                            "slow-hook"
                        })
                    })
                })
                .collect();
            hs.into_iter().map(|h| h.join().unwrap()).collect()
        });
        assert_eq!(BUILDS.load(Ordering::SeqCst), 1, "built more than once");
        assert!(folders.iter().all(|f| f.join("plugin.wasm").is_file()));
        // every fixture is a component, and `scan` reads the folder it was installed to
        let root = out_dir().join("plugins");
        let found = scan(&root);
        assert_eq!(
            found.len(),
            11,
            "{:?}",
            found
                .iter()
                .filter_map(|r| r.as_ref().err())
                .collect::<Vec<_>>()
        );
        for r in found {
            let installed = r.unwrap();
            let wasm = fs::read(installed.dir.join("plugin.wasm")).unwrap();
            // magic, version 0x0d, layer 1: a component, not a core module
            assert_eq!(
                wasm[..8],
                [0, b'a', b's', b'm', 0x0d, 0, 0x01, 0],
                "{}",
                installed.dir.display()
            );
        }
    }

    #[test]
    fn the_template_builds() {
        let folder = template();
        let found = scan(folder.parent().unwrap());
        assert_eq!(found.len(), 1);
        assert_eq!(
            found[0].as_ref().unwrap().manifest.name.as_str(),
            "my-plugin"
        );
    }
}
