//! The editor as the agents' settings tools reach it (unified-settings Task 32; design §13; docs/develop/hub.md,
//! "Agents change settings"): the subscribed connections (each a user's), the
//! `settings/proposed` and `settings/explain` events to them, and the answers a tool waits for (`settings/confirm`,
//! `settings/explained`). No subscriber: no editor.

use std::collections::{BTreeMap, HashMap};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use norn::tools::EditorAnswer;
use runstav::methods::settings::{Explain, Proposed, SettingScope};
use serde_json::{Value, json};
use tokio::sync::oneshot;

use crate::conn::Outbox;

/// The subscribers and the answers waited for.
#[derive(Default)]
pub struct Editors {
    subscribers: Mutex<BTreeMap<u64, Arc<Outbox>>>,
    /// Session id → the connections that asked for its `agent-entries`.
    entry_subs: Mutex<HashMap<String, std::collections::BTreeSet<u64>>>,
    /// Connection → the pace of the snapshots it gets for sessions it does not show.
    pacers: Mutex<HashMap<u64, crate::agents::wire::Pacer>>,
    confirms: Mutex<HashMap<i64, oneshot::Sender<EditorAnswer>>>,
    explains: Mutex<HashMap<u64, oneshot::Sender<Vec<Value>>>>,
    next: AtomicU64,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl Editors {
    /// Connection CONN gets the events from now on.
    pub fn subscribe(&self, conn: u64, out: Arc<Outbox>) {
        lock(&self.subscribers).insert(conn, out);
    }

    /// Connection CONN is gone.
    pub fn gone(&self, conn: u64) {
        lock(&self.subscribers).remove(&conn);
        lock(&self.pacers).remove(&conn);
        lock(&self.entry_subs).retain(|_, set| {
            set.remove(&conn);
            !set.is_empty()
        });
    }

    /// EVENT with DATA to every subscriber: queued for each before any is written (a queue never waits), so a newer
    /// event never reaches one subscriber before an older one. A closed connection is dropped.
    pub fn broadcast(&self, event: &str, data: Value) {
        let Some(line) = crate::front::event_line(event, data) else {
            return;
        };
        lock(&self.subscribers).retain(|_, out| out.push(line.clone()));
    }

    /// EVENT with DATA to connection CONN only; false when it is not subscribed or its connection is closed.
    pub fn send_to(&self, conn: u64, event: &str, data: Value) -> bool {
        let Some(line) = crate::front::event_line(event, data) else {
            return false;
        };
        let mut subs = lock(&self.subscribers);
        let Some(out) = subs.get(&conn) else {
            return false;
        };
        if out.push(line) {
            return true;
        }
        subs.remove(&conn);
        false
    }

    /// Session SID's snapshot DATA (`agent`) to every subscriber.  A connection that shows the session (it asked for
    /// its entries) gets it at once; any other gets at most [`SNAPSHOTS_PER_WINDOW`] a window of the sessions it does
    /// not show, the latest state of each when the window opens (on the hub's clock).
    pub fn broadcast_agent(self: &Arc<Self>, sid: &str, data: Value) {
        let Some(line) = crate::front::event_line("agent", data) else {
            return;
        };
        let shown = lock(&self.entry_subs).get(sid).cloned().unwrap_or_default();
        let conns: Vec<(u64, Arc<Outbox>)> = lock(&self.subscribers)
            .iter()
            .map(|(c, o)| (*c, o.clone()))
            .collect();
        let now = crate::clock::now();
        let mut closed = Vec::new();
        for (conn, out) in conns {
            let (send, arm) = if shown.contains(&conn) {
                if let Some(p) = lock(&self.pacers).get_mut(&conn) {
                    p.forget(sid);
                }
                (Some(line.clone()), None)
            } else {
                let o = lock(&self.pacers)
                    .entry(conn)
                    .or_default()
                    .offer(now, sid, line.clone());
                (o.send, o.arm)
            };
            if send.is_some_and(|l| !out.push(l)) {
                closed.push(conn);
            }
            if let Some(after) = arm {
                self.arm_snapshots(conn, after);
            }
        }
        if !closed.is_empty() {
            lock(&self.subscribers).retain(|c, _| !closed.contains(c));
        }
    }

    /// Call [`Editors::flush_snapshots`] for CONN after AFTER on the hub's clock.
    fn arm_snapshots(self: &Arc<Self>, conn: u64, after: Duration) {
        let me = self.clone();
        crate::clock::spawn("editors:snapshots", async move {
            crate::clock::sleep(after).await;
            me.flush_snapshots(conn);
        });
    }

    fn flush_snapshots(self: &Arc<Self>, conn: u64) {
        let Some(out) = lock(&self.subscribers).get(&conn).cloned() else {
            lock(&self.pacers).remove(&conn);
            return;
        };
        let (lines, again) = match lock(&self.pacers).get_mut(&conn) {
            Some(p) => p.flush(crate::clock::now()),
            None => return,
        };
        for l in lines {
            if !out.push(l) {
                lock(&self.subscribers).remove(&conn);
                return;
            }
        }
        if let Some(after) = again {
            self.arm_snapshots(conn, after);
        }
    }

    /// Connection CONN gets session SID's `agent-entries` from now on.
    pub fn subscribe_entries(&self, sid: &str, conn: u64) {
        lock(&self.entry_subs)
            .entry(sid.to_string())
            .or_default()
            .insert(conn);
        if let Some(p) = lock(&self.pacers).get_mut(&conn) {
            p.forget(sid);
        }
    }

    /// Connection CONN no longer gets session SID's `agent-entries`.
    pub fn unsubscribe_entries(&self, sid: &str, conn: u64) {
        let mut subs = lock(&self.entry_subs);
        if let Some(set) = subs.get_mut(sid) {
            set.remove(&conn);
            if set.is_empty() {
                subs.remove(sid);
            }
        }
    }

    /// The connections that get session SID's `agent-entries`.
    pub fn entry_subscribers(&self, sid: &str) -> Vec<u64> {
        lock(&self.entry_subs)
            .get(sid)
            .map(|s| s.iter().copied().collect())
            .unwrap_or_default()
    }

    /// EVENT with DATA to one subscriber, the first (the oldest connection): a change is written by one editor, not
    /// by each open one. A closed connection is dropped and the next one tried; false when none took it.
    fn send_one(&self, event: &str, data: Value) -> bool {
        let Some(line) = crate::front::event_line(event, data) else {
            return false;
        };
        let mut subs = lock(&self.subscribers);
        while let Some((&conn, out)) = subs.iter().next() {
            if out.push(line.clone()) {
                return true;
            }
            subs.remove(&conn);
        }
        false
    }

    /// The oldest editor connection, if any.
    pub fn first(&self) -> Option<u64> {
        lock(&self.subscribers).keys().next().copied()
    }

    /// Whether an editor is connected.
    pub fn present(&self) -> bool {
        !lock(&self.subscribers).is_empty()
    }

    /// `settings/proposed` P to one editor (the first subscribed), and its `settings/confirm` waited for at most WAIT;
    /// unconfirmed in time, the change stays pending.
    pub async fn propose(&self, p: Proposed, wait: Duration) -> EditorAnswer {
        if !self.present() {
            return EditorAnswer::NoEditor;
        }
        let tx = p.tx;
        // waited for before it is sent, so an answer never comes before its waiter
        let rx = (!wait.is_zero()).then(|| {
            let (s, r) = oneshot::channel();
            lock(&self.confirms).insert(tx, s);
            r
        });
        if !self.send_one("settings/proposed", json!(p)) {
            lock(&self.confirms).remove(&tx);
            return EditorAnswer::NoEditor;
        }
        let Some(rx) = rx else {
            return EditorAnswer::Sent;
        };
        let got = crate::clock::timeout(wait, rx).await;
        lock(&self.confirms).remove(&tx);
        match got {
            Ok(Ok(a)) => a,
            _ => EditorAnswer::Sent,
        }
    }

    /// The editor's `settings/confirm` of TX: to the tool waiting for it, if one is.
    pub fn confirmed(&self, tx: i64, ok: bool, error: Option<String>) {
        if let Some(s) = lock(&self.confirms).remove(&tx) {
            let _ = s.send(EditorAnswer::Confirmed { ok, error });
        }
    }

    /// `settings/explain` to the editors, and the first `settings/explained` waited for at most WAIT; `None` with no
    /// editor or no answer in time.
    pub async fn explain(
        &self,
        scope: SettingScope,
        names: Option<Vec<String>>,
        root: Option<String>,
        wait: Duration,
    ) -> Option<Vec<Value>> {
        if !self.present() {
            return None;
        }
        let req = self.next.fetch_add(1, Ordering::Relaxed) + 1;
        let (s, rx) = oneshot::channel();
        lock(&self.explains).insert(req, s);
        self.broadcast(
            "settings/explain",
            json!(Explain {
                req,
                scope,
                names,
                root
            }),
        );
        let got = crate::clock::timeout(wait, rx).await;
        lock(&self.explains).remove(&req);
        got.ok()?.ok()
    }

    /// The editor's `settings/explained` for REQ: true when a tool was waiting for it.
    pub fn explained(&self, req: u64, rows: Vec<Value>) -> bool {
        match lock(&self.explains).remove(&req) {
            Some(s) => s.send(rows).is_ok(),
            None => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn proposed(tx: i64) -> Proposed {
        Proposed {
            tx,
            scope: SettingScope::Global,
            name: "fill-column".into(),
            value: "80".into(),
            root: None,
            agent: "agent:s1".into(),
            reason: "r".into(),
        }
    }

    fn lines(out: &Outbox) -> Vec<Value> {
        out.take_lines()
            .iter()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    mod wire {
        use super::*;

        /// [D] A targeted send reaches the one connection, not the others; an unknown or gone one takes nothing.
        #[test]
        fn send_to_reaches_one_connection() {
            let e = Editors::default();
            let (a, b) = (Arc::new(Outbox::new(1)), Arc::new(Outbox::new(2)));
            e.subscribe(1, a.clone());
            e.subscribe(2, b.clone());
            assert!(e.send_to(2, "agent-entries", json!({"id": "s1"})));
            assert!(lines(&a).is_empty());
            let got = lines(&b);
            assert_eq!(got.len(), 1);
            assert_eq!(got[0]["event"], "agent-entries");
            assert!(!e.send_to(9, "agent-entries", json!({})));
            e.gone(2);
            assert!(!e.send_to(2, "agent-entries", json!({})));
        }
    }

    #[tokio::test]
    async fn no_subscriber_is_no_editor() {
        let e = Editors::default();
        assert_eq!(
            e.propose(proposed(1), Duration::from_secs(5)).await,
            EditorAnswer::NoEditor
        );
        assert_eq!(
            e.explain(SettingScope::Global, None, None, Duration::from_secs(5))
                .await,
            None
        );
        assert!(!e.explained(1, vec![]));
    }

    #[tokio::test]
    async fn a_confirm_reaches_the_waiting_tool() {
        let e = Arc::new(Editors::default());
        let out = Arc::new(Outbox::new(7));
        e.subscribe(7, out.clone());
        assert!(e.present());
        let waiting = {
            let e = e.clone();
            tokio::spawn(async move { e.propose(proposed(5), Duration::from_secs(10)).await })
        };
        // the event goes out first: on this single-threaded runtime the spawned `propose` runs as soon as this task
        // yields, and it sends the event before its first wait (the answer's)
        tokio::task::yield_now().await;
        let sent = lines(&out);
        assert_eq!(sent[0]["event"], "settings/proposed");
        assert_eq!(sent[0]["data"]["tx"], 5);
        e.confirmed(4, true, None); // another tx's: nobody waits for it
        e.confirmed(5, false, Some("not an integer".into()));
        assert_eq!(
            waiting.await.unwrap(),
            EditorAnswer::Confirmed {
                ok: false,
                error: Some("not an integer".into())
            }
        );
        // no wait: sent, nothing waits
        assert_eq!(
            e.propose(proposed(6), Duration::ZERO).await,
            EditorAnswer::Sent
        );
        assert!(lock(&e.confirms).is_empty());
        // no answer in time: sent, the waiter gone
        assert_eq!(
            e.propose(proposed(8), Duration::from_millis(20)).await,
            EditorAnswer::Sent
        );
        assert!(lock(&e.confirms).is_empty());
        e.gone(7);
        assert!(!e.present());
    }

    #[tokio::test]
    async fn a_proposal_goes_to_one_editor() {
        let e = Editors::default();
        let (a, b) = (Arc::new(Outbox::new(1)), Arc::new(Outbox::new(2)));
        e.subscribe(2, b.clone());
        e.subscribe(1, a.clone());
        assert_eq!(
            e.propose(proposed(9), Duration::ZERO).await,
            EditorAnswer::Sent
        );
        assert_eq!(lines(&a).len(), 1);
        assert!(lines(&b).is_empty());
    }

    #[tokio::test]
    async fn an_explain_answer_reaches_the_waiting_tool() {
        let e = Arc::new(Editors::default());
        let out = Arc::new(Outbox::new(3));
        e.subscribe(3, out.clone());
        let waiting = {
            let e = e.clone();
            tokio::spawn(async move {
                e.explain(
                    SettingScope::Shared,
                    Some(vec!["tab-width".into()]),
                    Some("/w/a".into()),
                    Duration::from_secs(10),
                )
                .await
            })
        };
        // as above: the request goes out before the spawned `explain` first waits
        tokio::task::yield_now().await;
        let sent = lines(&out);
        assert_eq!(sent[0]["event"], "settings/explain");
        assert_eq!(
            sent[0]["data"],
            json!({"req": 1, "scope": "shared", "names": ["tab-width"], "root": "/w/a"})
        );
        assert!(!e.explained(2, vec![]));
        assert!(e.explained(1, vec![json!({"name": "tab-width", "value": "4"})]));
        assert_eq!(
            waiting.await.unwrap(),
            Some(vec![json!({"name": "tab-width", "value": "4"})])
        );
        // no answer in time
        assert_eq!(
            e.explain(SettingScope::Global, None, None, Duration::from_millis(20))
                .await,
            None
        );
        assert!(lock(&e.explains).is_empty());
    }
}
