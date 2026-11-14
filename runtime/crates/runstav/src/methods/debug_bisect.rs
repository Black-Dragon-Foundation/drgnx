//! Bisect over the edit history (docs/develop/debugging.md, spec §19.6, §19.8): which change broke it.  The states
//! between a good state and now (agent steps, saves, launch snapshots, commits) a bisect can stop at
//! (`debug/bisect/states`), a bisect started (`debug/bisect`), stopped (`debug/bisect/cancel`), and its first bad step
//! narrowed to the hunks that matter (`debug/bisect/narrow`).  Its progress and result come as `debug-bisect` events.
//! The user's for now; agents reach bisect through the matrix's `debug.fork` row (D4).

use super::{invalid, method};
use crate::registry::Method;
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The longest path, id or argument, in bytes.
pub const TEXT_MAX: usize = 4096;
/// The most arguments a predicate's command takes.
pub const ARGV_MAX: usize = 64;

/// A state a bisect starts from or names: `commit` (ID a commit), `run` (ID a recorded run: its launch snapshot) or
/// `record` (ID an edit history record: the project after it).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugBisectState {
    pub kind: String,
    pub id: String,
}

/// What makes a state bad: `test` (ARGV fails: exit 0 good, 125 skip, 1–127 bad, as `git bisect run`), `exit` (ARGV
/// exits with CODE: bad; 0 or another code: good; 125 skip).  BUILD, when given, runs first: its failure skips the
/// state.  `exception` and `probe` (Python and JS) run RUN's configuration in each state (spec §19.3's plain run in a
/// slot): `exception` is bad when it raises at AT (`path:line`, relative to the project), `probe` when CONDITION is true
/// at AT at least once; a run the time box cut, or a probe line that never ran, skips the state.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugPredicate {
    pub kind: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub argv: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<i32>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub build: Vec<String>,
    /// Each run's time box, in seconds (default 600).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timebox_s: Option<u64>,
    /// `exception` and `probe`: the recorded run whose configuration runs, the place (`path:line`) and a probe's
    /// condition.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub condition: Option<String>,
}

/// `debug/bisect/states`: the states of ROOT after GOOD (every one the history keeps when none), oldest first.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugBisectStates {
    pub root: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub good: Option<DebugBisectState>,
}

/// The states: `{id, kind, at, label, author?, step?, decision?, record?}`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugBisectStateList {
    pub states: Vec<Value>,
}

/// `debug/bisect`: bisect ROOT from GOOD to now by PREDICATE, in PARALLEL slots (default 3).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugBisect {
    pub root: String,
    pub predicate: DebugPredicate,
    pub good: DebugBisectState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parallel: Option<u32>,
}

/// A bisect started: its id, its states and the estimate (`{runs, slots, states}`); `debug-bisect` events follow.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugBisectStarted {
    pub bisect: String,
    pub states: Vec<Value>,
    pub estimate: Value,
}

/// `debug/bisect/cancel`, `debug/bisect/narrow`: one bisect.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugBisectId {
    pub bisect: String,
}

fn check_text(path: &str, s: &str) -> Result<(), Error> {
    if s.is_empty() || s.len() > TEXT_MAX || s.contains('\0') {
        return Err(invalid(path, "a non-empty text of at most 4096 bytes"));
    }
    Ok(())
}

fn check_root(root: &str) -> Result<(), Error> {
    check_text("root", root)?;
    if !root.starts_with('/') {
        return Err(invalid("root", "an absolute path"));
    }
    Ok(())
}

fn check_state(path: &str, s: &DebugBisectState) -> Result<(), Error> {
    if !["commit", "run", "record"].contains(&s.kind.as_str()) {
        return Err(invalid(path, "a state: kind commit, run or record"));
    }
    check_text(path, &s.id)?;
    if !s.id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
        return Err(invalid(path, "a state's id"));
    }
    Ok(())
}

fn check_argv(path: &str, argv: &[String]) -> Result<(), Error> {
    if argv.len() > ARGV_MAX || argv.iter().any(|a| a.len() > TEXT_MAX || a.contains('\0')) {
        return Err(invalid(path, "at most 64 arguments of at most 4096 bytes"));
    }
    Ok(())
}

fn check_states(p: &DebugBisectStates) -> Result<(), Error> {
    check_root(&p.root)?;
    if let Some(g) = &p.good {
        check_state("good", g)?;
    }
    Ok(())
}

fn check_bisect(p: &DebugBisect) -> Result<(), Error> {
    check_root(&p.root)?;
    check_state("good", &p.good)?;
    let pr = &p.predicate;
    match pr.kind.as_str() {
        "test" | "exit" => {
            if pr.argv.is_empty() || pr.argv[0].is_empty() {
                return Err(invalid("predicate.argv", "a command: argv's first item"));
            }
        }
        "exception" | "probe" => {
            if pr.run.is_none() {
                return Err(invalid("predicate.run", "the recorded run to replay"));
            }
            let place = pr.at.as_deref().and_then(|a| a.rsplit_once(':'));
            let ok = place.is_some_and(|(path, line)| {
                !path.is_empty()
                    && !path.starts_with('/')
                    && !path.split('/').any(|c| c == "..")
                    && line.parse::<u32>().is_ok_and(|n| n > 0)
            });
            if !ok {
                return Err(invalid(
                    "predicate.at",
                    "the place to watch: PATH:LINE, the path relative to the project",
                ));
            }
            if pr.kind == "probe" && pr.condition.as_deref().is_none_or(str::is_empty) {
                return Err(invalid(
                    "predicate.condition",
                    "the probe's condition: the state is bad when it is true there",
                ));
            }
        }
        _ => return Err(invalid("predicate.kind", "test, exit, exception or probe")),
    }
    if pr.kind == "exit" && pr.code.is_none_or(|c| c == 0) {
        return Err(invalid("predicate.code", "the failing exit code (not 0)"));
    }
    check_argv("predicate.argv", &pr.argv)?;
    check_argv("predicate.build", &pr.build)?;
    if pr.timebox_s.is_some_and(|t| !(1..=86_400).contains(&t)) {
        return Err(invalid("predicate.timebox_s", "1 to 86400 seconds"));
    }
    if p.parallel.is_some_and(|n| !(1..=8).contains(&n)) {
        return Err(invalid("parallel", "1 to 8 slots"));
    }
    Ok(())
}

fn check_id(p: &DebugBisectId) -> Result<(), Error> {
    check_text("bisect", &p.bisect)?;
    if !p.bisect.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err(invalid("bisect", "a bisect's id"));
    }
    Ok(())
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "debug/bisect", DebugBisect(DebugBisect) -> DebugBisectStarted,
            classes: [User], writes: false,
            doc: "which change broke it: the good state re-checked, then the states up to now (agent steps, saves, launch snapshots, commits) run by the predicate in slots, each slot one folder restored by delta; `debug-bisect` events give the dots and the first bad state with its author, step and decision",
            check: check_bisect,
        ),
        method!(
            "debug/bisect/cancel", DebugBisectCancel(DebugBisectId) -> bool,
            classes: [User], writes: false,
            doc: "stop a bisect and its runs",
            check: check_id,
        ),
        method!(
            "debug/bisect/narrow", DebugBisectNarrow(DebugBisectId) -> bool,
            classes: [User], writes: false,
            doc: "narrow a bisect's first bad state to the hunks that make it fail (delta debugging); a `debug-bisect` event gives them",
            check: check_id,
        ),
        method!(
            "debug/bisect/states", DebugBisectStates(DebugBisectStates) -> DebugBisectStateList,
            classes: [User], writes: false,
            doc: "the states a bisect of a project can stop at after a good state: agent steps, saves, launch snapshots and commits, oldest first",
            check: check_states,
        ),
    ]
}

#[cfg(test)]
mod tests {
    use crate::registry::{self, Class};
    use serde_json::json;

    #[test]
    fn bisect_is_the_users_and_checks_its_predicate() {
        for name in [
            "debug/bisect",
            "debug/bisect/cancel",
            "debug/bisect/narrow",
            "debug/bisect/states",
        ] {
            let m = registry::find(name).unwrap_or_else(|| panic!("{name} is not registered"));
            assert!(m.allows(Class::User) && !m.allows(Class::Agent), "{name}");
        }
        let m = registry::find("debug/bisect").unwrap();
        let ok = json!({"root": "/p", "good": {"kind": "commit", "id": "abc123"},
                        "predicate": {"kind": "test", "argv": ["pytest", "-x"]}});
        assert!((m.decode)(&ok).is_ok());
        let bad = json!({"root": "/p", "good": {"kind": "commit", "id": "abc123"},
                         "predicate": {"kind": "exit", "argv": ["./run"], "code": 0}});
        assert_eq!(
            (m.decode)(&bad).err().and_then(|e| e.path).as_deref(),
            Some("predicate.code")
        );
        let bad = json!({"root": "/p", "good": {"kind": "tag", "id": "v1"},
                         "predicate": {"kind": "test", "argv": ["t"]}});
        assert_eq!(
            (m.decode)(&bad).err().and_then(|e| e.path).as_deref(),
            Some("good")
        );
        // the replayed predicates: a place PATH:LINE, and a probe's condition
        let ok = json!({"root": "/p", "good": {"kind": "commit", "id": "abc123"},
                        "predicate": {"kind": "probe", "run": "r1", "at": "app/stock.py:15", "condition": "x < 0"}});
        assert!((m.decode)(&ok).is_ok());
        for (pred, path) in [
            (json!({"kind": "exception", "run": "r1"}), "predicate.at"),
            (
                json!({"kind": "exception", "run": "r1", "at": "stock.py"}),
                "predicate.at",
            ),
            (
                json!({"kind": "exception", "run": "r1", "at": "/abs/stock.py:3"}),
                "predicate.at",
            ),
            (
                json!({"kind": "probe", "run": "r1", "at": "stock.py:3"}),
                "predicate.condition",
            ),
        ] {
            let bad = json!({"root": "/p", "good": {"kind": "commit", "id": "abc123"}, "predicate": pred});
            assert_eq!(
                (m.decode)(&bad).err().and_then(|e| e.path).as_deref(),
                Some(path),
                "{bad}"
            );
        }
    }
}
