//! Forwarding to the Lisp backend (design 8.2, review I4): what the front does not serve goes on as `{id, method,
//! params, caller}`, the params re-encoded from their typed decode (never the client's line) and `caller` the class
//! (and an agent socket's session and job) the front established.  Provider keys are exposed only while that line is
//! serialised, and the line is wiped once written.
//!
//! - A line over 1 MiB (the Lisp hub's `drgnx-hub--max-line`) is `invalid-params` and never sent: an over-long line
//!   would make the backend drop the front's whole connection.
//! - The backend's `{error: {message}}` is `internal` with that message; a `result` goes through the method's
//!   `check_result`, and one that does not fit is `internal` (logged with its path).
//! - Params and results are shaped by class ([`crate::shape`]).

use crate::backend::Backend;
use crate::dispatch::{Answer, BackendInfo, Caller, Forward};
use crate::shape;
use drgnx_proto::line::MAX_CLIENT_LINE;
use drgnx_proto::methods::Params;
use drgnx_proto::registry::{Class, Method};
use drgnx_proto::wire::{Error, ErrorCode};
use serde::Serialize;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use zeroize::Zeroizing;

/// The longest line the backend reads (bytes; the Lisp hub counts characters, of which there are no more).
pub const MAX_BACKEND_LINE: usize = MAX_CLIENT_LINE;

#[derive(Serialize)]
struct CallerJson<'a> {
    class: Class,
    #[serde(skip_serializing_if = "Option::is_none")]
    sid: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    job: Option<&'a str>,
}

#[derive(Serialize)]
struct Line<'a> {
    id: u64,
    method: &'a str,
    params: &'a Params,
    caller: CallerJson<'a>,
}

/// The line sent to the backend for request ID (no newline).
pub fn line(id: u64, method: &str, params: &Params, caller: &Caller) -> Zeroizing<String> {
    Zeroizing::new(
        serde_json::to_string(&Line {
            id,
            method,
            params,
            caller: CallerJson {
                class: caller.class,
                sid: caller.sid.as_deref(),
                job: caller.job.as_deref(),
            },
        })
        .expect("a request serializes"),
    )
}

/// The Lisp backend as the front's [`Forward`].
pub struct ToBackend(pub Arc<Backend>);

impl ToBackend {
    async fn call_backend(
        &self,
        caller: Caller,
        method: &'static Method,
        mut params: Params,
    ) -> Result<serde_json::Value, Error> {
        shape::params(&caller, &mut params)?;
        let id = self.0.next_id();
        let text = line(id, method.name, &params, &caller);
        drop(params);
        if text.len() > MAX_BACKEND_LINE {
            return Err(Error {
                code: ErrorCode::InvalidParams,
                message: "the request is too large for the Lisp backend".into(),
                path: None,
            });
        }
        let result = self.0.request(id, method.name, text).await?;
        let checked = (method.check_result)(&result).map_err(|e| {
            let at = e.path.unwrap_or_else(|| "(the whole result)".into());
            tracing::warn!(
                method = method.name,
                path = at,
                "the backend's answer does not match its schema"
            );
            Error {
                code: ErrorCode::Internal,
                message: format!(
                    "the backend's answer to {} does not match its schema: {at}",
                    method.name
                ),
                path: None,
            }
        })?;
        Ok(shape::result(&caller, method.name, checked))
    }
}

impl Forward for ToBackend {
    fn call<'a>(&'a self, caller: Caller, method: &'static Method, params: Params) -> Answer<'a> {
        Box::pin(self.call_backend(caller, method, params))
    }

    fn status<'a>(&'a self) -> Pin<Box<dyn Future<Output = BackendInfo> + Send + 'a>> {
        Box::pin(self.0.info())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use drgnx_proto::registry::find;
    use serde_json::{Value, json};

    fn decoded(method: &str, params: Value) -> Params {
        (find(method).unwrap().decode)(&params).unwrap().0
    }

    fn caller(class: Class, sid: Option<&str>, job: Option<&str>) -> Caller {
        Caller {
            class,
            sid: sid.map(str::to_string),
            job: job.map(str::to_string),
            conn_id: 3,
        }
    }

    #[test]
    fn the_line_is_the_typed_params_and_the_caller() {
        let p = decoded("job/stop", json!({"id": "j", "x": 1}));
        let l = line(7, "job/stop", &p, &caller(Class::User, None, None));
        assert_eq!(
            serde_json::from_str::<Value>(&l).unwrap(),
            json!({"id": 7, "method": "job/stop", "params": {"id": "j"}, "caller": {"class": "user"}})
        );
        let p = decoded("spend", json!({"job": "j1"}));
        let l = line(
            8,
            "spend",
            &p,
            &caller(Class::Agent, Some("s1"), Some("j1")),
        );
        assert_eq!(
            serde_json::from_str::<Value>(&l).unwrap(),
            json!({"id": 8, "method": "spend", "params": {"job": "j1"},
                   "caller": {"class": "agent", "sid": "s1", "job": "j1"}})
        );
        // keys go into the line (and only there)
        let p = decoded("gateway/keys", json!({"keys": {"openrouter": "sk-x"}}));
        let l = line(9, "gateway/keys", &p, &caller(Class::User, None, None));
        assert!(l.contains(r#""keys":{"openrouter":"sk-x"}"#), "{}", *l);
        assert!(!l.contains('\n'));
    }
}
