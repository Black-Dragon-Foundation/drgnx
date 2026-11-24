//! The `command` kind: an artifact made by a container job that runs the entry's steps in order.
//!
//! - **Steps.** [`container_argv`] turns the steps (each an argv, placeholders expanded) into one `sh -ec` script: the
//!   first step that fails ends the script, so the later ones never run. Each word is quoted, so a step is an argv and
//!   never shell text.
//! - **Out.** The job's `{out}` is the artifact's `.part` folder, mounted read-write at [`super::OUT_INSIDE`]. With `keep`,
//!   [`keep`] then copies only the named paths of the build folder into it; without, the steps write `{out}` themselves.
//! - **Commit.** [`finish`] commits the part when the job passed and drops it when it did not, so a failed build leaves
//!   nothing the store answers.

use std::fs;
use std::path::{Component, Path, PathBuf};

use forseti::Keep;

use super::expand::{Ctx, expand};
use super::store::PartDir;
use crate::sync::register::Register;

/// One word as `sh` reads it: in single quotes, a quote in it closed, escaped and opened again.
fn quote(w: &str) -> String {
    format!("'{}'", w.replace('\'', "'\\''"))
}

/// The argv that runs STEPS, placeholders expanded by CTX, in a container whose shell is `/bin/sh`: stops at the first
/// step that fails, and that step's status is the job's.
pub fn container_argv(steps: &[Vec<String>], ctx: &Ctx) -> villa::Result<Vec<String>> {
    if steps.is_empty() || steps.iter().any(Vec::is_empty) {
        return Err(villa::Error::invalid(
            "a command artifact has steps, each a command",
        ));
    }
    let mut script = String::new();
    for s in steps {
        let argv = expand(s, ctx)?;
        script.push_str(&argv.iter().map(|w| quote(w)).collect::<Vec<_>>().join(" "));
        script.push('\n');
    }
    Ok(vec!["/bin/sh".into(), "-ec".into(), script])
}

/// A path under a folder: relative, no `..`.
fn plain(p: &str) -> bool {
    !p.is_empty()
        && Path::new(p)
            .components()
            .all(|c| matches!(c, Component::Normal(_)))
}

/// Copies the files of BUILD/`keep.from` whose path (relative to `from`, `/`-separated) matches one of `keep.paths`
/// into OUT, keeping their folders and modes; returns how many. A link is never followed or copied. A `from` or a
/// pattern outside the build folder is refused.
pub fn keep(build: &Path, k: &Keep, out: &Path) -> villa::Result<usize> {
    if !(k.from == "." || plain(&k.from))
        || k.paths.is_empty()
        || k.paths
            .iter()
            .any(|p| p.starts_with('/') || p.split('/').any(|s| s == ".."))
    {
        return Err(villa::Error::invalid(format!(
            "`keep` is a folder of the build and the paths of it to keep, not {:?} {:?}",
            k.from, k.paths
        )));
    }
    let from = if k.from == "." {
        build.to_path_buf()
    } else {
        build.join(&k.from)
    };
    let mut n = 0;
    let mut stack: Vec<PathBuf> = vec![PathBuf::new()];
    while let Some(rel) = stack.pop() {
        let Ok(rd) = fs::read_dir(from.join(&rel)) else {
            continue;
        };
        for e in rd.flatten() {
            let r = rel.join(e.file_name());
            let Ok(t) = e.file_type() else { continue };
            if t.is_dir() {
                stack.push(r);
            } else if t.is_file() {
                let s = r.to_string_lossy().replace('\\', "/");
                if k.paths.iter().any(|g| forseti::artifact::glob_match(g, &s)) {
                    let to = out.join(&r);
                    if let Some(d) = to.parent() {
                        fs::create_dir_all(d)
                            .map_err(|e| villa::Error::io(format!("{}: {e}", d.display())))?;
                    }
                    fs::copy(e.path(), &to)
                        .map_err(|e| villa::Error::io(format!("{}: {e}", to.display())))?;
                    n += 1;
                }
            }
        }
    }
    Ok(n)
}

/// Ends a command artifact's build: PASSED (the job's verdict) with the build folder BUILD, and `keep` KEEP if the entry
/// has one, commits PART into REG at NOW and returns its folder; a job that did not pass drops the part and returns none.
pub fn finish(
    part: PartDir,
    passed: bool,
    build: &Path,
    kept: Option<&Keep>,
    reg: &mut Register,
    now: u64,
) -> villa::Result<Option<PathBuf>> {
    if !passed {
        return Ok(None);
    }
    if let Some(k) = kept {
        keep(build, k, part.path())?;
    }
    part.commit(reg, now).map(Some)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::artifact::store::Store;
    use forseti::{ArtifactKey, Role};
    use std::time::Duration;

    /// Runs ARGV (its first word a program) as the container would, and says how it ended.
    fn run(argv: &[String]) -> std::process::ExitStatus {
        crate::tool::limited(
            Path::new(&argv[0]),
            &argv[1..],
            &[],
            Duration::from_secs(60),
        )
        .unwrap()
        .status
    }

    fn ctx() -> Ctx {
        Ctx {
            src: "/work".into(),
            out: Some("/out".into()),
            build: "/target".into(),
            jobs: 2,
            ..Ctx::default()
        }
    }

    fn step(w: &[&str]) -> Vec<String> {
        w.iter().map(|s| s.to_string()).collect()
    }

    // [D] tmpfs root
    #[test]
    fn a_failed_step_stops_the_rest_and_commits_nothing() {
        let t = tempfile::tempdir().unwrap();
        let d = |n: &str| t.path().join(n).display().to_string();
        let steps = vec![
            step(&["touch", &d("one")]),
            step(&["false"]),
            step(&["touch", &d("three")]),
        ];
        let argv = container_argv(&steps, &ctx()).unwrap();
        assert_eq!(&argv[..2], ["/bin/sh", "-ec"]);
        let status = run(&argv);
        assert_eq!(
            status.code(),
            Some(1),
            "the failing step's status is the job's"
        );
        assert!(t.path().join("one").exists(), "the step before it ran");
        assert!(
            !t.path().join("three").exists(),
            "the step after it never ran"
        );
        // and the build commits nothing
        let root = t.path().join("runner");
        fs::create_dir_all(&root).unwrap();
        let store = Store::at(&root);
        let mut reg = Register::open(&root).unwrap();
        let k = ArtifactKey("e".repeat(64));
        let part = store.begin("p", Role::Gate, "command", &k).unwrap();
        let got = finish(part, false, t.path(), None, &mut reg, 1).unwrap();
        assert_eq!(got, None);
        assert_eq!(store.path("p", Role::Gate, "command", &k), None);
        assert!(reg.items().is_empty());
    }

    #[test]
    fn a_step_is_an_argv_never_shell_text() {
        let t = tempfile::tempdir().unwrap();
        let hit = t.path().join("injected");
        let word = format!("a'; touch {}; echo '", hit.display());
        let argv = container_argv(&[step(&["echo", &word])], &ctx()).unwrap();
        assert!(run(&argv).success());
        assert!(!hit.exists(), "a quote in a word closed nothing");
    }

    #[test]
    fn steps_expand_their_placeholders_and_a_bad_one_refuses_the_build() {
        let argv = container_argv(&[step(&["make", "-j{jobs}", "O={build}"])], &ctx()).unwrap();
        assert!(
            argv[2].contains("'-j2'") && argv[2].contains("'O=/target'"),
            "{argv:?}"
        );
        assert!(container_argv(&[step(&["make", "{nope}"])], &ctx()).is_err());
        assert!(container_argv(&[], &ctx()).is_err());
        assert!(container_argv(&[vec![]], &ctx()).is_err());
    }

    // [D] tmpfs root
    #[test]
    fn keep_copies_only_the_named_paths() {
        let t = tempfile::tempdir().unwrap();
        let build = t.path().join("build");
        for f in [
            "inst/bin/tool",
            "inst/bin/notes.txt",
            "inst/lib/x.so",
            "other/y",
        ] {
            let p = build.join(f);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            crate::fsio::write(&p, f).unwrap();
        }
        let out = t.path().join("out");
        fs::create_dir(&out).unwrap();
        let k = Keep {
            from: "inst".into(),
            paths: vec!["bin/tool".into(), "lib/**".into()],
        };
        assert_eq!(keep(&build, &k, &out).unwrap(), 2);
        let mut got: Vec<String> = vec![];
        let mut stack = vec![out.clone()];
        while let Some(d) = stack.pop() {
            for e in fs::read_dir(&d).unwrap().flatten() {
                if e.file_type().unwrap().is_dir() {
                    stack.push(e.path());
                } else {
                    got.push(e.path().strip_prefix(&out).unwrap().display().to_string());
                }
            }
        }
        got.sort();
        assert_eq!(got, ["bin/tool", "lib/x.so"]);
        // a keep that leaves the build folder is refused
        for bad in [
            Keep {
                from: "../x".into(),
                paths: vec!["*".into()],
            },
            Keep {
                from: "/etc".into(),
                paths: vec!["*".into()],
            },
            Keep {
                from: "inst".into(),
                paths: vec!["../*".into()],
            },
            Keep {
                from: "inst".into(),
                paths: vec![],
            },
        ] {
            assert!(keep(&build, &bad, &out).is_err(), "{bad:?}");
        }
    }

    // [D] tmpfs root
    #[test]
    fn a_passed_build_commits_what_keep_chose() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path().join("runner");
        let build = t.path().join("build");
        fs::create_dir_all(build.join("bin")).unwrap();
        crate::fsio::write(build.join("bin/hub"), "x").unwrap();
        crate::fsio::write(build.join("scratch"), "y").unwrap();
        fs::create_dir_all(&root).unwrap();
        let store = Store::at(&root);
        let mut reg = Register::open(&root).unwrap();
        let k = ArtifactKey("f".repeat(64));
        let part = store.begin("p", Role::Gate, "command", &k).unwrap();
        let kept = Keep {
            from: ".".into(),
            paths: vec!["bin/*".into()],
        };
        let done = finish(part, true, &build, Some(&kept), &mut reg, 9)
            .unwrap()
            .unwrap();
        assert!(done.join("bin/hub").exists() && !done.join("scratch").exists());
        assert_eq!(store.path("p", Role::Gate, "command", &k), Some(done));
    }
}
