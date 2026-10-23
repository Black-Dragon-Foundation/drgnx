//! Who an agent is: from the socket or the peer process, never an argument (Task 7; design §5.8, K3).
//!
//! A session's `mcp.sock` is its identity (Task 10 builds [`Identity::Session`] from the session that socket was
//! minted for); an outside bridge is `ext:KIND:PID-HASH`, computed by the hub from the bridge's peer process
//! ([`Identity::outside`]).  `DRGNX_AGENT` is never read here.  The rules are `core/drgnx-coord-mcp.el`'s
//! (`drgnx-coord-mcp--identity`, `--own`, `--not-outside`).

use std::path::{Path, PathBuf};

use sha1::{Digest, Sha1};

use super::Identity;

/// Whether ID is a plain agent id (`drgnx-coord-mcp--id-regexp`): ASCII letters, digits and `. _ : -`, not starting
/// with one of those four, at most 64 characters.  A newline or `]` would break out of the hub's header, a lookalike
/// of `user` would read as the user.
pub fn plain_id(id: &str) -> bool {
    let b = id.as_bytes();
    (1..=64).contains(&b.len())
        && b[0].is_ascii_alphanumeric()
        && b.iter()
            .all(|&c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b':' | b'-'))
}

/// Whether KIND is an outside agent's kind (`drgnx-coord-mcp--valid-kind`): a short lower-case name, `[a-z0-9]`
/// then up to 31 of `[a-z0-9_-]`.
pub fn valid_kind(kind: &str) -> bool {
    let b = kind.as_bytes();
    (1..=32).contains(&b.len())
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter()
            .all(|&c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, b'_' | b'-'))
}

/// The first 6 hex digits of sha1 over START (a process's start time, seconds since the epoch) rounded to the
/// second (`drgnx-coord-mcp--start-hash`: Lisp's `round` takes a tie to the even integer).
pub fn start_hash(start: f64) -> String {
    let secs = start.round_ties_even() as i64;
    Sha1::digest(secs.to_string().as_bytes())
        .iter()
        .take(3)
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The `hello` note of an identity that is its pid alone (`drgnx-coord-mcp--parent`'s fallback).
const PID_ALONE: &str = "the agent's start time could not be read: this identity is its pid alone, which another process may get later";

impl Identity {
    /// An outside bridge's identity (call 8): `ext:KIND:PID-HASH`, PID the agent's process (the bridge's parent),
    /// HASH [`start_hash`] of its start time; `ext:KIND:PID` when the start time cannot be read.  KIND must be
    /// [`valid_kind`].  HOME is the folder the bridge started in (its `hello`'s `cwd`).
    pub fn outside(
        kind: &str,
        pid: u32,
        start: Option<f64>,
        home: Option<PathBuf>,
    ) -> Result<Identity, String> {
        if !valid_kind(kind) {
            return Err(format!(
                "An agent kind is a short lower-case name (claude, codex, zed…), not {kind:?}"
            ));
        }
        let tag = match start {
            Some(s) => format!("{pid}-{}", start_hash(s)),
            None => pid.to_string(),
        };
        Ok(Identity::Outside {
            id: format!("ext:{kind}:{tag}"),
            kind: kind.to_owned(),
            home,
        })
    }

    /// The check every call starts with (`drgnx-coord-mcp--guard` calls `--identity`): an identity that is the user
    /// ("user" in any case, spaces around it ignored) or not a plain id refuses every tool.
    pub fn check(&self) -> Result<(), String> {
        let Some(id) = self.id() else { return Ok(()) };
        if id.trim().eq_ignore_ascii_case("user") {
            return Err(format!(
                "\"user\" is the user: no agent speaks as the user (the agent's id is {id})"
            ));
        }
        if !plain_id(id) {
            return Err(format!(
                "The agent's id is not a plain id (letters, digits and . _ : - only, at most 64): {id:?}"
            ));
        }
        if let Identity::Outside { kind, .. } = self
            && !valid_kind(kind)
        {
            return Err(format!(
                "An agent kind is a short lower-case name (claude, codex, zed…), not {kind:?}"
            ));
        }
        Ok(())
    }

    /// The caller's id, or `None` for a caller that only reads.
    pub fn id(&self) -> Option<&str> {
        match self {
            Identity::Session { agent, .. } => Some(agent),
            Identity::Outside { id, .. } => Some(id),
            Identity::None => None,
        }
    }

    /// The caller's id for a write (`drgnx-coord-mcp--me`), checked; an error for a caller with no identity.
    pub fn me(&self) -> Result<&str, String> {
        self.check()?;
        self.id().ok_or_else(|| {
            "This server has no agent identity (DRGNX_AGENT, or DRGNX_AGENT_KIND for an agent outside drgnx): it can only read"
                .to_string()
        })
    }

    /// The session's job: drgnx's own agents only, never an outside one's (`drgnx-coord-mcp--own "DRGNX_JOB"`).
    pub fn job(&self) -> Option<&str> {
        match self {
            Identity::Session { job, .. } => job.as_deref(),
            _ => None,
        }
    }

    /// The session's task, as [`Identity::job`] (`drgnx-coord-mcp--own "DRGNX_TASK"`).
    pub fn task(&self) -> Option<&str> {
        match self {
            Identity::Session { task, .. } => task.as_deref(),
            _ => None,
        }
    }

    /// The kind of an agent outside drgnx (`drgnx-coord-mcp--outside-kind`), else `None`.
    pub fn outside_kind(&self) -> Option<&str> {
        match self {
            Identity::Outside { kind, .. } => Some(kind),
            _ => None,
        }
    }

    /// The folder the agent started in (the Lisp server's `default-directory`), when known.
    pub fn home(&self) -> Option<&Path> {
        match self {
            Identity::Session { home, .. } => Some(home),
            Identity::Outside { home, .. } => home.as_deref(),
            Identity::None => None,
        }
    }

    /// An error for an outside agent: WHAT (a job's task, a decision) is drgnx's (`drgnx-coord-mcp--not-outside`).
    pub fn not_outside(&self, what: &str) -> Result<(), String> {
        match self {
            Identity::Outside { .. } => Err(format!(
                "jobs are drgnx's: report your work with report_edit ({what} is for drgnx's own job agents)"
            )),
            _ => Ok(()),
        }
    }

    /// An outside agent's process id, from its identity's tag (`hello` registers it as the agent's `pid`).
    pub fn pid(&self) -> Option<i64> {
        let Identity::Outside { id, kind, .. } = self else {
            return None;
        };
        let tag = id.strip_prefix(&format!("ext:{kind}:"))?;
        tag.split('-').next()?.parse().ok()
    }

    /// `hello`'s note for an outside identity that is its pid alone, else `None`.
    pub(crate) fn note(&self) -> Option<&'static str> {
        match self {
            Identity::Outside { id, kind, .. } => id
                .strip_prefix(&format!("ext:{kind}:"))
                .filter(|tag| !tag.contains('-'))
                .map(|_| PID_ALONE),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(agent: &str) -> Identity {
        Identity::Session {
            agent: agent.into(),
            job: Some("j".into()),
            task: Some("j#1".into()),
            home: PathBuf::from("/w"),
        }
    }

    #[test]
    fn ids_and_kinds_follow_the_lisp_rules() {
        assert!(plain_id("s-0123abcd"));
        assert!(plain_id("ext:claude:42-abcdef"));
        assert!(plain_id(&"a".repeat(64)));
        assert!(!plain_id(&"a".repeat(65)));
        assert!(!plain_id(""));
        assert!(!plain_id("-x"));
        assert!(!plain_id("a]b"));
        assert!(!plain_id("a\nb"));
        assert!(!plain_id("u\u{a0}ser"));
        assert!(valid_kind("claude") && valid_kind("gry-worker_2"));
        assert!(
            !valid_kind("Claude")
                && !valid_kind("-x")
                && !valid_kind("")
                && !valid_kind(&"a".repeat(33))
        );
    }

    #[test]
    fn an_outside_identity_is_kind_pid_and_start_hash() {
        let who = Identity::outside("codex", 4242, Some(1_700_000_000.4), None).unwrap();
        let hash = start_hash(1_700_000_000.0);
        assert_eq!(hash.len(), 6);
        assert_eq!(who.id(), Some(format!("ext:codex:4242-{hash}").as_str()));
        assert_eq!(who.pid(), Some(4242));
        assert_eq!(who.note(), None);
        assert_eq!(who.job(), None, "an outside agent never has a job");
        let alone = Identity::outside("codex", 7, None, None).unwrap();
        assert_eq!(alone.id(), Some("ext:codex:7"));
        assert_eq!(alone.note(), Some(PID_ALONE));
        assert!(Identity::outside("Codex", 7, None, None).is_err());
        // a tie goes to the even second, as Lisp's `round`
        assert_eq!(start_hash(2.5), start_hash(2.0));
        assert_eq!(start_hash(3.5), start_hash(4.0));
    }

    #[test]
    fn the_user_is_never_an_identity() {
        for id in ["user", "User", " USER ", "uSeR"] {
            let e = session(id).me().unwrap_err();
            assert!(e.starts_with("\"user\" is the user"), "{id}: {e}");
        }
        assert!(session("a]b").check().is_err());
        assert_eq!(session("s-1").me(), Ok("s-1"));
        assert!(
            Identity::None
                .me()
                .unwrap_err()
                .contains("no agent identity")
        );
        assert_eq!(Identity::None.check(), Ok(()));
    }

    #[test]
    fn only_outside_agents_are_refused_the_job_tools() {
        let out = Identity::outside("zed", 9, Some(1.0), None).unwrap();
        assert_eq!(
            out.not_outside("claim_task").unwrap_err(),
            "jobs are drgnx's: report your work with report_edit (claim_task is for drgnx's own job agents)"
        );
        assert_eq!(session("s-1").not_outside("claim_task"), Ok(()));
        assert_eq!(Identity::None.not_outside("claim_task"), Ok(()));
    }
}
