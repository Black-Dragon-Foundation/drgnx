//! What-if forks of a recorded debug run (docs/develop/debugging.md, "What-if forks"; spec §19.3): `debug/fork` makes
//! one (from a stop of the run, or a line's N-th pass; changing a value there, or the code), `debug/fork/run` runs a
//! code what-if once its tree is edited, `debug/fork/drop` removes one, and `debug/compare` answers a fork beside its
//! run. The hub's event `debug-fork` follows each fork from `preparing` to `done`.

use super::debug::{DebugAnswer, TEXT_MAX};
use super::{invalid, method};
use crate::registry::Method;
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Where a fork starts: a STOP of the run (its index), or the HIT-th pass of PATH's LINE.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugForkAt {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hit: Option<u32>,
}

/// A value a fork sets at its point: the variable at PATH (names from a scope down, `["item", "reserve"]`) gets TEXT,
/// an expression in the program's language.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugForkValue {
    pub path: Vec<String>,
    pub text: String,
}

/// What a fork changes: a VALUE, or the CODE (the fork's tree is edited first); neither: nothing (a replay).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugForkChange {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<DebugForkValue>,
    #[serde(default)]
    pub code: bool,
}

/// Where a fork ends: `"stop"` (the next stop) or `"exit"`, or a probe's next hit (`{"probe": ID}`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(untagged)]
pub enum DebugForkUntil {
    End(String),
    Probe { probe: String },
}

/// `debug/fork`: fork RUN at AT with CHANGE, running UNTIL `stop` (the next stop, the default), `exit`, or
/// `{"probe": ID}` (that probe's next hit). CONFIRM: the user said yes to a slow replay. INPUTS answer an earlier
/// `needs` (an input the run's configuration asks, whose value was not kept).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugFork {
    pub run: String,
    pub at: DebugForkAt,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub change: Option<DebugForkChange>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub until: Option<DebugForkUntil>,
    #[serde(default)]
    pub confirm: bool,
    /// Fork at this pass even though a local differed from the run's that may come from a source the fork does not
    /// replay (the clock, random numbers): what a failed fork's `anyway` offers.
    #[serde(default)]
    pub anyway: bool,
    #[serde(default)]
    pub inputs: Vec<DebugAnswer>,
}

/// `debug/fork`'s answer: the FORK's id, or ASK (a question: the replay is slow; ask again with `confirm`), or NEEDS
/// (as `debug/start`'s).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugForked {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ask: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub needs: Option<Value>,
}

/// `debug/fork/run` and `debug/fork/drop`: one FORK.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugForkId {
    pub fork: String,
}

/// `debug/compare`: FORK beside its RUN.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugCompare {
    pub run: String,
    pub fork: String,
}

/// `debug-fork` (and `debug/compare`'s answer): a fork as it goes. STATE is `preparing`, `editing` (a code what-if's
/// TREE waits for the edit), `running`, `done`, `failed` (ERROR) or `dropped`. Done: AT (the point, in the project),
/// MATCHED (`{matched, of, first}`: the hits before the point on the stopping thread, and the first that differs),
/// APPLIED (the value as the adapter took it), LANES (each probe's values after the point, then and now), THEN and NOW
/// (how the run and the fork went on: `{kind: stop|exit|probe, …}`), CHANGED (the files a code what-if changed).
/// Never an environment value.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugForkView {
    pub fork: String,
    pub run: String,
    pub state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tree: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub matched: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub applied: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lanes: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub then: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub now: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changed: Option<Vec<String>>,
}

fn check_id(path: &str, s: &str) -> Result<(), Error> {
    if s.is_empty() || s.len() > 256 {
        return Err(invalid(path, "a non-empty id of at most 256 bytes"));
    }
    Ok(())
}

fn check_fork(p: &DebugFork) -> Result<(), Error> {
    check_id("run", &p.run)?;
    let a = &p.at;
    match (a.stop, &a.path, a.line, a.hit) {
        (Some(_), None, None, None) => {}
        (None, Some(path), Some(l), Some(h)) if path.starts_with('/') && l > 0 && h > 0 => {
            if path.len() > TEXT_MAX {
                return Err(invalid("at.path", "at most 4096 bytes"));
            }
        }
        _ => {
            return Err(invalid(
                "at",
                "{stop: N}, or {path, line, hit} (an absolute path, line and hit from 1)",
            ));
        }
    }
    if let Some(c) = &p.change {
        if c.code && c.value.is_some() {
            return Err(invalid("change", "a value or the code, not both"));
        }
        if let Some(v) = &c.value
            && (v.path.is_empty()
                || v.path.len() > 64
                || v.path.iter().any(|n| n.is_empty() || n.len() > 256)
                || v.text.is_empty()
                || v.text.len() > TEXT_MAX)
        {
            return Err(invalid(
                "change.value",
                "a path of 1 to 64 names and a non-empty text of at most 4096 bytes",
            ));
        }
    }
    match &p.until {
        None => {}
        Some(DebugForkUntil::End(s)) if s == "stop" || s == "exit" => {}
        Some(DebugForkUntil::Probe { probe }) if !probe.is_empty() && probe.len() <= 256 => {}
        Some(_) => return Err(invalid("until", "\"stop\", \"exit\" or {\"probe\": ID}")),
    }
    if p.inputs.len() > super::debug::LIST_MAX {
        return Err(invalid("inputs", "at most 256 inputs"));
    }
    Ok(())
}

fn check_fork_id(p: &DebugForkId) -> Result<(), Error> {
    check_id("fork", &p.fork)
}

fn check_compare(p: &DebugCompare) -> Result<(), Error> {
    check_id("run", &p.run)?;
    check_id("fork", &p.fork)
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "debug/compare", DebugCompare(DebugCompare) -> DebugForkView,
            classes: [User], writes: false,
            doc: "a what-if fork beside its recorded run: matched on N of M hits before the point, the first difference, each probe's values after it, and how each went on",
            check: check_compare,
        ),
        method!(
            "debug/fork", DebugFork(DebugFork) -> DebugForked,
            classes: [User], writes: false,
            doc: "fork a recorded run in a sealed copy (Linux): from a stop or a line's N-th pass, setting a value there or editing the code, until the next stop, the end or a probe's next hit; the fork's id, or a question first (a slow replay, an input)",
            check: check_fork,
        ),
        method!(
            "debug/fork/drop", DebugForkDrop(DebugForkId) -> bool,
            classes: [User], writes: false,
            doc: "a what-if fork goes, with its tree",
            check: check_fork_id,
        ),
        method!(
            "debug/fork/run", DebugForkRun(DebugForkId) -> bool,
            classes: [User], writes: false,
            doc: "run a code what-if whose tree was edited (Run Fork): the files it changed are what Take Fork's Change offers",
            check: check_fork_id,
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fork(v: Value) -> Result<(), Error> {
        check_fork(&serde_json::from_value(v).unwrap())
    }

    #[test]
    fn a_fork_names_its_point_change_and_end() {
        assert!(fork(json!({"run": "r1", "at": {"stop": 4}})).is_ok());
        assert!(
            fork(
                json!({"run": "r1", "at": {"path": "/p/a.py", "line": 3, "hit": 2},
                        "change": {"value": {"path": ["item", "reserve"], "text": "0"}},
                        "until": {"probe": "shortfall"}})
            )
            .is_ok()
        );
        assert!(
            fork(
                json!({"run": "r1", "at": {"stop": 4}, "change": {"code": true}, "until": "exit"})
            )
            .is_ok()
        );
        for bad in [
            json!({"run": "", "at": {"stop": 4}}),
            json!({"run": "r1", "at": {}}),
            json!({"run": "r1", "at": {"stop": 4, "line": 3}}),
            json!({"run": "r1", "at": {"path": "a.py", "line": 3, "hit": 1}}),
            json!({"run": "r1", "at": {"path": "/a.py", "line": 3, "hit": 0}}),
            json!({"run": "r1", "at": {"stop": 1}, "change": {"code": true, "value": {"path": ["a"], "text": "1"}}}),
            json!({"run": "r1", "at": {"stop": 1}, "change": {"value": {"path": [], "text": "1"}}}),
            json!({"run": "r1", "at": {"stop": 1}, "until": "forever"}),
            json!({"run": "r1", "at": {"stop": 1}, "until": {"probe": ""}}),
        ] {
            assert!(fork(bad.clone()).is_err(), "{bad}");
        }
    }
}
