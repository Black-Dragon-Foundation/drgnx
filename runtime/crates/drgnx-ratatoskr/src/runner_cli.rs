//! `ratatoskr runner …` (`drgnx runner …`): the runners, from a terminal. A user client of the running hub (`ensure`d
//! first): one call each, so the checks are the hub's.
//!
//! ```text
//! runner list [--json]
//! runner add HOST --trust mine|my-cloud|shared [--name N] [--profile dedicated|workstation]
//!                 [--accept all|heavy] [--root DIR] [--prefix P]
//! runner check NAME | bench NAME | unbench NAME
//! runner trust NAME mine|my-cloud|shared
//! runner remove NAME [--yes]
//! runner audit [--key K] [--job J]          (the keys sent to jobs and read by them, oldest first)
//! runner cloud setup aws --regions R[,R…] --sizes S[,S…] [--hub ID]     (prints the role's policy; no hub call)
//! runner cloud setup gcp --project P [--member user:EMAIL] [--hub ID]   (prints the role and its binding; no hub call)
//! runner cloud cost | rotate-ca | off [--yes]
//! ```
//!
//! The output is plain text in 60 columns ([`format_list`]); a runner that is out of rotation shows its reason.
//! Exit 0 when the hub did it, 1 when it answered with an error (its text on stderr), 2 for arguments that do not parse.

use std::ffi::OsString;
use std::time::Duration;

use runstav::paths::Env;
use serde_json::{Value, json};

use crate::cli::ENSURE_TIMEOUT;
use crate::client::Client;

/// How long one quick call to the hub may take.
const CALL: Duration = Duration::from_secs(60);
/// How long `add` may take: the bundle's copy, the pulls and the bench.
const ADD: Duration = Duration::from_secs(3600);

/// The width the list is wrapped to.
pub const WIDTH: usize = 60;

const TRUSTS: [&str; 3] = ["mine", "my-cloud", "shared"];
const PROFILES: [&str; 2] = ["dedicated", "workstation"];
const ACCEPTS: [&str; 2] = ["all", "heavy"];

#[derive(Debug, PartialEq, Eq)]
pub enum RunnerCommand {
    List {
        json: bool,
    },
    /// One call to the hub: its method and params.
    Call {
        method: &'static str,
        params: Value,
    },
    /// `remove`, which deletes a folder: without `--yes` it says what it would do.
    Remove {
        name: String,
        yes: bool,
    },
    /// `cloud setup aws`: the IAM policy the user creates for drgnx's role, printed (no hub call; drgnx never creates
    /// IAM itself).
    CloudSetupAws {
        hub: String,
        regions: Vec<String>,
        sizes: Vec<String>,
    },
    /// `cloud off`, which ends machines and deletes images: without `--yes` it says what it would do.
    CloudOff {
        yes: bool,
    },
    /// `cloud setup gcp`: the custom role and the `gcloud` commands that create and bind it, printed (no hub call).
    CloudSetupGcp {
        hub: String,
        project: String,
        member: Option<String>,
    },
}

/// What `cloud setup gcp` prints: the role to save, the command that creates it, and the binding for a project of
/// drgnx's own and for one shared with other VMs (with the condition). MEMBER is who drgnx acts as.
pub fn setup_gcp_text(hub: &str, project: &str, member: Option<&str>) -> String {
    use crate::runners::cloud::gcp;
    let member = member.unwrap_or("user:YOUR-ACCOUNT");
    let own = gcp::setup_commands(project, member, false);
    let shared = gcp::setup_commands(project, member, true);
    format!(
        "# drgnx's role in {project}: save it as drgnx-gcp-role.json\n{}\n\
         # create it, then bind it to the account drgnx acts as, in a project of drgnx's own:\n{}\n{}\n\
         # in a project shared with other VMs, bind it with the condition instead (instances named drgnx-… only):\n{}\n\
         # drgnx labels its machines and disks drgnx-hub={hub}; it never creates IAM itself\n",
        gcp::ROLE.trim_end(),
        own[0],
        own[1],
        shared[1]
    )
}

fn one_of(what: &str, v: String, allowed: &[&str]) -> Result<String, String> {
    if allowed.contains(&v.as_str()) {
        Ok(v)
    } else {
        Err(format!(
            "{what} is one of {}, not {v:?}",
            allowed.join(", ")
        ))
    }
}

/// The arguments after `runner`.
pub fn parse(args: impl IntoIterator<Item = OsString>) -> Result<RunnerCommand, String> {
    use lexopt::Arg::{Long, Value as Word};
    use lexopt::ValueExt;
    let mut p = lexopt::Parser::from_args(args);
    let e = |e: lexopt::Error| e.to_string();
    let sub = match p.next().map_err(e)? {
        Some(Word(v)) => v.string().map_err(e)?,
        Some(other) => return Err(other.unexpected().to_string()),
        None => {
            return Err("runner needs a subcommand (list, add, check, bench, trust, unbench, remove, audit, cloud)".into());
        }
    };
    let mut words: Vec<String> = Vec::new();
    let mut opts: Vec<(&'static str, String)> = Vec::new();
    let (mut json_out, mut yes) = (false, false);
    let known: &[&'static str] = match sub.as_str() {
        "list" => &["json"],
        "add" => &["trust", "name", "profile", "accept", "root", "prefix"],
        "remove" => &["yes"],
        "audit" => &["key", "job"],
        "cloud" => &["hub", "regions", "sizes", "project", "member", "yes"],
        "check" | "bench" | "trust" | "unbench" => &[],
        other => return Err(format!("unknown runner subcommand {other:?}")),
    };
    while let Some(arg) = p.next().map_err(e)? {
        match arg {
            Word(v) => words.push(v.string().map_err(e)?),
            Long("json") if known.contains(&"json") => json_out = true,
            Long("yes") if known.contains(&"yes") => yes = true,
            Long(name) => match known.iter().find(|k| **k == name) {
                Some(k) if *k != "json" && *k != "yes" => {
                    opts.push((k, p.value().map_err(e)?.string().map_err(e)?))
                }
                _ => return Err(format!("runner {sub}: unknown option --{name}")),
            },
            other => return Err(other.unexpected().to_string()),
        }
    }
    let opt = |k: &str| opts.iter().find(|(n, _)| *n == k).map(|(_, v)| v.clone());
    let want = |n: usize, usage: &str| {
        if words.len() == n {
            Ok(())
        } else {
            Err(format!("usage: runner {usage}"))
        }
    };
    let by_name = |method: &'static str, words: &[String]| RunnerCommand::Call {
        method,
        params: json!({"name": words[0]}),
    };
    match sub.as_str() {
        "list" => {
            want(0, "list [--json]")?;
            Ok(RunnerCommand::List { json: json_out })
        }
        "add" => {
            want(
                1,
                "add HOST --trust mine|my-cloud|shared [--name N] [--profile P] [--accept A] [--root DIR] [--prefix P]",
            )?;
            let trust = opt("trust").ok_or("runner add needs --trust mine|my-cloud|shared")?;
            let mut params = json!({"host": words[0], "trust": one_of("--trust", trust, &TRUSTS)?});
            if let Some(v) = opt("name") {
                params["name"] = json!(v);
            }
            if let Some(v) = opt("profile") {
                params["profile"] = json!(one_of("--profile", v, &PROFILES)?);
            }
            if let Some(v) = opt("accept") {
                params["accept"] = json!(one_of("--accept", v, &ACCEPTS)?);
            }
            for k in ["root", "prefix"] {
                if let Some(v) = opt(k) {
                    params[k] = json!(v);
                }
            }
            Ok(RunnerCommand::Call {
                method: "runners/add",
                params,
            })
        }
        "check" => {
            want(1, "check NAME")?;
            Ok(by_name("runners/check", &words))
        }
        "bench" => {
            want(1, "bench NAME")?;
            Ok(by_name("runners/bench", &words))
        }
        "unbench" => {
            want(1, "unbench NAME")?;
            Ok(by_name("runners/unbench", &words))
        }
        "trust" => {
            want(2, "trust NAME mine|my-cloud|shared")?;
            let trust = one_of("trust", words[1].clone(), &TRUSTS)?;
            Ok(RunnerCommand::Call {
                method: "runners/set",
                params: json!({"name": words[0], "trust": trust}),
            })
        }
        "remove" => {
            want(1, "remove NAME [--yes]")?;
            Ok(RunnerCommand::Remove {
                name: words[0].clone(),
                yes,
            })
        }
        "audit" => {
            want(0, "audit [--key K] [--job J]")?;
            let mut params = serde_json::Map::new();
            for k in ["key", "job"] {
                if let Some(v) = opt(k) {
                    params.insert(k.into(), json!(v));
                }
            }
            Ok(RunnerCommand::Call {
                method: "runners/audit",
                params: Value::Object(params),
            })
        }
        "cloud" => {
            let usage = "usage: runner cloud setup aws --regions R[,R…] --sizes S[,S…] [--hub ID]\n       \
                         runner cloud setup gcp --project P [--member user:EMAIL] [--hub ID]";
            // the id the hub's runner code tags with today (runners::methods)
            let hub = opt("hub").unwrap_or_else(|| "hub".into());
            let plain = opt("hub").is_none()
                && opt("regions").is_none()
                && opt("sizes").is_none()
                && opt("project").is_none()
                && opt("member").is_none();
            if words == ["off"] && plain {
                return Ok(RunnerCommand::CloudOff { yes });
            }
            if yes {
                return Err("usage: runner cloud off [--yes]".into());
            }
            for (word, method) in [
                ("cost", "runners/cloud/cost"),
                ("rotate-ca", "runners/cloud/rotate-ca"),
            ] {
                if words == [word] && plain {
                    return Ok(RunnerCommand::Call {
                        method,
                        params: json!({}),
                    });
                }
            }
            if words == ["setup", "gcp"] {
                let project = opt("project").ok_or(usage)?;
                if opt("regions").is_some() || opt("sizes").is_some() {
                    return Err(usage.into());
                }
                return Ok(RunnerCommand::CloudSetupGcp {
                    hub,
                    project,
                    member: opt("member"),
                });
            }
            if words != ["setup", "aws"] || opt("project").is_some() || opt("member").is_some() {
                return Err(usage.into());
            }
            let list = |k: &str| -> Vec<String> {
                opt(k)
                    .unwrap_or_default()
                    .split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string)
                    .collect()
            };
            let (regions, sizes) = (list("regions"), list("sizes"));
            if regions.is_empty() || sizes.is_empty() {
                return Err(usage.into());
            }
            Ok(RunnerCommand::CloudSetupAws {
                hub,
                regions,
                sizes,
            })
        }
        _ => unreachable!("the subcommand was checked above"),
    }
}

/// `HH:MM` (UTC) of SECS since the epoch.
fn clock(secs: f64) -> String {
    let s = secs as u64 % 86_400;
    format!("{:02}:{:02}", s / 3600, s / 60 % 60)
}

/// Words wrapped to [`WIDTH`], each line after the first indented by INDENT.
fn wrap(text: &str, indent: usize) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    let mut cur = " ".repeat(indent);
    let mut empty = true;
    for w in text.split_whitespace() {
        if !empty && cur.chars().count() + 1 + w.chars().count() > WIDTH {
            lines.push(std::mem::replace(&mut cur, " ".repeat(indent)));
            empty = true;
        }
        if !empty {
            cur.push(' ');
        }
        cur.push_str(w);
        empty = false;
    }
    lines.push(cur);
    lines
}

/// The runner list as the design shows it, in plain text of at most [`WIDTH`] columns: a runner is its state dot, its
/// name, trust, profile and accept; then its size, jobs, disk and last check; a runner that is out of rotation says why
/// on a line of its own.
pub fn format_list(list: &Value) -> String {
    let runners = list["runners"].as_array().cloned().unwrap_or_default();
    if runners.is_empty() {
        return "no runners: drgnx runner add HOST --trust mine\n".into();
    }
    let mut out = String::new();
    for r in &runners {
        let s = |k: &str| r[k].as_str().unwrap_or("").to_string();
        let n = |k: &str| r[k].as_u64().unwrap_or(0);
        let state = s("state");
        let ready = state == "ready";
        let dot = if ready { "●" } else { "○" };
        let head = format!(
            "{dot} {:<14} {:<9} {} · {}",
            s("name").chars().take(14).collect::<String>(),
            s("trust"),
            s("profile"),
            s("accept")
        );
        out.push_str(&head.chars().take(WIDTH).collect::<String>());
        out.push('\n');
        let mut line = format!(
            "  {} cores · {}G · {} running · {}G free",
            n("cores"),
            n("mem_mib") / 1024,
            n("jobs"),
            n("disk_free_gb")
        );
        if let Some(t) = r["checked"].as_f64() {
            line.push_str(&format!(" · {}", clock(t)));
        }
        out.push_str(&line.chars().take(WIDTH).collect::<String>());
        out.push('\n');
        if !ready {
            for l in wrap(&state, 2) {
                out.push_str(&l);
                out.push('\n');
            }
        }
    }
    out
}

/// What `remove` without `--yes` says.
fn remove_note(name: &str) -> String {
    format!(
        "runner remove {name}: stops our units and containers there and deletes the runner's folder.\n\
         nothing changed: run again with --yes\n"
    )
}

/// What `cloud off` without `--yes` says.
fn cloud_off_note() -> String {
    "runner cloud off: ends every cloud machine of ours and deletes our images, snapshots and security group.\n\
     nothing changed: run again with --yes\n"
        .into()
}

/// `runner …`: the exit code.
pub fn run(env: &Env, cmd: RunnerCommand) -> i32 {
    let (method, params, within, json_out) = match cmd {
        RunnerCommand::List { json } => ("runners/list", json!({}), CALL, json),
        RunnerCommand::Call { method, params } => (
            method,
            params,
            if method == "runners/add" { ADD } else { CALL },
            true,
        ),
        RunnerCommand::Remove { name, yes } => {
            if !yes {
                print!("{}", remove_note(&name));
                return 0;
            }
            (
                "runners/remove",
                json!({"name": name, "confirm": true}),
                ADD,
                true,
            )
        }
        RunnerCommand::CloudOff { yes } => {
            if !yes {
                print!("{}", cloud_off_note());
                return 0;
            }
            ("runners/cloud/off", json!({}), ADD, true)
        }
        RunnerCommand::CloudSetupAws {
            hub,
            regions,
            sizes,
        } => {
            println!(
                "{}",
                crate::runners::cloud::aws::policy_for(&hub, &regions, &sizes)
            );
            return 0;
        }
        RunnerCommand::CloudSetupGcp {
            hub,
            project,
            member,
        } => {
            print!("{}", setup_gcp_text(&hub, &project, member.as_deref()));
            return 0;
        }
    };
    let hub = crate::supervise::ensure_quiet(env, ENSURE_TIMEOUT);
    if hub != 0 {
        return hub;
    }
    match Client::user(env, Duration::from_secs(5)).and_then(|mut c| c.call(method, params, within))
    {
        Ok(a) => {
            if json_out || method != "runners/list" {
                println!("{a}");
            } else {
                print!("{}", format_list(&a));
            }
            0
        }
        Err(e) => {
            eprintln!("ratatoskr runner: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(args: &[&str]) -> Result<RunnerCommand, String> {
        parse(args.iter().map(OsString::from))
    }

    fn runner(name: &str, state: &str) -> Value {
        json!({"name": name, "host": "h", "trust": "mine", "profile": "dedicated", "accept": "all",
            "root": "/r", "prefix": "drgnx", "arch": "x86_64", "os": "Fedora", "cores": 16, "mem_mib": 31744,
            "disk_free_gb": 81, "podman": "5.4", "linger": true, "landlock_abi": 8, "features": [],
            "state": state, "strikes": 0, "jobs": 4, "checked": 50_520.0})
    }

    /// Pattern D: the list is the design's columns, in at most 60 columns, a runner that is out of rotation says why.
    #[test]
    fn list_matches_the_designs_columns() {
        let text = format_list(&json!({"runners": [
            runner("desktop", "ready"),
            runner("a-long-runner-name-here", "benched: image pull failed twice (14:02, 14:20), and the next check is not due before the user takes a look"),
        ]}));
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines[0], "● desktop        mine      dedicated · all");
        assert_eq!(lines[1], "  16 cores · 31G · 4 running · 81G free · 14:02");
        assert!(lines[2].starts_with("○ a-long-runner-"), "{text}");
        assert!(
            text.contains("benched: image pull failed twice (14:02, 14:20)"),
            "{text}"
        );
        for l in &lines {
            assert!(l.chars().count() <= WIDTH, "{l:?} is over {WIDTH} columns");
        }
        assert!(
            lines[3].starts_with("  16 cores"),
            "a ready runner is two lines: {text}"
        );
        assert!(lines[4].starts_with("  benched: image pull"), "{text}");
        assert!(format_list(&json!({"runners": []})).starts_with("no runners"));
    }

    // [D] pure
    #[test]
    fn the_arguments_become_the_hubs_calls() {
        assert_eq!(
            p(&["list", "--json"]),
            Ok(RunnerCommand::List { json: true })
        );
        assert_eq!(
            p(&[
                "add",
                "desk",
                "--trust",
                "mine",
                "--profile",
                "workstation",
                "--root",
                "/srv/r"
            ]),
            Ok(RunnerCommand::Call {
                method: "runners/add",
                params: json!({"host": "desk", "trust": "mine", "profile": "workstation", "root": "/srv/r"}),
            })
        );
        assert_eq!(
            p(&["trust", "desk", "shared"]),
            Ok(RunnerCommand::Call {
                method: "runners/set",
                params: json!({"name": "desk", "trust": "shared"}),
            })
        );
        assert_eq!(
            p(&["remove", "desk"]),
            Ok(RunnerCommand::Remove {
                name: "desk".into(),
                yes: false
            })
        );
        // the key audit: every row, or one key's, or one job's
        assert_eq!(
            p(&["audit"]),
            Ok(RunnerCommand::Call {
                method: "runners/audit",
                params: json!({}),
            })
        );
        assert_eq!(
            p(&["audit", "--key", "CRATES_IO_TOKEN", "--job", "x1"]),
            Ok(RunnerCommand::Call {
                method: "runners/audit",
                params: json!({"key": "CRATES_IO_TOKEN", "job": "x1"}),
            })
        );
        for bad in [
            &[][..],
            &["frobnicate"],
            &["add", "desk"],
            &["add", "desk", "--trust", "friends"],
            &["add", "desk", "--trust", "mine", "--accept", "some"],
            &["trust", "desk", "friends"],
            &["check"],
            &["list", "extra"],
            &["remove", "desk", "--json"],
            &["audit", "x1"],
            &["audit", "--since", "1d"],
        ] {
            assert!(p(bad).is_err(), "{bad:?} should not parse");
        }
        assert!(remove_note("desk").contains("run again with --yes"));
        assert_eq!(
            p(&[
                "cloud",
                "setup",
                "aws",
                "--regions",
                "eu-west-1,us-east-1",
                "--sizes",
                "m7g.large"
            ]),
            Ok(RunnerCommand::CloudSetupAws {
                hub: "hub".into(),
                regions: vec!["eu-west-1".into(), "us-east-1".into()],
                sizes: vec!["m7g.large".into()],
            })
        );
        assert_eq!(
            p(&["cloud", "cost"]),
            Ok(RunnerCommand::Call {
                method: "runners/cloud/cost",
                params: json!({})
            })
        );
        assert_eq!(
            p(&["cloud", "rotate-ca"]),
            Ok(RunnerCommand::Call {
                method: "runners/cloud/rotate-ca",
                params: json!({})
            })
        );
        assert_eq!(
            p(&["cloud", "off"]),
            Ok(RunnerCommand::CloudOff { yes: false })
        );
        assert_eq!(
            p(&["cloud", "off", "--yes"]),
            Ok(RunnerCommand::CloudOff { yes: true })
        );
        assert!(p(&["cloud", "cost", "--yes"]).is_err());
        assert!(cloud_off_note().contains("run again with --yes"));
        assert!(p(&["cloud", "setup", "aws", "--sizes", "m7g.large"]).is_err());
        assert!(p(&["cloud", "setup", "gcp", "--regions", "r", "--sizes", "s"]).is_err());
        assert_eq!(
            p(&["cloud", "setup", "gcp", "--project", "p1"]),
            Ok(RunnerCommand::CloudSetupGcp {
                hub: "hub".into(),
                project: "p1".into(),
                member: None,
            })
        );
        assert_eq!(
            p(&[
                "cloud",
                "setup",
                "gcp",
                "--project",
                "p1",
                "--member",
                "user:me@example.org"
            ]),
            Ok(RunnerCommand::CloudSetupGcp {
                hub: "hub".into(),
                project: "p1".into(),
                member: Some("user:me@example.org".into()),
            })
        );
        let out = setup_gcp_text("hub", "p1", None);
        assert!(out.contains("\"includedPermissions\""), "{out}");
        assert!(
            out.contains("gcloud iam roles create drgnxRunner --project=p1"),
            "{out}"
        );
        assert!(
            out.contains(&crate::runners::cloud::gcp::condition("p1")),
            "{out}"
        );
    }
}
