//! The workspace's binaries, found from a test wherever cargo put the test's own binary.
//!
//! Cargo up to 1.99 put a test binary in `<target dir>/<profile>/deps/`; 1.100's build-dir layout puts it in
//! `<target dir>/<profile>/build/<package>/<hash>/out/`.  The workspace's binaries stay in `<target dir>/<profile>/`
//! in both, so a test finds that folder by its child on the way up (`deps` or `build`), never by a count of `..`.

use std::path::{Path, PathBuf};
use std::process::Command;

/// The profile folder (`<target dir>/debug`, `…/release`, a custom profile's) of the build that made the running
/// test binary, where the workspace's binaries are.  Panics outside a cargo layout.
pub fn profile_dir() -> PathBuf {
    let exe = std::env::current_exe().expect("the test binary's path");
    profile_dir_of(&exe).unwrap_or_else(|| {
        panic!(
            "{} is in no cargo profile folder (no deps/ or build/ above it)",
            exe.display()
        )
    })
}

/// The profile folder above EXE: the nearest folder whose child on the way up is `deps` or `build`.
pub(crate) fn profile_dir_of(exe: &Path) -> Option<PathBuf> {
    exe.ancestors()
        .zip(exe.ancestors().skip(1))
        .skip(1)
        .find(|(child, _)| {
            matches!(
                child.file_name().and_then(|n| n.to_str()),
                Some("deps" | "build")
            )
        })
        .map(|(_, dir)| dir.to_path_buf())
}

/// The workspace's binary NAME: BUILT when cargo named it (`option_env!("CARGO_BIN_EXE_<name>")`, which cargo sets
/// for a package's own integration tests), else the path in the variable VAR when it is set, else NAME in
/// [`profile_dir`].
pub fn workspace_bin(name: &str, built: Option<&str>, var: Option<&str>) -> PathBuf {
    if let Some(p) = built {
        return p.into();
    }
    if let Some(p) = var.and_then(std::env::var_os) {
        return p.into();
    }
    profile_dir().join(format!("{name}{}", std::env::consts::EXE_SUFFIX))
}

/// [`workspace_bin`] NAME of PACKAGE, built first when it is not there: into the test's own target dir and profile,
/// so a run with `--target-dir` or `--release` finds it.  Panics when the build fails.
pub fn workspace_bin_built(package: &str, name: &str, var: Option<&str>) -> PathBuf {
    let bin = workspace_bin(name, None, var);
    if bin.exists() {
        return bin;
    }
    let dir = profile_dir();
    let profile = dir.file_name().and_then(|n| n.to_str()).unwrap_or("debug");
    let profile = if profile == "debug" { "dev" } else { profile };
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".into());
    let ok = Command::new(cargo)
        .args(["build", "-p", package, "--bin", name, "--profile", profile])
        .arg("--target-dir")
        .arg(dir.parent().expect("the target dir"))
        .status()
        .is_ok_and(|s| s.success());
    assert!(
        ok && bin.exists(),
        "{name} is not built ({})",
        bin.display()
    );
    bin
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_profile_folder_is_found_in_both_layouts() {
        let up_to_1_99 = Path::new("/w/runtime/target/debug/deps/engine-0123abcd");
        let from_1_100 =
            Path::new("/w/runtime/target/debug/build/bifrost/b3bf89ab/out/engine-b3bf89ab");
        let custom = Path::new("/build/w/target/x86_64-unknown-linux-musl/ci/deps/conn-1");
        assert_eq!(
            profile_dir_of(up_to_1_99).unwrap(),
            Path::new("/w/runtime/target/debug")
        );
        assert_eq!(
            profile_dir_of(from_1_100).unwrap(),
            Path::new("/w/runtime/target/debug")
        );
        assert_eq!(
            profile_dir_of(custom).unwrap(),
            Path::new("/build/w/target/x86_64-unknown-linux-musl/ci")
        );
        assert_eq!(profile_dir_of(Path::new("/usr/bin/ratatoskr")), None);
    }

    #[test]
    fn a_built_path_wins_then_the_variable() {
        assert_eq!(
            workspace_bin("x", Some("/given/x"), Some("SKULD_TEST_UNSET_VAR")),
            Path::new("/given/x")
        );
        assert_eq!(
            workspace_bin("x", None, Some("SKULD_TEST_UNSET_VAR")),
            profile_dir().join(format!("x{}", std::env::consts::EXE_SUFFIX))
        );
    }
}
