//! `cargo xtask test-sandbox [NEXTEST ARGS…]`: the sentinel-HOME run (docs/develop/standards/test-harness.md).
//! `cargo nextest run` with HOME set to a fresh, empty, read-only directory and the XDG variables unset; it fails if
//! the tests fail or if anything was made in that directory. With no arguments it runs the clean crates' tests
//! (standards.toml); arguments replace that selection (`--workspace`, `-E …`).

use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

pub fn run(args: Vec<String>) -> Result<ExitCode, String> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default();
    let selection = if args.is_empty() {
        clean_selection(&root)?
    } else {
        args
    };
    let sentinel = root
        .join("target")
        .join(format!("sentinel-home-{}", std::process::id()));
    std::fs::create_dir_all(&sentinel).map_err(|e| format!("{}: {e}", sentinel.display()))?;
    set_mode(&sentinel, 0o555)?;

    // cargo and rustup keep finding their own homes: only the tests' HOME changes
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let cargo_home =
        std::env::var_os("CARGO_HOME").map_or_else(|| home.join(".cargo"), PathBuf::from);
    let rustup_home =
        std::env::var_os("RUSTUP_HOME").map_or_else(|| home.join(".rustup"), PathBuf::from);
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".into());
    let mut cmd = Command::new(cargo);
    cmd.current_dir(&root)
        .args(["nextest", "run", "--no-fail-fast"])
        .args(&selection)
        .env("HOME", &sentinel)
        .env("CARGO_HOME", cargo_home)
        .env("RUSTUP_HOME", rustup_home);
    for var in [
        "XDG_CONFIG_HOME",
        "XDG_STATE_HOME",
        "XDG_CACHE_HOME",
        "XDG_DATA_HOME",
        "XDG_RUNTIME_DIR",
        "DRGNX_PROFILE",
    ] {
        cmd.env_remove(var);
    }
    let status = cmd.status().map_err(|e| format!("cargo nextest: {e}"))?;

    set_mode(&sentinel, 0o755)?;
    let mut made = Vec::new();
    list(&sentinel, &mut made);
    let mut report = String::new();
    for p in &made {
        report.push_str(&format!(
            "test-sandbox: a test wrote under the sentinel HOME: {}\n",
            p.strip_prefix(&sentinel).unwrap_or(p).display()
        ));
    }
    let clean = made.is_empty();
    if clean {
        std::fs::remove_dir(&sentinel).map_err(|e| format!("{}: {e}", sentinel.display()))?;
    }
    report.push_str(&format!(
        "test-sandbox: tests {}, sentinel HOME {}\n",
        if status.success() { "passed" } else { "failed" },
        if clean { "untouched" } else { "written" }
    ));
    print!("{report}");
    Ok(if status.success() && clean {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    })
}

/// `-E 'package(a) | package(b) …'` over the crates standards.toml marks clean.
fn clean_selection(root: &Path) -> Result<Vec<String>, String> {
    let text = std::fs::read_to_string(root.join("standards.toml"))
        .map_err(|e| format!("standards.toml: {e}"))?;
    let t: toml::Table = text.parse().map_err(|e| format!("standards.toml: {e}"))?;
    let clean: Vec<String> = t
        .get("crates")
        .and_then(|c| c.as_table())
        .map(|c| {
            c.iter()
                .filter(|(_, m)| m.get("clean").and_then(|v| v.as_bool()) == Some(true))
                .map(|(k, _)| format!("package({k})"))
                .collect()
        })
        .unwrap_or_default();
    if clean.is_empty() {
        return Err("standards.toml marks no crate clean".into());
    }
    Ok(vec!["--workspace".into(), "-E".into(), clean.join(" | ")])
}

fn set_mode(p: &Path, mode: u32) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(mode))
        .map_err(|e| format!("{}: {e}", p.display()))
}

fn list(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let p = e.path();
        out.push(p.clone());
        if p.is_dir() {
            list(&p, out);
        }
    }
}
