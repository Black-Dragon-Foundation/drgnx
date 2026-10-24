//! Session transcripts on disk (agent system part 1, Task 8b): `<state>/hub/transcripts/<sid>.jsonl`, mode 0600, one
//! line `{"n": INDEX, "entry": ENTRY}` per entry, and the held queue in `<sid>.queue.json`.  Every string of an entry
//! goes through `runstav::secrets::looks_like_secret` before it is written: a hit is replaced by `[redacted: KIND]`,
//! so a key the agent saw or the user pasted never rests in a file.  A restarted hub reads the transcript back, so
//! nothing the session said is lost.

use super::queue::Queue;
use runstav::methods::agents::Entry;
use runstav::secrets::looks_like_secret;
use serde_json::Value;
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::PathBuf;

/// TEXT with every secret-looking part replaced by `[redacted: KIND]`.  A private key (it spans lines) takes the
/// whole text; otherwise each line is looked at, and within a hit line each word: a hit that no single word explains
/// (`KEY = value` over three words) takes the line.
pub fn redact(text: &str) -> String {
    match looks_like_secret(text) {
        None => return text.to_string(),
        Some(kind @ "private-key") => return format!("[redacted: {kind}]"),
        Some(_) => {}
    }
    let mut out = String::with_capacity(text.len());
    for line in text.split_inclusive('\n') {
        let body = line.trim_end_matches(['\n', '\r']);
        let tail = &line[body.len()..];
        let Some(line_kind) = looks_like_secret(body) else {
            out.push_str(line);
            continue;
        };
        let mut hit = false;
        let mut redone = String::with_capacity(body.len());
        for word in body.split_inclusive(char::is_whitespace) {
            let w = word.trim_end();
            match looks_like_secret(w) {
                Some(kind) if !w.is_empty() => {
                    hit = true;
                    redone.push_str(&format!("[redacted: {kind}]"));
                    redone.push_str(&word[w.len()..]);
                }
                _ => redone.push_str(word),
            }
        }
        if hit {
            out.push_str(&redone);
        } else {
            out.push_str(&format!("[redacted: {line_kind}]"));
        }
        out.push_str(tail);
    }
    out
}

/// V with every string value redacted (keys are the protocol's, not content).
pub fn redact_value(v: &mut Value) {
    match v {
        Value::String(s) => {
            let r = redact(s);
            if r != *s {
                *s = r;
            }
        }
        Value::Array(a) => a.iter_mut().for_each(redact_value),
        Value::Object(o) => o.values_mut().for_each(redact_value),
        _ => {}
    }
}

/// The transcripts folder of one hub.
#[derive(Clone, Debug)]
pub struct Store {
    dir: PathBuf,
}

impl Store {
    /// `<hub dir>/transcripts`.
    pub fn new(hub_dir: &std::path::Path) -> Store {
        Store {
            dir: hub_dir.join("transcripts"),
        }
    }

    fn file(&self, sid: &str, ext: &str) -> PathBuf {
        self.dir.join(format!("{sid}.{ext}"))
    }

    fn ensure(&self) -> std::io::Result<()> {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&self.dir)
    }

    /// Append ENTRIES (index, entry), redacted.
    pub fn append(&self, sid: &str, entries: &[(u64, Entry)]) -> std::io::Result<()> {
        if entries.is_empty() {
            return Ok(());
        }
        self.ensure()?;
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(self.file(sid, "jsonl"))?;
        let mut buf = String::new();
        for (n, e) in entries {
            let mut v = serde_json::json!({"n": n, "entry": e});
            redact_value(&mut v);
            buf.push_str(&v.to_string());
            buf.push('\n');
        }
        f.write_all(buf.as_bytes())
    }

    /// The entries written so far, in index order (a later line for an index replaces the earlier one; a line that
    /// does not parse is skipped).
    pub fn load(&self, sid: &str) -> Vec<Entry> {
        let Ok(text) = std::fs::read_to_string(self.file(sid, "jsonl")) else {
            return Vec::new();
        };
        let mut by: std::collections::BTreeMap<u64, Entry> = std::collections::BTreeMap::new();
        for line in text.lines() {
            let Ok(v) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            let (Some(n), Some(e)) = (
                v.get("n").and_then(Value::as_u64),
                v.get("entry")
                    .and_then(|e| serde_json::from_value::<Entry>(e.clone()).ok()),
            ) else {
                continue;
            };
            by.insert(n, e);
        }
        by.into_values().collect()
    }

    /// What a restart needs of a session that is not in `asession` (a brainstorm's topic note and design document:
    /// without them it would resume without its write fence).  Best effort.
    pub fn save_meta(&self, sid: &str, meta: &Value) {
        let write = || -> std::io::Result<()> {
            self.ensure()?;
            let mut f = std::fs::OpenOptions::new()
                .create(true)
                .write(true)
                .truncate(true)
                .mode(0o600)
                .open(self.file(sid, "meta.json"))?;
            f.write_all(meta.to_string().as_bytes())
        };
        if let Err(e) = write() {
            tracing::warn!(sid, "cannot keep the session's notes: {e}");
        }
    }

    pub fn load_meta(&self, sid: &str) -> Value {
        std::fs::read_to_string(self.file(sid, "meta.json"))
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or(Value::Null)
    }

    /// Keep the held queue (an empty one removes the file).  Unredacted: the prompts are still to be sent, and the
    /// file is 0600 in the hub's private folder.
    pub fn save_queue(&self, sid: &str, q: &Queue, paused: bool) -> std::io::Result<()> {
        let path = self.file(sid, "queue.json");
        if q.is_empty() && !paused {
            return match std::fs::remove_file(path) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
                _ => Ok(()),
            };
        }
        self.ensure()?;
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .mode(0o600)
            .open(path)?;
        f.write_all(
            serde_json::json!({"queue": q, "paused": paused})
                .to_string()
                .as_bytes(),
        )
    }

    pub fn load_queue(&self, sid: &str) -> (Queue, bool) {
        let Ok(text) = std::fs::read_to_string(self.file(sid, "queue.json")) else {
            return (Queue::default(), false);
        };
        let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        let q = v
            .get("queue")
            .and_then(|q| serde_json::from_value(q.clone()).ok())
            .unwrap_or_default();
        (q, v.get("paused").and_then(Value::as_bool).unwrap_or(false))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use runstav::methods::agents::EntryType;
    use serde_json::{Map, json};
    use std::os::unix::fs::PermissionsExt;

    fn entry(kind: EntryType, text: &str) -> Entry {
        let mut rest = Map::new();
        rest.insert("text".into(), json!(text));
        Entry { kind, rest }
    }

    /// Built in two pieces: this source is public, and a key-shaped literal would trip the secret scan.
    fn key() -> String {
        ["sk-ant-", "api03-Zk3Qw9Lm2Xv8Rt5Yp7Hn4Bd6Fg1Jc0Ua"].concat()
    }

    #[test]
    fn a_key_in_a_sentence_is_replaced_and_the_rest_kept() {
        let r = redact(&format!("use {} for the call\nsecond line", key()));
        assert!(!r.contains("Zk3Qw9"), "{r}");
        assert!(r.contains("[redacted: "), "{r}");
        assert!(r.starts_with("use "), "{r}");
        assert!(
            r.ends_with("for the call\nsecond line") || r.contains("second line"),
            "{r}"
        );
        assert_eq!(redact("nothing secret here"), "nothing secret here");
    }

    #[test]
    fn a_private_key_takes_the_whole_text() {
        let t = [
            "-----BEGIN ",
            "PRIVATE KEY-----\nMIIEvQIBADANBgkq\n-----END PRIVATE KEY-----\n",
        ]
        .concat();
        assert_eq!(redact(&t), "[redacted: private-key]");
    }

    #[test]
    fn the_file_is_private_redacted_and_read_back() {
        let dir = tempfile::tempdir().unwrap();
        let s = Store::new(dir.path());
        s.append(
            "a1",
            &[
                (0, entry(EntryType::User, &format!("here: {}", key()))),
                (1, entry(EntryType::Agent, "fine")),
            ],
        )
        .unwrap();
        let path = dir.path().join("transcripts/a1.jsonl");
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let raw = std::fs::read_to_string(&path).unwrap();
        assert!(!raw.contains("Zk3Qw9"), "{raw}");
        let back = s.load("a1");
        assert_eq!(back.len(), 2);
        assert!(
            back[0].rest["text"]
                .as_str()
                .unwrap()
                .contains("[redacted: ")
        );
        assert_eq!(back[1].rest["text"], "fine");
        assert!(s.load("nobody").is_empty());
    }

    #[test]
    fn the_queue_file_comes_and_goes() {
        let dir = tempfile::tempdir().unwrap();
        let s = Store::new(dir.path());
        let mut q = Queue::default();
        q.push("later".into(), super::super::queue::Origin::User, false);
        s.save_queue("a1", &q, true).unwrap();
        let (back, paused) = s.load_queue("a1");
        assert_eq!(back.texts(), ["later"]);
        assert!(paused);
        s.save_queue("a1", &Queue::default(), false).unwrap();
        assert!(s.load_queue("a1").0.is_empty());
        assert!(!dir.path().join("transcripts/a1.queue.json").exists());
    }
}
