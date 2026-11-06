//! An agent's job never changes the user's packages (docs/guide/extensions.md, "Suggested by an agent"): the hub refuses
//! an agent's `exec/start` whose argv installs, updates, syncs or removes packages, whatever the sandbox would allow.
//! Only the user's own jobs (the Extensions view's) do that.

/// drgnx's commands that change packages (`bin/drgnx sync|upgrade|…`, and `drgnx update`, which changes drgnx itself).
const DRGNX_COMMANDS: &[&str] = &[
    "pkg", "sync", "upgrade", "rollback", "lock", "bisect", "update",
];

/// The Lisp an Emacs would run to change packages: Emacs's package functions and drgnx's package layer.
const LISP: &[&str] = &[
    "package-install",
    "package-install-file",
    "package-install-from-buffer",
    "package-upgrade",
    "package-upgrade-all",
    "package-reinstall",
    "package-delete",
    "package-vc-install",
    "package-vc-upgrade",
    "package-vc-upgrade-all",
    "drgnx-pkg",
];

/// Where one shell command ends inside an argument (`sh -c "a; b && c"`).
fn is_separator(c: char) -> bool {
    matches!(c, ';' | '&' | '|' | '\n' | '`')
}

/// Where one word ends: blanks, quotes, Lisp's parentheses, `=` (`--eval=(…)`) and `$(`.
fn is_break(c: char) -> bool {
    c.is_whitespace()
        || matches!(
            c,
            '\'' | '"' | '(' | ')' | '=' | '$' | '{' | '}' | '<' | '>'
        )
}

fn basename(word: &str) -> &str {
    word.rsplit('/').next().unwrap_or(word)
}

/// ARGV as the commands it runs, each a list of words: ARGV itself, and every argument that holds blanks (a shell's
/// `-c` string, an Emacs's `-eval`) cut at the shell's separators.
fn commands(argv: &[String]) -> Vec<Vec<&str>> {
    let mut out = vec![argv.iter().map(String::as_str).collect::<Vec<_>>()];
    for a in argv
        .iter()
        .skip(1)
        .filter(|a| a.chars().any(char::is_whitespace))
    {
        out.extend(
            a.split(is_separator)
                .map(|seg| {
                    seg.split(is_break)
                        .filter(|w| !w.is_empty())
                        .collect::<Vec<_>>()
                })
                .filter(|seg| !seg.is_empty()),
        );
    }
    out
}

/// Why ARGV changes the user's packages, or `None`: a drgnx package command (`drgnx upgrade`, `bin/drgnx pkg`), the
/// package layer run as a program or loaded into an Emacs (`drgnx-pkg …`, `-l drgnx-pkg`), or an Emacs whose Lisp
/// calls a package function (`emacs --batch -eval "(package-install 'x)"`), in ARGV or in a shell string it holds.
/// Text that only names them (`grep drgnx-pkg core/`) is not refused.
pub fn changes_packages(argv: &[String]) -> Option<String> {
    let cmds = commands(argv);
    for words in &cmds {
        for (i, w) in words.iter().enumerate() {
            let next = words.get(i + 1).copied().unwrap_or("");
            if basename(w) == "drgnx" && DRGNX_COMMANDS.contains(&next) {
                return Some(format!("drgnx {next}"));
            }
            let stem = basename(w).trim_end_matches(".elc").trim_end_matches(".el");
            let loaded = i > 0 && matches!(words[i - 1], "-l" | "--load");
            if stem == "drgnx-pkg" && (i == 0 || loaded) {
                return Some("drgnx-pkg".into());
            }
        }
    }
    // an Emacs (or emacsclient, which reaches your running one) with a package function in its Lisp
    let words: Vec<&str> = argv
        .iter()
        .flat_map(|a| a.split(|c| is_break(c) || is_separator(c)))
        .filter(|w| !w.is_empty())
        .collect();
    if words.iter().any(|w| basename(w).starts_with("emacs")) {
        for w in &words {
            if let Some(f) = LISP
                .iter()
                .find(|f| *w == **f || (**f == "drgnx-pkg" && w.starts_with("drgnx-pkg-")))
            {
                return Some(format!("an Emacs that runs {f}"));
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    /// Pure (D): the package commands of drgnx, its Lisp package layer and Emacs's own, as argv or inside a shell
    /// command, are refused.
    #[test]
    fn package_commands_are_refused() {
        for a in [
            &["bin/drgnx", "pkg", "install", "magit"][..],
            &["/opt/drgnx/bin/drgnx", "upgrade", "--only", "magit"],
            &["drgnx", "sync"],
            &["drgnx", "rollback", "3"],
            &["drgnx-pkg", "install", "magit"],
            &[
                "emacs",
                "--batch",
                "-l",
                "drgnx-pkg",
                "-f",
                "drgnx-pkg-cli",
                "--",
                "sync",
            ],
            &["emacs", "--batch", "-eval", "(package-install 'magit)"],
            &[
                "emacs-31.1",
                "-Q",
                "--batch",
                "--eval=(progn (require 'package) (package-vc-install \"x\"))",
            ],
            &["sh", "-c", "cd /tmp && bin/drgnx upgrade"],
            &[
                "bash",
                "-lc",
                "true; emacs --batch --eval \"(package-upgrade 'magit)\"",
            ],
        ] {
            assert!(changes_packages(&argv(a)).is_some(), "{a:?}");
        }
    }

    /// Pure (D): ordinary jobs, drgnx's other commands and text that only names the package layer run.
    #[test]
    fn other_jobs_run() {
        for a in [
            &["make", "test"][..],
            &["bin/drgnx", "test"],
            &["bin/drgnx", "doctor"],
            &["grep", "-rn", "drgnx-pkg", "core/"],
            &["rg", "package-install", "lisp/"],
            &[
                "emacs",
                "--batch",
                "-l",
                "ert",
                "-l",
                "test/unit/pkg-test.el",
                "-f",
                "ert-run-tests-batch-and-exit",
            ],
            &["cargo", "test", "-p", "norn"],
        ] {
            assert_eq!(changes_packages(&argv(a)), None, "{a:?}");
        }
    }
}
