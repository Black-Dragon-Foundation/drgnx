//! `ratatoskr outside bind|unbind|list`: the user's bindings of outside agents (Claude Code, Codex, … started outside
//! drgnx) from a terminal.  A user client of the running hub, `ensure`d first: each subcommand is one hub method
//! (`outside/bind`, `outside/unbind`, `outside/bindings`), so the checks are the hub's.
//!
//! Output is text, or the method's answer as one JSON line with `--json`.  Exit 0 when the command did what was asked,
//! 1 when it did not (an error, an unbind of no binding), 2 for arguments that do not parse.

use std::ffi::OsString;
use std::path::PathBuf;
use std::time::Duration;

use runstav::paths::Env;
use serde_json::{Value, json};

use crate::cli::ENSURE_TIMEOUT;
use crate::client::Client;

/// How long one call to the hub may take (a bind runs git once).
const CALL: Duration = Duration::from_secs(30);

pub const USAGE: &str = "usage: ratatoskr outside bind --kind K --root DIR --role manager|worker|chat [--json]\n\
    \x20      ratatoskr outside unbind ID [--json]\n\
    \x20      ratatoskr outside list [--json]";

#[derive(Debug, PartialEq, Eq)]
pub struct OutsideCommand {
    pub sub: Sub,
    pub json: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Sub {
    Bind {
        kind: String,
        root: PathBuf,
        role: String,
    },
    Unbind(String),
    List,
}

/// The arguments after `outside`.
pub fn parse(args: impl IntoIterator<Item = OsString>) -> Result<OutsideCommand, String> {
    use lexopt::Arg::{Long, Value as Word};
    use lexopt::ValueExt;
    let mut p = lexopt::Parser::from_args(args);
    let e = |e: lexopt::Error| e.to_string();
    let sub = match p.next().map_err(e)? {
        Some(Word(v)) => v.string().map_err(e)?,
        Some(other) => return Err(other.unexpected().to_string()),
        None => return Err(format!("outside needs a subcommand\n{USAGE}")),
    };
    let (mut kind, mut root, mut role, mut id, mut json) = (None, None, None, None, false);
    while let Some(arg) = p.next().map_err(e)? {
        match arg {
            Long("json") => json = true,
            Long("kind") if sub == "bind" => {
                kind = Some(p.value().map_err(e)?.string().map_err(e)?)
            }
            Long("root") if sub == "bind" => root = Some(PathBuf::from(p.value().map_err(e)?)),
            Long("role") if sub == "bind" => {
                let r = p.value().map_err(e)?.string().map_err(e)?;
                if !matches!(r.as_str(), "manager" | "worker" | "chat") {
                    return Err(format!("--role is manager, worker or chat, not {r:?}"));
                }
                role = Some(r);
            }
            Word(v) if sub == "unbind" && id.is_none() => id = Some(v.string().map_err(e)?),
            other => return Err(other.unexpected().to_string()),
        }
    }
    let sub = match sub.as_str() {
        "bind" => Sub::Bind {
            kind: kind.ok_or("outside bind needs --kind")?,
            root: root.ok_or("outside bind needs --root")?,
            role: role.ok_or("outside bind needs --role")?,
        },
        "unbind" => Sub::Unbind(id.ok_or("outside unbind needs the binding's ID")?),
        "list" => Sub::List,
        other => return Err(format!("unknown outside subcommand {other:?}\n{USAGE}")),
    };
    Ok(OutsideCommand { sub, json })
}

impl OutsideCommand {
    /// The method and its params; a relative `--root` is taken from CWD.
    pub fn call(&self, cwd: &std::path::Path) -> (&'static str, Value) {
        match &self.sub {
            Sub::Bind { kind, root, role } => (
                "outside/bind",
                json!({"kind": kind, "root": cwd.join(root), "role": role}),
            ),
            Sub::Unbind(id) => ("outside/unbind", json!({"id": id})),
            Sub::List => ("outside/bindings", json!({})),
        }
    }
}

/// The answer A of a call as text.
fn text(sub: &Sub, a: &Value) -> String {
    let line = |b: &Value| {
        format!(
            "{}  {} agents in {} act as {}",
            b["id"].as_str().unwrap_or(""),
            b["kind"].as_str().unwrap_or(""),
            b["root"].as_str().unwrap_or(""),
            b["role"].as_str().unwrap_or("")
        )
    };
    match sub {
        Sub::Bind { .. } => line(a),
        Sub::Unbind(id) if a == &json!(true) => format!("{id}: unbound"),
        Sub::Unbind(id) => format!("{id}: no such binding"),
        Sub::List => {
            let rows = a["bindings"].as_array().cloned().unwrap_or_default();
            if rows.is_empty() {
                "no bindings".into()
            } else {
                rows.iter().map(line).collect::<Vec<_>>().join("\n")
            }
        }
    }
}

/// `outside …`: the exit code.
pub fn run(env: &Env, cmd: OutsideCommand) -> i32 {
    let cwd = std::env::current_dir().unwrap_or_default();
    let (method, params) = cmd.call(&cwd);
    let hub = crate::supervise::ensure_quiet(env, ENSURE_TIMEOUT);
    if hub != 0 {
        return hub;
    }
    match Client::user(env, Duration::from_secs(5)).and_then(|mut c| c.call(method, params, CALL)) {
        Ok(a) => {
            if cmd.json {
                println!("{a}");
            } else {
                println!("{}", text(&cmd.sub, &a));
            }
            i32::from(matches!(cmd.sub, Sub::Unbind(_)) && a != json!(true))
        }
        Err(e) => {
            eprintln!("ratatoskr outside: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn p(args: &[&str]) -> Result<OutsideCommand, String> {
        parse(args.iter().map(OsString::from))
    }

    #[test]
    fn outside_cli_parses_bind_unbind_list() {
        let c = p(&[
            "bind", "--kind", "claude", "--root", "org", "--role", "worker", "--json",
        ])
        .unwrap();
        assert_eq!(
            c,
            OutsideCommand {
                sub: Sub::Bind {
                    kind: "claude".into(),
                    root: "org".into(),
                    role: "worker".into()
                },
                json: true
            }
        );
        assert_eq!(
            c.call(Path::new("/w")),
            (
                "outside/bind",
                json!({"kind": "claude", "root": "/w/org", "role": "worker"})
            )
        );
        // an absolute root is kept as given
        let abs = p(&[
            "bind", "--kind", "codex", "--root", "/x/y", "--role", "chat",
        ])
        .unwrap();
        assert_eq!(abs.call(Path::new("/w")).1["root"], "/x/y");
        let u = p(&["unbind", "binding:claude-0123456789ab"]).unwrap();
        assert_eq!(
            (u.call(Path::new("/w")), u.json),
            (
                (
                    "outside/unbind",
                    json!({"id": "binding:claude-0123456789ab"})
                ),
                false
            )
        );
        assert_eq!(
            p(&["list", "--json"]).unwrap().call(Path::new("/w")),
            ("outside/bindings", json!({}))
        );
        assert_eq!(text(&Sub::List, &json!({"bindings": []})), "no bindings");
        assert_eq!(
            text(&Sub::Unbind("b".into()), &json!(false)),
            "b: no such binding"
        );
        for bad in [
            &[][..],
            &["frobnicate"],
            &["bind", "--kind", "claude", "--root", "/x"],
            &[
                "bind", "--kind", "claude", "--root", "/x", "--role", "admin",
            ],
            &["bind", "--root", "/x", "--role", "worker"],
            &["unbind"],
            &["unbind", "a", "b"],
            &["list", "--kind", "claude"],
        ] {
            assert!(p(bad).is_err(), "{bad:?} should not parse");
        }
    }
}
