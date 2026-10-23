//! `ratatoskr graph …` (Urdr Task 17; storage §8): the store's commands from a terminal.  A user client of the
//! running hub, `ensure`d first: every subcommand is one hub method (`graph/export`, `graph/import`, `graph/backup`,
//! `graph/revert`, `graph/excise`, `graph/scrub`, `graph/grants`, `graph/sql`, `graph/compact`, `graph/proposed`),
//! so the class checks, the deny-list and the one writer are the hub's, never this process's.
//!
//! Output is text, or the method's answer as one JSON line with `--json`.  Exit 0 when the command did what was
//! asked, 1 when it did not (an error, a failed backup, a revert that was blocked).
//!
//! `excise` is permanent: on a terminal it asks first, and without one it needs `--yes`.

use std::ffi::OsString;
use std::io::{BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use runstav::paths::Env;
use serde_json::{Value, json};

use crate::cli::ENSURE_TIMEOUT;
use crate::client::Client;

/// A backup, an export or a scrub of a big store takes a while; the hub answers when it is done.
const LONG: Duration = Duration::from_secs(600);

pub const USAGE: &str = "usage: ratatoskr graph export [--project P --out DIR] [--since TX] [--with activity] [--history] [--json]\n\
    \x20      ratatoskr graph import DIR [--json]\n\
    \x20      ratatoskr graph backup [now] [--json]\n\
    \x20      ratatoskr graph revert --tx N | --entity ID --to-ver V [--cascade] [--json]\n\
    \x20      ratatoskr graph excise ID|TX [--field F]... --reason R [--rotate-backups] [--transcripts] [--yes] [--json]\n\
    \x20      ratatoskr graph scrub [--json]\n\
    \x20      ratatoskr graph grants [list [--who W] | grant WHO WHAT [--access read|edit-user-tasks] [--expires T] | revoke ID] [--json]\n\
    \x20      ratatoskr graph sql 'SELECT …' [--json]\n\
    \x20      ratatoskr graph compact [--dry-run] [--json]\n\
    \x20      ratatoskr graph proposed accept|reject TX... [--json]";

#[derive(Debug, PartialEq, Eq)]
pub struct GraphCommand {
    pub sub: Sub,
    pub json: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Sub {
    Export {
        project: Option<String>,
        out: Option<PathBuf>,
        since: Option<u64>,
        with_activity: bool,
        history: bool,
    },
    Import {
        dir: PathBuf,
    },
    Backup,
    Revert {
        tx: Option<u64>,
        entity: Option<String>,
        to_ver: Option<u64>,
        cascade: bool,
    },
    Excise {
        target: String,
        fields: Vec<String>,
        reason: String,
        rotate_backups: bool,
        transcripts: bool,
        yes: bool,
    },
    Scrub,
    Grants(GrantsSub),
    Sql(String),
    Compact {
        dry_run: bool,
    },
    Proposed {
        accept: Vec<u64>,
        reject: Vec<u64>,
    },
}

#[derive(Debug, PartialEq, Eq)]
pub enum GrantsSub {
    List {
        who: Option<String>,
    },
    Grant {
        who: String,
        what: String,
        access: String,
        expires: Option<String>,
    },
    Revoke(String),
}

fn num(v: &str, what: &str) -> Result<u64, String> {
    v.parse()
        .map_err(|_| format!("{what} takes a whole number, not {v:?}"))
}

/// The arguments after `graph`.
pub fn parse(args: impl IntoIterator<Item = OsString>) -> Result<GraphCommand, String> {
    use lexopt::Arg::{Long, Value as Word};
    use lexopt::ValueExt;
    let mut p = lexopt::Parser::from_args(args);
    let e = |e: lexopt::Error| e.to_string();
    let name = match p.next().map_err(e)? {
        Some(Word(v)) => v.string().map_err(e)?,
        Some(other) => return Err(other.unexpected().to_string()),
        None => return Err("graph needs a subcommand".into()),
    };
    let mut json = false;
    // words and options, in order; each subcommand reads what it knows
    let mut words: Vec<String> = Vec::new();
    let mut opts: Vec<(String, Option<String>)> = Vec::new();
    // options that take a value
    let valued = [
        "project", "out", "since", "tx", "entity", "to-ver", "field", "reason", "who", "access",
        "expires", "with",
    ];
    while let Some(arg) = p.next().map_err(e)? {
        match arg {
            Long("json") => json = true,
            Long(k) if valued.contains(&k) => {
                let k = k.to_string();
                let v = p.value().map_err(e)?.string().map_err(e)?;
                opts.push((k, Some(v)));
            }
            Long(k) => opts.push((k.to_string(), None)),
            Word(v) => words.push(v.string().map_err(e)?),
            other => return Err(other.unexpected().to_string()),
        }
    }
    let known = |allowed: &[&str]| -> Result<(), String> {
        match opts.iter().find(|(k, _)| !allowed.contains(&k.as_str())) {
            Some((k, _)) => Err(format!("graph {name}: unknown option --{k}")),
            None => Ok(()),
        }
    };
    let get = |k: &str| {
        opts.iter()
            .rev()
            .find(|(o, _)| o == k)
            .and_then(|(_, v)| v.clone())
    };
    let flag = |k: &str| opts.iter().any(|(o, _)| o == k);
    let no_words = |n: usize| -> Result<(), String> {
        if words.len() > n {
            Err(format!("graph {name}: unexpected argument {:?}", words[n]))
        } else {
            Ok(())
        }
    };
    let sub = match name.as_str() {
        "export" => {
            known(&["project", "out", "since", "with", "history"])?;
            no_words(0)?;
            let project = get("project");
            let out = get("out").map(PathBuf::from);
            if project.is_some() && out.is_none() {
                return Err(
                    "graph export --project needs --out DIR (it never writes into a repository unless --out names it)"
                        .into(),
                );
            }
            let with_activity = match get("with").as_deref() {
                None => false,
                Some("activity") => true,
                Some(other) => return Err(format!("--with takes activity, not {other:?}")),
            };
            Sub::Export {
                project,
                out,
                since: get("since").map(|s| num(&s, "--since")).transpose()?,
                with_activity,
                history: flag("history"),
            }
        }
        "import" => {
            known(&[])?;
            no_words(1)?;
            Sub::Import {
                dir: words
                    .first()
                    .map(PathBuf::from)
                    .ok_or("graph import needs DIR")?,
            }
        }
        "backup" => {
            known(&[])?;
            match words.first().map(String::as_str) {
                None | Some("now") => {}
                Some(other) => return Err(format!("graph backup takes `now`, not {other:?}")),
            }
            no_words(1)?;
            Sub::Backup
        }
        "revert" => {
            known(&["tx", "entity", "to-ver", "cascade"])?;
            no_words(0)?;
            let (tx, entity) = (get("tx"), get("entity"));
            match (&tx, &entity) {
                (Some(_), Some(_)) | (None, None) => {
                    return Err("graph revert takes --tx N, or --entity ID --to-ver V".into());
                }
                (None, Some(_)) if get("to-ver").is_none() => {
                    return Err("graph revert --entity needs --to-ver V".into());
                }
                (Some(_), None) if get("to-ver").is_some() => {
                    return Err("--to-ver goes with --entity".into());
                }
                _ => {}
            }
            Sub::Revert {
                tx: tx.map(|s| num(&s, "--tx")).transpose()?,
                entity,
                to_ver: get("to-ver").map(|s| num(&s, "--to-ver")).transpose()?,
                cascade: flag("cascade"),
            }
        }
        "excise" => {
            known(&["field", "reason", "rotate-backups", "transcripts", "yes"])?;
            no_words(1)?;
            Sub::Excise {
                target: words
                    .first()
                    .cloned()
                    .ok_or("graph excise needs an ID or a TX")?,
                fields: opts
                    .iter()
                    .filter(|(k, _)| k == "field")
                    .filter_map(|(_, v)| v.clone())
                    .collect(),
                reason: get("reason").ok_or("graph excise needs --reason R")?,
                rotate_backups: flag("rotate-backups"),
                transcripts: flag("transcripts"),
                yes: flag("yes"),
            }
        }
        "scrub" => {
            known(&[])?;
            no_words(0)?;
            Sub::Scrub
        }
        "grants" => {
            known(&["who", "access", "expires"])?;
            let mut w = words.iter().map(String::as_str);
            let g = match w.next() {
                None | Some("list") => {
                    no_words(1)?;
                    GrantsSub::List { who: get("who") }
                }
                Some("grant") => {
                    no_words(3)?;
                    GrantsSub::Grant {
                        who: w
                            .next()
                            .ok_or("graph grants grant needs WHO and WHAT")?
                            .into(),
                        what: w
                            .next()
                            .ok_or("graph grants grant needs WHO and WHAT")?
                            .into(),
                        access: get("access").unwrap_or_else(|| "read".into()),
                        expires: get("expires"),
                    }
                }
                Some("revoke") => {
                    no_words(2)?;
                    GrantsSub::Revoke(w.next().ok_or("graph grants revoke needs an ID")?.into())
                }
                Some(other) => return Err(format!("unknown grants subcommand {other:?}")),
            };
            Sub::Grants(g)
        }
        "sql" => {
            known(&[])?;
            no_words(1)?;
            Sub::Sql(words.first().cloned().ok_or("graph sql needs a SELECT")?)
        }
        "compact" => {
            known(&["dry-run"])?;
            no_words(0)?;
            Sub::Compact {
                dry_run: flag("dry-run"),
            }
        }
        "proposed" => {
            known(&[])?;
            let which = words.first().map(String::as_str);
            let ids = words
                .iter()
                .skip(1)
                .map(|s| num(s, "a tx"))
                .collect::<Result<Vec<_>, _>>()?;
            if ids.is_empty() {
                return Err("graph proposed accept|reject needs at least one TX".into());
            }
            match which {
                Some("accept") => Sub::Proposed {
                    accept: ids,
                    reject: Vec::new(),
                },
                Some("reject") => Sub::Proposed {
                    accept: Vec::new(),
                    reject: ids,
                },
                _ => return Err("graph proposed takes accept or reject, then TX...".into()),
            }
        }
        other => return Err(format!("unknown graph subcommand {other:?}")),
    };
    Ok(GraphCommand { sub, json })
}

/// `--expires T`: unix seconds, or a time from NOW such as `90s`, `30m`, `12h`, `7d`.
fn expires_at(text: &str, now: f64) -> Result<f64, String> {
    let bad = || format!("--expires takes unix seconds or a span like 12h or 7d, not {text:?}");
    if let Ok(secs) = text.parse::<f64>() {
        return Ok(secs);
    }
    let (n, unit) = text.split_at(text.len().saturating_sub(1));
    let n: f64 = n.parse().map_err(|_| bad())?;
    let unit = match unit {
        "s" => 1.0,
        "m" => 60.0,
        "h" => 3600.0,
        "d" => 86400.0,
        _ => return Err(bad()),
    };
    Ok(now + n * unit)
}

fn absolute(p: &Path, cwd: &Path) -> String {
    cwd.join(p).to_string_lossy().into_owned()
}

impl GraphCommand {
    /// The hub method and its params.  CWD makes `--out` and `import DIR` absolute; NOW (unix seconds) is the base of
    /// a relative `--expires`.
    pub fn request(&self, cwd: &Path, now: f64) -> Result<(&'static str, Value), String> {
        Ok(match &self.sub {
            Sub::Export {
                project,
                out,
                since,
                with_activity,
                history,
            } => {
                let mut p = json!({});
                if let Some(v) = project {
                    p["project"] = json!(v);
                }
                if let Some(v) = out {
                    p["out"] = json!(absolute(v, cwd));
                }
                if let Some(v) = since {
                    p["since"] = json!(v);
                }
                if *with_activity {
                    p["with_activity"] = json!(true);
                }
                if *history {
                    p["history"] = json!(true);
                }
                ("graph/export", p)
            }
            Sub::Import { dir } => ("graph/import", json!({"dir": absolute(dir, cwd)})),
            Sub::Backup => ("graph/backup", json!({})),
            Sub::Revert {
                tx,
                entity,
                to_ver,
                cascade,
            } => {
                let mut p = json!({});
                if let Some(v) = tx {
                    p["tx"] = json!(v);
                }
                if let Some(v) = entity {
                    p["entity"] = json!(v);
                }
                if let Some(v) = to_ver {
                    p["ver"] = json!(v);
                }
                if *cascade {
                    p["cascade"] = json!(true);
                }
                ("graph/revert", p)
            }
            Sub::Excise {
                target,
                fields,
                reason,
                rotate_backups,
                transcripts,
                ..
            } => {
                // a number is a tx, anything else an entity id
                let target = match target.parse::<u64>() {
                    Ok(n) => json!(n),
                    Err(_) => json!(target),
                };
                let mut p = json!({"target": target, "reason": reason});
                if !fields.is_empty() {
                    p["fields"] = json!(fields);
                }
                if *rotate_backups {
                    p["rotate_backups"] = json!(true);
                }
                if *transcripts {
                    p["transcripts"] = json!(true);
                }
                ("graph/excise", p)
            }
            Sub::Scrub => ("graph/scrub", json!({})),
            Sub::Grants(GrantsSub::List { who }) => (
                "graph/grants",
                json!({"list": who.as_ref().map_or_else(|| json!({}), |w| json!({"who": w}))}),
            ),
            Sub::Grants(GrantsSub::Grant {
                who,
                what,
                access,
                expires,
            }) => {
                let mut g = json!({"who": who, "what": what, "access": access});
                if let Some(t) = expires {
                    g["expires"] = json!(expires_at(t, now)?);
                }
                ("graph/grants", json!({"grant": g}))
            }
            Sub::Grants(GrantsSub::Revoke(id)) => ("graph/grants", json!({"revoke": id})),
            Sub::Sql(sql) => ("graph/sql", json!({"sql": sql})),
            Sub::Compact { dry_run } => ("graph/compact", json!({"dry_run": dry_run})),
            Sub::Proposed { accept, reject } => {
                let mut p = json!({});
                if !accept.is_empty() {
                    p["accept"] = json!(accept);
                }
                if !reject.is_empty() {
                    p["reject"] = json!(reject);
                }
                ("graph/proposed", p)
            }
        })
    }
}

/// What an excise does before it asks the hub.
#[derive(Debug, PartialEq, Eq)]
pub enum Confirm {
    Go,
    Ask,
    Refuse,
}

/// `--yes` goes ahead; a terminal asks; anything else (a script, a pipe) refuses, because an excise cannot be undone.
pub fn confirm(yes: bool, terminal: bool) -> Confirm {
    match (yes, terminal) {
        (true, _) => Confirm::Go,
        (false, true) => Confirm::Ask,
        (false, false) => Confirm::Refuse,
    }
}

/// Ask QUESTION on OUT and read one line from INPUT: only `y` or `yes` goes ahead.
pub fn ask(question: &str, input: &mut impl BufRead, out: &mut impl Write) -> bool {
    let _ = write!(out, "{question} [y/N] ");
    let _ = out.flush();
    let mut line = String::new();
    if input.read_line(&mut line).is_err() {
        return false;
    }
    matches!(line.trim().to_ascii_lowercase().as_str(), "y" | "yes")
}

fn n(v: &Value) -> u64 {
    v.as_u64().unwrap_or(0)
}

fn list(v: &Value) -> Vec<&str> {
    v.as_array()
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default()
}

/// What an excise's scrub reports about the WAL, as the user should read it.
fn wal_line(a: &Value) -> Option<String> {
    if a["wal_truncated"] == true {
        return None;
    }
    let who = a["blocked_by"].as_str()?;
    Some(format!(
        "the WAL still holds old pages ({who} are using it): close drgnx editors and run `drgnx graph scrub`"
    ))
}

/// The text `graph SUB` prints for the hub's answer A, and whether the command did what was asked.
pub fn render(sub: &Sub, a: &Value) -> (String, bool) {
    let mut out = String::new();
    let mut ok = true;
    match sub {
        Sub::Export { .. } | Sub::Import { .. } => {
            let verb = if matches!(sub, Sub::Export { .. }) {
                "exported"
            } else {
                "imported"
            };
            if let Some(e) = a["error"].as_str() {
                out.push_str(&format!("{verb} nothing: {e}\n"));
                ok = false;
            } else {
                out.push_str(&format!(
                    "{verb} {} entities, {} links, {} txs {} {} ({} skipped)\n",
                    n(&a["entities"]),
                    n(&a["links"]),
                    n(&a["txs"]),
                    if verb == "exported" { "to" } else { "from" },
                    a["dir"].as_str().unwrap_or("?"),
                    n(&a["skipped"])
                ));
            }
            for r in a["refused"].as_array().into_iter().flatten() {
                out.push_str(&format!("refused: {r}\n"));
            }
        }
        Sub::Backup => {
            if a["ok"] == true {
                out.push_str(&format!(
                    "backup {} ({} bytes, {:.0} ms), checked\n",
                    a["path"].as_str().unwrap_or("?"),
                    n(&a["bytes"]),
                    a["ms"].as_f64().unwrap_or(0.0)
                ));
            } else {
                ok = false;
                out.push_str(&format!(
                    "backup failed: {}\n",
                    a["error"].as_str().unwrap_or("unknown")
                ));
            }
            for r in list(&a["removed"]) {
                out.push_str(&format!("rotated away {r}\n"));
            }
        }
        Sub::Revert { cascade, .. } => {
            if let Some(b) = a["blocked"].as_array().filter(|b| !b.is_empty()) {
                ok = false;
                let txs: Vec<String> = b.iter().map(Value::to_string).collect();
                out.push_str(&format!(
                    "blocked: later changes depend on it; revert these txs first (newest first): {}\n",
                    txs.join(", ")
                ));
            } else if a["listed"] == true || *cascade {
                out.push_str(&format!("{}\n", a["reverted"]));
            } else {
                let r = &a["reverted"];
                out.push_str(&format!(
                    "reverted {} entities, {} links\n",
                    r["entities"].as_array().map_or(0, Vec::len),
                    r["links"].as_array().map_or(0, Vec::len)
                ));
            }
        }
        Sub::Excise { .. } => {
            out.push_str(&format!(
                "excised in tx {}: {} entities, {} versions, {} txs and {} other rows blanked\n",
                n(&a["tx"]),
                n(&a["entities"]),
                n(&a["versions"]),
                n(&a["txs_blanked"]),
                n(&a["blanked"])
            ));
            if let Some(w) = wal_line(a) {
                out.push_str(&format!("{w}\n"));
            }
            for (key, text) in [
                (
                    "backups_holding",
                    "still holds the text (run again with --rotate-backups to remove it)",
                ),
                ("backups_removed", "removed"),
                (
                    "transcripts_holding",
                    "still holds the text (run again with --transcripts to redact it)",
                ),
                ("transcripts_redacted", "redacted"),
            ] {
                for f in list(&a[key]) {
                    out.push_str(&format!("{f}: {text}\n"));
                }
            }
        }
        Sub::Scrub => {
            out.push_str(&format!(
                "vacuumed: {}, WAL truncated: {}\n",
                a["vacuumed"] == true,
                a["wal_truncated"] == true
            ));
            if let Some(w) = wal_line(a) {
                ok = false;
                out.push_str(&format!("{w}\n"));
            }
        }
        Sub::Grants(_) => {
            let rows: Vec<&Value> = if let Some(g) = a["grants"].as_array() {
                g.iter().collect()
            } else if a["grant"].is_object() {
                vec![&a["grant"]]
            } else {
                Vec::new()
            };
            for g in &rows {
                out.push_str(&format!(
                    "{}  {} -> {}  {}  {}{}\n",
                    g["id"].as_str().unwrap_or("?"),
                    g["who"].as_str().unwrap_or("?"),
                    g["what"].as_str().unwrap_or("?"),
                    g["access"].as_str().unwrap_or("?"),
                    g["status"].as_str().unwrap_or("?"),
                    g["expires"].as_f64().map_or(String::new(), |t| format!(
                        " until {}",
                        crate::log::rfc3339(t as u64)
                    ))
                ));
            }
            if a["grants"].is_array() && rows.is_empty() {
                out.push_str("no grants\n");
            }
            if let Some(r) = a["revoked"].as_bool() {
                out.push_str(if r { "revoked\n" } else { "no such grant\n" });
                ok = r;
            }
        }
        Sub::Sql(_) => {
            let cols = list(&a["columns"]);
            out.push_str(&format!("{}\n", cols.join("\t")));
            for row in a["rows"].as_array().into_iter().flatten() {
                let cells: Vec<String> = row
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|c| match c {
                        Value::String(s) => s.clone(),
                        Value::Null => "NULL".into(),
                        other => other.to_string(),
                    })
                    .collect();
                out.push_str(&format!("{}\n", cells.join("\t")));
            }
            if a["truncated"] == true {
                out.push_str("(truncated: more rows than the cap or the deadline allowed)\n");
            }
        }
        Sub::Compact { .. } => {
            let dry = a["dry_run"] == true;
            out.push_str(&format!(
                "{} {} old versions of parsed entities, {} link stats of retired sessions folded into file totals\n",
                if dry { "would drop" } else { "dropped" },
                n(&a["versions"]),
                n(&a["link_stats"])
            ));
        }
        Sub::Proposed { .. } => {
            if let Some(b) = a["blocked"].as_array().filter(|b| !b.is_empty()) {
                ok = false;
                out.push_str(&format!("blocked: {}\n", Value::Array(b.clone())));
            }
            let r = &a["reverted"];
            out.push_str(&format!(
                "reverted {} entities, {} links\n",
                r["entities"].as_array().map_or(0, Vec::len),
                r["links"].as_array().map_or(0, Vec::len)
            ));
        }
    }
    (out, ok)
}

/// `graph …`: the exit code.
pub fn run(env: &Env, cmd: GraphCommand) -> i32 {
    let cwd = match std::env::current_dir() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("ratatoskr graph: no working directory: {e}");
            return 1;
        }
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64());
    let (method, params) = match cmd.request(&cwd, now) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("ratatoskr graph: {e}");
            return 2;
        }
    };
    if let Sub::Excise {
        target,
        yes,
        reason,
        ..
    } = &cmd.sub
    {
        let stdin = std::io::stdin();
        match confirm(*yes, stdin.is_terminal()) {
            Confirm::Go => {}
            Confirm::Refuse => {
                eprintln!(
                    "ratatoskr graph excise: it cannot be undone; run it in a terminal to confirm, or pass --yes"
                );
                return 2;
            }
            Confirm::Ask => {
                let q = format!(
                    "Excise {target} for good (reason: {reason}); the text is blanked in every version and copy?"
                );
                if !ask(&q, &mut stdin.lock(), &mut std::io::stderr()) {
                    eprintln!("nothing changed");
                    return 1;
                }
            }
        }
    }
    let hub = crate::supervise::ensure_quiet(env, ENSURE_TIMEOUT);
    if hub != 0 {
        return hub;
    }
    let answer =
        Client::user(env, Duration::from_secs(5)).and_then(|mut c| c.call(method, params, LONG));
    match answer {
        Ok(a) => {
            if cmd.json {
                println!("{a}");
                return 0;
            }
            let (text, ok) = render(&cmd.sub, &a);
            print!("{text}");
            i32::from(!ok)
        }
        Err(e) => {
            eprintln!("ratatoskr graph: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(args: &[&str]) -> Result<GraphCommand, String> {
        parse(args.iter().map(OsString::from))
    }

    #[test]
    fn project_export_needs_out() {
        let e = p(&["export", "--project", "demo"]).unwrap_err();
        assert!(e.contains("--out"), "{e}");
        let ok = p(&["export", "--project", "demo", "--out", "rel/dir"]).unwrap();
        let (method, params) = ok.request(Path::new("/work"), 0.0).unwrap();
        assert_eq!(method, "graph/export");
        assert_eq!(params, json!({"project": "demo", "out": "/work/rel/dir"}));
        // the default goes to the hub's own folder
        let (_, none) = p(&["export"])
            .unwrap()
            .request(Path::new("/w"), 0.0)
            .unwrap();
        assert_eq!(none, json!({}));
    }

    #[test]
    fn excise_asks_on_a_terminal() {
        assert_eq!(confirm(false, true), Confirm::Ask);
        assert_eq!(confirm(false, false), Confirm::Refuse);
        assert_eq!(confirm(true, false), Confirm::Go);
        assert_eq!(confirm(true, true), Confirm::Go);
        let mut said = Vec::new();
        assert!(ask("sure?", &mut "yes\n".as_bytes(), &mut said));
        assert!(!ask("sure?", &mut "\n".as_bytes(), &mut said));
        assert!(!ask("sure?", &mut "no\n".as_bytes(), &mut said));
        assert!(!ask("sure?", &mut "".as_bytes(), &mut said));
        assert!(String::from_utf8(said).unwrap().contains("sure? [y/N]"));
    }

    #[test]
    fn every_subcommand_maps_to_one_method() {
        let cwd = Path::new("/w");
        let m = |a: &[&str]| p(a).unwrap().request(cwd, 1000.0).unwrap();
        assert_eq!(m(&["backup", "now"]), ("graph/backup", json!({})));
        assert_eq!(m(&["scrub"]), ("graph/scrub", json!({})));
        assert_eq!(
            m(&[
                "revert",
                "--entity",
                "task:a-00001",
                "--to-ver",
                "2",
                "--cascade"
            ]),
            (
                "graph/revert",
                json!({"entity": "task:a-00001", "ver": 2, "cascade": true})
            )
        );
        assert_eq!(
            m(&["revert", "--tx", "7"]),
            ("graph/revert", json!({"tx": 7}))
        );
        assert_eq!(
            m(&[
                "excise",
                "12",
                "--reason",
                "leaked",
                "--field",
                "body",
                "--rotate-backups"
            ]),
            (
                "graph/excise",
                json!({"target": 12, "reason": "leaked", "fields": ["body"], "rotate_backups": true})
            )
        );
        assert_eq!(
            m(&["excise", "task:a-00001", "--reason", "x"]).1["target"],
            "task:a-00001"
        );
        assert_eq!(
            m(&[
                "grants",
                "grant",
                "profile:review",
                "project:3",
                "--expires",
                "2h"
            ]),
            (
                "graph/grants",
                json!({"grant": {"who": "profile:review", "what": "project:3", "access": "read", "expires": 8200.0}})
            )
        );
        assert_eq!(
            m(&["grants", "revoke", "g1"]),
            ("graph/grants", json!({"revoke": "g1"}))
        );
        assert_eq!(m(&["grants"]), ("graph/grants", json!({"list": {}})));
        assert_eq!(
            m(&["sql", "select 1"]),
            ("graph/sql", json!({"sql": "select 1"}))
        );
        assert_eq!(
            m(&["compact", "--dry-run"]),
            ("graph/compact", json!({"dry_run": true}))
        );
        assert_eq!(
            m(&["proposed", "reject", "4", "5"]),
            ("graph/proposed", json!({"reject": [4, 5]}))
        );
        assert_eq!(
            m(&["import", "dump"]),
            ("graph/import", json!({"dir": "/w/dump"}))
        );
    }

    #[test]
    fn bad_lines_are_usage_errors() {
        for bad in [
            &["revert"][..],
            &["revert", "--tx", "1", "--entity", "x"],
            &["revert", "--entity", "x"],
            &["excise", "3"],
            &["export", "--with", "everything"],
            &["export", "--since", "soon"],
            &["backup", "later"],
            &["proposed", "accept"],
            &["proposed", "maybe", "1"],
            &["grants", "grant", "only-who"],
            &["scrub", "--force"],
            &["nonsense"],
            &[],
        ] {
            assert!(p(bad).is_err(), "{bad:?} should not parse");
        }
        assert!(p(&["sql", "select 1", "--json"]).unwrap().json);
        assert!(expires_at("soon", 0.0).is_err());
        assert_eq!(expires_at("1700000000", 0.0).unwrap(), 1_700_000_000.0);
    }

    #[test]
    fn answers_read_as_text_and_failures_exit_nonzero() {
        let (t, ok) = render(
            &Sub::Backup,
            &json!({"ok": true, "path": "/d/backup/work-1.db", "bytes": 10, "ms": 3.0, "removed": []}),
        );
        assert!(
            ok && t.contains("work-1.db") && t.contains("checked"),
            "{t}"
        );
        let (t, ok) = render(
            &Sub::Backup,
            &json!({"ok": false, "error": "integrity", "path": "x", "bytes": 0, "ms": 1.0, "removed": []}),
        );
        assert!(!ok && t.contains("integrity"), "{t}");
        let (t, ok) = render(
            &Sub::Excise {
                target: "1".into(),
                fields: vec![],
                reason: "r".into(),
                rotate_backups: false,
                transcripts: false,
                yes: true,
            },
            &json!({"tx": 9, "entities": 1, "versions": 3, "txs_blanked": 2, "blanked": 0, "vacuumed": true,
                    "wal_truncated": false, "blocked_by": "readers", "backups_holding": ["/d/backup/work-1.db"]}),
        );
        assert!(ok);
        assert!(
            t.contains("close drgnx editors and run `drgnx graph scrub`"),
            "{t}"
        );
        assert!(t.contains("work-1.db: still holds"), "{t}");
        let (_, ok) = render(
            &Sub::Revert {
                tx: Some(1),
                entity: None,
                to_ver: None,
                cascade: false,
            },
            &json!({"blocked": [5]}),
        );
        assert!(!ok);
        let (t, _) = render(
            &Sub::Sql("x".into()),
            &json!({"columns": ["a", "b"], "rows": [[1, "x"], [null, "y"]], "truncated": true}),
        );
        assert!(
            t.starts_with("a\tb\n1\tx\nNULL\ty\n") && t.contains("truncated"),
            "{t}"
        );
    }
}
