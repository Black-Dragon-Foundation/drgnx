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
pub mod check;
#[cfg(target_os = "linux")]
pub mod host;
pub mod install;
pub mod nevers;
pub mod resolve;
pub mod web;

/// The two names a session's CDP endpoint is given under. The hub sets both; an editor's value for either is dropped.
pub const ENDPOINT_ENV: [&str; 2] = ["PLAYWRIGHT_MCP_CDP_ENDPOINT", "DRGNX_BROWSER_CDP"];

/// A session's CDP secret: 32 random bytes. It travels in the agent's environment only: its `Debug` never shows it,
/// and nothing logs the endpoint's path.
#[derive(Clone, PartialEq, Eq)]
pub struct Secret(pub [u8; 32]);

impl Secret {
    /// 32 fresh bytes from the kernel.
    pub fn new() -> std::io::Result<Secret> {
        use std::io::Read;
        let mut b = [0u8; 32];
        std::fs::File::open("/dev/urandom")?.read_exact(&mut b)?;
        Ok(Secret(b))
    }

    /// The bytes as 64 lower-case hex digits, as the URL carries them.
    pub fn hex(&self) -> String {
        self.0.iter().map(|b| format!("{b:02x}")).collect()
    }

    /// The endpoint the agent connects to through its CDP relay PORT: `ws://127.0.0.1:PORT/devtools/browser/HEX`.
    pub fn endpoint(&self, port: u16) -> String {
        format!("ws://127.0.0.1:{port}{}{}", broker::PATH_PREFIX, self.hex())
    }
}

impl std::fmt::Debug for Secret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Secret(…)")
    }
}

/// A session's memory cap (`agents-session-memory`: digits and an optional K, M, G or T, powers of 1024) in bytes.
pub fn memory_bytes(text: &str) -> Option<u64> {
    let (digits, unit) = match text.char_indices().last()? {
        (i, c) if c.is_ascii_alphabetic() => (&text[..i], c),
        _ => (text, 'B'),
    };
    let n: u64 = digits.parse().ok().filter(|n| *n > 0)?;
    let shift = match unit {
        'B' => 0,
        'K' => 10,
        'M' => 20,
        'G' => 30,
        'T' => 40,
        _ => return None,
    };
    n.checked_mul(1 << shift)
}

/// Whether CURRENT bytes are above HIGH percent of CAP.
pub fn over_high(current: u64, cap: u64, high: u32) -> bool {
    u128::from(current) * 100 > u128::from(cap) * u128::from(high)
}

/// A browser session's memory watch (Linux, with a user systemd): its scope's cgroup is read once (`systemctl --user
/// show -P ControlGroup UNIT`, within 2 s), then its `memory.current` every second; each time it rises above HIGH
/// percent of CAP, STOP is called (`BrokerHandle::stop("memory")`, which does nothing while the browser is not
/// running). It ends when the cgroup goes, or when STOP says the session is gone (false).
pub async fn memory_watch(unit: String, cap: u64, high: u32, stop: impl Fn() -> bool) {
    let cg = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        tokio::process::Command::new("systemctl")
            .args(["--user", "show", "-P", "ControlGroup", &unit])
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output(),
    )
    .await;
    let cg = match cg {
        Ok(Ok(o)) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_owned(),
        _ => {
            tracing::info!(unit = %unit, "no memory watch: the scope's cgroup is not known");
            return;
        }
    };
    if !cg.starts_with('/') {
        tracing::info!(unit = %unit, "no memory watch: the scope has no cgroup");
        return;
    }
    let file = std::path::Path::new("/sys/fs/cgroup")
        .join(cg.trim_start_matches('/'))
        .join("memory.current");
    let mut above = false;
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        let Some(current) = tokio::fs::read_to_string(&file)
            .await
            .ok()
            .and_then(|t| t.trim().parse::<u64>().ok())
        else {
            return;
        };
        let now = over_high(current, cap, high);
        if now && !above && !stop() {
            return;
        }
        above = now;
    }
}

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

    #[test]
    fn the_secret_is_never_shown_and_the_memory_mark_is_a_share_of_the_cap() {
        let s = Secret([0xab; 32]);
        assert_eq!(format!("{s:?}"), "Secret(…)");
        assert!(!format!("{:?}", Some(&s)).contains("ab"));
        assert_eq!(
            s.endpoint(9222),
            format!("ws://127.0.0.1:9222/devtools/browser/{}", "ab".repeat(32))
        );
        assert_ne!(Secret::new().unwrap(), Secret::new().unwrap());
        assert_eq!(memory_bytes("4G"), Some(4 << 30));
        assert_eq!(memory_bytes("512M"), Some(512 << 20));
        assert_eq!(memory_bytes("1000"), Some(1000));
        for bad in ["", "0", "4 G", "G", "4X", "-1G"] {
            assert_eq!(memory_bytes(bad), None, "{bad}");
        }
        let cap = 4 << 30;
        assert!(!over_high(cap / 4 * 3, cap, 75));
        assert!(over_high(cap / 4 * 3 + 1, cap, 75));
    }
}
