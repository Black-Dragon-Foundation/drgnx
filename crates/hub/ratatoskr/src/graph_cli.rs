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

/// The kinds `import-records --only` takes (`runstav`'s `RecordKind`).
const RECORD_KINDS: [&str; 7] = [
    "specs",
    "plans",
    "ledgers",
    "decisions",
    "deferred",
    "build-board",
    "board",
];

/// A backup, an export or a scrub of a big store takes a while; the hub answers when it is done.
const LONG: Duration = Duration::from_secs(600);

pub const USAGE: &str = "usage: ratatoskr graph export [--project P --out DIR] [--since TX] [--with activity] [--history] [--json]\n\
    \x20      ratatoskr graph import DIR [--json]\n\
    \x20      ratatoskr graph backup [now] [--json]\n\
    \x20      ratatoskr graph revert --tx N | --entity ID --to-ver V [--cascade] [--json]\n\
    \x20      ratatoskr graph excise ID|TX [--field F]... --reason R [--rotate-backups] [--transcripts] [--yes] [--json]\n\
    \x20      ratatoskr graph scrub [--json]\n\
    \x20      ratatoskr graph grants [list [--who W] | grant WHO WHAT [--access read|edit-user-tasks] [--expires T] | revoke ID] [--json]\n\
    \x20      ratatoskr graph grants grant --who WHO --where PROJECT|plan:ID|task:ID --what OP... [--until T] [--json]\n\
    \x20      ratatoskr graph grants edit ID [--what OP...] [--until T|none] [--json]   show WHO [--json]\n\
    \x20      ratatoskr graph settings [only-user-closes on|off] [--json]\n\
    \x20      ratatoskr graph sql 'SELECT …' [--json]\n\
    \x20      ratatoskr graph compact [--dry-run] [--json]\n\
    \x20      ratatoskr graph proposed accept|reject TX... [--json]\n\
    \x20      ratatoskr graph forget --root DIR [--missing] [--path FILE]... [--dry-run] [--yes] [--json]\n\
    \x20      ratatoskr graph import-records --root DIR [--only specs|plans|ledgers|decisions|deferred|build-board|board] [--path FILE] [--dry-run] [--adopt] [--json]\n\
    \x20      ratatoskr graph forget-root ROOT [--json]";

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
    /// The store's settings: shown, or "only I close my tasks" set.
    Settings {
        only_user_closes: Option<bool>,
    },
    Sql(String),
    Compact {
        dry_run: bool,
    },
    Proposed {
        accept: Vec<u64>,
        reject: Vec<u64>,
    },
    ImportRecords {
        root: PathBuf,
        only: Option<String>,
        path: Option<PathBuf>,
        dry_run: bool,
        /// Adopt a root `forget-root` turned off again.
        adopt: bool,
    },
    /// "Not for this project": the root's records retired, the files untouched (`records/forget-root`).
    ForgetRoot {
        root: PathBuf,
    },
    /// Retires what files the scan once read held, when the files are gone (moved or deleted) or named.
    Forget {
        root: PathBuf,
        missing: bool,
        paths: Vec<PathBuf>,
        dry_run: bool,
        yes: bool,
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
        /// A `task-write` grant's operations (`--what`).
        ops: Vec<String>,
    },
    Revoke(String),
    Edit {
        id: String,
        ops: Vec<String>,
        /// `none` clears it.
        until: Option<String>,
    },
    /// The active grants that apply to an actor: WHO is `ext:KIND:ID` or a session id, PROJECT (`--project`) the project
    /// it works in and PROFILE (`--profile`) its profile, so a project or profile grant that names them is counted too.
    Show {
        who: String,
        project: Option<String>,
        profile: Option<String>,
    },
}

fn num(v: &str, what: &str) -> villa::Result<u64> {
    v.parse()
        .map_err(|_| villa::Error::invalid(format!("{what} takes a whole number, not {v:?}")))
}

/// The arguments after `graph`.
pub fn parse(args: impl IntoIterator<Item = OsString>) -> villa::Result<GraphCommand> {
    use lexopt::Arg::{Long, Value as Word};
    use lexopt::ValueExt;
    let mut p = lexopt::Parser::from_args(args);
    let e = |e: lexopt::Error| villa::Error::invalid(e.to_string());
    let name = match p.next().map_err(e)? {
        Some(Word(v)) => v.string().map_err(e)?,
        Some(other) => return Err(villa::Error::invalid(other.unexpected().to_string())),
        None => return Err(villa::Error::invalid("graph needs a subcommand")),
    };
    let mut json = false;
    // words and options, in order; each subcommand reads what it knows
    let mut words: Vec<String> = Vec::new();
    let mut opts: Vec<(String, Option<String>)> = Vec::new();
    // options that take a value
    let valued = [
        "project", "out", "since", "tx", "entity", "to-ver", "field", "reason", "who", "access",
        "expires", "with", "root", "only", "path", "where", "what", "until", "profile",
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
            other => return Err(villa::Error::invalid(other.unexpected().to_string())),
        }
    }
    let known = |allowed: &[&str]| -> villa::Result<()> {
        match opts.iter().find(|(k, _)| !allowed.contains(&k.as_str())) {
            Some((k, _)) => Err(villa::Error::invalid(format!(
                "graph {name}: unknown option --{k}"
            ))),
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
    let no_words = |n: usize| -> villa::Result<()> {
        if words.len() > n {
            Err(villa::Error::invalid(format!(
                "graph {name}: unexpected argument {:?}",
                words[n]
            )))
        } else {
            Ok(())
        }
    };
    let sub = match name.as_str() {
        "export" => {
            known(&["project", "out", "since", "with", "history"])
                .map_err(|e| villa::Error::invalid(e.to_string()))?;
            no_words(0).map_err(|e| villa::Error::invalid(e.to_string()))?;
            let project = get("project");
            let out = get("out").map(PathBuf::from);
            if project.is_some() && out.is_none() {
                return Err(villa::Error::invalid(
                    "graph export --project needs --out DIR (it never writes into a repository unless --out names it)",
                ));
            }
            let with_activity = match get("with").as_deref() {
                None => false,
                Some("activity") => true,
                Some(other) => {
                    return Err(villa::Error::invalid(format!(
                        "--with takes activity, not {other:?}"
                    )));
                }
            };
            Sub::Export {
                project,
                out,
                since: get("since")
                    .map(|s| num(&s, "--since"))
                    .transpose()
                    .map_err(|e| villa::Error::invalid(e.to_string()))?,
                with_activity,
                history: flag("history"),
            }
        }
        "import" => {
            known(&[]).map_err(|e| villa::Error::invalid(e.to_string()))?;
            no_words(1).map_err(|e| villa::Error::invalid(e.to_string()))?;
            Sub::Import {
                dir: words
                    .first()
                    .map(PathBuf::from)
                    .ok_or_else(|| villa::Error::invalid("graph import needs DIR"))?,
            }
        }
        "import-records" => {
            known(&["root", "only", "path", "dry-run", "adopt"])
                .map_err(|e| villa::Error::invalid(e.to_string()))?;
            no_words(0).map_err(|e| villa::Error::invalid(e.to_string()))?;
            let only = get("only");
            if let Some(o) = &only
                && !RECORD_KINDS.contains(&o.as_str())
            {
                return Err(villa::Error::invalid(format!(
                    "--only takes {}, not {o:?}",
                    RECORD_KINDS.join(", ")
                )));
            }
            Sub::ImportRecords {
                root: get("root").map(PathBuf::from).ok_or_else(|| {
                    villa::Error::invalid("graph import-records needs --root DIR")
                })?,
                only,
                path: get("path").map(PathBuf::from),
                dry_run: flag("dry-run"),
                adopt: flag("adopt"),
            }
        }
        "forget-root" => {
            known(&[])?;
            no_words(1)?;
            Sub::ForgetRoot {
                root: words
                    .first()
                    .map(PathBuf::from)
                    .ok_or_else(|| villa::Error::invalid("graph forget-root needs ROOT"))?,
            }
        }
        "backup" => {
            known(&[]).map_err(|e| villa::Error::invalid(e.to_string()))?;
            match words.first().map(String::as_str) {
                None | Some("now") => {}
                Some(other) => {
                    return Err(villa::Error::invalid(format!(
                        "graph backup takes `now`, not {other:?}"
                    )));
                }
            }
            no_words(1).map_err(|e| villa::Error::invalid(e.to_string()))?;
            Sub::Backup
        }
        "revert" => {
            known(&["tx", "entity", "to-ver", "cascade"])
                .map_err(|e| villa::Error::invalid(e.to_string()))?;
            no_words(0).map_err(|e| villa::Error::invalid(e.to_string()))?;
            let (tx, entity) = (get("tx"), get("entity"));
            match (&tx, &entity) {
                (Some(_), Some(_)) | (None, None) => {
                    return Err(villa::Error::invalid(
                        "graph revert takes --tx N, or --entity ID --to-ver V",
                    ));
                }
                (None, Some(_)) if get("to-ver").is_none() => {
                    return Err(villa::Error::invalid(
                        "graph revert --entity needs --to-ver V",
                    ));
                }
                (Some(_), None) if get("to-ver").is_some() => {
                    return Err(villa::Error::invalid("--to-ver goes with --entity"));
                }
                _ => {}
            }
            Sub::Revert {
                tx: tx
                    .map(|s| num(&s, "--tx"))
                    .transpose()
                    .map_err(|e| villa::Error::invalid(e.to_string()))?,
                entity,
                to_ver: get("to-ver")
                    .map(|s| num(&s, "--to-ver"))
                    .transpose()
                    .map_err(|e| villa::Error::invalid(e.to_string()))?,
                cascade: flag("cascade"),
            }
        }
        "excise" => {
            known(&["field", "reason", "rotate-backups", "transcripts", "yes"])
                .map_err(|e| villa::Error::invalid(e.to_string()))?;
            no_words(1).map_err(|e| villa::Error::invalid(e.to_string()))?;
            Sub::Excise {
                target: words
                    .first()
                    .cloned()
                    .ok_or_else(|| villa::Error::invalid("graph excise needs an ID or a TX"))?,
                fields: opts
                    .iter()
                    .filter(|(k, _)| k == "field")
                    .filter_map(|(_, v)| v.clone())
                    .collect(),
                reason: get("reason")
                    .ok_or_else(|| villa::Error::invalid("graph excise needs --reason R"))?,
                rotate_backups: flag("rotate-backups"),
                transcripts: flag("transcripts"),
                yes: flag("yes"),
            }
        }
        "scrub" => {
            known(&[]).map_err(|e| villa::Error::invalid(e.to_string()))?;
            no_words(0).map_err(|e| villa::Error::invalid(e.to_string()))?;
            Sub::Scrub
        }
        "grants" => {
            known(&[
                "who", "access", "expires", "where", "what", "until", "project", "profile",
            ])?;
            let ops: Vec<String> = opts
                .iter()
                .filter(|(k, _)| k == "what")
                .filter_map(|(_, v)| v.clone())
                .flat_map(|v| {
                    v.split(',')
                        .map(str::trim)
                        .map(String::from)
                        .collect::<Vec<_>>()
                })
                .filter(|o| !o.is_empty())
                .collect();
            let until = get("until").or_else(|| get("expires"));
            let mut w = words.iter().map(String::as_str);
            let g = match w.next() {
                None | Some("list") => {
                    no_words(1)?;
                    GrantsSub::List { who: get("who") }
                }
                Some("grant") => {
                    no_words(3)?;
                    let who = get("who").or_else(|| w.next().map(String::from));
                    let what = get("where").or_else(|| w.next().map(String::from));
                    let (who, what) = who.zip(what).ok_or_else(|| {
                        villa::Error::invalid(
                            "graph grants grant needs WHO and WHAT (or --who and --where, with --what OP...)",
                        )
                    })?;
                    let access = match (get("access"), ops.is_empty()) {
                        (None, false) => "task-write".to_owned(),
                        (Some(a), false) if a != "task-write" => {
                            return Err(villa::Error::invalid(
                                "--what names a task-write grant's operations, not --access",
                            ));
                        }
                        (Some(a), _) => a,
                        (None, true) => "read".to_owned(),
                    };
                    if access == "task-write" && ops.is_empty() {
                        return Err(villa::Error::invalid(
                            "a task-write grant needs --what OP...",
                        ));
                    }
                    GrantsSub::Grant {
                        who,
                        what,
                        access,
                        expires: until,
                        ops,
                    }
                }
                Some("revoke") => {
                    no_words(2)?;
                    GrantsSub::Revoke(
                        w.next()
                            .ok_or_else(|| {
                                villa::Error::invalid("graph grants revoke needs an ID")
                            })?
                            .into(),
                    )
                }
                Some("edit") => {
                    no_words(2)?;
                    let id = w
                        .next()
                        .ok_or_else(|| villa::Error::invalid("graph grants edit needs an ID"))?
                        .to_owned();
                    if ops.is_empty() && until.is_none() {
                        return Err(villa::Error::invalid(
                            "graph grants edit needs --what OP... or --until T",
                        ));
                    }
                    GrantsSub::Edit { id, ops, until }
                }
                Some("show") => {
                    no_words(2)?;
                    GrantsSub::Show {
                        who: w
                            .next()
                            .ok_or_else(|| villa::Error::invalid("graph grants show needs WHO"))?
                            .into(),
                        project: get("project"),
                        profile: get("profile"),
                    }
                }
                Some(other) => {
                    return Err(villa::Error::invalid(format!(
                        "unknown grants subcommand {other:?}"
                    )));
                }
            };
            Sub::Grants(g)
        }
        "settings" => {
            known(&[])?;
            no_words(2)?;
            let only_user_closes = match words.as_slice() {
                [] => None,
                [k, v] if k == "only-user-closes" => Some(match v.as_str() {
                    "on" => true,
                    "off" => false,
                    other => {
                        return Err(villa::Error::invalid(format!(
                            "only-user-closes takes on or off, not {other:?}"
                        )));
                    }
                }),
                _ => {
                    return Err(villa::Error::invalid(
                        "graph settings takes only-user-closes on|off, or nothing",
                    ));
                }
            };
            Sub::Settings { only_user_closes }
        }
        "forget" => {
            known(&["root", "missing", "path", "dry-run", "yes"])?;
            no_words(0)?;
            let paths: Vec<PathBuf> = opts
                .iter()
                .filter(|(k, _)| k == "path")
                .filter_map(|(_, v)| v.clone())
                .map(PathBuf::from)
                .collect();
            if !flag("missing") && paths.is_empty() {
                return Err(villa::Error::invalid(
                    "graph forget needs --missing, or --path FILE for each source to forget",
                ));
            }
            Sub::Forget {
                root: PathBuf::from(
                    get("root")
                        .ok_or_else(|| villa::Error::invalid("graph forget needs --root DIR"))?,
                ),
                missing: flag("missing"),
                paths,
                dry_run: flag("dry-run"),
                yes: flag("yes"),
            }
        }
        "sql" => {
            known(&[]).map_err(|e| villa::Error::invalid(e.to_string()))?;
            no_words(1).map_err(|e| villa::Error::invalid(e.to_string()))?;
            Sub::Sql(
                words
                    .first()
                    .cloned()
                    .ok_or_else(|| villa::Error::invalid("graph sql needs a SELECT"))?,
            )
        }
        "compact" => {
            known(&["dry-run"]).map_err(|e| villa::Error::invalid(e.to_string()))?;
            no_words(0).map_err(|e| villa::Error::invalid(e.to_string()))?;
            Sub::Compact {
                dry_run: flag("dry-run"),
            }
        }
        "proposed" => {
            known(&[]).map_err(|e| villa::Error::invalid(e.to_string()))?;
            let which = words.first().map(String::as_str);
            let ids = words
                .iter()
                .skip(1)
                .map(|s| num(s, "a tx"))
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| villa::Error::invalid(e.to_string()))?;
            if ids.is_empty() {
                return Err(villa::Error::invalid(
                    "graph proposed accept|reject needs at least one TX",
                ));
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
                _ => {
                    return Err(villa::Error::invalid(
                        "graph proposed takes accept or reject, then TX...",
                    ));
                }
            }
        }
        other => {
            return Err(villa::Error::invalid(format!(
                "unknown graph subcommand {other:?}"
            )));
        }
    };
    Ok(GraphCommand { sub, json })
}

/// `--expires T`: unix seconds, or a time from NOW such as `90s`, `30m`, `12h`, `7d`.
fn expires_at(text: &str, now: f64) -> villa::Result<f64> {
    let bad = || {
        villa::Error::invalid(format!(
            "--expires takes unix seconds or a span like 12h or 7d, not {text:?}"
        ))
    };
    if let Ok(secs) = text.parse::<f64>() {
        return Ok(secs);
    }
    let (n, unit) = text.split_at(text.len().saturating_sub(1));
    let n: f64 = n
        .parse()
        .map_err(|_| bad())
        .map_err(|e| villa::Error::invalid(e.to_string()))?;
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
    pub fn request(&self, cwd: &Path, now: f64) -> villa::Result<(&'static str, Value)> {
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
            Sub::ImportRecords {
                root,
                only,
                path,
                dry_run,
                adopt,
            } => {
                let mut p = json!({"root": absolute(root, cwd)});
                if *adopt {
                    p["adopt"] = json!(true);
                }
                if let Some(o) = only {
                    p["only"] = json!(o);
                }
                if let Some(f) = path {
                    p["path"] = json!(absolute(f, cwd));
                }
                if *dry_run {
                    p["dry_run"] = json!(true);
                }
                ("records/import", p)
            }
            Sub::ForgetRoot { root } => {
                ("records/forget-root", json!({"root": absolute(root, cwd)}))
            }
            // the first of its calls: the sources the store holds under ROOT (the second is [`forget_call`])
            Sub::Forget { root, .. } => ("graph/sql", forget_listing(&absolute(root, cwd))),
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
                ops,
            }) => {
                let mut g = json!({"who": who, "what": what, "access": access});
                if let Some(t) = expires {
                    g["expires"] = json!(
                        expires_at(t, now).map_err(|e| villa::Error::invalid(e.to_string()))?
                    );
                }
                if !ops.is_empty() {
                    g["ops"] = json!(ops);
                }
                ("graph/grants", json!({"grant": g}))
            }
            Sub::Grants(GrantsSub::Edit { id, ops, until }) => {
                let mut e = json!({"id": id});
                if !ops.is_empty() {
                    e["ops"] = json!(ops);
                }
                match until.as_deref() {
                    Some("none") => e["clear_expires"] = json!(true),
                    Some(t) => e["expires"] = json!(expires_at(t, now)?),
                    None => {}
                }
                ("graph/grants", json!({"edit": e}))
            }
            Sub::Grants(GrantsSub::Show {
                who,
                project,
                profile,
            }) => {
                let mut l = json!({"effective_for": who, "active": true});
                if let Some(p) = project {
                    l["project"] = json!(p);
                }
                if let Some(p) = profile {
                    l["profile"] = json!(p);
                }
                ("graph/grants", json!({"list": l}))
            }
            Sub::Grants(GrantsSub::Revoke(id)) => ("graph/grants", json!({"revoke": id})),
            Sub::Settings { only_user_closes } => (
                "graph/settings",
                match only_user_closes {
                    Some(on) => json!({"set": {"only_user_closes": on}}),
                    None => json!({"get": {}}),
                },
            ),
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

/// `graph/put-parsed {gone}` takes at most this many sources a call.
const FORGET_BATCH: usize = 1000;

/// The `graph/sql` call listing the source files the store holds under ROOT: the files the scan recorded, and the
/// sources of live entities (a path under ROOT, `/` ended, so `/a/b` never takes `/a/bc`).
pub fn forget_listing(root: &str) -> Value {
    let prefix = format!("{}/", root.trim_end_matches('/'));
    json!({
        "sql": "select path from parsed_file where substr(path, 1, length(?1)) = ?1 \
                union select source from entity where retired_tx is null and substr(source, 1, length(?1)) = ?1 \
                order by 1",
        "params": [prefix],
        "rows": 10000,
    })
}

/// Which of KNOWN (the listing's paths) to forget: the ones EXISTS says are gone when MISSING, and the ones named in
/// PATHS.  Also the PATHS the store holds nothing of.
pub fn forget_pick(
    known: &[String],
    paths: &[String],
    missing: bool,
    exists: &dyn Fn(&str) -> bool,
) -> (Vec<String>, Vec<String>) {
    let picked = known
        .iter()
        .filter(|k| (missing && !exists(k)) || paths.contains(k))
        .cloned()
        .collect();
    let unknown = paths
        .iter()
        .filter(|p| !known.contains(p))
        .cloned()
        .collect();
    (picked, unknown)
}

/// The `graph/put-parsed` calls retiring PICKED, a batch each.
pub fn forget_call(picked: &[String]) -> Vec<Value> {
    picked
        .chunks(FORGET_BATCH)
        .map(|c| json!({"gone": c.iter().map(|p| json!({"kind": "file", "path": p})).collect::<Vec<_>>()}))
        .collect()
}

/// `graph forget`: list, pick, say what it will do, ask, then retire.  The exit code.
fn forget_run(env: &Env, cmd: &GraphCommand) -> i32 {
    let Sub::Forget {
        missing,
        paths,
        dry_run,
        yes,
        ..
    } = &cmd.sub
    else {
        return 2;
    };
    let cwd = std::env::current_dir().unwrap_or_default();
    let (_, listing) = match cmd.request(&cwd, 0.0) {
        Ok(r) => r,
        Err(e) => {
            crate::soft::err_line(&format!("ratatoskr graph: {e}"));
            return 2;
        }
    };
    let hub = crate::supervise::ensure_quiet(env, ENSURE_TIMEOUT);
    if hub != 0 {
        return hub;
    }
    let mut client = match Client::user(env, Duration::from_secs(5)) {
        Ok(c) => c,
        Err(e) => {
            crate::soft::err_line(&format!("ratatoskr graph: {e}"));
            return 1;
        }
    };
    let rows = match client.call("graph/sql", listing, LONG) {
        Ok(a) => a,
        Err(e) => {
            crate::soft::err_line(&format!("ratatoskr graph: {e}"));
            return 1;
        }
    };
    let known: Vec<String> = rows["rows"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| r[0].as_str().map(str::to_owned))
        .collect();
    let named: Vec<String> = paths.iter().map(|p| absolute(p, &cwd)).collect();
    let (picked, unknown) = forget_pick(&known, &named, *missing, &|p| Path::new(p).exists());
    for u in &unknown {
        crate::soft::err_line(&format!("not in the store: {u}"));
    }
    if cmd.json && *dry_run {
        crate::soft::out_line(
            &json!({"dry_run": true, "gone": picked, "unknown": unknown}).to_string(),
        );
        return 0;
    }
    if picked.is_empty() {
        crate::soft::out_line("nothing to forget");
        return 0;
    }
    for p in &picked {
        crate::soft::out_line(&format!(
            "{} {p}",
            if *dry_run { "would forget" } else { "forget" }
        ));
    }
    if *dry_run {
        return 0;
    }
    let stdin = std::io::stdin();
    match confirm(*yes, stdin.is_terminal()) {
        Confirm::Go => {}
        Confirm::Refuse => {
            crate::soft::err_line(
                "ratatoskr graph forget: it retires what these files held; run it in a terminal to confirm, or pass --yes",
            );
            return 2;
        }
        Confirm::Ask => {
            let q = format!(
                "Forget {} sources: what they hold is retired (history is kept)?",
                picked.len()
            );
            if !ask(&q, &mut stdin.lock(), &mut annall::raw_err()) {
                crate::soft::err_line("nothing changed");
                return 1;
            }
        }
    }
    let mut code = 0;
    for call in forget_call(&picked) {
        match client.call("graph/put-parsed", call, LONG) {
            Ok(a) if cmd.json => crate::soft::out_line(&a.to_string()),
            Ok(a) => {
                let (text, ok) = render(&cmd.sub, &a);
                crate::soft::out_text(&text);
                code |= i32::from(!ok);
            }
            Err(e) => {
                crate::soft::err_line(&format!("ratatoskr graph: {e}"));
                return 1;
            }
        }
    }
    code
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
    crate::soft::done(write!(out, "{question} [y/N] "), "write");
    crate::soft::done(out.flush(), "graph_cli");
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
        Sub::ImportRecords { .. } => {
            let dry = a["dry_run"] == true;
            for f in a["files"].as_array().into_iter().flatten() {
                out.push_str(&format!(
                    "{} {}: {} entities, {} operations\n",
                    if dry { "would import" } else { "imported" },
                    f["path"].as_str().unwrap_or("?"),
                    n(&f["entities"]),
                    n(&f["ops"])
                ));
            }
            if let Some(b) = a["backup"].as_str() {
                out.push_str(&format!("backup {b}\n"));
            }
        }
        Sub::ForgetRoot { .. } => {
            out.push_str(&format!(
                "not for this project: {} records of {} files retired; the files are untouched \
                 (import-records --adopt takes them again)\n",
                n(&a["pieces"]),
                n(&a["files"])
            ));
        }
        Sub::Forget { .. } => {
            out.push_str(&format!(
                "forgot: {} entities retired, their history kept\n",
                n(&a["retired"])
            ));
            for r in a["refused"].as_array().into_iter().flatten() {
                ok = false;
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
                let ops = list(&g["ops"]);
                out.push_str(&format!(
                    "{}  {} -> {}  {}{}  {}{}\n",
                    g["id"].as_str().unwrap_or("?"),
                    g["who"].as_str().unwrap_or("?"),
                    g["what"].as_str().unwrap_or("?"),
                    g["access"].as_str().unwrap_or("?"),
                    if ops.is_empty() {
                        String::new()
                    } else {
                        format!(" [{}]", ops.join(", "))
                    },
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
            if let Some(r) = a["edited"].as_bool() {
                out.push_str(if r { "edited\n" } else { "no such grant\n" });
                ok = r;
            }
        }
        Sub::Settings { .. } => {
            out.push_str(&format!(
                "only-user-closes: {}\n",
                if a["only_user_closes"] == true {
                    "on"
                } else {
                    "off"
                }
            ));
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
            crate::soft::err_line(&format!("ratatoskr graph: no working directory: {e}"));
            return 1;
        }
    };
    let now = crate::clock::wall_secs();
    if matches!(cmd.sub, Sub::Forget { .. }) {
        return forget_run(env, &cmd);
    }
    let (method, params) = match cmd.request(&cwd, now) {
        Ok(r) => r,
        Err(e) => {
            crate::soft::err_line(&format!("ratatoskr graph: {e}"));
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
                crate::soft::err_line(
                    "ratatoskr graph excise: it cannot be undone; run it in a terminal to confirm, or pass --yes",
                );
                return 2;
            }
            Confirm::Ask => {
                let q = format!(
                    "Excise {target} for good (reason: {reason}); the text is blanked in every version and copy?"
                );
                if !ask(&q, &mut stdin.lock(), &mut annall::raw_err()) {
                    crate::soft::err_line("nothing changed");
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
                crate::soft::out_line(&a.to_string());
                return 0;
            }
            let (text, ok) = render(&cmd.sub, &a);
            crate::soft::out_text(&text);
            i32::from(!ok)
        }
        Err(e) => {
            crate::soft::err_line(&format!("ratatoskr graph: {e}"));
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(args: &[&str]) -> villa::Result<GraphCommand> {
        parse(args.iter().map(OsString::from))
    }

    #[test]
    fn project_export_needs_out() {
        let e = p(&["export", "--project", "demo"]).unwrap_err();
        assert!(e.message().contains("--out"), "{e}");
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
    fn task_write_grants_and_settings_make_the_exact_calls() {
        let m = |args: &[&str]| p(args).unwrap().request(Path::new("/w"), 1000.0).unwrap();
        assert_eq!(
            m(&[
                "grants",
                "grant",
                "--who",
                "kind:claude",
                "--where",
                "project:3",
                "--what",
                "update.title",
                "--what",
                "status.done,note",
                "--until",
                "1h",
            ]),
            (
                "graph/grants",
                json!({"grant": {"who": "kind:claude", "what": "project:3", "access": "task-write",
                    "expires": 4600.0, "ops": ["update.title", "status.done", "note"]}})
            )
        );
        assert_eq!(
            m(&[
                "grants", "edit", "grant:x", "--what", "claim", "--until", "none"
            ]),
            (
                "graph/grants",
                json!({"edit": {"id": "grant:x", "ops": ["claim"], "clear_expires": true}})
            )
        );
        assert_eq!(
            m(&["grants", "edit", "grant:x", "--until", "2h"]).1,
            json!({"edit": {"id": "grant:x", "expires": 8200.0}})
        );
        assert_eq!(
            m(&["grants", "show", "ext:claude:7"]),
            (
                "graph/grants",
                json!({"list": {"effective_for": "ext:claude:7", "active": true}})
            )
        );
        assert_eq!(
            m(&[
                "grants",
                "show",
                "s-1",
                "--project",
                "demo",
                "--profile",
                "claude"
            ])
            .1,
            json!({"list": {"effective_for": "s-1", "active": true, "project": "demo", "profile": "claude"}})
        );
        assert_eq!(m(&["settings"]), ("graph/settings", json!({"get": {}})));
        assert_eq!(
            m(&["settings", "only-user-closes", "on"]),
            ("graph/settings", json!({"set": {"only_user_closes": true}}))
        );
        assert_eq!(
            m(&["settings", "only-user-closes", "off"]).1,
            json!({"set": {"only_user_closes": false}})
        );
        for bad in [
            &["grants", "grant", "--who", "any-outside", "--what", "note"][..],
            &[
                "grants", "grant", "x", "y", "--access", "read", "--what", "note",
            ],
            &["grants", "edit", "grant:x"],
            &["grants", "show"],
            &["settings", "only-user-closes"],
            &["settings", "only-user-closes", "maybe"],
            &["settings", "nonsense", "on"],
        ] {
            assert!(p(bad).is_err(), "{bad:?} should not parse");
        }
        // the legacy positional grant still reads, and a grant with operations lists them
        assert_eq!(
            m(&[
                "grants",
                "grant",
                "session:s",
                "project:3",
                "--access",
                "edit-user-tasks"
            ])
            .1,
            json!({"grant": {"who": "session:s", "what": "project:3", "access": "edit-user-tasks"}})
        );
        let (t, _) = render(
            &p(&["grants"]).unwrap().sub,
            &json!({"grants": [{"id": "grant:x", "who": "any-outside", "what": "project:3",
                "access": "task-write", "ops": ["note", "status.done"], "status": "active", "active": true}]}),
        );
        assert!(t.contains("task-write [note, status.done]"), "{t}");
        let (t, _) = render(
            &Sub::Settings {
                only_user_closes: None,
            },
            &json!({"only_user_closes": true}),
        );
        assert_eq!(t, "only-user-closes: on\n");
    }

    #[test]
    fn only_takes_every_record_kind() {
        for k in [
            "specs",
            "plans",
            "ledgers",
            "decisions",
            "deferred",
            "build-board",
            "board",
        ] {
            assert!(
                p(&["import-records", "--root", "/r", "--only", k]).is_ok(),
                "{k}"
            );
        }
        let e = p(&["import-records", "--root", "/r", "--only", "foo"]).unwrap_err();
        for k in [
            "specs",
            "decisions",
            "plans",
            "ledgers",
            "deferred",
            "build-board",
            "board",
        ] {
            assert!(e.message().contains(k), "{e}");
        }
    }

    #[test]
    fn path_is_parsed_and_needs_a_value() {
        let c = p(&[
            "import-records",
            "--root",
            "/r",
            "--path",
            "docs/specs/x/a.md",
        ])
        .unwrap();
        let (method, params) = c.request(Path::new("/w"), 0.0).unwrap();
        assert_eq!(method, "records/import");
        assert_eq!(
            params,
            json!({"root": "/r", "path": "/w/docs/specs/x/a.md"})
        );
        assert!(p(&["import-records", "--root", "/r", "--path"]).is_err());
    }

    #[test]
    fn graph_cli_parses_forget_root() {
        let c = p(&["forget-root", "proj", "--json"]).unwrap();
        assert!(c.json);
        assert_eq!(
            c.request(Path::new("/w"), 0.0).unwrap(),
            ("records/forget-root", json!({"root": "/w/proj"}))
        );
        assert!(p(&["forget-root"]).is_err(), "ROOT is needed");
        assert!(p(&["forget-root", "/a", "/b"]).is_err());
        let (text, ok) = render(&c.sub, &json!({"pieces": 12, "files": 3}));
        assert!(ok);
        assert!(text.contains("12 records of 3 files retired"), "{text}");
        // and back on: an import that adopts the root again
        let again = p(&["import-records", "--root", "/r", "--adopt"]).unwrap();
        assert_eq!(
            again.request(Path::new("/w"), 0.0).unwrap().1,
            json!({"root": "/r", "adopt": true})
        );
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
    fn forget_parses_and_lists_the_stores_sources_under_the_root() {
        let c = p(&[
            "forget",
            "--root",
            "org",
            "--missing",
            "--dry-run",
            "--path",
            "a.md",
            "--path",
            "b.md",
        ])
        .unwrap();
        assert_eq!(
            c.sub,
            Sub::Forget {
                root: "org".into(),
                missing: true,
                paths: vec!["a.md".into(), "b.md".into()],
                dry_run: true,
                yes: false
            }
        );
        let (m, params) = c.request(Path::new("/w"), 0.0).unwrap();
        assert_eq!(m, "graph/sql");
        assert_eq!(params["params"], json!(["/w/org/"]));
        for bad in [
            &["forget", "--root", "x"][..],
            &["forget", "--missing"],
            &["forget", "--root", "x", "--missing", "y"],
        ] {
            assert!(p(bad).is_err(), "{bad:?} should not parse");
        }
        // a path is picked when it is missing, or named; a named one the store never held is reported
        let known: Vec<String> = ["/o/a.md", "/o/b.md", "/o/c.md"].map(String::from).into();
        let here = |p: &str| p == "/o/b.md";
        let (picked, unknown) =
            forget_pick(&known, &["/o/c.md".into(), "/o/z.md".into()], true, &here);
        assert_eq!(
            (picked, unknown),
            (
                vec!["/o/a.md".to_owned(), "/o/c.md".to_owned()],
                vec!["/o/z.md".to_owned()]
            )
        );
        let (picked, _) = forget_pick(&known, &[], false, &here);
        assert!(picked.is_empty());
        // at most 1000 sources a call
        let many: Vec<String> = (0..2001).map(|i| format!("/o/{i}.md")).collect();
        let calls = forget_call(&many);
        assert_eq!(
            calls
                .iter()
                .map(|c| c["gone"].as_array().unwrap().len())
                .collect::<Vec<_>>(),
            [1000, 1000, 1]
        );
        assert_eq!(
            calls[0]["gone"][0],
            json!({"kind": "file", "path": "/o/0.md"})
        );
    }

    /// A plan whose file moved is retired with its tasks and steps (history kept); one whose file is there is not.
    #[test]
    fn forgetting_a_moved_plan_retires_it_and_leaves_a_present_one() {
        use norn::parsed::{self, PutParsed};
        use urdr::graph::guard::Guard;
        use urdr::graph::schema::GRAPH_DDL;
        use urdr::graph::{Class, Tx, TxMeta};
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_string_lossy().into_owned();
        let (moved, kept) = (
            format!("{root}/docs/plans/moved.md"),
            format!("{root}/docs/plans/kept.md"),
        );
        std::fs::create_dir_all(dir.path().join("docs/plans")).unwrap();
        crate::fsio::write(&kept, "# K\n").unwrap();
        let mut c = urdr::Connection::open_in_memory().unwrap();
        c.execute_batch(GRAPH_DDL).unwrap();
        c.execute_batch(
            "create table parsed_file (path text primary key, mtime real); create table kv (key text primary key, value text);",
        )
        .unwrap();
        fn put(
            c: &mut urdr::Connection,
            deny: &norn::deny::DenyList,
            req: Value,
        ) -> parsed::PutAnswer {
            let mut g = Guard::default();
            norn::grants::register(&mut g);
            let req: PutParsed = serde_json::from_value(req).unwrap();
            let mut tx = Tx::for_test(
                c,
                TxMeta::new("scan:/w", Class::System, "scan"),
                std::sync::Arc::new(g),
            );
            let a = parsed::put(&mut tx, deny, req).unwrap();
            tx.commit_for_test().unwrap();
            a
        }
        let deny = norn::deny::DenyList::load(&dir.path().join("home"), &dir.path().join("config"));
        let source = |p: &str| {
            json!({"source": {"kind": "file", "path": p}, "mtime": 1.0, "entities": [
                {"id": format!("plan:{p}"), "kind": "plan", "title": "P", "status": "open", "data": {"path": p}},
                {"id": format!("task:{p}#1"), "kind": "task", "title": "one", "status": "open",
                 "data": {"path": p, "parent": format!("plan:{p}"), "ord": 1}}]})
        };
        put(
            &mut c,
            &deny,
            json!({"sources": [source(&moved), source(&kept)]}),
        );
        // the listing the command sends, run as the hub would
        let listing = forget_listing(&root);
        let rows: Vec<String> = {
            let mut st = c.prepare(listing["sql"].as_str().unwrap()).unwrap();
            st.query_map([listing["params"][0].as_str().unwrap()], |r| r.get(0))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert_eq!(rows, [kept.clone(), moved.clone()]);
        let (picked, _) = forget_pick(&rows, &[], true, &|p| Path::new(p).exists());
        assert_eq!(picked, std::slice::from_ref(&moved));
        for call in forget_call(&picked) {
            let a = put(&mut c, &deny, call);
            assert_eq!(a.retired, 2);
        }
        let live = |c: &urdr::Connection, path: &str| -> i64 {
            c.query_row(
                "select count(*) from entity where source = ?1 and retired_tx is null",
                [path],
                |r| r.get(0),
            )
            .unwrap()
        };
        assert_eq!((live(&c, &moved), live(&c, &kept)), (0, 2));
        // retired, not deleted: the rows and their versions are still there
        let all: i64 = c
            .query_row(
                "select count(*) from entity where source = ?1",
                [&moved],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(all, 2);
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
