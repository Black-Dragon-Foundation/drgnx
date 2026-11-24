//! The running executable's path, resolved once at start.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

static START_EXE: OnceLock<PathBuf> = OnceLock::new();

/// The executable's path as resolved at start (set by [`resolve_exe`]; a re-exec runs this path).
pub fn start_exe() -> Option<&'static Path> {
    START_EXE.get().map(PathBuf::as_path)
}

/// Resolve the running executable's path once.  Linux and Android: `readlink /proc/self/exe`, which at start names the file on
/// disk; macOS: `_NSGetExecutablePath` (what `current_exe` calls) and `realpath`.
pub fn resolve_exe() -> std::io::Result<&'static Path> {
    if let Some(p) = START_EXE.get() {
        return Ok(p);
    }
    #[cfg(any(target_os = "linux", target_os = "android"))]
    let path = std::fs::read_link("/proc/self/exe")?;
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    let path = std::fs::canonicalize(std::env::current_exe()?)?;
    Ok(START_EXE.get_or_init(|| path).as_path())
}

/// Tests: take PATH as the executable resolved at start.  A unit test's own binary is libtest's harness, which is no
/// sandbox helper (it refuses `sandbox-inner --spec-fd`); a test that runs the real sandbox pins the built hub instead.
/// Panics when another path was resolved first.
#[cfg(any(test, feature = "test-support"))]
pub fn pin_exe_for_test(path: PathBuf) {
    let got = START_EXE.get_or_init(|| path.clone());
    assert_eq!(
        got, &path,
        "the executable was resolved before the test pinned it"
    );
}
