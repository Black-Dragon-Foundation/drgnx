//! The `brew` a Mac job runs: a shim, first in the job's `PATH` (`<root>/bin/brew-shim/brew`, a link to the runner's
//! `sleipnir`). A job runs Homebrew read-only and offline, where Homebrew can't name a package's prefix: it loads the
//! formula from its JSON API (a download, under a lock in Homebrew's var) or from the homebrew/core tap (a clone). The
//! shim answers those queries from the prefix's own folders (`--prefix`, `--prefix [--installed] NAME…`,
//! `--cellar [NAME…]`), refuses loudly what needs the network or writes Homebrew, and hands everything else to the real
//! brew, with a note naming the shim when it fails. `docs/develop/sleipnir.md`, "Homebrew in a job". Pure but for
//! [`run`]: the rows run on Linux.

use std::path::{Path, PathBuf};

/// Homebrew's prefix on Apple silicon (the contract's only Mac).
pub const PREFIX: &str = "/opt/homebrew";

/// The shim's folder under the runner root, first in a Mac job's `PATH`.
pub fn shim_dir(root: &Path) -> PathBuf {
    root.join("bin/brew-shim")
}

/// What the shim does with a call.
#[derive(Debug, PartialEq, Eq)]
pub enum Answer {
    /// Print this (a line each) and exit 0.
    Say(Vec<String>),
    /// Print this to stderr and exit 1.
    Fail(String),
    /// Run the real brew.
    Brew,
}

/// The commands that need the network or write Homebrew: refused by name, never handed to brew.
const REFUSED: &[&str] = &[
    "install",
    "reinstall",
    "upgrade",
    "update",
    "update-reset",
    "uninstall",
    "remove",
    "rm",
    "tap",
    "untap",
    "tap-new",
    "fetch",
    "link",
    "ln",
    "unlink",
    "pin",
    "unpin",
    "cleanup",
    "autoremove",
    "postinstall",
    "migrate",
    "bundle",
    "services",
    "edit",
    "create",
    "extract",
    "analytics",
    // brew's aliases of the above
    "up",
    "instal",
    "uninstal",
    "post_install",
];

/// The shim's name in its messages.
const SHIM: &str = "sleipnir's brew shim (a Mac job runs Homebrew read-only and offline)";

/// The shim's answer to `brew ARGS` under PREFIX.
pub fn answer(args: &[String], prefix: &Path) -> Answer {
    let Some(first) = args.first() else {
        return Answer::Brew;
    };
    // the command: the first word that isn't an option (`brew -v install` installs)
    if let Some(cmd) = args.iter().find(|a| !a.starts_with('-'))
        && REFUSED.contains(&cmd.as_str())
        && !matches!(first.as_str(), "--prefix" | "--cellar")
    {
        return Answer::Fail(format!(
            "{SHIM}: `brew {cmd}` needs the network or writes Homebrew; run it in your own account"
        ));
    }
    let (opt, folder) = match first.as_str() {
        "--prefix" => (true, "opt"),
        "--cellar" => (false, "Cellar"),
        _ => return Answer::Brew,
    };
    let mut installed = false;
    let mut names = Vec::new();
    for a in &args[1..] {
        match a.as_str() {
            "--installed" if opt => installed = true,
            x if x.starts_with('-') => return Answer::Brew,
            // a tap's formula (`user/tap/name`) is linked by its own name
            x => names.push(x.rsplit('/').next().unwrap_or(x)),
        }
    }
    if names.is_empty() {
        let p = if opt {
            prefix.to_path_buf()
        } else {
            prefix.join(folder)
        };
        return Answer::Say(vec![p.display().to_string()]);
    }
    let mut out = Vec::new();
    for n in names {
        let p = prefix.join(folder).join(n);
        if installed && !p.exists() {
            return Answer::Fail(format!(
                "{SHIM}: {n} is not installed ({} is missing)",
                p.display()
            ));
        }
        out.push(p.display().to_string());
    }
    Answer::Say(out)
}

/// Runs the shim for `brew ARGS` (the process was started as `brew`): prints its answer, or runs the real brew under
/// [`PREFIX`] and names the shim if that fails. The exit code.
pub fn run(args: &[String]) -> i32 {
    let prefix = Path::new(PREFIX);
    match answer(args, prefix) {
        Answer::Say(lines) => {
            for l in lines {
                println!("{l}");
            }
            0
        }
        Answer::Fail(m) => {
            eprintln!("{m}");
            1
        }
        Answer::Brew => {
            let real = prefix.join("bin/brew");
            match std::process::Command::new(&real).args(args).status() {
                Ok(s) if s.success() => 0,
                Ok(s) => {
                    let code = s.code().unwrap_or(1);
                    eprintln!(
                        "{SHIM}: `brew {}` failed (exit {code}); a call that needs the network or writes Homebrew \
                         fails in a job",
                        args.join(" ")
                    );
                    code
                }
                Err(e) => {
                    eprintln!("{SHIM}: {}: {e}", real.display());
                    1
                }
            }
        }
    }
}

/// Makes `<root>/bin/brew-shim/brew` a link to EXE (the runner's `sleipnir`), replacing a stale one atomically. The
/// shim's folder.
pub fn ensure_shim(root: &Path, exe: &Path) -> Result<PathBuf, String> {
    let dir = shim_dir(root);
    let link = dir.join("brew");
    if std::fs::read_link(&link).ok().as_deref() == Some(exe) {
        return Ok(dir);
    }
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let tmp = dir.join(".brew.new");
    let _ = std::fs::remove_file(&tmp);
    std::os::unix::fs::symlink(exe, &tmp).map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, &link).map_err(|e| format!("{}: {e}", link.display()))?;
    Ok(dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(s: &str) -> Vec<String> {
        s.split_whitespace().map(String::from).collect()
    }

    fn prefix() -> tempfile::TempDir {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(d.path().join("opt/libgccjit")).unwrap();
        d
    }

    /// [D] The prefix queries are answered from the prefix's folders: `--prefix` itself, a formula's opt link (installed
    /// or not, as brew), `--cellar`; with `--installed`, a formula that isn't is a loud failure naming the shim.
    #[test]
    fn prefix_queries_are_answered_offline() {
        let d = prefix();
        let p = d.path();
        let s = |x: &Path| x.display().to_string();
        assert_eq!(answer(&args("--prefix"), p), Answer::Say(vec![s(p)]));
        assert_eq!(
            answer(&args("--prefix --installed libgccjit"), p),
            Answer::Say(vec![s(&p.join("opt/libgccjit"))])
        );
        assert_eq!(
            answer(&args("--prefix libgccjit gmp"), p),
            Answer::Say(vec![s(&p.join("opt/libgccjit")), s(&p.join("opt/gmp"))])
        );
        assert_eq!(
            answer(&args("--prefix homebrew/core/libgccjit --installed"), p),
            Answer::Say(vec![s(&p.join("opt/libgccjit"))])
        );
        match answer(&args("--prefix --installed gmp"), p) {
            Answer::Fail(m) => assert!(m.contains("brew shim") && m.contains("gmp"), "{m}"),
            a => panic!("{a:?}"),
        }
        assert_eq!(
            answer(&args("--cellar"), p),
            Answer::Say(vec![s(&p.join("Cellar"))])
        );
        assert_eq!(
            answer(&args("--cellar gmp"), p),
            Answer::Say(vec![s(&p.join("Cellar/gmp"))])
        );
    }

    /// [D] What needs the network or writes Homebrew fails loudly, naming the shim and the command; never silently.
    #[test]
    fn writes_and_network_are_refused_by_name() {
        let d = prefix();
        for c in [
            "install gmp",
            "update",
            "upgrade",
            "tap a/b",
            "uninstall gmp",
            "fetch gmp",
            "link gmp",
            "cleanup",
            // brew's aliases, and options before the command
            "up",
            "instal gmp",
            "uninstal gmp",
            "post_install gmp",
            "-v install gmp",
            "--debug upgrade",
        ] {
            match answer(&args(c), d.path()) {
                Answer::Fail(m) => {
                    let cmd = c.split_whitespace().find(|w| !w.starts_with('-')).unwrap();
                    assert!(
                        m.contains("brew shim") && m.contains(&format!("brew {cmd}")),
                        "{m}"
                    );
                }
                a => panic!("{c}: {a:?}"),
            }
        }
    }

    /// [D] The shim is a link to the runner's sleipnir, made once and replaced when the runner's binary moves.
    #[test]
    fn the_shim_links_to_the_runner() {
        let d = tempfile::tempdir().unwrap();
        let (a, b) = (
            d.path().join("bin/v1/sleipnir"),
            d.path().join("bin/v2/sleipnir"),
        );
        let dir = ensure_shim(d.path(), &a).unwrap();
        assert_eq!(dir, d.path().join("bin/brew-shim"));
        assert_eq!(std::fs::read_link(dir.join("brew")).unwrap(), a);
        ensure_shim(d.path(), &a).unwrap();
        ensure_shim(d.path(), &b).unwrap();
        assert_eq!(std::fs::read_link(dir.join("brew")).unwrap(), b);
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
    }

    /// [D] Everything else goes to the real brew: reading the Cellar, its version, a query with options the shim
    /// doesn't know.
    #[test]
    fn the_rest_goes_to_brew() {
        let d = prefix();
        for c in [
            "ls -v libgccjit",
            "list",
            "--version",
            "--prefix --unbrewed",
            "config",
            "",
        ] {
            assert_eq!(answer(&args(c), d.path()), Answer::Brew, "{c}");
        }
    }
}
