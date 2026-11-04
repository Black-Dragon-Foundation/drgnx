//! The browser an agent session gets (docs/guide/agent-browser.md): where to find one ([`resolve`]) and
//! `ratatoskr browser install | list` ([`install`]), which `bin/drgnx browser` runs with the same arguments; in the
//! hub, each browser session's web proxy ([`web`]) and what no grant opens to it ([`nevers`]).
//!
//! Nothing of the commands runs by itself: the download happens only when the user runs `browser install`, and no command reads
//! from the terminal.  Exit 0 when it did what was asked, 1 when it could not (the text is on stderr), 2 for
//! arguments that do not parse.
//!
//! `ratatoskr browser-host` ([`host`], Linux only) is the other end: the process inside a session's sandbox that runs
//! Chromium over its pipe for the hub ([`host_main`]). [`broker`] is the hub's side: the agent's websocket on the
//! session's `cdp.sock`, brokered to that host.

pub mod broker;
#[cfg(target_os = "linux")]
pub mod host;
pub mod install;
pub mod nevers;
pub mod resolve;
pub mod web;

use std::ffi::OsString;

/// `ratatoskr browser-host …` ([`host::main`]); its exit code. Not Linux: 1, as there is no browser host there.
pub fn host_main(args: Vec<OsString>) -> i32 {
    #[cfg(target_os = "linux")]
    {
        host::main(args)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = args;
        eprintln!("ratatoskr browser-host: the browser host is Linux only");
        1
    }
}

use runstav::paths::{Env, config_dir, data_dir};
use serde_json::json;

use crate::settings::{Kv, Settings};

#[derive(Debug, PartialEq, Eq)]
pub struct BrowserCommand {
    pub sub: Sub,
    pub json: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Sub {
    /// `install [--version V]`.
    Install { version: Option<String> },
    /// `list`: the browser sessions would get, the downloads, and the pinned versions.
    List,
}

/// The arguments after `browser`.
pub fn parse(args: impl IntoIterator<Item = OsString>) -> Result<BrowserCommand, String> {
    use lexopt::Arg::{Long, Value};
    use lexopt::ValueExt;
    let mut p = lexopt::Parser::from_args(args);
    let e = |e: lexopt::Error| e.to_string();
    let name = match p.next().map_err(e)? {
        Some(Value(v)) => v.string().map_err(e)?,
        Some(other) => return Err(other.unexpected().to_string()),
        None => return Err("browser needs a subcommand: install or list".into()),
    };
    let (mut json, mut version) = (false, None);
    while let Some(arg) = p.next().map_err(e)? {
        match arg {
            Long("json") => json = true,
            Long("version") if name == "install" => {
                version = Some(p.value().map_err(e)?.string().map_err(e)?);
            }
            other => return Err(other.unexpected().to_string()),
        }
    }
    let sub = match name.as_str() {
        "install" => Sub::Install { version },
        "list" => Sub::List,
        other => return Err(format!("unknown browser subcommand {other:?}")),
    };
    Ok(BrowserCommand { sub, json })
}

/// Run the command; the exit code.
pub fn run(env: &Env, cmd: BrowserCommand) -> i32 {
    let data = data_dir(env);
    match cmd.sub {
        Sub::Install { version } => {
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("drgnx browser install: no async runtime: {e}");
                    return 1;
                }
            };
            let log = |line: &str| {
                if !cmd.json {
                    eprintln!("{line}");
                }
            };
            match runtime.block_on(install::install(&data, version.as_deref(), &log)) {
                Ok(done) if cmd.json => {
                    println!("{}", json!({"ok": true, "installed": done}));
                    0
                }
                Ok(done) => {
                    let how = if done.already {
                        "already installed"
                    } else {
                        "installed"
                    };
                    println!(
                        "{how}: chrome-headless-shell {} (released {}) at {}",
                        done.version,
                        done.released,
                        done.binary.display()
                    );
                    0
                }
                Err(e) => {
                    if cmd.json {
                        println!("{}", json!({"ok": false, "error": e.to_string()}));
                    } else {
                        eprintln!("drgnx browser install: {e}");
                    }
                    1
                }
            }
        }
        Sub::List => {
            let values = Settings::load(&config_dir(env), &Kv::default()).values;
            let found = resolve::resolve(&values, &data);
            let downloads = resolve::installed(&data);
            let pins = install::pins();
            let platform = install::platform_key();
            if cmd.json {
                let pinned: Vec<_> = pins
                    .iter()
                    .map(|p| {
                        let ready = platform
                            .and_then(|k| p.platforms.get(k))
                            .is_some_and(|x| x.sha256.is_some());
                        json!({"version": p.version, "released": p.released, "installable": ready})
                    })
                    .collect();
                let installed: Vec<_> = downloads
                    .iter()
                    .map(|(dir, f)| json!({"version": f.version, "released": f.released, "dir": dir}))
                    .collect();
                let (browser, fix) = match &found {
                    Ok(f) => (json!(f), json!(null)),
                    Err(n) => (json!(null), json!(n.fix)),
                };
                println!(
                    "{}",
                    json!({"browser": browser, "fix": fix, "installed": installed, "pinned": pinned})
                );
            } else {
                match &found {
                    Ok(f) => println!(
                        "sessions get: {} ({:?}, {})",
                        f.path.display(),
                        f.kind,
                        f.version.as_deref().unwrap_or("version unknown")
                    ),
                    Err(n) => println!("sessions get: no browser; {}", n.fix),
                }
                for (dir, f) in &downloads {
                    println!(
                        "downloaded: {} (released {}) in {}",
                        f.version,
                        f.released,
                        dir.display()
                    );
                }
                for p in &pins {
                    let ready = platform
                        .and_then(|k| p.platforms.get(k))
                        .is_some_and(|x| x.sha256.is_some());
                    println!(
                        "pinned: {} (released {}){}",
                        p.version,
                        p.released,
                        if ready {
                            ""
                        } else {
                            ", not installable on this platform yet"
                        }
                    );
                }
            }
            0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(a: &[&str]) -> Vec<OsString> {
        a.iter().map(OsString::from).collect()
    }

    #[test]
    fn parsing() {
        assert_eq!(
            parse(args(&["install"])).unwrap(),
            BrowserCommand {
                sub: Sub::Install { version: None },
                json: false
            }
        );
        assert_eq!(
            parse(args(&["install", "--version", "1.2.3.4", "--json"])).unwrap(),
            BrowserCommand {
                sub: Sub::Install {
                    version: Some("1.2.3.4".into())
                },
                json: true
            }
        );
        assert_eq!(parse(args(&["list", "--json"])).unwrap().sub, Sub::List);
        assert!(parse(args(&[])).is_err());
        assert!(parse(args(&["list", "--version", "1"])).is_err());
        assert!(parse(args(&["frob"])).is_err());
        assert!(parse(args(&["install", "extra"])).is_err());
    }
}
