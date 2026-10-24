//! `hello` v1 (design 4.2, 4.4; SB-T12-6): the hub challenges first, the client proves it read the cap with an HMAC
//! over both nonces, and only then does the hub prove itself.  A hello line is worth nothing on another connection:
//! that connection's challenge differs.
//!
//! - A valid proof makes a main-socket connection `user`; on an agent socket the class stays `agent` whatever the
//!   proof.  The reply then carries the hub's proof.
//! - A wrong proof is `not-allowed` (logged and counted), and the class does not change.
//! - No proof leaves the class as it is.
//! - At most one hello reaches this per connection: a second one is `proto`, whatever it holds.

use crate::dispatch::Caller;
use runstav::methods::hub::{HelloParams, HelloReply, Runtime};
use runstav::proof::{self, Cap};
use runstav::registry::{self, Class};
use runstav::wire::{Error, ErrorCode};
use std::path::PathBuf;

/// Which socket a connection came in on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Socket {
    /// `hub-HASH.sock`: `service` until a valid hello makes it `user`.
    Main,
    /// A session's own socket (`--agent-socket SID[:JOB]`): `agent`, bound to that session and job.
    Agent { sid: String, job: Option<String> },
}

/// One connection's state.
pub struct Session {
    pub conn: u64,
    pub socket: Socket,
    pub class: Class,
    /// This connection's challenge: the nonce the client's proof must cover.
    pub hub_nonce: String,
    /// The protocol the hello said (0 before one).
    pub proto: u32,
    /// A hello has been answered here.
    pub hello_done: bool,
    /// The peer's pid (`SO_PEERCRED`), when the system gives it: the front compares it with the backend's.
    pub peer_pid: Option<i32>,
    /// The folder the hello said the client started in (`cwd`): an outside agent's home for `mcp/attach`.
    pub cwd: Option<PathBuf>,
    /// Set by `mcp/attach` once answered: the connection carries MCP from its next byte, as this identity.
    pub attach: Option<norn::tools::Identity>,
}

impl Session {
    pub fn new(conn: u64, socket: Socket) -> Session {
        let class = match socket {
            Socket::Main => Class::Service,
            Socket::Agent { .. } => Class::Agent,
        };
        Session {
            conn,
            socket,
            class,
            hub_nonce: String::new(),
            proto: 0,
            hello_done: false,
            peer_pid: None,
            cwd: None,
            attach: None,
        }
    }

    /// The caller this connection is; [`Caller::backend`] is the front's to set (it knows the backend's pid).
    pub fn caller(&self) -> Caller {
        let (sid, job) = match &self.socket {
            Socket::Main => (None, None),
            Socket::Agent { sid, job } => (Some(sid.clone()), job.clone()),
        };
        Caller {
            class: self.class,
            sid,
            job,
            conn_id: self.conn,
            backend: false,
        }
    }
}

/// `hello` P on session S, with the hub's CAP, while work.db's schema is SCHEMA (0 without one): the reply, after
/// which S has its class and protocol.
pub fn hello(
    s: &mut Session,
    cap: &Cap,
    p: &HelloParams,
    schema: u32,
) -> Result<HelloReply, Error> {
    if s.hello_done {
        return Err(Error {
            code: ErrorCode::Proto,
            message: "hello was already answered on this connection".into(),
            path: None,
        });
    }
    s.hello_done = true;
    s.proto = u32::try_from(p.proto).unwrap_or(u32::MAX);
    s.cwd = p.cwd.as_ref().map(|c| PathBuf::from(c.as_str()));
    let mut hub_proof = None;
    if let Some(given) = &p.proof {
        let want = proof::client_proof(cap, &s.hub_nonce, p.nonce.as_str());
        if !proof::verify(&want, given.as_str()) {
            tracing::warn!(
                conn = s.conn,
                class = s.class.name(),
                "refused a hello with a wrong proof"
            );
            return Err(Error {
                code: ErrorCode::NotAllowed,
                message: "hello: the proof does not match this hub's cap and challenge".into(),
                path: None,
            });
        }
        if s.socket == Socket::Main {
            s.class = Class::User;
        }
        hub_proof = Some(proof::hub_proof(cap, p.nonce.as_str(), &s.hub_nonce));
    }
    Ok(HelloReply {
        proto: u64::from(registry::PROTO),
        proto_min: u64::from(registry::PROTO_MIN),
        drgnx_version: Some(crate::version::COMMIT.into()),
        schema: Some(u64::from(schema)),
        records: Some(u64::from(registry::RECORDS)),
        class: Some(s.class),
        methods: registry::registry()
            .iter()
            .map(|m| m.name.to_string())
            .collect(),
        runtime: Some(Runtime {
            version: env!("CARGO_PKG_VERSION").into(),
            commit: crate::version::COMMIT.into(),
        }),
        proof: hub_proof,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use runstav::types::{Hex64, Nonce};

    fn params(proof: Option<String>, proto: u64) -> (HelloParams, String) {
        let nonce = proof::nonce().unwrap();
        let p = HelloParams {
            proto,
            nonce: Nonce::new(nonce.clone()).unwrap(),
            drgnx_version: None,
            schema: None,
            records: None,
            client: None,
            proof: proof.map(|x| Hex64::new(x).unwrap()),
            cwd: None,
        };
        (p, nonce)
    }

    fn session(socket: Socket) -> Session {
        let mut s = Session::new(1, socket);
        s.hub_nonce = proof::nonce().unwrap();
        s
    }

    /// A hello whose proof is right for S.
    fn valid(s: &Session, cap: &Cap) -> (HelloParams, String) {
        let nonce = proof::nonce().unwrap();
        let (mut p, _) = params(None, 1);
        p.nonce = Nonce::new(nonce.clone()).unwrap();
        p.proof = Some(Hex64::new(proof::client_proof(cap, &s.hub_nonce, &nonce)).unwrap());
        (p, nonce)
    }

    #[test]
    fn a_valid_proof_makes_user_and_the_hub_proves_itself() {
        let cap = Cap::generate().unwrap();
        let mut s = session(Socket::Main);
        let (p, nonce) = valid(&s, &cap);
        let r = hello(&mut s, &cap, &p, 6).unwrap();
        assert_eq!(s.class, Class::User);
        assert_eq!((s.proto, s.hello_done), (1, true));
        assert_eq!(r.class, Some(Class::User));
        assert_eq!(r.proof, Some(proof::hub_proof(&cap, &nonce, &s.hub_nonce)));
        assert_eq!((r.proto, r.proto_min), (1, 1));
        assert_eq!((r.schema, r.records), (Some(6), Some(2)));
        assert_eq!(r.drgnx_version.as_deref(), Some(crate::version::COMMIT));
        assert_eq!(
            r.runtime,
            Some(Runtime {
                version: env!("CARGO_PKG_VERSION").into(),
                commit: crate::version::COMMIT.into()
            })
        );
        assert_eq!(r.methods.len(), registry::registry().len());
        // the reply is what the registry says hello returns
        let v = serde_json::to_value(&r).unwrap();
        assert_eq!(
            (registry::find("hello").unwrap().check_result)(&v).unwrap(),
            v
        );
    }

    #[test]
    fn a_proof_for_another_challenge_or_cap_is_refused_and_changes_nothing() {
        let cap = Cap::generate().unwrap();
        // another connection's proof: its challenge differs
        let other = session(Socket::Main);
        let (p, _) = valid(&other, &cap);
        let mut s = session(Socket::Main);
        let e = hello(&mut s, &cap, &p, 0).unwrap_err();
        assert_eq!(e.code, ErrorCode::NotAllowed);
        assert_eq!(s.class, Class::Service);
        // another cap's proof
        let mut s = session(Socket::Main);
        let (p, _) = valid(&s, &Cap::generate().unwrap());
        assert_eq!(
            hello(&mut s, &cap, &p, 0).unwrap_err().code,
            ErrorCode::NotAllowed
        );
        assert_eq!(s.class, Class::Service);
    }

    #[test]
    fn no_proof_leaves_the_class_and_an_agent_socket_stays_agent() {
        let cap = Cap::generate().unwrap();
        let mut s = session(Socket::Main);
        let r = hello(&mut s, &cap, &params(None, 1).0, 0).unwrap();
        assert_eq!(
            (s.class, r.class, r.proof),
            (Class::Service, Some(Class::Service), None)
        );
        let agent = Socket::Agent {
            sid: "s1".into(),
            job: Some("j1".into()),
        };
        let mut s = session(agent.clone());
        let (p, _) = valid(&s, &cap);
        let r = hello(&mut s, &cap, &p, 0).unwrap();
        assert_eq!((s.class, r.class), (Class::Agent, Some(Class::Agent)));
        let c = s.caller();
        assert_eq!(
            (c.sid.as_deref(), c.job.as_deref()),
            (Some("s1"), Some("j1"))
        );
        let mut s = session(agent);
        hello(&mut s, &cap, &params(None, 1).0, 0).unwrap();
        assert_eq!(s.class, Class::Agent);
    }

    #[test]
    fn a_second_hello_is_proto_and_changes_nothing() {
        let cap = Cap::generate().unwrap();
        let mut s = session(Socket::Main);
        let (p, _) = valid(&s, &cap);
        hello(&mut s, &cap, &p, 0).unwrap();
        let (again, _) = valid(&s, &cap);
        let e = hello(&mut s, &cap, &again, 0).unwrap_err();
        assert_eq!(e.code, ErrorCode::Proto);
        assert_eq!(e.message, "hello was already answered on this connection");
        assert_eq!((s.class, s.proto), (Class::User, 1));
        // a wrong proof counts as the one hello too
        let mut s = session(Socket::Main);
        let (p, _) = params(Some("0".repeat(64)), 1);
        assert_eq!(
            hello(&mut s, &cap, &p, 0).unwrap_err().code,
            ErrorCode::NotAllowed
        );
        let (p, _) = valid(&s, &cap);
        assert_eq!(
            hello(&mut s, &cap, &p, 0).unwrap_err().code,
            ErrorCode::Proto
        );
        assert_eq!(s.class, Class::Service);
    }

    #[test]
    fn the_protocol_said_is_kept() {
        let cap = Cap::generate().unwrap();
        let mut s = session(Socket::Main);
        let (mut p, _) = valid(&s, &cap);
        p.proto = 7;
        hello(&mut s, &cap, &p, 0).unwrap();
        assert_eq!((s.class, s.proto), (Class::User, 7));
        let mut s = session(Socket::Main);
        let (mut p, _) = params(None, 1);
        p.proto = u64::MAX;
        hello(&mut s, &cap, &p, 0).unwrap();
        assert_eq!(s.proto, u32::MAX);
    }
}
