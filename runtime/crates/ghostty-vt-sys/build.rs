//! Links libghostty-vt. `GHOSTTY_VT_LIB` (a directory holding `libghostty-vt.a`, or the file) is linked as it is.
//! Otherwise the pinned source and dependency tarballs (pin.toml; `fetch.sh` downloads them, this script never does)
//! are checked against their sha256, unpacked into OUT_DIR and built with `zig build --system`, in a fresh, empty Zig
//! cache (a non-empty Zig 0.17 cache can crash the build, and an empty one proves the build used only the pinned
//! packages). Zig is a build tool only and must be 0.17.x.
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::{env, fs};

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=pin.toml");
    for v in ["GHOSTTY_VT_LIB", "GHOSTTY_VT_TARBALLS", "ZIG"] {
        println!("cargo:rerun-if-env-changed={v}");
    }
    if env::var_os("CARGO_FEATURE_GHOSTTY").is_none() {
        return;
    }
    let pin = Pin::read(&PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap()).join("pin.toml"));
    println!("cargo:rustc-env=GHOSTTY_VT_PIN_VERSION={}", pin.version);
    if let Some(lib) = env::var_os("GHOSTTY_VT_LIB") {
        let lib = PathBuf::from(lib);
        let dir = if lib.is_file() {
            lib.parent().unwrap().to_path_buf()
        } else {
            lib
        };
        assert!(
            dir.join("libghostty-vt.a").is_file(),
            "GHOSTTY_VT_LIB: no libghostty-vt.a in {}",
            dir.display()
        );
        link(&dir);
        return;
    }
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let tarballs = env::var_os("GHOSTTY_VT_TARBALLS")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap()).join("tarballs"));
    let prefix = out.join("prefix");
    let stamp = out.join("built-for");
    let want = format!(
        "{} {} {} {}",
        pin.version,
        pin.source.1,
        pin.deps.1,
        zig_target()
    );
    if prefix.join("lib/libghostty-vt.a").is_file()
        && fs::read_to_string(&stamp).ok().as_deref() == Some(&want)
    {
        link(&prefix.join("lib"));
        return;
    }
    for (file, sha) in [&pin.source, &pin.deps] {
        let path = tarballs.join(file);
        let bytes = fs::read(&path).unwrap_or_else(|e| {
            panic!("cannot read {} ({e}): run runtime/crates/ghostty-vt-sys/fetch.sh, or set GHOSTTY_VT_TARBALLS to the directory holding the pinned tarballs", path.display())
        });
        let got = hex(&Sha256::digest(&bytes));
        assert_eq!(
            &got,
            sha,
            "{} is not the file pin.toml pins (sha256 {got})",
            path.display()
        );
    }
    let src = out.join("src");
    let _ = fs::remove_dir_all(&src);
    fs::create_dir_all(&src).unwrap();
    for (file, _) in [&pin.source, &pin.deps] {
        run(
            Command::new("tar")
                .arg("-xzf")
                .arg(tarballs.join(file))
                .arg("-C")
                .arg(&src),
            "tar",
        );
    }
    let tree = src.join(format!("libghostty-vt-{}", pin.version));
    let deps = src.join(format!("libghostty-vt-{}-deps", pin.version));
    let zig = env::var("ZIG").unwrap_or_else(|_| "zig".into());
    let version = Command::new(&zig)
        .arg("version")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
    match version {
        Ok(v) if v.starts_with(&format!("{}.", pin.zig)) => {}
        Ok(v) => panic!(
            "zig {v} cannot build libghostty-vt {}: it needs Zig {}.x (mise install zig@{}.0, or set ZIG)",
            pin.version, pin.zig, pin.zig
        ),
        Err(e) => panic!(
            "no zig ({e}): libghostty-vt {} is built with Zig {}.x (mise install zig@{}.0, or set ZIG; docs/develop/terminal.md)",
            pin.version, pin.zig, pin.zig
        ),
    }
    let cache = out.join("zig-cache");
    let _ = fs::remove_dir_all(&cache);
    fs::create_dir_all(&cache).unwrap();
    let _ = fs::remove_dir_all(&prefix);
    let mut cmd = Command::new(&zig);
    cmd.current_dir(&tree)
        .env("ZIG_GLOBAL_CACHE_DIR", &cache)
        .env("ZIG_LOCAL_CACHE_DIR", out.join("zig-local"))
        .arg("build")
        .arg("--prefix")
        .arg(&prefix)
        .arg("--system")
        .arg(&deps)
        .args(["-Doptimize=ReleaseFast", "-Dcpu=baseline"])
        .arg(format!("-Dtarget={}", zig_target()));
    if env::var_os("CARGO_FEATURE_NO_SIMD").is_some() {
        cmd.arg("-Dsimd=false");
    }
    run(&mut cmd, "zig build");
    assert!(
        prefix.join("lib/libghostty-vt.a").is_file(),
        "zig build left no libghostty-vt.a in {}",
        prefix.display()
    );
    fs::write(&stamp, want).unwrap();
    link(&prefix.join("lib"));
}

fn link(dir: &Path) {
    println!(
        "cargo:rustc-env=GHOSTTY_VT_ARCHIVE={}",
        dir.join("libghostty-vt.a").display()
    );
    println!("cargo:rustc-link-search=native={}", dir.display());
    println!("cargo:rustc-link-lib=static=ghostty-vt");
}

fn run(cmd: &mut Command, what: &str) {
    let st = cmd.status().unwrap_or_else(|e| panic!("{what}: {e}"));
    assert!(st.success(), "{what} failed ({st})");
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Zig's name of the target Cargo builds for (`-Dtarget`).
fn zig_target() -> String {
    let get = |k: &str| env::var(k).unwrap_or_default();
    let arch = get("CARGO_CFG_TARGET_ARCH");
    let (os, abi) = match (
        get("CARGO_CFG_TARGET_OS").as_str(),
        get("CARGO_CFG_TARGET_ENV").as_str(),
    ) {
        ("linux", "musl") => ("linux", "-musl"),
        ("linux", _) => ("linux", "-gnu"),
        ("android", _) => ("linux", "-android"),
        ("macos", _) => ("macos", ""),
        (o, _) => panic!("ghostty-vt-sys: no Zig target for {arch}-{o}"),
    };
    format!("{arch}-{os}{abi}")
}

/// pin.toml: `version`, `zig`, and the `file`/`sha256` of `[source]` and `[deps]`.
struct Pin {
    version: String,
    zig: String,
    source: (String, String),
    deps: (String, String),
}

impl Pin {
    fn read(path: &Path) -> Pin {
        let text = fs::read_to_string(path).unwrap();
        let (mut section, mut version, mut zig) = (String::new(), String::new(), String::new());
        let (mut source, mut deps) = (
            (String::new(), String::new()),
            (String::new(), String::new()),
        );
        for line in text
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
        {
            if let Some(s) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
                section = s.into();
                continue;
            }
            let Some((k, v)) = line.split_once('=') else {
                continue;
            };
            let v = v.trim().trim_matches('"').to_string();
            match (section.as_str(), k.trim()) {
                ("", "version") => version = v,
                ("", "zig") => zig = v,
                ("source", "file") => source.0 = v,
                ("source", "sha256") => source.1 = v,
                ("deps", "file") => deps.0 = v,
                ("deps", "sha256") => deps.1 = v,
                _ => {}
            }
        }
        Pin {
            version,
            zig,
            source,
            deps,
        }
    }
}
