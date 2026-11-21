//! The Always ledger of one session (agent system part 3, docs/develop/hub.md "Always grants"): an "Always" is the
//! agent's own rule (the option `allow_always` of a permission request), which the hub cannot read back.  So the hub
//! writes down each one the user gives: a record `always:<session>:<key>` (written as `("hub", Class::System)`) and a
//! row here.  The key names the step: the tool call's kind and a hash of its title.  Taking a grant back marks it
//! revoked; from then on the hub asks again for a matching request, whatever the matrix says, so the user's yes (or
//! Always) has to be given again.  The agent's own rule is out of the hub's reach: no adapter takes one back today, so
//! a revoke says `kept`, and a restart of the session at its current step (a fork, which starts a new agent process
//! with no memory) clears it.

use runstav::methods::agents::{AgentRule, Grant, Revoked};
use serde_json::Value;
use std::sync::{Mutex, MutexGuard};

/// A session's grants, oldest first.
#[derive(Default)]
pub struct Ledger {
    rows: Mutex<Vec<Grant>>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// FNV-1a of TEXT in hex: a short, stable name for a title.
fn hash(text: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in text.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{h:016x}")
}

/// The kind, key and title of a tool call as a grant names it: the kind (`other` when it has none) and the hash of its
/// title, else of its command.
pub fn key_of(tool: Option<&Value>) -> (String, String, Option<String>) {
    let kind = tool
        .and_then(|t| t.get("kind"))
        .and_then(Value::as_str)
        .filter(|k| !k.is_empty())
        .unwrap_or("other")
        .to_owned();
    let title = tool
        .and_then(|t| {
            t.get("title")
                .or_else(|| t.pointer("/rawInput/command"))
                .and_then(Value::as_str)
        })
        .map(str::to_owned);
    let key = format!("{kind}-{}", hash(title.as_deref().unwrap_or("")));
    (kind, key, title)
}

impl Ledger {
    /// The user gave SESSION an Always on a request for TOOL (answered on CARD) at AT: the grant, new, or the earlier
    /// one for the same key given again (no longer revoked).
    pub fn record(&self, session: &str, tool: Option<&Value>, card: Option<i64>, at: f64) -> Grant {
        let (kind, key, title) = key_of(tool);
        let id = format!("always:{session}:{key}");
        let mut rows = lock(&self.rows);
        if let Some(g) = rows.iter_mut().find(|g| g.id == id) {
            g.revoked = false;
            g.at = at;
            g.card = card.or(g.card);
            return g.clone();
        }
        let g = Grant {
            id,
            session: session.to_owned(),
            tool: kind,
            key,
            title,
            card,
            at,
            revoked: false,
        };
        rows.push(g.clone());
        g
    }

    /// Every grant, revoked ones too, oldest first.
    pub fn list(&self) -> Vec<Grant> {
        lock(&self.rows).clone()
    }

    /// Take grant ID back: the revoked grant and what is left of the agent's rule; an error (its reason) when the
    /// session has no such grant, or it was revoked already.  RESTART: whether the session has a step to restart at.
    pub fn revoke(&self, id: &str, restart: bool) -> Result<(Grant, Revoked), String> {
        let mut rows = lock(&self.rows);
        let g = rows
            .iter_mut()
            .find(|g| g.id == id)
            .ok_or_else(|| format!("this session has no grant {id}"))?;
        if g.revoked {
            return Err(format!("grant {id} is revoked already"));
        }
        g.revoked = true;
        let out = Revoked {
            grant: id.to_owned(),
            agent_rule: AgentRule::Kept,
            restart,
        };
        Ok((g.clone(), out))
    }

    /// Whether a revoked grant covers TOOL: the hub then asks, whatever the matrix says.
    pub fn revoked_covers(&self, tool: Option<&Value>) -> bool {
        let (_, key, _) = key_of(tool);
        lock(&self.rows).iter().any(|g| g.revoked && g.key == key)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tool(kind: &str, title: &str) -> Value {
        json!({"kind": kind, "title": title})
    }

    #[test]
    fn a_grant_names_the_kind_and_the_title() {
        let l = Ledger::default();
        let g = l.record("s1", Some(&tool("edit", "Edit a.rs")), Some(7), 10.0);
        assert!(g.id.starts_with("always:s1:edit-"));
        assert_eq!(
            (g.tool.as_str(), g.card, g.revoked),
            ("edit", Some(7), false)
        );
        // the same step again is the same grant; another title is another
        let again = l.record("s1", Some(&tool("edit", "Edit a.rs")), None, 11.0);
        assert_eq!(
            (again.id.as_str(), again.card, again.at),
            (g.id.as_str(), Some(7), 11.0)
        );
        l.record("s1", Some(&tool("edit", "Edit b.rs")), None, 12.0);
        assert_eq!(l.list().len(), 2);
    }

    #[test]
    fn revoking_asks_again_for_a_matching_step_only() {
        let l = Ledger::default();
        let t = tool("execute", "cargo test");
        let g = l.record("s1", Some(&t), None, 1.0);
        assert!(!l.revoked_covers(Some(&t)));
        let (done, out) = l.revoke(&g.id, true).unwrap();
        assert!(done.revoked);
        assert_eq!((out.agent_rule, out.restart), (AgentRule::Kept, true));
        assert!(l.revoked_covers(Some(&t)));
        assert!(!l.revoked_covers(Some(&tool("execute", "cargo build"))));
        // taken back twice, or never given, is a refusal with its reason
        assert!(
            l.revoke(&g.id, true)
                .unwrap_err()
                .contains("revoked already")
        );
        assert!(
            l.revoke("always:s1:none", true)
                .unwrap_err()
                .contains("no grant")
        );
        // giving it again lifts the revoke
        l.record("s1", Some(&t), None, 2.0);
        assert!(!l.revoked_covers(Some(&t)));
    }
}
