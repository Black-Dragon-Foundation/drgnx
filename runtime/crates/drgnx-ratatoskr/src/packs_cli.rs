//! `ratatoskr packs …` (`drgnx packs …`): the language pack tools.
//!
//! ```text
//! packs check DIR [--builtin] [--other DIR]…
//! ```
//!
//! `check` reads the pack in DIR the way sync will (skald: the manifest, every file it names, the `highlights.scm`
//! subset, and, unless `--builtin`, the command, install, reserved-name and claim rules against the packs given with
//! `--other`). Needs no hub. Exit 0 when the pack passes, 1 when it does not (a line per problem on stderr), 2 for
//! arguments that do not parse.

use std::ffi::OsString;
use std::path::PathBuf;

use skald::{Claims, Source, check_dir};

#[derive(Debug, PartialEq, Eq)]
pub enum PacksCommand {
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
        Some(Word(v)) => return Err(format!("unknown packs subcommand {v:?}")),
        _ => return Err("packs needs a subcommand (check)".into()),
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
    let PacksCommand::Check {
        dir,
        builtin,
        others,
    } = cmd;
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
