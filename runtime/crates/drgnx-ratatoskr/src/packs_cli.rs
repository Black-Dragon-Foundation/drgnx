//! `ratatoskr packs …` (`drgnx packs …`): the language pack tools.
//!
//! ```text
//! packs check DIR [--builtin] [--other DIR]…
//! packs sync --plan FILE [--out FILE]
//! packs load-check LIB NAME MIN_ABI [FILE=PATH]…
//! packs pin REPO COMMIT [--src DIR]
//! ```
//!
//! `pin` fetches a grammar at a commit and prints the `:repo`, `:commit`, `:tree-sha256` and `:src` of its
//! `:grammars` entry, with the ABI its `parser.c` declares (a comment line); it refuses a commit with no `parser.c`.
//!
//! `sync --plan` is the pack job's grammar half (`skald::job`): the plan (an `.eld` plist) lists the grammars to fetch
//! and build, and the answer, `(:ok t :staged (…))` or `(:ok nil :error "…")`, goes to `--out` (or stdout). Every
//! library is load-checked in a child of this same binary (`load-check`), so a grammar that crashes or loops there
//! fails the job and nothing else. Exit 0 when it staged, 1 when it did not.
//!
//! `load-check` is that child: it loads LIB, checks the ABI, compiles the queries, prints one answer line
//! (`skald::job::check_answer`) and exits 0, or 2 (ABI), 3 (query) or 4 (load).
//!
//! `check` reads the pack in DIR the way sync will (skald: the manifest, every file it names, the `highlights.scm`
//! subset, and, unless `--builtin`, the command, install, reserved-name and claim rules against the packs given with
//! `--other`). Needs no hub. Exit 0 when the pack passes, 1 when it does not (a line per problem on stderr), 2 for
//! arguments that do not parse.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use skald::{Claims, Source, check_dir};

#[derive(Debug, PartialEq, Eq)]
pub enum PacksCommand {
    Sync {
        plan: PathBuf,
        out: Option<PathBuf>,
    },
    Pin {
        repo: String,
        commit: String,
        src: String,
    },
    LoadCheck {
        lib: PathBuf,
        name: String,
        min_abi: u32,
        queries: Vec<(String, PathBuf)>,
    },
    Check {
        dir: PathBuf,
        builtin: bool,
        others: Vec<PathBuf>,
    },
}

/// The arguments after `packs`.
pub fn parse(args: impl IntoIterator<Item = OsString>) -> Result<PacksCommand, String> {
    use lexopt::Arg::{Long, Value as Word};
    let mut p = lexopt::Parser::from_args(args);
    let e = |e: lexopt::Error| e.to_string();
    match p.next().map_err(e)? {
        Some(Word(v)) if v == "check" => {}
        Some(Word(v)) if v == "sync" => {
            let (mut plan, mut out) = (None, None);
            while let Some(arg) = p.next().map_err(e)? {
                match arg {
                    Long("plan") => plan = Some(PathBuf::from(p.value().map_err(e)?)),
                    Long("out") => out = Some(PathBuf::from(p.value().map_err(e)?)),
                    other => return Err(other.unexpected().to_string()),
                }
            }
            let plan = plan.ok_or("usage: packs sync --plan FILE [--out FILE]")?;
            return Ok(PacksCommand::Sync { plan, out });
        }
        Some(Word(v)) if v == "pin" => {
            let (mut words, mut src) = (Vec::new(), "src".to_string());
            while let Some(arg) = p.next().map_err(e)? {
                match arg {
                    Word(v) => words.push(v.to_string_lossy().into_owned()),
                    Long("src") => src = p.value().map_err(e)?.to_string_lossy().into_owned(),
                    other => return Err(other.unexpected().to_string()),
                }
            }
            let [repo, commit] = words.as_slice() else {
                return Err("usage: packs pin REPO COMMIT [--src DIR]".into());
            };
            return Ok(PacksCommand::Pin {
                repo: repo.clone(),
                commit: commit.clone(),
                src,
            });
        }
        Some(Word(v)) if v == "load-check" => {
            let words: Vec<OsString> = p.raw_args().map_err(e)?.collect();
            let usage = "usage: packs load-check LIB NAME MIN_ABI [FILE=PATH]…";
            let [lib, name, abi, rest @ ..] = words.as_slice() else {
                return Err(usage.into());
            };
            let min_abi = abi.to_str().and_then(|a| a.parse().ok()).ok_or(usage)?;
            let mut queries = Vec::new();
            for q in rest {
                let q = q.to_str().ok_or(usage)?;
                let (file, path) = q.split_once('=').ok_or(usage)?;
                queries.push((file.to_string(), PathBuf::from(path)));
            }
            return Ok(PacksCommand::LoadCheck {
                lib: PathBuf::from(lib),
                name: name.to_str().ok_or(usage)?.to_string(),
                min_abi,
                queries,
            });
        }
        Some(Word(v)) => return Err(format!("unknown packs subcommand {v:?}")),
        _ => return Err("packs needs a subcommand (check, sync, load-check)".into()),
    }
    let (mut dir, mut builtin, mut others) = (None, false, Vec::new());
    while let Some(arg) = p.next().map_err(e)? {
        match arg {
            Word(v) if dir.is_none() => dir = Some(PathBuf::from(v)),
            Long("builtin") => builtin = true,
            Long("other") => others.push(PathBuf::from(p.value().map_err(e)?)),
            Long(name) => return Err(format!("packs check: unknown option --{name}")),
            other => return Err(other.unexpected().to_string()),
        }
    }
    let dir = dir.ok_or("usage: packs check DIR [--builtin] [--other DIR]…")?;
    Ok(PacksCommand::Check {
        dir,
        builtin,
        others,
    })
}

/// `packs …`: the exit code.
pub fn run(cmd: PacksCommand) -> i32 {
    let (dir, builtin, others) = match cmd {
        PacksCommand::Check {
            dir,
            builtin,
            others,
        } => (dir, builtin, others),
        PacksCommand::Sync { plan, out } => return sync(&plan, out.as_deref()),
        PacksCommand::Pin { repo, commit, src } => {
            return match skald::job::pin(&repo, &commit, &src) {
                Ok((tree, abi)) => {
                    println!(
                        "(:repo {} :commit {} :tree-sha256 {} :src {})  ; ABI {}",
                        lisp_string(&repo),
                        lisp_string(&commit),
                        lisp_string(&tree),
                        lisp_string(&src),
                        abi.map_or("?".to_string(), |a| a.to_string())
                    );
                    0
                }
                Err(e) => {
                    eprintln!("{e}");
                    1
                }
            };
        }
        PacksCommand::LoadCheck {
            lib,
            name,
            min_abi,
            queries,
        } => return load_check(&lib, &name, min_abi, &queries),
    };
    let source = if builtin {
        Source::Builtin
    } else {
        Source::Fetched
    };
    let mut claims = Claims::default();
    for o in &others {
        let r = check_dir(o, Source::Builtin, &Claims::default());
        match r.manifest {
            Some(m) => claims.add_pack(&m),
            None => {
                eprintln!("{}: not a readable pack", o.display());
                return 1;
            }
        }
    }
    let report = check_dir(&dir, source, &claims);
    for q in &report.problems {
        eprintln!("{}: {:?}: {}", q.path, q.kind, q.message);
    }
    if report.problems.is_empty() {
        let name = report.manifest.map(|m| m.pack).unwrap_or_default();
        println!("{name}: ok");
        0
    } else {
        1
    }
}

/// The child of a sync: one answer line, and an exit code the parent does not need (it reads the line).
fn load_check(lib: &Path, name: &str, min_abi: u32, queries: &[(String, PathBuf)]) -> i32 {
    let mut texts = Vec::new();
    for (file, path) in queries {
        match std::fs::read_to_string(path) {
            Ok(t) => texts.push((file.clone(), t)),
            Err(e) => {
                println!("load {file}: {e}");
                return 4;
            }
        }
    }
    let r = skald::job::check_library(lib, name, min_abi, &texts);
    println!("{}", skald::job::check_answer(&r));
    match r {
        Ok(_) => 0,
        Err(skald::job::JobError::Abi { .. }) => 2,
        Err(skald::job::JobError::Query { .. }) => 3,
        Err(_) => 4,
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PlanUnit {
    name: String,
    repo: String,
    commit: String,
    tree_sha256: String,
    #[serde(default = "default_src")]
    src: String,
}

fn default_src() -> String {
    "src".into()
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PlanQuery {
    grammar: String,
    file: String,
    path: PathBuf,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Plan {
    version: i64,
    staging: PathBuf,
    #[serde(default = "default_abi")]
    min_abi: u32,
    #[serde(default)]
    units: Vec<PlanUnit>,
    #[serde(default)]
    queries: Vec<PlanQuery>,
}

fn default_abi() -> u32 {
    15
}

fn lisp_string(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

fn read_plan(path: &Path) -> Result<Plan, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let nodes = huginn::read::read_all(&bytes, huginn::read::Limits::default())
        .map_err(|e| format!("the plan: {e}"))?;
    let [node] = nodes.as_slice() else {
        return Err("the plan is one plist".into());
    };
    let plan: Plan = serde_path_to_error::deserialize(huginn::de::Deserializer::new(node))
        .map_err(|e| format!("the plan: {}: {}", e.path(), e.inner().message))?;
    if plan.version != 1 {
        return Err(format!(
            "plan version {} is not one this drgnx reads (1)",
            plan.version
        ));
    }
    Ok(plan)
}

/// `packs sync --plan`: the answer is `(:ok t :staged …)` or `(:ok nil :error …)`.
fn sync(plan_path: &Path, out: Option<&Path>) -> i32 {
    let answer = (|| -> Result<String, String> {
        let plan = read_plan(plan_path)?;
        let units: Vec<skald::job::Unit> = plan
            .units
            .into_iter()
            .map(|u| skald::job::Unit {
                name: u.name,
                repo: u.repo,
                commit: u.commit,
                tree_sha256: u.tree_sha256,
                src: u.src,
            })
            .collect();
        let mut queries = Vec::new();
        for q in plan.queries {
            let text = std::fs::read_to_string(&q.path)
                .map_err(|e| format!("{}: {e}", q.path.display()))?;
            queries.push(skald::job::Query {
                grammar: q.grammar,
                file: q.file,
                text,
            });
        }
        let mut opts = skald::job::Options::new(plan.staging, plan.min_abi);
        opts.checker = Some(std::env::current_exe().map_err(|e| e.to_string())?);
        let staged = skald::job::run(&units, &queries, &opts).map_err(|e| e.to_string())?;
        let rows: Vec<String> = staged
            .iter()
            .map(|s| {
                format!(
                    "(:name {} :commit {} :tree-sha256 {} :lib {} :lib-sha256 {} :abi {})",
                    lisp_string(&s.name),
                    lisp_string(&s.commit),
                    lisp_string(&s.tree_sha256),
                    lisp_string(&s.lib.to_string_lossy()),
                    lisp_string(&s.lib_sha256),
                    s.abi
                )
            })
            .collect();
        Ok(format!("(:ok t :staged ({}))\n", rows.join("\n  ")))
    })();
    let (text, code) = match answer {
        Ok(t) => (t, 0),
        Err(e) => (format!("(:ok nil :error {})\n", lisp_string(&e)), 1),
    };
    match out {
        Some(p) => {
            if let Err(e) = std::fs::write(p, &text) {
                eprintln!("{}: {e}", p.display());
                return 1;
            }
        }
        None => print!("{text}"),
    }
    code
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(a: &[&str]) -> Vec<OsString> {
        a.iter().map(OsString::from).collect()
    }

    #[test]
    fn check_takes_a_folder_and_options() {
        assert_eq!(
            parse(args(&["check", "p", "--builtin", "--other", "q"])),
            Ok(PacksCommand::Check {
                dir: "p".into(),
                builtin: true,
                others: vec!["q".into()]
            })
        );
        assert!(parse(args(&["check"])).is_err());
        assert!(parse(args(&["check", "p", "--nope"])).is_err());
        assert!(parse(args(&["list"])).is_err());
        assert_eq!(
            parse(args(&["sync", "--plan", "p.eld", "--out", "o.eld"])),
            Ok(PacksCommand::Sync {
                plan: "p.eld".into(),
                out: Some("o.eld".into())
            })
        );
        assert!(parse(args(&["sync"])).is_err());
        assert_eq!(
            parse(args(&[
                "load-check",
                "l.so",
                "json",
                "15",
                "q/tags.scm=/tmp/x"
            ])),
            Ok(PacksCommand::LoadCheck {
                lib: "l.so".into(),
                name: "json".into(),
                min_abi: 15,
                queries: vec![("q/tags.scm".into(), "/tmp/x".into())]
            })
        );
        assert!(parse(args(&["load-check", "l.so", "json", "x"])).is_err());
    }

    #[test]
    fn a_missing_pack_fails_and_a_good_one_passes() {
        let d = std::env::temp_dir().join(format!("packs-cli-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let cmd = |dir: &std::path::Path| PacksCommand::Check {
            dir: dir.into(),
            builtin: false,
            others: vec![],
        };
        assert_eq!(run(cmd(&d)), 1);
        std::fs::write(
            d.join("pack.eld"),
            r#"(:pack "scala" :schema 1 :version "1" :name "Scala" :summary "s" :license "MIT")"#,
        )
        .unwrap();
        assert_eq!(run(cmd(&d)), 0);
        std::fs::remove_dir_all(&d).unwrap();
    }
}
