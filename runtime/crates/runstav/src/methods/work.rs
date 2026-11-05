//! The Work space's methods (agent system part 2; `docs/develop/work-space.md`, `docs/guide/work-space.md`).
//!
//! Machines: `machines/report` (a user connection tells the hub which slots a machine has and who holds them, for a
//! time) and `machines/list`; the event `machines-changed` carries the list again when it changed.

use super::{Empty, invalid, method};
use crate::registry::Method;
use crate::types::null_as_empty;
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// The workspace a Work view shows: one id, the roots (repositories or folders) it spans. The editor sends it with
/// every subscription; the hub never decides what a workspace is.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Workspace {
    /// `workspace:` and 12 hex digits.
    pub id: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub roots: Vec<std::path::PathBuf>,
}

/// One slot of a machine: where one agent job runs.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Slot {
    pub id: String,
    /// Who holds it now (a job or a session id); none when free.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub holder: Option<String>,
    /// What the slot is for: `agent-job`, `build`, `test`, `gpu`, ...
    pub kind: String,
}

/// What a reporter (jobq) says about one machine: its slots, valid for `ttl` seconds.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MachineReport {
    pub machine: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub slots: Vec<Slot>,
    /// Seconds the report stands; after that the machine is gone from the list until it reports again.
    pub ttl: f64,
}

/// A machine as the hub lists it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Machine {
    pub machine: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub slots: Vec<Slot>,
    /// The hub's own machine: always listed, never expires.
    pub local: bool,
}

/// `machines/list`'s answer, and the data of `machines-changed`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MachinesList {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub machines: Vec<Machine>,
}

/// The longest machine name, in bytes.
pub const NAME_MAX: usize = 64;
/// Most slots one report may hold.
pub const SLOTS_MAX: usize = 256;
/// The longest a report may stand, in seconds.
pub const TTL_MAX: f64 = 86_400.0;

fn check_report(p: &MachineReport) -> Result<(), Error> {
    let name = p.machine.as_str();
    if name.is_empty()
        || name.len() > NAME_MAX
        || name.chars().any(|c| c.is_whitespace() || c.is_control())
    {
        return Err(invalid(
            "machine",
            "a name of 1 to 64 characters with no spaces",
        ));
    }
    if name == "local" {
        return Err(invalid(
            "machine",
            "local is the hub's own machine; it is not reported",
        ));
    }
    if !(p.ttl > 0.0 && p.ttl <= TTL_MAX) {
        return Err(invalid("ttl", "seconds, more than 0 and at most 86400"));
    }
    if p.slots.len() > SLOTS_MAX {
        return Err(invalid("slots", "at most 256 slots"));
    }
    if p.slots.iter().any(|s| s.id.is_empty() || s.kind.is_empty()) {
        return Err(invalid("slots", "every slot needs an id and a kind"));
    }
    Ok(())
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "machines/report", MachinesReport(MachineReport) -> Machine,
            classes: [User], writes: false,
            doc: "a machine's slots and who holds them, valid for ttl seconds (jobq reports; an agent may not)",
            check: check_report,
        ),
        method!(
            "machines/list", MachinesList(Empty) -> MachinesList,
            classes: [User], writes: false,
            doc: "the machines the hub knows: local, and those reported and not yet expired",
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn report(v: serde_json::Value) -> Result<MachineReport, Error> {
        let (p, _) = crate::registry::decode_params::<MachineReport>(&v)?;
        check_report(&p).map(|()| p)
    }

    #[test]
    fn a_report_is_checked() {
        assert!(
            report(
                json!({"machine": "desktop", "ttl": 30, "slots": [{"id": "s1", "kind": "build"}]})
            )
            .is_ok()
        );
        for bad in [
            json!({"machine": "", "ttl": 30}),
            json!({"machine": "a b", "ttl": 30}),
            json!({"machine": "local", "ttl": 30}),
            json!({"machine": "m", "ttl": 0}),
            json!({"machine": "m", "ttl": 90000}),
            json!({"machine": "m", "ttl": 5, "slots": [{"id": "", "kind": "build"}]}),
        ] {
            assert!(report(bad.clone()).is_err(), "{bad}");
        }
    }
}
