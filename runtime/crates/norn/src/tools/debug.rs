//! The debugger's tools for agents (graphical debugging spec §19.5, D4: a partner agent).  The hub checks each call
//! against the matrix's `debug.*` rows for the calling session (`debug.read`, `debug.probe`, `debug.fork`,
//! `debug.live-eval`, `debug.drive`; an Ask is a card, never a prompt) and acts: reads of the user's sessions and
//! recorded runs, probes and breakpoints marked as the agent's, what-if forks (sealed), and, only where the rows allow
//! it, an evaluate or a step in the user's live session.  The user's own step wins: a step names the stop it was
//! read at, and a session that has moved on since refuses it.  The edit history (`history/*`) stays the user's: no
//! tool here reaches it.  Hypotheses are `debug_hypothesis` records; a fix is offered (a card) only after it passed
//! its predicate in a fresh fork.

use mimir::{BoxFuture, Tool};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::guard::{CoordTool, guarded};
use super::{Coord, Ctx, Identity};

/// `debug_read`: what to read.
#[derive(Debug, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ReadArgs {
    /// sessions, runs (ROOT's), run (RUN's stops, hits), stop (RUN's STOP: frames, values), fork (FORK)
    pub what: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork: Option<String>,
}

/// `debug_probe`: a probe or a breakpoint of yours in the user's session.
#[derive(Debug, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ProbeArgs {
    pub root: String,
    /// probe (EXPR each time PATH:LINE runs), breakpoint (at PATH:LINE), remove (your ID)
    pub op: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expr: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
}

/// `debug_fork`: a what-if fork of a recorded run.
#[derive(Debug, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ForkArgs {
    pub run: String,
    /// {stop: N} or {path, line, hit}
    pub at: Value,
    /// {value: {path: [names], text}}; none replays
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub change: Option<Value>,
    /// stop, exit or {probe: ID}
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub until: Option<Value>,
}

/// `debug_live`: the user's live session.
#[derive(Debug, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct LiveArgs {
    /// From debug_read sessions
    pub debug_session: String,
    /// evaluate (EXPR), continue, next, step-in, step-out
    pub op: String,
    /// The epoch you read; refused if the user moved on
    pub epoch: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expr: Option<String>,
}

/// `debug_hypothesis`: one hypothesis of the investigation.
#[derive(Debug, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HypothesisArgs {
    pub root: String,
    /// To change one you recorded
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub title: String,
    /// open, confirmed, rejected
    pub state: String,
    /// run R stop N, run R probe P hit N, fork F
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub evidence: Vec<String>,
}

/// `debug_fix`: a fix, checked in a fresh fork before it is offered.
#[derive(Debug, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FixArgs {
    pub hypothesis: String,
    pub run: String,
    /// Changed files
    pub files: Vec<FixFile>,
    /// {exception: PATH:LINE} (not raised there) or {probe: PATH:LINE, expr, not} (EXPR never NOT); and exit 0
    pub predicate: Value,
}

#[derive(Debug, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FixFile {
    pub path: String,
    pub text: String,
}

macro_rules! debug_tool {
    ($ty:ident, $args:ty, $name:literal, $desc:literal) => {
        pub struct $ty;
        impl CoordTool for $ty {
            type Args = $args;
            const NAME: &'static str = $name;
            const DESCRIPTION: &'static str = $desc;
            fn run<'a>(
                &'a self,
                coord: &'a Coord,
                who: &'a Identity,
                args: $args,
            ) -> BoxFuture<'a, Result<String, String>> {
                Box::pin(async move {
                    let Identity::Session { sid, .. } = who else {
                        return Err("the debugger's tools are for agents drgnx runs".into());
                    };
                    let args = serde_json::to_value(args).map_err(|e| e.to_string())?;
                    coord.hub().debug(sid, $name, args).await
                })
            }
        }
    };
}

debug_tool!(
    DebugRead,
    ReadArgs,
    "debug_read",
    "Read debug sessions, recorded runs, their stops and values, or a fork."
);
debug_tool!(
    DebugProbe,
    ProbeArgs,
    "debug_probe",
    "Add or remove your probe or breakpoint in the user's debug session."
);
debug_tool!(
    DebugFork,
    ForkArgs,
    "debug_fork",
    "Fork a recorded run (sealed) at a point, maybe change a value, and run on."
);
debug_tool!(
    DebugLive,
    LiveArgs,
    "debug_live",
    "Evaluate in or step the user's live session, if allowed."
);
debug_tool!(
    DebugHypothesis,
    HypothesisArgs,
    "debug_hypothesis",
    "Record or update a hypothesis with its evidence."
);
debug_tool!(
    DebugFix,
    FixArgs,
    "debug_fix",
    "Check a fix in a fresh fork; only a passing fix is offered to the user."
);

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![
        guarded(DebugRead),
        guarded(DebugProbe),
        guarded(DebugFork),
        guarded(DebugLive),
        guarded(DebugHypothesis),
        guarded(DebugFix),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::CoordDb;
    use crate::tools::{Hub, SessionRow};
    use mimir::ToolResult;
    use std::sync::{Arc, Mutex};

    /// A hub that keeps each debugger call it gets.
    #[derive(Default)]
    struct Calls(Mutex<Vec<(String, String, Value)>>);
    impl Hub for Calls {
        fn sessions(&self) -> BoxFuture<'_, Option<Vec<SessionRow>>> {
            Box::pin(async { None })
        }
        fn notify(&self) {}
        fn debug(
            &self,
            sid: &str,
            op: &'static str,
            args: Value,
        ) -> BoxFuture<'_, Result<String, String>> {
            self.0
                .lock()
                .unwrap()
                .push((sid.to_owned(), op.to_owned(), args));
            Box::pin(async { Ok("done".to_string()) })
        }
    }

    /// Each debugger tool reaches the hub as the calling session, with its name and its arguments; an outside agent
    /// is refused before the hub.
    #[tokio::test]
    async fn each_debugger_tool_reaches_the_hub_as_its_session() {
        let dir = tempfile::tempdir().unwrap();
        let hub = Arc::new(Calls::default());
        let coord = Arc::new(Coord::new(
            CoordDb::spawn(dir.path().join("work.db")),
            hub.clone(),
        ));
        let who = Identity::Session {
            agent: "ada".into(),
            sid: "s1".into(),
            profile: None,
            job: None,
            task: None,
            home: dir.path().to_path_buf(),
        };
        let all = tools();
        let names: Vec<&str> = all.iter().map(|t| t.name()).collect();
        assert_eq!(
            names,
            [
                "debug_read",
                "debug_probe",
                "debug_fork",
                "debug_live",
                "debug_hypothesis",
                "debug_fix"
            ]
        );
        let live = all.iter().find(|t| t.name() == "debug_live").unwrap();
        let args = serde_json::json!({"debug_session": "d1", "op": "next", "epoch": 3});
        live.check(&args).unwrap();
        match live.call(&(coord.clone(), who), args.clone()).await {
            ToolResult::Ok { .. } => {}
            _ => panic!("debug_live was not answered"),
        }
        assert_eq!(
            *hub.0.lock().unwrap(),
            [("s1".to_owned(), "debug_live".to_owned(), args)]
        );
        // a step must name the stop it was read at
        assert!(
            live.check(&serde_json::json!({"debug_session": "d1", "op": "next"}))
                .is_err()
        );
        let outside = Identity::Outside {
            id: "ext:x:1".into(),
            kind: "x".into(),
            home: None,
        };
        let read = all.iter().find(|t| t.name() == "debug_read").unwrap();
        match read
            .call(&(coord, outside), serde_json::json!({"what": "sessions"}))
            .await
        {
            ToolResult::Err(t) => assert!(t.contains("agents drgnx runs"), "{t}"),
            _ => panic!("an outside agent read the debugger"),
        }
        assert_eq!(hub.0.lock().unwrap().len(), 1);
    }
}
