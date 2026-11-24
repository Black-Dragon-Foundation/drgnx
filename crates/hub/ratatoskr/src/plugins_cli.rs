//! `ratatoskr plugins …` (`drgnx plugins …`): installing plugins from a terminal.
//!
//! ```text
//! plugins install PATH [--replace]
//! plugins list [--json]
//! plugins remove NAME
//! ```
//!
//! `install` and `remove` work on the data folder (`<data>/plugins`) and need no hub; a running hub is told afterwards,
//! so its card appears at once. `list` asks the hub (`plugins/list`, started when none runs). Installing never
//! approves: the card, the Extensions view and Settings → Plugins do, with the hash they show. Exit 0 when it worked,
//! 1 when it did not (its text on stderr), 2 for arguments that do not parse.

use std::ffi::OsString;
use std::path::PathBuf;
use std::time::Duration;

use runstav::paths::{Env, data_dir};
use serde_json::{Value, json};

use crate::cli::ENSURE_TIMEOUT;
use crate::client::Client;

/// How long one call to the hub may take.
const CALL: Duration = Duration::from_secs(30);

#[derive(Debug, PartialEq, Eq)]
pub enum PluginsCommand {
    Install { path: PathBuf, replace: bool },
    List { json: bool },
    Remove { name: String },
}

/// The arguments after `plugins`.
pub fn parse(args: impl IntoIterator<Item = OsString>) -> villa::Result<PluginsCommand> {
    use lexopt::Arg::{Long, Value as Word};
    use lexopt::ValueExt;
    let mut p = lexopt::Parser::from_args(args);
    let e = |e: lexopt::Error| villa::Error::invalid(e.to_string());
    let sub = match p.next().map_err(e)? {
        Some(Word(v)) => v.string().map_err(e)?,
        Some(other) => return Err(villa::Error::invalid(other.unexpected().to_string())),
        None => {
            return Err(villa::Error::invalid(
                "plugins needs a subcommand (install, list, remove)",
            ));
        }
    };
    let mut words: Vec<OsString> = Vec::new();
    let (mut replace, mut json_out) = (false, false);
    while let Some(arg) = p.next().map_err(e)? {
        match (sub.as_str(), arg) {
            (_, Word(v)) => words.push(v),
            ("install", Long("replace")) => replace = true,
            ("list", Long("json")) => json_out = true,
            (s, Long(name)) => {
                return Err(villa::Error::invalid(format!(
                    "plugins {s}: unknown option --{name}"
                )));
            }
            (_, other) => return Err(villa::Error::invalid(other.unexpected().to_string())),
        }
    }
    let one = |usage: &str| -> villa::Result<OsString> {
        match words.as_slice() {
            [w] => Ok(w.clone()),
            _ => Err(villa::Error::invalid(format!("usage: plugins {usage}"))),
        }
    };
    match sub.as_str() {
        "install" => Ok(PluginsCommand::Install {
            path: PathBuf::from(
                one("install PATH [--replace]")
                    .map_err(|e| villa::Error::invalid(e.to_string()))?,
            ),
            replace,
        }),
        "list" if words.is_empty() => Ok(PluginsCommand::List { json: json_out }),
        "list" => Err(villa::Error::invalid("usage: plugins list [--json]")),
        "remove" => Ok(PluginsCommand::Remove {
            name: one("remove NAME")
                .map_err(|e| villa::Error::invalid(e.to_string()))?
                .into_string()
                .map_err(|_| villa::Error::invalid("a plugin name is plain text"))?,
        }),
        other => Err(villa::Error::invalid(format!(
            "unknown plugins subcommand {other:?}"
        ))),
    }
}

/// What `list` prints: a plugin a line, its state, its version, and what it waits for.
pub fn format_list(list: &Value) -> String {
    let plugins = list["plugins"].as_array().cloned().unwrap_or_default();
    if plugins.is_empty() {
        return "no plugins: drgnx plugins install PATH\n".into();
    }
    let mut out = String::new();
    for p in &plugins {
        let s = |k: &str| p[k].as_str().unwrap_or("").to_string();
        let state = s("state");
        out.push_str(&format!(
            "{:<12} {:<16} {}\n",
            state,
            s("name"),
            p["version"].as_str().unwrap_or("-")
        ));
        match state.as_str() {
            "unapproved" | "changed" => out.push_str(&format!(
                "  approve it in drgnx (Extensions or Settings → Plugins) · {}\n",
                s("hash")
            )),
            "broken" => out.push_str(&format!("  {}\n", s("problem"))),
            _ => {}
        }
    }
    out
}

/// `plugins …`: the exit code.
pub fn run(env: &Env, cmd: PluginsCommand) -> i32 {
    let root = data_dir(env).join("plugins");
    match cmd {
        PluginsCommand::Install { path, replace } => {
            match crate::plugins::install(&root, &path, replace) {
                Ok(i) => {
                    crate::soft::out_line(&format!(
                        "installed {} {}\nhash {}\napprove it in drgnx (Extensions or Settings → Plugins)",
                        i.name, i.version, i.hash
                    ));
                    tell_hub(env);
                    0
                }
                Err(e) => {
                    crate::soft::err_line(&format!("ratatoskr plugins: {e}"));
                    1
                }
            }
        }
        PluginsCommand::Remove { name } => match crate::plugins::remove(&root, &name) {
            Ok(()) => {
                crate::soft::out_line(&format!("removed {name}"));
                tell_hub(env);
                0
            }
            Err(e) => {
                crate::soft::err_line(&format!("ratatoskr plugins: {e}"));
                1
            }
        },
        PluginsCommand::List { json: json_out } => {
            let hub = crate::supervise::ensure_quiet(env, ENSURE_TIMEOUT);
            if hub != 0 {
                return hub;
            }
            match Client::user(env, Duration::from_secs(5))
                .and_then(|mut c| c.call("plugins/list", json!({}), CALL))
            {
                Ok(a) if json_out => {
                    crate::soft::out_line(&a.to_string());
                    0
                }
                Ok(a) => {
                    crate::soft::out_text(&format_list(&a));
                    0
                }
                Err(e) => {
                    crate::soft::err_line(&format!("ratatoskr plugins: {e}"));
                    1
                }
            }
        }
    }
}

/// A hub that runs looks at the folder now (its cards, its events). One that does not has nothing to be told.
fn tell_hub(env: &Env) {
    if let Ok(mut c) = Client::user(env, Duration::from_secs(2)) {
        crate::soft::done(c.call("plugins/list", json!({}), CALL), "plugins_cli");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(args: &[&str]) -> villa::Result<PluginsCommand> {
        parse(args.iter().map(OsString::from))
    }

    // [D] pure
    #[test]
    fn the_arguments_become_commands() {
        assert_eq!(
            p(&["install", "/x/y"]),
            Ok(PluginsCommand::Install {
                path: "/x/y".into(),
                replace: false
            })
        );
        assert_eq!(
            p(&["install", "--replace", "y"]),
            Ok(PluginsCommand::Install {
                path: "y".into(),
                replace: true
            })
        );
        assert_eq!(
            p(&["list", "--json"]),
            Ok(PluginsCommand::List { json: true })
        );
        assert_eq!(
            p(&["remove", "alpha"]),
            Ok(PluginsCommand::Remove {
                name: "alpha".into()
            })
        );
        for bad in [
            &[][..],
            &["frobnicate"],
            &["install"],
            &["install", "a", "b"],
            &["install", "a", "--json"],
            &["list", "x"],
            &["remove", "a", "--replace"],
        ] {
            assert!(p(bad).is_err(), "{bad:?} should not parse");
        }
    }

    // [D] pure
    #[test]
    fn the_list_says_what_waits_for_you() {
        let t = format_list(&json!({"plugins": [
            {"name": "alpha", "version": "1.0.0", "state": "approved", "hash": "a"},
            {"name": "beta", "version": "0.2.0", "state": "unapproved", "hash": "b"},
            {"name": "gamma", "state": "broken", "problem": "name: bad"},
        ]}));
        assert!(t.contains("approved     alpha"), "{t}");
        assert!(
            t.contains("approve it in drgnx (Extensions or Settings → Plugins) · b"),
            "{t}"
        );
        assert!(t.contains("  name: bad"), "{t}");
        assert!(format_list(&json!({"plugins": []})).starts_with("no plugins"));
    }
}
