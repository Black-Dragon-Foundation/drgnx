//! `ratatoskr job …`: plan runs from a terminal.  A user client of the running hub, `ensure`d first: every subcommand is
//! one hub method (`job/propose`, `job/approve`, `job/status`, `job/stop`, `job/resume`), so the checks are the hub's.
//! `bin/drgnx job` runs it with the same arguments.
//!
//! Output is the job as text ([`format_job`]), or the method's answer as one JSON line with `--json`.  Exit 0 when the
//! hub did what was asked, 1 when it answered with an error (its text on stderr), 2 for arguments that do not parse.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::time::Duration;

use runstav::methods::jobs::{JobStatusResult, JobSummary};
use runstav::paths::Env;
use serde_json::{Value, json};

use crate::cli::ENSURE_TIMEOUT;
use crate::client::Client;

/// How long one call to the hub may take.
const CALL: Duration = Duration::from_secs(30);

#[derive(Debug, PartialEq, Eq)]
pub struct JobCommand {
    pub sub: Sub,
    pub json: bool,
}

/// A `--budget` that passed [`budget`]: its text, sent as the number it is.
#[derive(Debug, PartialEq, Eq)]
pub struct Usd(String);

impl Usd {
    fn number(&self) -> f64 {
        self.0.parse().unwrap_or_default()
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Sub {
    Propose {
        plan: PathBuf,
        repo: Option<PathBuf>,
        budget: Option<Usd>,
        auto: bool,
    },
    Approve {
        id: String,
        budget: Option<Usd>,
    },
    Status {
        id: Option<String>,
    },
    Stop {
        id: String,
    },
    Resume {
        id: String,
        budget: Option<Usd>,
    },
}

/// `--budget`'s text as USD: digits with at most one point (`5`, `.5`, `2.50`), nothing else.
fn budget(text: &str) -> Result<Usd, String> {
    let digits = text.chars().filter(char::is_ascii_digit).count();
    let points = text.chars().filter(|c| *c == '.').count();
    if digits == 0 || points > 1 || text.chars().any(|c| !c.is_ascii_digit() && c != '.') {
        return Err(format!("--budget wants a number of USD, not {text:?}"));
    }
    Ok(Usd(text.to_string()))
}

/// The arguments after `job`.
pub fn parse(args: impl IntoIterator<Item = OsString>) -> Result<JobCommand, String> {
    use lexopt::Arg::{Long, Value as Word};
    use lexopt::ValueExt;
    let mut p = lexopt::Parser::from_args(args);
    let e = |e: lexopt::Error| e.to_string();
    let name = match p.next().map_err(e)? {
        Some(Word(v)) => v.string().map_err(e)?,
        Some(other) => return Err(other.unexpected().to_string()),
        None => return Err("job needs a subcommand".into()),
    };
    if !["propose", "approve", "status", "stop", "resume"].contains(&name.as_str()) {
        return Err(format!("unknown job subcommand {name:?}"));
    }
    let (mut json, mut auto) = (false, false);
    let (mut repo, mut budget_text) = (None, None);
    let mut words: Vec<String> = Vec::new();
    while let Some(arg) = p.next().map_err(e)? {
        match arg {
            Long("json") => json = true,
            Long("auto") if name == "propose" => auto = true,
            Long("repo") if name == "propose" => {
                repo = Some(p.value().map_err(e)?.string().map_err(e)?);
            }
            Long("budget") if ["propose", "approve", "resume"].contains(&name.as_str()) => {
                budget_text = Some(p.value().map_err(e)?.string().map_err(e)?);
            }
            Word(v) => words.push(v.string().map_err(e)?),
            other => return Err(other.unexpected().to_string()),
        }
    }
    let budget = budget_text.as_deref().map(budget).transpose()?;
    let one = |what: &str| -> Result<String, String> {
        match words.as_slice() {
            [w] => Ok(w.clone()),
            [] => Err(format!("job {name} needs {what}")),
            [_, extra, ..] => Err(format!("job {name}: unexpected argument {extra:?}")),
        }
    };
    let sub = match name.as_str() {
        "propose" => Sub::Propose {
            plan: one("a plan")?.into(),
            repo: repo.map(PathBuf::from),
            budget,
            auto,
        },
        "approve" => Sub::Approve {
            id: one("a job id")?,
            budget,
        },
        "resume" => Sub::Resume {
            id: one("a job id")?,
            budget,
        },
        "stop" => Sub::Stop {
            id: one("a job id")?,
        },
        _ => Sub::Status {
            id: match words.as_slice() {
                [] => None,
                _ => Some(one("a job id")?),
            },
        },
    };
    Ok(JobCommand { sub, json })
}

fn absolute(cwd: &Path, p: &Path) -> String {
    cwd.join(p).to_string_lossy().into_owned()
}

impl JobCommand {
    /// The one hub call: its method and params.  Relative paths are relative to `cwd`.
    pub fn request(&self, cwd: &Path) -> (&'static str, Value) {
        match &self.sub {
            Sub::Propose {
                plan,
                repo,
                budget,
                auto,
            } => {
                let mut params = json!({"plan": absolute(cwd, plan)});
                if let Some(r) = repo {
                    params["repo"] = json!(absolute(cwd, r));
                }
                if let Some(b) = budget {
                    params["budget"] = json!(b.number());
                }
                if *auto {
                    params["auto"] = json!(true);
                }
                ("job/propose", params)
            }
            Sub::Approve { id, budget } => ("job/approve", with_budget(id, budget.as_ref())),
            Sub::Resume { id, budget } => ("job/resume", with_budget(id, budget.as_ref())),
            Sub::Stop { id } => ("job/stop", json!({"id": id})),
            Sub::Status { id } => (
                "job/status",
                id.as_ref().map_or_else(|| json!({}), |i| json!({"id": i})),
            ),
        }
    }
}

fn with_budget(id: &str, budget: Option<&Usd>) -> Value {
    let mut params = json!({"id": id});
    if let Some(b) = budget {
        params["budget"] = json!(b.number());
    }
    params
}

/// A JSON value as the text of a column: strings bare, `null` and missing as nothing.
fn plain(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
    }
}

/// The non-empty list under a key.
fn list<'a>(v: &'a Value, key: &str) -> &'a [Value] {
    v.get(key)
        .and_then(Value::as_array)
        .map_or(&[][..], Vec::as_slice)
}

fn col(v: &Value, key: &str) -> String {
    plain(v.get(key))
}

/// A job as the text of `drgnx job status ID`.
pub fn format_job(job: &JobSummary) -> String {
    use std::fmt::Write as _;
    let mut out = String::new();
    let text = |o: &Option<String>| o.clone().unwrap_or_default();
    let _ = writeln!(
        out,
        "{}  {}  [{}]",
        job.id,
        text(&job.title),
        text(&job.status)
    );
    let _ = writeln!(out, "  repository {}", text(&job.repo));
    for t in &job.tasks {
        let deps: Vec<String> = list(t, "deps")
            .iter()
            .map(|d| format!("Task {}", plain(Some(d))))
            .collect();
        let after = if deps.is_empty() {
            String::new()
        } else {
            format!(", after {}", deps.join(", "))
        };
        let _ = writeln!(
            out,
            "  Task {}: {}  — {} on {}, {}{after}",
            col(t, "n"),
            col(t, "title"),
            col(t, "role"),
            col(t, "profile"),
            col(t, "status"),
        );
    }
    let est = job.estimate.clone().unwrap_or(Value::Null);
    let usd = est.get("usd").and_then(Value::as_f64).unwrap_or(0.0);
    let unpriced: Vec<String> = list(&est, "unpriced")
        .iter()
        .map(|u| plain(Some(u)))
        .collect();
    let unpriced = if unpriced.is_empty() {
        String::new()
    } else {
        format!(" (unpriced: {})", unpriced.join(", "))
    };
    let _ = writeln!(
        out,
        "  estimate ~{usd:.2} USD, {} tokens{unpriced}",
        col(&est, "tokens")
    );
    let budget = job
        .budget
        .map_or_else(|| "none".to_string(), |b| format!("{b:?} USD"));
    let _ = writeln!(
        out,
        "  budget {budget}, spent {:.2} USD",
        job.spent.unwrap_or(0.0)
    );
    for w in &job.warnings {
        let _ = writeln!(out, "  warning: {}", plain(Some(w)));
    }
    for a in &job.agents {
        let _ = writeln!(
            out,
            "  agent {} ({}) {} on {}",
            col(a, "id"),
            col(a, "profile"),
            col(a, "status"),
            col(a, "task"),
        );
    }
    for p in &job.permissions {
        let _ = writeln!(out, "  asks: {} ({})", col(p, "title"), col(p, "agent"));
    }
    for c in &job.cards {
        let task = match col(c, "task") {
            t if t.is_empty() => t,
            t => format!("{t}: "),
        };
        let _ = writeln!(
            out,
            "  card #{} [{}] {task}{}",
            col(c, "id"),
            col(c, "kind"),
            col(c, "title"),
        );
    }
    for m in &job.messages {
        let _ = writeln!(
            out,
            "  message #{} from {}: {}",
            col(m, "id"),
            col(m, "sender"),
            col(m, "text"),
        );
    }
    out
}

/// What a successful call prints without `--json`.
fn render(sub: &Sub, answer: &Value) -> Result<String, String> {
    let bad = |e: serde_json::Error| format!("the hub's answer does not fit: {e}");
    if let Sub::Status { id: None } = sub {
        let all: JobStatusResult = serde_json::from_value(answer.clone()).map_err(bad)?;
        return Ok(match all {
            JobStatusResult::All { jobs } if jobs.is_empty() => "No jobs.\n".into(),
            JobStatusResult::All { jobs } => jobs.iter().map(format_job).collect(),
            JobStatusResult::One(job) => format_job(&job),
        });
    }
    let job: JobSummary = serde_json::from_value(answer.clone()).map_err(bad)?;
    let mut out = format_job(&job);
    if matches!(sub, Sub::Propose { .. }) && job.status.as_deref() == Some("proposed") {
        out.push_str(&format!("Approve with: drgnx job approve {}\n", job.id));
    }
    Ok(out)
}

/// `job …`: the exit code.
pub fn run(env: &Env, cmd: JobCommand) -> i32 {
    let cwd = match std::env::current_dir() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("ratatoskr job: no working directory: {e}");
            return 1;
        }
    };
    let (method, params) = cmd.request(&cwd);
    let hub = crate::supervise::ensure_quiet(env, ENSURE_TIMEOUT);
    if hub != 0 {
        return hub;
    }
    let answer =
        Client::user(env, Duration::from_secs(5)).and_then(|mut c| c.call(method, params, CALL));
    match answer {
        Ok(a) if cmd.json => {
            println!("{a}");
            0
        }
        Ok(a) => match render(&cmd.sub, &a) {
            Ok(text) => {
                print!("{text}");
                0
            }
            Err(e) => {
                eprintln!("ratatoskr job: {e}");
                1
            }
        },
        Err(e) => {
            eprintln!("ratatoskr job: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(args: &[&str]) -> Result<JobCommand, String> {
        parse(args.iter().map(OsString::from))
    }

    #[test]
    fn format_matches_the_lisp_golden() {
        let jobs: Vec<JobSummary> = serde_json::from_str(include_str!(
            "../../../../test/fixtures/job-format/jobs.json"
        ))
        .unwrap();
        let golden = include_str!("../../../../test/fixtures/job-format/jobs.golden.txt");
        let texts: Vec<String> = jobs
            .iter()
            .map(|j| format!("{}=====\n", format_job(j)))
            .collect();
        assert_eq!(texts.concat(), golden);
    }

    #[test]
    fn bad_args_exit_2() {
        for bad in [
            &[][..],
            &["frobnicate"],
            &["propose"],
            &["propose", "a.md", "b.md"],
            &["propose", "a.md", "--nope"],
            &["approve"],
            &["approve", "job-1", "--auto"],
            &["status", "a", "b"],
            &["stop", "job-1", "--budget", "1"],
            &["propose", "a.md", "--repo"],
        ] {
            assert!(p(bad).is_err(), "{bad:?} should not parse");
        }
    }

    #[test]
    fn budget_must_be_a_number() {
        for bad in ["", "abc", "1e3", "-1", "1.2.3", ".", "5 USD"] {
            let e = p(&["approve", "job-1", "--budget", bad]);
            assert!(e.is_err(), "--budget {bad:?} should be refused");
        }
        for (text, want) in [("5", 5.0), (".5", 0.5), ("2.50", 2.5)] {
            let c = p(&["resume", "job-1", "--budget", text]).unwrap();
            assert_eq!(
                c.request(Path::new("/w")),
                ("job/resume", json!({"id": "job-1", "budget": want}))
            );
        }
    }

    #[test]
    fn every_subcommand_maps_to_one_method() {
        let cwd = Path::new("/w");
        let m = |a: &[&str]| p(a).unwrap().request(cwd);
        assert_eq!(
            m(&[
                "propose",
                "plans/a.md",
                "--repo",
                "r",
                "--budget",
                "5",
                "--auto"
            ]),
            (
                "job/propose",
                json!({"plan": "/w/plans/a.md", "repo": "/w/r", "budget": 5.0, "auto": true})
            )
        );
        assert_eq!(
            m(&["propose", "/abs/a.md"]),
            ("job/propose", json!({"plan": "/abs/a.md"}))
        );
        assert_eq!(m(&["status"]), ("job/status", json!({})));
        assert_eq!(
            m(&["status", "job-1", "--json"]),
            ("job/status", json!({"id": "job-1"}))
        );
        assert_eq!(m(&["stop", "job-1"]), ("job/stop", json!({"id": "job-1"})));
        assert_eq!(
            m(&["approve", "job-1"]),
            ("job/approve", json!({"id": "job-1"}))
        );
    }

    #[test]
    fn a_proposal_says_how_to_approve_it() {
        let job = json!({"id": "job-9", "title": "T", "status": "proposed", "repo": "/r"});
        let sub = Sub::Propose {
            plan: "a.md".into(),
            repo: None,
            budget: None,
            auto: false,
        };
        assert!(
            render(&sub, &job)
                .unwrap()
                .ends_with("Approve with: drgnx job approve job-9\n")
        );
        let running = json!({"id": "job-9", "status": "running"});
        assert!(!render(&sub, &running).unwrap().contains("Approve with"));
        assert_eq!(
            render(&Sub::Status { id: None }, &json!({"jobs": []})).unwrap(),
            "No jobs.\n"
        );
    }
}
