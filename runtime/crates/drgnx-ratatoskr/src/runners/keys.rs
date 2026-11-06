//! Job keys (docs/guide/runners.md, "Keys"; design §6.6): how the user's keys reach a job without touching disk.
//!
//! - **The handover:** the hub asks with the event `runners/need-keys {names}`; the editor answers only from a command
//!   the user runs (`runners/keys`). [`Keys`] holds them as `bifrost::Keys` does: `SecretString`s in memory, never
//!   `Debug`, `Clone` or `Serialize`, zeroed on drop.
//! - **Who may name one:** only a key on the project's `drgnx-runners-job-keys` list ([`on_the_project_list`]), and a
//!   session only through the matrix's `job.keys`.
//! - **Sending:** [`send`], after the attempt's `started`, only where the runner's trust allows it ([`trust_ok`]:
//!   never `shared`; `my-cloud` only the keys on its list), one `key` frame per key. Each is recorded as `key_sent`
//!   (`job`, `attempt`, `key`, `runner`, `at`), the fact the hub knows for sure; a runner's `key-use` frames become
//!   `key_use`, labelled runner-reported.

use forseti::{JobTrust, RunnerTrust};
use runstav::methods::runners::{AuditKind, AuditRow, KeyNames};
use runstav::types::KeyName;
use secrecy::{ExposeSecret, SecretString};
use serde_json::{Value, json};
use sleipnir::proto::{Frame, JobRef, Key, KeyValue};
use std::collections::{BTreeMap, VecDeque};
use std::sync::{Mutex, OnceLock};

/// How many audit rows the hub keeps in memory (the graph keeps them all).
const AUDIT_KEPT: usize = 10_000;

/// What the hub tells the user's connections: an event's name and its data.
type Tell = Box<dyn Fn(&str, Value) + Send + Sync>;
/// Where an audit row is written for good (the graph).
type Sink = Box<dyn Fn(&AuditRow) + Send + Sync>;

/// The job keys the hub holds, and the audit of where they went.
#[derive(Default)]
pub struct Keys {
    held: Mutex<BTreeMap<String, SecretString>>,
    audit: Mutex<VecDeque<AuditRow>>,
    tell: OnceLock<Tell>,
    sink: OnceLock<Sink>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Keys {
    /// Events go through TELL (the hub's broadcast to user connections); the first call wins.
    pub fn set_tell(&self, tell: impl Fn(&str, Value) + Send + Sync + 'static) {
        let _ = self.tell.set(Box::new(tell));
    }

    /// Audit rows go to SINK as well (the graph's `key_sent` and `key_use`); the first call wins.
    pub fn set_sink(&self, sink: impl Fn(&AuditRow) + Send + Sync + 'static) {
        let _ = self.sink.set(Box::new(sink));
    }

    /// `runners/keys`: PAIRS to memory, nowhere else. The names now held.
    pub fn take(&self, pairs: impl IntoIterator<Item = (String, SecretString)>) -> Vec<String> {
        let mut held = lock(&self.held);
        for (name, value) in pairs {
            held.insert(name, value);
        }
        held.keys().cloned().collect()
    }

    /// `runners/keys-held`: the names, never a value.
    pub fn held(&self) -> KeyNames {
        KeyNames {
            names: lock(&self.held)
                .keys()
                .filter_map(|n| KeyName::new(n.as_str()).ok())
                .collect(),
        }
    }

    /// A copy of NAME's value, for the one frame or job that takes it.
    pub fn value(&self, name: &str) -> Option<SecretString> {
        lock(&self.held)
            .get(name)
            .map(|v| SecretString::from(v.expose_secret().to_string()))
    }

    /// Of NAMES, those the hub doesn't hold.
    pub fn missing(&self, names: &[String]) -> Vec<String> {
        let held = lock(&self.held);
        names
            .iter()
            .filter(|n| !held.contains_key(n.as_str()))
            .cloned()
            .collect()
    }

    /// Tells the user's connections the hub needs NAMES (`runners/need-keys`): a card for the editor, never answered
    /// from the event itself.
    pub fn ask(&self, names: &[String]) {
        if names.is_empty() {
            return;
        }
        let data = KeyNames {
            names: names
                .iter()
                .filter_map(|n| KeyName::new(n.as_str()).ok())
                .collect(),
        };
        self.tell_event("runners/need-keys", json!(data));
    }

    /// Tells the user's connections EVENT with DATA (a notice, the need for keys).
    pub fn tell_event(&self, event: &str, data: Value) {
        if let Some(t) = self.tell.get() {
            t(event, data);
        }
    }

    /// Records ROW: in memory, and in the graph.
    pub fn record(&self, row: AuditRow) {
        if let Some(s) = self.sink.get() {
            s(&row);
        }
        let mut a = lock(&self.audit);
        if a.len() >= AUDIT_KEPT {
            a.pop_front();
        }
        a.push_back(row);
    }

    /// The rows kept in memory: of JOB, of KEY, or all, oldest first.
    pub fn audit(&self, job: Option<&str>, key: Option<&str>) -> Vec<AuditRow> {
        lock(&self.audit)
            .iter()
            .filter(|r| job.is_none_or(|j| r.job == j) && key.is_none_or(|k| r.key.as_str() == k))
            .cloned()
            .collect()
    }
}

/// A row of KIND for key NAME of attempt R on RUNNER at AT.
pub fn row(kind: AuditKind, r: &JobRef, name: &str, runner: &str, at: u64) -> Option<AuditRow> {
    Some(AuditRow {
        kind,
        job: r.job.clone(),
        attempt: r.attempt,
        key: KeyName::new(name).ok()?,
        runner: runner.into(),
        at,
        runner_reported: kind == AuditKind::Use,
    })
}

/// A job may name only keys on its project's `drgnx-runners-job-keys` LIST; the first one that isn't refuses it.
pub fn on_the_project_list(names: &[String], list: &[String]) -> Result<(), String> {
    for n in names {
        if KeyName::new(n.as_str()).is_err() {
            return Err(format!("key {n:?}: {}", KeyName::WHAT));
        }
        if !list.iter().any(|l| l == n) {
            return Err(format!(
                "key {n} is not on the project's drgnx-runners-job-keys list: add it there to let jobs name it"
            ));
        }
    }
    Ok(())
}

/// Whether job keys NAMES may reach a runner of TRUST whose own list is ALLOWED: never `shared`; `my-cloud` only the
/// keys on its list; `mine` every one (design §6.6).
pub fn trust_ok(names: &[String], trust: RunnerTrust, allowed: &[String]) -> bool {
    trust != RunnerTrust::Shared
        && forseti::place::trust_ok(JobTrust::PrivateKeys, names, trust, allowed)
}

/// What [`send`] did.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Sent {
    /// The keys a `key` frame went for.
    pub sent: Vec<String>,
    /// The keys the hub doesn't hold yet (asked for with `runners/need-keys`).
    pub missing: Vec<String>,
    /// Why nothing may go to this runner.
    pub refused: Option<String>,
}

/// Sends the started attempt R the job keys NAMES through LINK (one `key` frame each), to RUNNER of TRUST whose list
/// is ALLOWED, only where [`trust_ok`]; each one sent is recorded as `key_sent` at NOW. Keys the hub doesn't hold are
/// asked for.
#[allow(clippy::too_many_arguments)]
pub fn send(
    link: &dyn Fn(Frame) -> bool,
    runner: &str,
    trust: RunnerTrust,
    allowed: &[String],
    r: &JobRef,
    names: &[String],
    keys: &Keys,
    now: u64,
) -> Sent {
    let mut out = Sent::default();
    if !trust_ok(names, trust, allowed) {
        out.refused = Some(format!(
            "runner {runner} may not get the keys {}",
            names.join(", ")
        ));
        return out;
    }
    for name in names {
        let Some(value) = keys.value(name) else {
            out.missing.push(name.clone());
            continue;
        };
        let sent = link(Frame::Key(Key {
            r: r.clone(),
            name: name.clone(),
            value: KeyValue::new(value),
        }));
        if !sent {
            out.missing.push(name.clone());
            continue;
        }
        if let Some(row) = row(AuditKind::Sent, r, name, runner, now) {
            keys.record(row);
        }
        out.sent.push(name.clone());
    }
    keys.ask(&out.missing);
    out
}

/// The graph's records of ROW: `key_sent:<job>.<attempt>.<key>`, or `key_use:<job>.<attempt>.<key>.<at>.<n>` (one per
/// read), written as `("hub", Class::System)`.
pub fn graph_sink(db: norn::store::CoordDb) -> impl Fn(&AuditRow) + Send + Sync + 'static {
    let seq = std::sync::atomic::AtomicU64::new(0);
    move |row: &AuditRow| {
        let (kind, name) = match row.kind {
            AuditKind::Sent => (
                "key_sent",
                format!("{}.{}.{}", row.job, row.attempt, row.key.as_str()),
            ),
            AuditKind::Use => (
                "key_use",
                format!(
                    "{}.{}.{}.{}.{}",
                    row.job,
                    row.attempt,
                    row.key.as_str(),
                    row.at,
                    seq.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                ),
            ),
        };
        let data = json!(row);
        let db = db.clone();
        crate::clock::spawn("runners:key-audit", async move {
            let meta = urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "runners/keys");
            if let Err(e) = db
                .write(meta, move |tx| {
                    norn::write::runners::put(tx, kind, &name, data).map(|_| ())
                })
                .await
            {
                tracing::warn!("runners: the key audit's record: {e}");
            }
        });
    }
}

/// The graph's `key_sent` and `key_use` rows, oldest first.
pub async fn graph_audit(db: &norn::store::CoordDb) -> Result<Vec<AuditRow>, String> {
    let mut rows = vec![];
    for kind in ["key_sent", "key_use"] {
        let got = db
            .read(move |c| norn::read::runners::list(c, kind))
            .await
            .map_err(|e| e.to_string())?;
        rows.extend(
            got.into_iter()
                .filter_map(|(_, data)| serde_json::from_value::<AuditRow>(data).ok()),
        );
    }
    rows.sort_by(|a, b| (a.at, &a.job, a.attempt).cmp(&(b.at, &b.job, b.attempt)));
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sleipnir::proto::Nonce;

    fn names(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    // [D] pure: a key not on the project's list is refused at submit, naming it and the setting; so is a name no
    // variable can have
    #[test]
    fn a_key_off_the_project_list_is_refused() {
        let list = names(&["CRATES_IO_TOKEN", "NPM_TOKEN"]);
        assert_eq!(on_the_project_list(&names(&["NPM_TOKEN"]), &list), Ok(()));
        assert_eq!(on_the_project_list(&[], &[]), Ok(()));
        let e = on_the_project_list(&names(&["NPM_TOKEN", "AWS_SECRET"]), &list).unwrap_err();
        assert!(
            e.contains("AWS_SECRET") && e.contains("drgnx-runners-job-keys"),
            "{e}"
        );
        let e = on_the_project_list(&names(&["NPM_TOKEN"]), &[]).unwrap_err();
        assert!(e.contains("NPM_TOKEN"), "{e}");
        for bad in ["a b", "1X", "X=Y", ""] {
            assert!(
                on_the_project_list(&names(&[bad]), &names(&[bad])).is_err(),
                "{bad:?}"
            );
        }
    }

    // [D] pure: one `key` frame per held key to a `mine` runner, each recorded as `key_sent`; a missing one is asked
    // for; a `shared` runner and a `my-cloud` runner without the key on its list get no frame and no record
    #[test]
    fn keys_go_one_frame_each_and_never_to_shared() {
        let keys = Keys::default();
        let asked = std::sync::Arc::new(Mutex::new(vec![]));
        let a = asked.clone();
        keys.set_tell(move |e, d| lock(&a).push((e.to_string(), d)));
        keys.take([
            ("A".to_string(), SecretString::from("va".to_string())),
            ("B".to_string(), SecretString::from("vb".to_string())),
        ]);
        let r = JobRef {
            job: "x1".into(),
            attempt: 2,
            nonce: Nonce([1; 16]),
        };
        let frames = std::cell::RefCell::new(vec![]);
        let link = |f: Frame| {
            frames.borrow_mut().push(f);
            true
        };
        let s = send(
            &link,
            "desk",
            RunnerTrust::Mine,
            &[],
            &r,
            &names(&["A", "B", "C"]),
            &keys,
            7,
        );
        assert_eq!(
            s,
            Sent {
                sent: names(&["A", "B"]),
                missing: names(&["C"]),
                refused: None
            }
        );
        let got: Vec<(String, String)> = frames
            .borrow()
            .iter()
            .map(|f| match f {
                Frame::Key(k) => (k.name.clone(), k.value.expose().to_string()),
                f => panic!("{f:?}"),
            })
            .collect();
        assert_eq!(
            got,
            vec![("A".into(), "va".into()), ("B".into(), "vb".into())]
        );
        let audit = keys.audit(Some("x1"), None);
        assert_eq!(audit.len(), 2);
        assert!(audit.iter().all(|a| a.kind == AuditKind::Sent
            && a.runner == "desk"
            && a.attempt == 2
            && a.at == 7
            && !a.runner_reported));
        assert_eq!(
            lock(&asked).clone(),
            vec![("runners/need-keys".to_string(), json!({"names": ["C"]}))]
        );
        frames.borrow_mut().clear();
        for (trust, allowed) in [
            (RunnerTrust::Shared, names(&["A"])),
            (RunnerTrust::MyCloud, names(&["B"])),
        ] {
            let s = send(
                &link,
                "other",
                trust,
                &allowed,
                &r,
                &names(&["A"]),
                &keys,
                8,
            );
            assert!(s.refused.is_some() && s.sent.is_empty(), "{trust:?}");
        }
        assert!(frames.borrow().is_empty(), "no key frame went");
        assert_eq!(keys.audit(None, None).len(), 2, "and nothing was recorded");
        // my-cloud with the key on its list gets it
        let s = send(
            &link,
            "cloud",
            RunnerTrust::MyCloud,
            &names(&["A"]),
            &r,
            &names(&["A"]),
            &keys,
            9,
        );
        assert_eq!(s.sent, names(&["A"]));
        // the names held, never a value
        assert_eq!(
            serde_json::to_value(keys.held()).unwrap(),
            json!({"names": ["A", "B"]})
        );
    }
}
