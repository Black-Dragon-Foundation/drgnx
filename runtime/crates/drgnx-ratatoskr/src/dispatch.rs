//! The dispatcher (design 4.3, the contract's order): every line is checked before anything runs.
//!
//! 1. an unknown method → `no-method`;
//! 2. a class the method does not take → `not-allowed`;
//!    2b. the Lisp backend calling the front ([`Caller::backend`]): a method the front does not serve, or `subscribe`
//!    → `not-allowed` (the seam rule: a backend call never waits on the backend, so it cannot deadlock);
//! 3. a call on a user connection whose hello said a newer protocol → `proto`;
//! 4. the typed decode → `invalid-params` with its `path` (keys the method does not know are dropped and listed);
//! 5. a method that writes while work.db is newer than this hub → `schema`;
//! 6. the handler, whose failure is `internal`.
//!
//! [`prelude_as`] is steps 1–5 with no handler: the connection loop calls it, the fuzz target [`prelude`] (no backend).  A refusal is
//! logged and counted by [`Refusals::note`], with the method, the code, the class and the path, never the params or
//! the message (a decode error's message can quote a value: a key, a prompt).

use runstav::line;
use runstav::methods::Params;
use runstav::methods::hub::{Backend, Refusals as RefusalsResult};
use runstav::registry::{self, Class, Home, Method};
use runstav::wire::{Error, ErrorCode, Id, Request};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;

/// How many refusals `status` lists.
pub const KEEP: usize = 20;

/// The longest method name a refusal keeps (a client may send anything there).
const METHOD_CHARS: usize = 64;

/// A request that passed steps 1–5.
pub struct Call {
    /// None for a notification: dispatched, never answered.
    pub id: Option<Id>,
    pub method: &'static Method,
    pub params: Params,
    /// The dotted paths of the keys dropped (the answer's `ignored`).
    pub ignored: Vec<String>,
}

/// A request refused before its handler.
#[derive(Debug)]
pub struct Refusal {
    /// The id to answer; none for a notification (counted and logged, not answered).
    pub id: Option<Id>,
    /// The method asked for, when the line had one.
    pub method: Option<String>,
    pub error: Error,
}

/// What [`prelude`] gives instead of a [`Call`].
#[derive(Debug)]
pub enum ErrorAnswerOrDrop {
    /// Refused: answered when it has an id; always counted.
    Refused(Refusal),
    /// A line that is no request and has no id: logged and dropped (nobody waits for it).
    Drop(String),
}

/// Steps 1–5 for LINE on a connection of CLASS whose hello said PROTO (0: no hello), while work.db's schema is
/// READ_ONLY when it is newer than this hub's.  A connection that is not the backend's: [`prelude_as`].
pub fn prelude(
    class: Class,
    proto: u32,
    read_only: Option<u32>,
    line: &str,
) -> Result<Call, ErrorAnswerOrDrop> {
    prelude_as(class, false, proto, read_only, line)
}

/// [`prelude`] on a connection that is the Lisp backend's when BACKEND ([`Caller::backend`]): step 2b applies.
pub fn prelude_as(
    class: Class,
    backend: bool,
    proto: u32,
    read_only: Option<u32>,
    line: &str,
) -> Result<Call, ErrorAnswerOrDrop> {
    let v = line::parse_strict(line).map_err(|e| match e.id {
        Some(id) => refuse_with(Some(id), None, ErrorCode::InvalidParams, e.message, e.path),
        None => ErrorAnswerOrDrop::Drop(format!(
            "a line that is no request and has no id: {}",
            e.message
        )),
    })?;
    let req: Request = match serde_json::from_value(v) {
        Ok(r) => r,
        Err(e) => {
            // the line is an object (parse_strict): its id, when it reads, is answered
            let id = line::parse_strict(line)
                .ok()
                .and_then(|v| v.get("id").cloned())
                .and_then(|i| serde_json::from_value::<Id>(i).ok());
            return Err(match id {
                Some(id) => refuse_with(
                    Some(id),
                    None,
                    ErrorCode::InvalidParams,
                    format!("not a request: {e}"),
                    None,
                ),
                None => {
                    ErrorAnswerOrDrop::Drop(format!("a line that is no request and has no id: {e}"))
                }
            });
        }
    };
    let refuse = |code, message: String, path| {
        refuse_with(
            req.id.clone(),
            Some(req.method.clone()),
            code,
            message,
            path,
        )
    };
    // 1
    let Some(m) = registry::find(&req.method) else {
        return Err(refuse(
            ErrorCode::NoMethod,
            format!("no method {}", cut(&req.method)),
            None,
        ));
    };
    // 2
    if !m.allows(class) {
        let message = if class == Class::Service && m.allows(Class::User) {
            format!(
                "{} needs the user's capability (an editor or CLI of an older drgnx: update it)",
                m.name
            )
        } else {
            format!(
                "{} is not allowed on this connection ({} class)",
                m.name,
                class.name()
            )
        };
        return Err(refuse(ErrorCode::NotAllowed, message, None));
    }
    // 2b: the backend waits on nothing that waits on it
    if backend && m.home == Home::Backend {
        return Err(refuse(
            ErrorCode::NotAllowed,
            "the backend may call only what the front serves".into(),
            None,
        ));
    }
    if backend && m.name == "subscribe" {
        return Err(refuse(
            ErrorCode::NotAllowed,
            "the backend hears the front through notifications".into(),
            None,
        ));
    }
    // 3
    if class == Class::User && m.name != "hello" && proto > registry::PROTO {
        return Err(refuse(
            ErrorCode::Proto,
            format!(
                "this hub speaks protocol {}, the connection's hello said {proto}: restart the hub (drgnx hub stop)",
                registry::PROTO
            ),
            None,
        ));
    }
    // 4
    let (params, ignored) =
        (m.decode)(&req.params).map_err(|e| refuse(ErrorCode::InvalidParams, e.message, e.path))?;
    // 5
    if let Some(schema) = read_only.filter(|_| m.writes) {
        return Err(refuse(
            ErrorCode::Schema,
            format!(
                "work.db is schema {schema}, newer than this hub's {}: update drgnx",
                registry::SCHEMA
            ),
            None,
        ));
    }
    Ok(Call {
        id: req.id,
        method: m,
        params,
        ignored,
    })
}

/// A method name as a refusal keeps it: at most [`METHOD_CHARS`] characters.
fn cut(method: &str) -> &str {
    match method.char_indices().nth(METHOD_CHARS) {
        Some((i, _)) => &method[..i],
        None => method,
    }
}

fn refuse_with(
    id: Option<Id>,
    method: Option<String>,
    code: ErrorCode,
    message: String,
    path: Option<String>,
) -> ErrorAnswerOrDrop {
    ErrorAnswerOrDrop::Refused(Refusal {
        id,
        method,
        error: Error {
            code,
            message,
            path,
        },
    })
}

/// The refusals the hub counted, and the last [`KEEP`] (newest first) for `status`.
#[derive(Default)]
pub struct Refusals {
    count: u64,
    last: VecDeque<Value>,
}

impl Refusals {
    /// Count and log a refusal of METHOD on connection CONN of CLASS, at AT (RFC 3339).  Only the method (cut to 64
    /// characters), the code, the class and the path are kept and logged.
    pub fn note(
        &mut self,
        at: String,
        conn: u64,
        class: Class,
        method: Option<&str>,
        error: &Error,
    ) {
        let method = method.map(cut);
        let code = serde_json::to_value(error.code).expect("a code serializes");
        let code = code.as_str().unwrap_or_default();
        tracing::info!(
            conn,
            method,
            code,
            class = class.name(),
            path = error.path.as_deref(),
            "refused a call"
        );
        self.count += 1;
        let mut entry = json!({"at": at, "code": code, "class": class.name()});
        if let Some(m) = method {
            entry["method"] = json!(m);
        }
        if let Some(p) = &error.path {
            entry["path"] = json!(p);
        }
        self.last.push_front(entry);
        self.last.truncate(KEEP);
    }

    pub fn status(&self) -> RefusalsResult {
        RefusalsResult {
            count: self.count,
            last: self.last.iter().cloned().collect(),
        }
    }
}

/// Who calls a method: the connection's class, for an agent socket its session and job, and whether it is the Lisp
/// backend.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Caller {
    pub class: Class,
    pub sid: Option<String>,
    pub job: Option<String>,
    pub conn_id: u64,
    /// The connection's peer pid is the backend's (starting or running): the seam rule (dispatch step 2b) holds it to
    /// what the front serves, and only it may name a message's sender.  Any relaxation of the peer-pid rule (R-FIX-M9:
    /// a backend that connects through a helper, say) must keep marking the backend's connections, or a backend call
    /// could wait on the backend itself (call 2, review m10).
    pub backend: bool,
}

/// What a forwarded call answers.
pub type Answer<'a> = Pin<Box<dyn Future<Output = Result<Value, Error>> + Send + 'a>>;

/// What `status` says of the backend: its state and pid (the gateway's numbers are the front's own).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct BackendInfo {
    pub backend: Option<Backend>,
}

/// The methods the front does not serve itself go here (the Lisp backend: [`crate::forward`]).  PARAMS are the
/// decoded params, re-encoded only into the line sent on, never the line as it came.
pub trait Forward: Send + Sync {
    fn call<'a>(&'a self, caller: Caller, method: &'static Method, params: Params) -> Answer<'a>;

    /// What `status` says of the backend (nothing, without one).
    fn status<'a>(&'a self) -> Pin<Box<dyn Future<Output = BackendInfo> + Send + 'a>> {
        Box::pin(async { BackendInfo::default() })
    }

    /// The backend's pid while it is starting (once spawned) or running: a connection from it is [`Caller::backend`].
    fn backend_pid(&self) -> Option<i32> {
        None
    }

    /// METHOD with PARAMS sent to the backend as a notification (no id, never awaited): dropped when no backend runs.
    fn notify_backend<'a>(
        &'a self,
        method: &'static str,
        params: Value,
    ) -> Pin<Box<dyn Future<Output = ()> + Send + 'a>> {
        let _ = (method, params);
        Box::pin(async {})
    }
}

/// No backend: every forwarded call is `internal` "backend not running".
pub struct NoBackend;

impl Forward for NoBackend {
    fn call<'a>(&'a self, _: Caller, _: &'static Method, _: Params) -> Answer<'a> {
        Box::pin(async {
            Err(Error {
                code: ErrorCode::Internal,
                message: "backend not running".into(),
                path: None,
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conn::Outbox;
    use crate::front::Front;
    use crate::hello::{Session, Socket};
    use runstav::proof::Cap;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};

    fn refused(r: Result<Call, ErrorAnswerOrDrop>) -> Refusal {
        match r {
            Err(ErrorAnswerOrDrop::Refused(r)) => r,
            Err(ErrorAnswerOrDrop::Drop(why)) => panic!("dropped: {why}"),
            Ok(c) => panic!("{} passed", c.method.name),
        }
    }

    fn code(r: Result<Call, ErrorAnswerOrDrop>) -> ErrorCode {
        refused(r).error.code
    }

    #[test]
    fn the_steps_come_in_the_contracts_order() {
        use Class::*;
        let ro = Some(9);
        // 1 before 2: an unknown method is no-method for every class
        assert_eq!(
            code(prelude(Service, 0, ro, r#"{"id":1,"method":"no/such"}"#)),
            ErrorCode::NoMethod
        );
        // 2 before 3, 4 and 5: a service connection's bad params on a writing method are not-allowed
        let r = refused(prelude(
            Service,
            9,
            ro,
            r#"{"id":1,"method":"job/stop","params":{"id":5}}"#,
        ));
        assert_eq!(r.error.code, ErrorCode::NotAllowed);
        assert_eq!(
            r.error.message,
            "job/stop needs the user's capability (an editor or CLI of an older drgnx: update it)"
        );
        let r = refused(prelude(Agent, 0, None, r#"{"id":1,"method":"job/stop"}"#));
        assert_eq!(
            r.error.message,
            "job/stop is not allowed on this connection (agent class)"
        );
        // 3 before 4: a newer hello's user call is proto, bad params or not; hello itself never is
        assert_eq!(
            code(prelude(
                User,
                2,
                None,
                r#"{"id":1,"method":"job/stop","params":{"id":5}}"#
            )),
            ErrorCode::Proto
        );
        assert_eq!(
            code(prelude(
                User,
                2,
                None,
                r#"{"id":1,"method":"hello","params":{}}"#
            )),
            ErrorCode::InvalidParams
        );
        // proto only judges user connections (a service one is no client of this protocol's)
        assert!(prelude(Service, 2, None, r#"{"id":1,"method":"ping"}"#).is_ok());
        // 4 before 5: bad params of a writing method on a read-only hub are invalid-params, with the path
        let r = refused(prelude(
            User,
            1,
            ro,
            r#"{"id":1,"method":"job/stop","params":{"id":5}}"#,
        ));
        assert_eq!(r.error.code, ErrorCode::InvalidParams);
        assert_eq!(r.error.path.as_deref(), Some("id"));
        // 5: good params of a writing method on a read-only hub
        let r = refused(prelude(
            User,
            1,
            ro,
            r#"{"id":1,"method":"job/stop","params":{"id":"j"}}"#,
        ));
        assert_eq!(r.error.code, ErrorCode::Schema);
        assert_eq!(
            r.error.message,
            "work.db is schema 9, newer than this hub's 8: update drgnx"
        );
        // a method that only reads still runs on a read-only hub, and its dropped keys are listed
        let c = prelude(
            User,
            1,
            ro,
            r#"{"id":"x","method":"job/status","params":{"q":1}}"#,
        )
        .unwrap_or_else(|_| panic!("refused"));
        assert_eq!(c.method.name, "job/status");
        assert_eq!(c.id, Some(Id::Str("x".into())));
        assert_eq!(c.ignored, ["q"]);
        // no hello (proto 0) on a user connection is not proto
        assert!(prelude(User, 0, None, r#"{"id":1,"method":"job/status"}"#).is_ok());
    }

    #[test]
    fn a_backend_caller_gets_only_front_methods() {
        use Class::*;
        // the backend (a proven user) may call what the front serves
        for line in [
            r#"{"id":1,"method":"ping"}"#,
            r#"{"id":1,"method":"status"}"#,
            r#"{"id":1,"method":"coord/notify"}"#,
            r#"{"id":1,"method":"events/add","params":{"kind":"job"}}"#,
        ] {
            assert!(prelude_as(User, true, 1, None, line).is_ok(), "{line}");
        }
        // never what it serves itself: that call would wait on the backend
        let r = refused(prelude_as(
            User,
            true,
            1,
            None,
            r#"{"id":1,"method":"env/set","params":{"env":[]}}"#,
        ));
        assert_eq!(
            (r.error.code, r.error.message.as_str()),
            (
                ErrorCode::NotAllowed,
                "the backend may call only what the front serves"
            )
        );
        let r = refused(prelude_as(
            User,
            true,
            1,
            None,
            r#"{"id":1,"method":"subscribe"}"#,
        ));
        assert_eq!(
            (r.error.code, r.error.message.as_str()),
            (
                ErrorCode::NotAllowed,
                "the backend hears the front through notifications"
            )
        );
        // every method: step 2b refuses exactly the backend's own and subscribe (step 2 refuses, before it, what the
        // user class may not call: the service-only mcp/attach)
        for m in registry::registry() {
            let line = json!({"id": 1, "method": m.name}).to_string();
            let r = prelude_as(User, true, 1, None, &line);
            let not_allowed = matches!(&r, Err(ErrorAnswerOrDrop::Refused(x)) if x.error.code == ErrorCode::NotAllowed);
            assert_eq!(
                not_allowed,
                !m.allows(User) || m.home == Home::Backend || m.name == "subscribe",
                "{}",
                m.name
            );
        }
        // another user connection is not held to it
        assert!(prelude_as(User, false, 1, None, r#"{"id":1,"method":"job/status"}"#).is_ok());
        assert!(prelude(User, 1, None, r#"{"id":1,"method":"subscribe"}"#).is_ok());
    }

    #[test]
    fn lines_that_are_no_request() {
        use Class::*;
        // a duplicate key, with the id read: invalid-params at its path
        let r = refused(prelude(
            User,
            1,
            None,
            r#"{"id":4,"method":"ping","params":{"a":1,"a":2}}"#,
        ));
        assert_eq!(r.id, Some(Id::Num(4)));
        assert_eq!(r.error.code, ErrorCode::InvalidParams);
        assert_eq!(r.error.path.as_deref(), Some("params.a"));
        // not JSON, with an id: answered; without one: dropped
        assert_eq!(
            refused(prelude(User, 1, None, r#"{"id":7,"method":"#)).id,
            Some(Id::Num(7))
        );
        assert!(matches!(
            prelude(User, 1, None, r#"{"method":"#),
            Err(ErrorAnswerOrDrop::Drop(_))
        ));
        // JSON but no request (no method): answered when the id reads
        let r = refused(prelude(User, 1, None, r#"{"id":8}"#));
        assert_eq!(
            (r.id, r.error.code),
            (Some(Id::Num(8)), ErrorCode::InvalidParams)
        );
        assert!(matches!(
            prelude(User, 1, None, r#"{"x":1}"#),
            Err(ErrorAnswerOrDrop::Drop(_))
        ));
        // a refused notification has no id to answer
        let r = refused(prelude(Service, 0, None, r#"{"method":"job/stop"}"#));
        assert_eq!((r.id, r.method.as_deref()), (None, Some("job/stop")));
        // a notification that passes is a call without an id
        assert!(prelude(Service, 0, None, r#"{"method":"ping"}"#).is_ok_and(|c| c.id.is_none()));
    }

    #[test]
    fn refusals_keep_the_last_twenty_newest_first() {
        let mut r = Refusals::default();
        let e = |code| Error {
            code,
            message: "m".into(),
            path: None,
        };
        for i in 0..25 {
            r.note(
                format!("t{i}"),
                1,
                Class::Service,
                Some("job/stop"),
                &e(ErrorCode::NotAllowed),
            );
        }
        let long = "x".repeat(200);
        r.note(
            "t".into(),
            1,
            Class::User,
            Some(&long),
            &e(ErrorCode::NoMethod),
        );
        let s = r.status();
        assert_eq!(s.count, 26);
        assert_eq!(s.last.len(), KEEP);
        assert_eq!(s.last[0]["method"].as_str().unwrap().chars().count(), 64);
        assert_eq!(s.last[1]["at"], "t24");
        assert_eq!(
            s.last[1],
            json!({"at": "t24", "method": "job/stop", "code": "not-allowed", "class": "service"})
        );
    }

    /// A `Forward` that counts its calls.
    struct Spy(AtomicUsize);

    impl Forward for Spy {
        fn call<'a>(&'a self, _: Caller, _: &'static Method, _: Params) -> Answer<'a> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Box::pin(async { Ok(json!(true)) })
        }
    }

    fn front(dir: &std::path::Path, forward: Arc<dyn Forward>) -> Arc<Front> {
        let work_db = crate::store::WorkDb::spawn(dir.join("work.db")).unwrap();
        Arc::new(Front::new(
            Cap::generate().unwrap(),
            dir.join("hub-x.sock"),
            work_db,
            norn::store::CoordDb::spawn(dir.join("work.db")),
            forward,
        ))
    }

    /// A user connection: its hello said proto 1 with a valid proof.
    fn user(front: &Front) -> Session {
        let mut s = Session::new(front.next_conn(), Socket::Main);
        s.class = Class::User;
        s.proto = 1;
        s.hello_done = true;
        s
    }

    #[tokio::test]
    async fn bad_params_never_reach_forward() {
        let dir = tempfile::tempdir().unwrap();
        let spy = Arc::new(Spy(AtomicUsize::new(0)));
        let f = front(dir.path(), spy.clone());
        let mut s = user(&f);
        let out = Arc::new(Outbox::new(s.conn));
        for bad in [
            r#"{"id":1,"method":"job/stop","params":{}}"#,
            r#"{"id":2,"method":"job/stop","params":{"id":5}}"#,
            r#"{"id":3,"method":"job/stop","params":{"id":"a","id":"b"}}"#,
            r#"{"id":4,"method":"agents/start","params":{"profile":"p","cwd":"/ssh:h:/x"}}"#,
            r#"{"id":5,"method":"env/set","params":{"env":[{"name":"PATH","value":"bin"}]}}"#,
            r#"{"id":6,"method":"job/stop","params":[]}"#,
            r#"{"method":"job/stop","params":{}}"#,
        ] {
            f.line(&mut s, &out, bad).await;
        }
        assert_eq!(
            spy.0.load(Ordering::SeqCst),
            0,
            "a bad call reached the backend"
        );
        let answers = out.take_lines();
        assert_eq!(answers.len(), 6, "{answers:?}");
        assert!(
            answers.iter().all(|a| a.contains("\"invalid-params\"")),
            "{answers:?}"
        );
        // the spy counts: a good call is forwarded once (env/set: the backend's last method)
        f.line(
            &mut s,
            &out,
            r#"{"id":9,"method":"env/set","params":{"env":[]}}"#,
        )
        .await;
        assert_eq!(spy.0.load(Ordering::SeqCst), 1);
        assert_eq!(f.status().refusals.map(|r| r.count), Some(7));
    }

    std::thread_local! {
        /// Where the test subscriber writes this thread's log lines, while a test captures them.
        static CAPTURE: std::cell::RefCell<Option<Arc<Mutex<Vec<u8>>>>> = const { std::cell::RefCell::new(None) };
    }

    /// Writes to this thread's [`CAPTURE`], or nowhere.
    struct ThreadLog;

    impl std::io::Write for ThreadLog {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            CAPTURE.with(|c| {
                if let Some(buf) = &*c.borrow() {
                    buf.lock().unwrap().extend_from_slice(b);
                }
            });
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    /// Capture this thread's log lines (TRACE and up, JSON).  The subscriber is the global one, for every test
    /// thread: a subscriber scoped to one thread misses events whose call site another test thread hit first
    /// (tracing caches each call site's interest across threads).
    fn capture_log() -> Arc<Mutex<Vec<u8>>> {
        static INIT: std::sync::Once = std::sync::Once::new();
        INIT.call_once(|| {
            let subscriber = tracing_subscriber::fmt()
                .json()
                .with_max_level(tracing::Level::TRACE)
                .with_writer(|| ThreadLog)
                .finish();
            tracing::subscriber::set_global_default(subscriber)
                .expect("the only global subscriber");
        });
        let buf = Arc::new(Mutex::new(Vec::new()));
        CAPTURE.with(|c| *c.borrow_mut() = Some(buf.clone()));
        buf
    }

    #[tokio::test]
    async fn a_refusal_log_has_no_params() {
        const CANARY: &str = "sk-canary-1f2e3d";
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path(), Arc::new(NoBackend));
        let log = capture_log();
        let out = Arc::new(Outbox::new(1));
        // a service connection: not-allowed
        let mut service = Session::new(f.next_conn(), Socket::Main);
        f.line(
            &mut service,
            &out,
            &format!(r#"{{"id":1,"method":"gateway/keys","params":{{"keys":{{"openrouter":"{CANARY}"}}}}}}"#),
        )
        .await;
        // a user connection: invalid-params whose decode error quotes the value
        let mut u = user(&f);
        f.line(
            &mut u,
            &out,
            &format!(r#"{{"id":2,"method":"gateway/keys","params":{{"keys":"{CANARY}"}}}}"#),
        )
        .await;
        let answers = out.take_lines();
        assert_eq!(answers.len(), 2, "{answers:?}");
        assert!(answers[0].contains("not-allowed"), "{answers:?}");
        // the client gets the message (it sent the value); the log and status never do
        assert!(
            answers[1].contains("invalid-params") && answers[1].contains(CANARY),
            "{answers:?}"
        );
        let logged = String::from_utf8(log.lock().unwrap().clone()).unwrap();
        assert!(
            logged.contains("gateway/keys"),
            "the refusals are logged: {logged}"
        );
        assert!(logged.contains("invalid-params"), "{logged}");
        assert!(
            !logged.contains("canary"),
            "the log has the params: {logged}"
        );
        let status = serde_json::to_string(&f.status()).unwrap();
        assert!(status.contains("\"count\":2"), "{status}");
        assert!(
            !status.contains("canary"),
            "status has the params: {status}"
        );
    }

    /// Review m2 (design §6.2, fail closed): a hub that could not be hardened (on macOS, started under a debugger)
    /// takes no key over `gateway/keys`, says why, and its status says so too; once hardened it takes them.
    #[tokio::test]
    async fn an_unhardened_hub_takes_no_key() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path(), Arc::new(NoBackend));
        let out = Arc::new(Outbox::new(1));
        let mut u = user(&f);
        let keys =
            r#"{"id":1,"method":"gateway/keys","params":{"keys":{"openrouter":"sk-canary-m2"}}}"#;
        f.gate
            .set_hardened(Err("cannot deny debuggers the hub: busy".into()));
        f.line(&mut u, &out, keys).await;
        let answer = out.take_lines().join("\n");
        assert!(
            answer.contains("not-allowed")
                && answer.contains("this hub cannot protect keys: cannot deny debuggers the hub"),
            "{answer}"
        );
        assert!(f.gate.keys_held().providers.is_empty());
        let status = f.gate.status();
        assert_eq!(
            status.keys_refused.as_deref(),
            Some("cannot deny debuggers the hub: busy")
        );
        f.gate.set_hardened(Ok(()));
        f.line(&mut u, &out, keys).await;
        let answer = out.take_lines().join("\n");
        assert!(answer.contains(r#""result":true"#), "{answer}");
        assert_eq!(f.gate.keys_held().providers.len(), 1);
        assert!(f.gate.status().keys_refused.is_none());
    }
}
