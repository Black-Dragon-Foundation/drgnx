//! The link rows: the engine's static library, built by Zig, in a Rust test binary. `no_duplicate_compiler_rt_symbols`
//! and `no_libstdcxx_reference` read the binary with `nm` (and `readelf` / `otool`); `builds_offline` builds the crate
//! in a network namespace of its own from the pinned tarballs.
#![cfg(feature = "ghostty")]

use ghostty_vt_sys::bindings::*;
use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::Command;

fn tool(name: &str, args: &[&str], file: &str) -> String {
    let out = Command::new(name)
        .args(args)
        .arg(file)
        .output()
        .unwrap_or_else(|e| panic!("{name}: {e} (binutils in the image?)"));
    assert!(
        out.status.success(),
        "{name} {args:?} {file}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

#[test]
fn links_and_creates_a_terminal() {
    let mut term: GhosttyTerminal = core::ptr::null_mut();
    let mut fmt: GhosttyFormatter = core::ptr::null_mut();
    let mut buf = [0u8; 256];
    let mut written = 0usize;
    // SAFETY: the documented call sequence of ghostty/vt/terminal.h and formatter.h; the handles are freed below.
    unsafe {
        assert_eq!(
            ghostty_terminal_new(core::ptr::null(), &mut term, 80, 24),
            GHOSTTY_SUCCESS
        );
        ghostty_terminal_vt_write(term, b"hi".as_ptr(), 2);
        assert_eq!(
            ghostty_formatter_terminal_new(core::ptr::null(), &mut fmt, term),
            GHOSTTY_SUCCESS
        );
        assert_eq!(
            ghostty_formatter_format_buf(fmt, buf.as_mut_ptr(), buf.len(), &mut written),
            GHOSTTY_SUCCESS
        );
        ghostty_formatter_free(fmt);
        ghostty_terminal_free(term);
    }
    assert_eq!(&buf[..written], b"hi");
}

#[test]
fn the_library_is_the_version_this_crate_was_written_for() {
    let v = ghostty_vt_sys::ghostty_vt_check().expect("ghostty_vt_check");
    assert!(
        v.starts_with(ghostty_vt_sys::PINNED_VERSION) || option_env!("GHOSTTY_VT_LIB").is_some(),
        "{v}"
    );
}

/// A symbol as the C and Rust sources name it: Mach-O puts a `_` before every name (`___addtf3` is `__addtf3`, `__ZN3hwy…`
/// is the C++ name `_ZN3hwy…`), ELF does not.
fn source_name(name: &str) -> &str {
    if cfg!(target_os = "macos") {
        name.strip_prefix('_').unwrap_or(name)
    } else {
        name
    }
}

/// The global code symbols FILE defines: each one's source name, whether it is weak, and its `nm` line. ELF's `nm`
/// says `T` or `W`; Mach-O's prints a weak definition as `T` too, so there it is read from `nm -m`
/// (`(__TEXT,__text) weak private external ___addtf3`: `private` is hidden visibility, as Zig gives compiler_rt).
fn code_globals(file: &str) -> Vec<(String, bool, String)> {
    if cfg!(target_os = "macos") {
        tool("nm", &["-m", "--defined-only", "-g"], file)
            .lines()
            .filter(|l| l.contains("(__TEXT,"))
            .filter_map(|l| {
                let name = source_name(l.split_whitespace().last()?).to_string();
                Some((
                    name,
                    l.split_whitespace().any(|w| w == "weak"),
                    l.to_string(),
                ))
            })
            .collect()
    } else {
        tool("nm", &["--defined-only", "-g"], file)
            .lines()
            .filter_map(|l| {
                let mut w = l.split_whitespace().rev();
                let name = w.next()?.to_string();
                match w.next()? {
                    "T" => Some((name, false, l.to_string())),
                    "W" => Some((name, true, l.to_string())),
                    _ => None,
                }
            })
            .collect()
    }
}

#[test]
fn no_duplicate_compiler_rt_symbols() {
    // The archive's compiler_rt must not clash with Rust's compiler_builtins: every global symbol it defines under a
    // compiler_rt name is weak, so the linker keeps one; and the linked test binary defines no name twice.
    let archive = env!("GHOSTTY_VT_ARCHIVE");
    let strong: BTreeSet<(String, String)> = code_globals(archive)
        .into_iter()
        .filter(|(name, weak, _)| {
            !weak
                && name.starts_with("__")
                && !name.starts_with("__cxa")
                && !name.starts_with("__zig")
        })
        .map(|(name, _, line)| (name, line))
        .collect();
    assert!(
        strong.is_empty(),
        "the archive defines {} strong compiler_rt-style symbols: {:?}; their nm lines begin: {:?}",
        strong.len(),
        strong.iter().map(|(n, _)| n).collect::<Vec<_>>(),
        strong.iter().take(5).map(|(_, l)| l).collect::<Vec<_>>()
    );
    let exe = std::env::current_exe().unwrap();
    let mut seen = BTreeSet::new();
    let dup: Vec<String> = tool("nm", &["--defined-only", "-g"], exe.to_str().unwrap())
        .lines()
        .filter_map(|l| {
            l.split_whitespace()
                .last()
                .map(|n| source_name(n).to_string())
        })
        .filter(|n| n.starts_with("__") && !seen.insert(n.clone()))
        .collect();
    assert!(
        dup.is_empty(),
        "symbols defined twice in the test binary: {dup:?}"
    );
}

#[test]
fn no_libstdcxx_reference() {
    let exe = std::env::current_exe().unwrap();
    let exe = exe.to_str().unwrap();
    // libc++'s names are _ZNSt3__1…; libstdc++'s are _ZNSt…, _ZNKSt…, _ZSt… without the __1 inline namespace
    let undefined = tool("nm", &["--undefined-only"], exe);
    let bad: Vec<&str> = undefined
        .lines()
        .filter_map(|l| l.split_whitespace().last())
        .filter(|n| {
            (n.starts_with("_ZNSt") || n.starts_with("_ZNKSt") || n.starts_with("_ZSt"))
                && !n.contains("St3__1")
        })
        .collect();
    assert!(bad.is_empty(), "undefined libstdc++ symbols: {bad:?}");
    let needed = if cfg!(target_os = "macos") {
        tool("otool", &["-L"], exe)
    } else {
        tool("readelf", &["-d"], exe)
    };
    assert!(
        !needed.contains("libstdc++") && !needed.contains("libc++"),
        "the test binary needs a C++ runtime library:\n{needed}"
    );
}

/// Linux only: macOS has no network namespace to build in (`unshare` is util-linux). The build reads the same pinned
/// tarballs there, so this row on Linux covers both.
#[cfg(target_os = "linux")]
#[test]
fn builds_offline() {
    // The same crate, built in a network namespace of its own (no interface at all) from the pinned tarballs.
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let tarballs = std::env::var_os("GHOSTTY_VT_TARBALLS")
        .map(PathBuf::from)
        .unwrap_or_else(|| dir.join("tarballs"));
    let target = std::env::temp_dir().join(format!("ghostty-offline-{}", std::process::id()));
    let st = Command::new("unshare")
        .args(["--net", "--map-root-user", "--"])
        .arg(std::env::var("CARGO").unwrap_or_else(|_| "cargo".into()))
        .args([
            "build",
            "--locked",
            "--offline",
            "-p",
            "ghostty-vt-sys",
            "--lib",
        ])
        .arg("--manifest-path")
        .arg(dir.join("Cargo.toml"))
        .env("CARGO_TARGET_DIR", &target)
        .env("GHOSTTY_VT_TARBALLS", &tarballs)
        // a compiler cache (sccache) is a client of a server it cannot reach from an empty namespace
        .env_remove("RUSTC_WRAPPER")
        .env_remove("CARGO_BUILD_RUSTC_WRAPPER")
        .status()
        .expect("unshare (util-linux)");
    let _ = std::fs::remove_dir_all(&target);
    assert!(st.success(), "the offline build failed: {st}");
}

#[test]
fn notice_matches_pin() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let pin = std::fs::read_to_string(dir.join("pin.toml")).unwrap();
    let notice = std::fs::read_to_string(dir.join("NOTICE")).unwrap();
    let files: Vec<&str> = pin
        .lines()
        .filter_map(|l| l.trim().strip_prefix("file = \""))
        .filter_map(|l| l.strip_suffix('"'))
        .collect();
    assert_eq!(
        files.len(),
        2,
        "pin.toml names a source and a deps tarball: {files:?}"
    );
    for f in files {
        assert!(notice.contains(f), "NOTICE does not name {f}");
    }
    for name in [
        "libghostty-vt",
        "simdutf",
        "Highway",
        "Wuffs",
        "uucode",
        "aro",
        "translate_c",
        "shell integration",
    ] {
        assert!(notice.contains(name), "NOTICE does not mention {name}");
    }
}
