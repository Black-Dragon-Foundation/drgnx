//! The editor as the agents' settings tools reach it (unified-settings Task 32; design §13; docs/develop/hub.md,
//! "Agents change settings"): the subscribed connections (each a user's: the backend's is never subscribed), the
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
    }

    /// EVENT with DATA to every subscriber: queued for each before any is written (a queue never waits), so a newer
    /// event never reaches one subscriber before an older one. A closed connection is dropped.
    pub fn broadcast(&self, event: &str, data: Value) {
        let Some(line) = crate::front::event_line(event, data) else {
            return;
        };
        lock(&self.subscribers).retain(|_, out| out.push(line.clone()));
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
        let got = tokio::time::timeout(wait, rx).await;
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
        let got = tokio::time::timeout(wait, rx).await;
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
        // the event goes out first
        let mut sent = Vec::new();
        for _ in 0..200 {
            sent = lines(&out);
            if !sent.is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
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
        let mut sent = Vec::new();
        for _ in 0..200 {
            sent = lines(&out);
            if !sent.is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
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
