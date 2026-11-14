//! `ratatoskr machines report --machine M --ttl S [--json FILE|-]`: tell the hub which slots a machine has (jobq calls
//! this). A user client of the running hub, `ensure`d first: one `machines/report` call, so the checks are the hub's.
//!
//! The slots come as JSON, from FILE or standard input (`-`): a list `[{"id", "kind", "holder"?}, ...]`, or an object
//! with that list under `slots`. Without `--json` the machine has no slots. Exit 0 when the hub took the report, 1 when
//! it answered with an error (its text on stderr), 2 for arguments that do not parse or slots that are not JSON.

use std::ffi::OsString;
use std::io::Read;
use std::time::Duration;

use runstav::paths::Env;
use serde_json::{Value, json};

use crate::cli::ENSURE_TIMEOUT;
use crate::client::Client;

/// How long one call to the hub may take.
const CALL: Duration = Duration::from_secs(30);

#[derive(Debug, PartialEq, Eq)]
pub struct MachinesCommand {
    pub machine: String,
    /// Seconds, as typed; a number above 0 (checked in [`parse`]).
    pub ttl: String,
    /// A file, or `-` for standard input.
    pub slots_from: Option<String>,
}

/// The arguments after `machines`.
pub fn parse(args: impl IntoIterator<Item = OsString>) -> Result<MachinesCommand, String> {
    use lexopt::Arg::{Long, Value as Word};
    use lexopt::ValueExt;
    let mut p = lexopt::Parser::from_args(args);
    let e = |e: lexopt::Error| e.to_string();
    match p.next().map_err(e)? {
        Some(Word(v)) if v == "report" => {}
        Some(Word(v)) => {
            return Err(format!(
                "unknown machines subcommand {:?}",
                v.string().map_err(e)?
            ));
        }
        Some(other) => return Err(other.unexpected().to_string()),
        None => return Err("machines needs a subcommand (report)".into()),
    }
    let (mut machine, mut ttl, mut slots_from) = (None, None, None);
    while let Some(arg) = p.next().map_err(e)? {
        match arg {
            Long("machine") => machine = Some(p.value().map_err(e)?.string().map_err(e)?),
            Long("ttl") => {
                let t = p.value().map_err(e)?.string().map_err(e)?;
                t.parse::<f64>()
                    .ok()
                    .filter(|n| n.is_finite() && *n > 0.0)
                    .ok_or_else(|| format!("--ttl wants a number of seconds, not {t:?}"))?;
                ttl = Some(t);
            }
            Long("json") => slots_from = Some(p.value().map_err(e)?.string().map_err(e)?),
            other => return Err(other.unexpected().to_string()),
        }
    }
    Ok(MachinesCommand {
        machine: machine.ok_or("machines report needs --machine")?,
        ttl: ttl.ok_or("machines report needs --ttl")?,
        slots_from,
    })
}

impl MachinesCommand {
    /// The `machines/report` params; SLOTS is the JSON text read from `--json`, if any.
    pub fn params(&self, slots: Option<&str>) -> Result<Value, String> {
        let slots = match slots {
            None => json!([]),
            Some(text) => {
                let v: Value = serde_json::from_str(text)
                    .map_err(|e| format!("the slots are not JSON: {e}"))?;
                match v {
                    Value::Array(_) => v,
                    Value::Object(mut o) => o.remove("slots").unwrap_or_else(|| json!([])),
                    _ => return Err("the slots are a list, or an object with `slots`".into()),
                }
            }
        };
        let ttl: f64 = self.ttl.parse().unwrap_or_default();
        Ok(json!({"machine": self.machine, "ttl": ttl, "slots": slots}))
    }
}

fn read_slots(from: &str) -> Result<String, String> {
    let mut text = String::new();
    if from == "-" {
        std::io::stdin()
            .read_to_string(&mut text)
            .map_err(|e| format!("standard input: {e}"))?;
    } else {
        text = std::fs::read_to_string(from).map_err(|e| format!("{from}: {e}"))?;
    }
    Ok(text)
}

/// `machines report`: the exit code.
pub fn run(env: &Env, cmd: &MachinesCommand) -> i32 {
    let params = match cmd.slots_from.as_deref().map(read_slots).transpose() {
        Ok(text) => match cmd.params(text.as_deref()) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("ratatoskr machines: {e}");
                return 2;
            }
        },
        Err(e) => {
            eprintln!("ratatoskr machines: {e}");
            return 2;
        }
    };
    let hub = crate::supervise::ensure_quiet(env, ENSURE_TIMEOUT);
    if hub != 0 {
        return hub;
    }
    match Client::user(env, Duration::from_secs(5))
        .and_then(|mut c| c.call("machines/report", params, CALL))
    {
        Ok(a) => {
            println!("{a}");
            0
        }
        Err(e) => {
            eprintln!("ratatoskr machines: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(args: &[&str]) -> Result<MachinesCommand, String> {
        parse(args.iter().map(OsString::from))
    }

    /// Pattern D: the arguments and the slots' two shapes.
    #[test]
    fn parses_and_reports() {
        let c = p(&[
            "report",
            "--machine",
            "desktop",
            "--ttl",
            "45",
            "--json",
            "s.json",
        ])
        .unwrap();
        assert_eq!(
            c,
            MachinesCommand {
                machine: "desktop".into(),
                ttl: "45".into(),
                slots_from: Some("s.json".into())
            }
        );
        let list = r#"[{"id":"a","kind":"build"}]"#;
        let obj = r#"{"slots":[{"id":"a","kind":"build"}]}"#;
        assert_eq!(c.params(Some(list)).unwrap(), c.params(Some(obj)).unwrap());
        assert_eq!(c.params(None).unwrap()["slots"], json!([]));
        assert!(c.params(Some("nope")).is_err());
        assert!(c.params(Some("3")).is_err());
        for bad in [
            &[][..],
            &["frobnicate"],
            &["report"],
            &["report", "--machine", "m"],
            &["report", "--machine", "m", "--ttl", "soon"],
            &["report", "--machine", "m", "--ttl", "0"],
            &["report", "--machine", "m", "--ttl", "5", "--nope"],
        ] {
            assert!(p(bad).is_err(), "{bad:?} should not parse");
        }
    }
}
