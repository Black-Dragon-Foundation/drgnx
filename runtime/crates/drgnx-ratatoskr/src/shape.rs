//! What a caller may see and ask, by class (design 4.2), on top of the registry's class check:
//!
//! - `agents/list`: a `user` gets the backend's snapshots; a `service` connection gets `{sessions: [{id, name, job,
//!   task}]}`, and an `agent` the same for its own job's sessions (and its own session) only.
//! - `spend` from an `agent`: `job` defaults to the caller's own job, and another job is `not-allowed`.
//!
//! The params are shaped before the line goes to the backend, the result after it passed `check_result`; `spend` is the
//! front's since Task 22 ([`crate::gateway`]), which shapes its params here the same way.

use crate::dispatch::Caller;
use runstav::methods::Params;
use runstav::registry::Class;
use runstav::types::Id;
use runstav::wire::{Error, ErrorCode};
use serde_json::{Map, Value};

/// The keys of a session a `service` or `agent` caller of `agents/list` gets.
pub const SUMMARY_KEYS: [&str; 4] = ["id", "name", "job", "task"];

/// PARAMS as CALLER may send them on: an agent's `spend` reads its own job.
pub fn params(caller: &Caller, params: &mut Params) -> Result<(), Error> {
    if caller.class != Class::Agent {
        return Ok(());
    }
    if let Params::Spend(p) = params {
        let refuse = || Error {
            code: ErrorCode::NotAllowed,
            message: "spend: an agent reads only its own job's spend (agent class)".into(),
            path: Some("job".into()),
        };
        let own = caller.job.as_deref().ok_or_else(refuse)?;
        match &p.job {
            None => p.job = Some(Id::new(own).map_err(|_| refuse())?),
            Some(j) if j.as_str() == own => {}
            Some(_) => return Err(refuse()),
        }
    }
    Ok(())
}

/// METHOD's checked RESULT as CALLER may see it.
pub fn result(caller: &Caller, method: &str, result: Value) -> Value {
    if method != "agents/list" || caller.class == Class::User {
        return result;
    }
    let sessions = result
        .get("sessions")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mine = |s: &Value| match caller.class {
        Class::Agent => {
            let field = |k: &str| s.get(k).and_then(Value::as_str);
            (caller.job.is_some() && field("job") == caller.job.as_deref())
                || (caller.sid.is_some() && field("id") == caller.sid.as_deref())
        }
        _ => true,
    };
    let shaped: Vec<Value> = sessions
        .iter()
        .filter(|s| mine(s))
        .map(|s| {
            let keep: Map<String, Value> = SUMMARY_KEYS
                .iter()
                .filter_map(|k| s.get(*k).map(|v| (k.to_string(), v.clone())))
                .collect();
            Value::Object(keep)
        })
        .collect();
    serde_json::json!({ "sessions": shaped })
}

#[cfg(test)]
mod tests {
    use super::*;
    use runstav::registry::find;
    use serde_json::json;

    fn caller(class: Class, sid: Option<&str>, job: Option<&str>) -> Caller {
        Caller {
            class,
            sid: sid.map(str::to_string),
            job: job.map(str::to_string),
            conn_id: 1,
            backend: false,
        }
    }

    fn list() -> Value {
        json!({"sessions": [
            {"id": "s1", "name": "agent-1", "job": "j1", "task": "T#1", "profile": "p", "cwd": "/x", "queue": []},
            {"id": "s2", "name": "agent-2", "job": "j2", "profile": "p", "queue": []},
            {"id": "s3", "name": "chat", "profile": "p", "queue": []},
        ]})
    }

    #[test]
    fn agents_list_is_whole_for_the_user_and_a_summary_for_the_others() {
        let u = caller(Class::User, None, None);
        assert_eq!(result(&u, "agents/list", list()), list());
        let s = caller(Class::Service, None, None);
        assert_eq!(
            result(&s, "agents/list", list()),
            json!({"sessions": [
                {"id": "s1", "name": "agent-1", "job": "j1", "task": "T#1"},
                {"id": "s2", "name": "agent-2", "job": "j2"},
                {"id": "s3", "name": "chat"},
            ]})
        );
        // an agent: its own job's sessions only
        let a = caller(Class::Agent, Some("s9"), Some("j1"));
        assert_eq!(
            result(&a, "agents/list", list()),
            json!({"sessions": [{"id": "s1", "name": "agent-1", "job": "j1", "task": "T#1"}]})
        );
        // an agent without a job sees its own session only
        let a = caller(Class::Agent, Some("s3"), None);
        assert_eq!(
            result(&a, "agents/list", list()),
            json!({"sessions": [{"id": "s3", "name": "chat"}]})
        );
        // other methods pass as they are
        assert_eq!(result(&s, "spend", json!({"cost": 1})), json!({"cost": 1}));
    }

    fn spend(v: Value) -> Params {
        (find("spend").unwrap().decode)(&v).unwrap().0
    }

    #[test]
    fn an_agents_spend_is_its_own_jobs() {
        let a = caller(Class::Agent, Some("s1"), Some("j1"));
        let mut p = spend(json!({}));
        params(&a, &mut p).unwrap();
        assert_eq!(p.to_value(), json!({"job": "j1"}));
        let mut p = spend(json!({"job": "j1", "agent": "agent-1"}));
        params(&a, &mut p).unwrap();
        assert_eq!(p.to_value(), json!({"job": "j1", "agent": "agent-1"}));
        let mut p = spend(json!({"job": "j2"}));
        let e = params(&a, &mut p).unwrap_err();
        assert_eq!(
            (e.code, e.path.as_deref()),
            (ErrorCode::NotAllowed, Some("job"))
        );
        // an agent without a job has no spend to read
        let mut p = spend(json!({}));
        assert!(params(&caller(Class::Agent, Some("s1"), None), &mut p).is_err());
        // the user and a service connection ask what they ask
        for c in [
            caller(Class::User, None, None),
            caller(Class::Service, None, None),
        ] {
            let mut p = spend(json!({"job": "j2"}));
            params(&c, &mut p).unwrap();
            assert_eq!(p.to_value(), json!({"job": "j2"}));
        }
    }
}
