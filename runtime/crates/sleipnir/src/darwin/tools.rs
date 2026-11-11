//! A Mac runner's language toolchains: the project's pins (`rust@1.95`) installed by `mise` into the runner root, at
//! `runner add` and at a health check, as the runner account and outside any job sandbox (`sleipnir tools`). Each pin
//! leaves a record, `<root>/tools/env/NAME@VER.json`: the folders it puts on `PATH` and the variables it sets. The probe
//! offers `tool:NAME@VER` for each record, and a job placed with that feature gets the record in its environment and
//! reads `<root>/tools`. `mise` is the user's, from Homebrew; nothing is installed outside the root.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// The variables a job's sandbox sets itself: a tool's record never overrides them.
pub const JOB_OWNED: &[&str] = &[
    "HOME",
    "TMPDIR",
    "PATH",
    "LANG",
    "CARGO_HOME",
    super::memwatch::MARKER,
];

/// What a pin puts in a job's environment.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Record {
    /// Folders put before the job's `PATH`, in order.
    pub path: Vec<String>,
    /// Other variables, as `mise env` gave them.
    pub env: Vec<(String, String)>,
}

/// `rust@1.95` → (`rust`, `1.95`): a lowercase name, then a version of letters, digits, `.`, `-`, `_` and `+`.
pub fn parse_pin(pin: &str) -> Option<(&str, &str)> {
    let (name, ver) = pin.split_once('@')?;
    let name_ok = name.starts_with(|c: char| c.is_ascii_lowercase() || c.is_ascii_digit())
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '-' | '_' | '.'));
    let ver_ok = ver.starts_with(|c: char| c.is_ascii_alphanumeric())
        && ver
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | '+'));
    (name_ok && ver_ok).then_some((name, ver))
}

/// The records' folder under ROOT.
pub fn env_dir(root: &Path) -> PathBuf {
    root.join("tools").join("env")
}

/// The features of the records' file names: `rust@1.95.json` → `tool:rust@1.95` (anything else is skipped).
pub fn features(files: &[String]) -> Vec<String> {
    let mut f: Vec<String> = files
        .iter()
        .filter_map(|n| n.strip_suffix(".json"))
        .filter(|p| parse_pin(p).is_some())
        .map(|p| format!("tool:{p}"))
        .collect();
    f.sort();
    f
}

/// The record files under ROOT, by name (none when there is no folder).
pub fn installed(root: &Path) -> Vec<String> {
    std::fs::read_dir(env_dir(root))
        .map(|d| {
            d.filter_map(|e| e.ok())
                .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
                .filter_map(|e| e.file_name().into_string().ok())
                .collect()
        })
        .unwrap_or_default()
}

/// The record of `mise env --json`'s ENV, run with BASE_PATH as its `PATH`: the `PATH` folders mise put before
/// BASE_PATH, and every other variable but mise's own and the job's (EXTRA, the install's own homes, come last).
pub fn record(
    env: &serde_json::Map<String, serde_json::Value>,
    base_path: &str,
    extra: &[(String, String)],
) -> Record {
    let base: Vec<&str> = base_path.split(':').collect();
    let path = env
        .get("PATH")
        .and_then(|p| p.as_str())
        .map(|p| {
            p.split(':')
                .filter(|d| !d.is_empty() && !base.contains(d))
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();
    let mut vars: Vec<(String, String)> = env
        .iter()
        .filter(|(k, _)| !k.starts_with("MISE_") && !JOB_OWNED.contains(&k.as_str()))
        .filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_string())))
        .collect();
    for (k, v) in extra {
        if !vars.iter().any(|(x, _)| x == k) {
            vars.push((k.clone(), v.clone()));
        }
    }
    vars.sort();
    Record { path, env: vars }
}

/// BASE (a job's own environment) with RECORDS: their folders before its `PATH`, their other variables where BASE has
/// none (a job's own never change).
pub fn job_env(mut base: Vec<(String, String)>, records: &[Record]) -> Vec<(String, String)> {
    let dirs: Vec<&str> = records
        .iter()
        .flat_map(|r| r.path.iter().map(String::as_str))
        .collect();
    if !dirs.is_empty() {
        for (k, v) in base.iter_mut() {
            if k == "PATH" {
                *v = format!("{}:{v}", dirs.join(":"));
            }
        }
    }
    for r in records {
        for (k, v) in &r.env {
            if !JOB_OWNED.contains(&k.as_str()) && !base.iter().any(|(x, _)| x == k) {
                base.push((k.clone(), v.clone()));
            }
        }
    }
    base
}

/// The records of FEATURES' `tool:` pins under ROOT; a pin without one is named in the error.
pub fn records_for(root: &Path, features: &[String]) -> Result<Vec<Record>, String> {
    features
        .iter()
        .filter_map(|f| f.strip_prefix("tool:"))
        .map(|pin| {
            let file = env_dir(root).join(format!("{pin}.json"));
            std::fs::read(&file)
                .ok()
                .and_then(|b| serde_json::from_slice(&b).ok())
                .ok_or_else(|| {
                    format!(
                        "no {pin} on this Mac (`drgnx runner check` installs the project's pins)"
                    )
                })
        })
        .collect()
}

/// The user's `mise`, from Homebrew.
pub fn find_mise() -> Option<PathBuf> {
    ["/opt/homebrew/bin/mise", "/usr/local/bin/mise"]
        .into_iter()
        .map(PathBuf::from)
        .find(|p| p.is_file())
}

/// One pin's outcome.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Outcome {
    pub pin: String,
    /// None: installed and recorded; else why not.
    pub failed: Option<String>,
}

/// PINS installed by MISE into ROOT, each recorded (`mise install`, then `mise env --json`), with BASE_PATH as their
/// `PATH`. mise's data, cache, state and config, and Rust's homes, are all under ROOT; HOME stays the account's.
pub fn install(mise: &Path, root: &Path, base_path: &str, pins: &[String]) -> Vec<Outcome> {
    let tools = root.join("tools");
    let homes = vec![(
        "RUSTUP_HOME".to_string(),
        tools.join("rustup").display().to_string(),
    )];
    let vars: Vec<(String, String)> = [
        ("MISE_DATA_DIR", tools.join("mise")),
        ("MISE_STATE_DIR", tools.join("mise-state")),
        ("MISE_CONFIG_DIR", tools.join("mise-config")),
        (
            "MISE_GLOBAL_CONFIG_FILE",
            tools.join("mise-config").join("config.toml"),
        ),
        ("MISE_CACHE_DIR", root.join("cache").join("mise")),
        ("MISE_CEILING_PATHS", root.to_path_buf()),
        ("MISE_RUSTUP_HOME", tools.join("rustup")),
        ("MISE_CARGO_HOME", tools.join("cargo")),
        ("CARGO_HOME", tools.join("cargo")),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v.display().to_string()))
    .chain(homes.iter().cloned())
    .chain([
        ("MISE_YES".to_string(), "1".to_string()),
        ("PATH".to_string(), base_path.to_string()),
    ])
    .collect();
    let run = |args: &[&str]| -> Result<String, String> {
        let mut cmd = std::process::Command::new(mise);
        cmd.args(args)
            .current_dir(root)
            .env_clear()
            .envs(vars.iter().map(|(k, v)| (k, v)));
        for k in ["HOME", "USER", "LOGNAME", "LANG"] {
            if let Some(v) = std::env::var_os(k) {
                cmd.env(k, v);
            }
        }
        let out = cmd.output().map_err(|e| format!("mise: {e}"))?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        } else {
            let err = String::from_utf8_lossy(&out.stderr);
            let last = err
                .lines()
                .rev()
                .find(|l| !l.trim().is_empty())
                .unwrap_or("");
            Err(format!(
                "mise {}: {} ({})",
                args.join(" "),
                last.trim(),
                out.status
            ))
        }
    };
    let dir = env_dir(root);
    pins.iter()
        .map(|pin| {
            let failed = (|| -> Result<(), String> {
                parse_pin(pin).ok_or_else(|| format!("{pin:?} is not NAME@VERSION"))?;
                std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
                run(&["install", pin])?;
                let out = run(&["env", "--json", pin])?;
                let env: serde_json::Map<String, serde_json::Value> =
                    serde_json::from_str(&out).map_err(|e| format!("mise env: {e}"))?;
                let rec = record(&env, base_path, &homes);
                let file = dir.join(format!("{pin}.json"));
                let part = dir.join(format!("{pin}.json.part"));
                std::fs::write(&part, serde_json::to_vec(&rec).expect("record"))
                    .and_then(|_| std::fs::rename(&part, &file))
                    .map_err(|e| format!("{}: {e}", file.display()))
            })()
            .err();
            Outcome {
                pin: pin.clone(),
                failed,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [D] Pins: a name and a version; anything else is refused.
    #[test]
    fn pins() {
        assert_eq!(parse_pin("rust@1.95"), Some(("rust", "1.95")));
        assert_eq!(parse_pin("node@22.11.0"), Some(("node", "22.11.0")));
        assert_eq!(parse_pin("rust"), None);
        assert_eq!(parse_pin("rust@"), None);
        assert_eq!(parse_pin("../x@1"), None);
        assert_eq!(parse_pin("rust@1;rm"), None);
        assert_eq!(parse_pin("Rust@1"), None);
    }

    /// [D] The records' names are the features; part files and strays are not.
    #[test]
    fn features_are_the_records() {
        let files = [
            "rust@1.95.json",
            "node@22.json",
            "rust@1.96.json.part",
            "notes.txt",
            "x.json",
        ]
        .map(String::from);
        assert_eq!(features(&files), ["tool:node@22", "tool:rust@1.95"]);
    }

    /// [D] A record keeps the folders mise put before the base PATH and its own variables, never mise's or the job's.
    #[test]
    fn a_record_is_what_mise_adds() {
        let env = serde_json::json!({
            "PATH": "/r/tools/cargo/bin:/r/tools/mise/installs/rust/1.95/bin:/opt/homebrew/bin:/usr/bin:/bin",
            "RUSTUP_TOOLCHAIN": "1.95",
            "MISE_SHELL": "zsh",
            "HOME": "/Users/x",
            "CARGO_HOME": "/r/tools/cargo"
        });
        let rec = record(
            env.as_object().unwrap(),
            "/opt/homebrew/bin:/usr/bin:/bin",
            &[("RUSTUP_HOME".into(), "/r/tools/rustup".into())],
        );
        assert_eq!(
            rec.path,
            ["/r/tools/cargo/bin", "/r/tools/mise/installs/rust/1.95/bin"]
        );
        assert_eq!(
            rec.env,
            [
                ("RUSTUP_HOME".to_string(), "/r/tools/rustup".to_string()),
                ("RUSTUP_TOOLCHAIN".to_string(), "1.95".to_string())
            ]
        );
    }

    /// [D] A job's environment: the tools' folders first on PATH, their variables added, the job's own unchanged.
    #[test]
    fn a_job_gets_its_tools() {
        let base = vec![
            ("HOME".to_string(), "/a/home".to_string()),
            ("PATH".to_string(), "/usr/bin:/bin".to_string()),
        ];
        let recs = [
            Record {
                path: vec!["/r/rust/bin".into()],
                env: vec![
                    ("RUSTUP_TOOLCHAIN".into(), "1.95".into()),
                    ("HOME".into(), "/evil".into()),
                ],
            },
            Record {
                path: vec!["/r/node/bin".into()],
                env: vec![],
            },
        ];
        let env = job_env(base.clone(), &recs);
        assert!(env.contains(&(
            "PATH".into(),
            "/r/rust/bin:/r/node/bin:/usr/bin:/bin".into()
        )));
        assert!(env.contains(&("HOME".into(), "/a/home".into())));
        assert!(env.contains(&("RUSTUP_TOOLCHAIN".into(), "1.95".into())));
        assert_eq!(job_env(base.clone(), &[]), base);
    }

    /// [D] A job's records: each pin's file; a pin with none is named.
    #[test]
    fn records_by_feature() {
        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(env_dir(root.path())).unwrap();
        let rec = Record {
            path: vec!["/x/bin".into()],
            env: vec![],
        };
        std::fs::write(
            env_dir(root.path()).join("rust@1.95.json"),
            serde_json::to_vec(&rec).unwrap(),
        )
        .unwrap();
        let f = ["xcode-clt", "tool:rust@1.95"].map(String::from);
        assert_eq!(records_for(root.path(), &f).unwrap(), [rec]);
        let why = records_for(root.path(), &["tool:node@22".into()]).unwrap_err();
        assert!(why.contains("no node@22"), "{why}");
        assert_eq!(installed(root.path()), ["rust@1.95.json"]);
    }

    /// [C] macOS CI (`--ignored`, after `brew install mise`): a pinned Rust (`SLEIPNIR_TOOLS_PIN`, default
    /// `rust@1.95`) installed by the user's mise into a root, then a job's Seatbelt profile with that pin finds
    /// `cargo --version` from the root, at the pinned version.
    #[cfg(all(target_os = "macos", feature = "runner"))]
    #[test]
    #[ignore = "macos-tools"]
    fn a_pinned_rust_runs_in_a_job() {
        use crate::darwin::sandbox;
        use std::path::PathBuf;
        let pin = std::env::var("SLEIPNIR_TOOLS_PIN").unwrap_or_else(|_| "rust@1.95".into());
        let ver = parse_pin(&pin).expect("a pin").1.to_string();
        let t = tempfile::tempdir().unwrap();
        let root = t.path().canonicalize().unwrap();
        let mise = find_mise().expect("mise: brew install mise");
        let out = install(&mise, &root, sandbox::PATH, std::slice::from_ref(&pin));
        assert_eq!(out[0].failed, None, "{out:?}");
        let records = records_for(&root, &[format!("tool:{pin}")]).unwrap();
        let (dir, src) = (root.join("jobs/j1.1"), root.join("slots/s1"));
        let (home, tmp) = sandbox::home_tmp(&dir);
        for d in [&src, &home, &tmp] {
            std::fs::create_dir_all(d).unwrap();
        }
        let tools_dir = root.join("tools");
        let spec = sandbox::spec(&sandbox::Job {
            dir: &dir,
            src: &src,
            cwd: Path::new("."),
            writes_tree: false,
            marker: "hub/j1/1",
            tools_dir: &tools_dir,
            tools: &records,
        });
        let ctx = gleipnir::Context {
            home: std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_default(),
            closed: vec![],
            open_inside_closed: vec![],
            user_sockets: vec![],
            run_parents: vec![],
            program_dirs: sandbox::PATH
                .split(':')
                .map(PathBuf::from)
                .chain(
                    records
                        .iter()
                        .flat_map(|r| r.path.iter().map(PathBuf::from)),
                )
                .collect(),
            env_deny: vec![],
        };
        let valid = gleipnir::validate(spec, &ctx, gleipnir::spec::Target::Macos).unwrap();
        let dev = std::process::Command::new("/usr/bin/xcode-select")
            .arg("-p")
            .output()
            .unwrap();
        let dev = String::from_utf8_lossy(&dev.stdout).trim().to_string();
        let profile = gleipnir::sbpl::profile(
            &valid,
            &gleipnir::sbpl::MacContext {
                developer_dir: std::fs::canonicalize(dev).ok(),
                ..Default::default()
            },
        )
        .unwrap();
        let sb = dir.join("job.sb");
        std::fs::write(&sb, profile).unwrap();
        let run = std::process::Command::new("/usr/bin/sandbox-exec")
            .arg("-f")
            .arg(&sb)
            .args(["cargo", "--version"])
            .env_clear()
            .envs(valid.spec().env.iter().map(|(k, v)| (k, v)))
            .current_dir(&valid.spec().chdir)
            .output()
            .unwrap();
        let said = format!(
            "{}{}",
            String::from_utf8_lossy(&run.stdout),
            String::from_utf8_lossy(&run.stderr)
        );
        assert!(run.status.success(), "{said}");
        assert!(said.starts_with(&format!("cargo {ver}")), "{said}");
    }

    /// [D] The install: mise runs in the root with its folders and Rust's homes there, and each pin is recorded; a
    /// failing pin is named with mise's last line and leaves no record (a fake `mise`, on Linux).
    #[cfg(unix)]
    #[test]
    fn install_records_each_pin() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        // by its true name: macOS's temporary folder is under /var, a link to /private/var, and mise sees $PWD resolved
        let root = dir.path().canonicalize().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mise = bin.path().join("mise");
        std::fs::write(
            &mise,
            "#!/bin/sh\n\
             echo \"$PWD|$MISE_DATA_DIR|$CARGO_HOME|$RUSTUP_HOME|$*\" >> \"$MISE_DATA_DIR.log\"\n\
             case \"$1 $2\" in\n\
             'install bad@1') echo 'downloading'; echo 'no such version' >&2; exit 1;;\n\
             'env --json') printf '{\"PATH\":\"%s/installs/x/bin:%s\",\"X_HOME\":\"1\"}' \"$MISE_DATA_DIR\" \"$PATH\";;\n\
             esac\n",
        )
        .unwrap();
        std::fs::set_permissions(&mise, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::create_dir_all(root.as_path().join("tools")).unwrap();
        let out = install(
            &mise,
            root.as_path(),
            "/usr/bin:/bin",
            &["rust@1.95".into(), "bad@1".into(), "x".into()],
        );
        assert_eq!(
            out[0],
            Outcome {
                pin: "rust@1.95".into(),
                failed: None
            }
        );
        assert!(
            out[1]
                .failed
                .as_deref()
                .unwrap()
                .contains("no such version"),
            "{out:?}"
        );
        assert!(
            out[2].failed.as_deref().unwrap().contains("NAME@VERSION"),
            "{out:?}"
        );
        assert_eq!(features(&installed(root.as_path())), ["tool:rust@1.95"]);
        let rec = records_for(root.as_path(), &["tool:rust@1.95".into()])
            .unwrap()
            .remove(0);
        let tools = root.as_path().join("tools");
        assert_eq!(
            rec.path,
            [format!("{}/installs/x/bin", tools.join("mise").display())]
        );
        assert!(rec.env.contains(&(
            "RUSTUP_HOME".into(),
            tools.join("rustup").display().to_string()
        )));
        let log = std::fs::read_to_string(tools.join("mise.log")).unwrap();
        let first = log.lines().next().unwrap();
        assert_eq!(
            first,
            format!(
                "{}|{}|{}|{}|install rust@1.95",
                root.as_path().display(),
                tools.join("mise").display(),
                tools.join("cargo").display(),
                tools.join("rustup").display()
            )
        );
    }
}
