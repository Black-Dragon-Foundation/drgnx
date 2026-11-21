//! The origin trail (docs/develop/debugging.md, spec §19.4, §19.8): `debug/origin` asks where a value at a recorded stop
//! came from; the trail comes as `debug-origin` events, a level per replay.  The user's (a recorded run's values are
//! theirs, `debug.read`).

use super::{invalid, method};
use crate::registry::Method;
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// The longest expression or run id, in bytes.
pub const TEXT_MAX: usize = 4096;

/// `debug/origin`: where EXPR (a name or a dotted path, `item.reserve`) came from at stop STOP of recorded run RUN,
/// DEPTH levels deep (1 to 3, default 3).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugOrigin {
    pub run: String,
    pub stop: u64,
    pub expr: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub depth: Option<u32>,
}

/// A trail started: its id (the `debug-origin` events name it).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugOriginStarted {
    pub origin: String,
}

fn check(p: &DebugOrigin) -> Result<(), Error> {
    if p.run.is_empty()
        || p.run.len() > TEXT_MAX
        || !p
            .run
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
    {
        return Err(invalid("run", "a run id"));
    }
    let ident = |s: &str| {
        !s.is_empty()
            && !s.starts_with(|c: char| c.is_ascii_digit())
            && s.chars().all(|c| c.is_alphanumeric() || c == '_')
    };
    if p.expr.len() > TEXT_MAX || !p.expr.split('.').all(ident) {
        return Err(invalid("expr", "a name or a dotted path (item.reserve)"));
    }
    if p.depth.is_some_and(|d| !(1..=3).contains(&d)) {
        return Err(invalid("depth", "1 to 3 levels"));
    }
    Ok(())
}

pub(crate) fn methods() -> Vec<Method> {
    vec![method!(
        "debug/origin", DebugOrigin(DebugOrigin) -> DebugOriginStarted,
        classes: [User], writes: false,
        doc: "where did this come from: the recorded run replayed to the stop under a tracer (Python 3.12 and later) that records the stores to the value and their operands, a level per replay; older Pythons get the assignments as candidates, not traced; `debug-origin` events give the trail",
        check: check,
    )]
}

#[cfg(test)]
mod tests {
    use crate::registry::{self, Class};
    use serde_json::json;

    #[test]
    fn origin_is_the_users_and_takes_a_dotted_path() {
        let m = registry::find("debug/origin").expect("debug/origin is registered");
        assert!(m.allows(Class::User) && !m.allows(Class::Agent));
        assert!((m.decode)(&json!({"run": "r-1", "stop": 3, "expr": "item.reserve"})).is_ok());
        for (bad, path) in [
            (json!({"run": "r-1", "stop": 3, "expr": "item.x()"}), "expr"),
            (
                json!({"run": "r-1", "stop": 3, "expr": "x", "depth": 4}),
                "depth",
            ),
            (json!({"run": "../r", "stop": 3, "expr": "x"}), "run"),
        ] {
            assert_eq!(
                (m.decode)(&bad).err().and_then(|e| e.path).as_deref(),
                Some(path)
            );
        }
    }
}
