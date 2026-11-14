//! `ratatoskr recording lint DIR…`: the secret lint (`runstav::recording::lint_run`) over recorded runs, for
//! `bin/drgnx record` (stop, export, check) and the org folder's pre-commit hook.  No hub, no runtime.
//!
//! Each finding is a line on stdout, `FILE:OFFSET: KIND (HEAD…)`: the first four characters of what it found, never the
//! value.  Exit 0 when every run is clean, 1 when any finding was printed (or a run could not be read), 2 for arguments
//! that do not parse.

use std::ffi::OsString;
use std::path::PathBuf;

#[derive(Debug, PartialEq, Eq)]
pub struct RecordingCommand {
    pub dirs: Vec<PathBuf>,
}

/// `lint DIR…`.
pub fn parse(args: impl Iterator<Item = OsString>) -> Result<RecordingCommand, String> {
    let mut args = args;
    match args.next().and_then(|a| a.into_string().ok()).as_deref() {
        Some("lint") => {}
        Some(other) => return Err(format!("unknown recording subcommand {other:?}")),
        None => return Err("recording needs a subcommand: lint DIR…".into()),
    }
    let dirs: Vec<PathBuf> = args.map(PathBuf::from).collect();
    if dirs.is_empty() {
        return Err("recording lint needs at least one DIR".into());
    }
    Ok(RecordingCommand { dirs })
}

/// The lint of every DIR; the exit status.
pub fn run(cmd: &RecordingCommand) -> i32 {
    let mut status = 0;
    for dir in &cmd.dirs {
        match runstav::recording::lint_run(dir) {
            Ok(findings) => {
                for f in &findings {
                    println!("{}: {f}", dir.display());
                }
                if !findings.is_empty() {
                    status = 1;
                }
            }
            Err(e) => {
                eprintln!("ratatoskr recording lint: {e}");
                status = 1;
            }
        }
    }
    status
}

#[cfg(test)]
mod tests {
    use super::*;

    // Pattern D (pure).
    #[test]
    fn lint_takes_directories_and_nothing_else() {
        let a = |v: &[&str]| parse(v.iter().map(OsString::from));
        assert_eq!(
            a(&["lint", "/r/a", "/r/b"]).unwrap().dirs,
            [PathBuf::from("/r/a"), PathBuf::from("/r/b")]
        );
        assert!(a(&["lint"]).is_err());
        assert!(a(&["export", "/r/a"]).is_err());
        assert!(a(&[]).is_err());
    }
}
