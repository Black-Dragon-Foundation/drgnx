//! The result cache's key and lookup (job-scheduler design §9.2). Pure: the store is a parameter.
//!
//! The key is the SHA-256 of everything that decides a result, with the schema version first, so a new scheme never
//! meets an old key. A lookup answers only a pass at most a day old, never for a gate, `--fresh` or a timing run, never
//! a red, and judges the stored counts again with the job's current `expect`.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::model::{Expect, JobId, Verdict};

/// The key scheme. Bumping it invalidates every stored result.
pub const SCHEMA: u32 = 1;
/// A stored pass is reused for this long.
pub const MAX_AGE_S: u64 = 24 * 3600;

/// Every part of the key (§9.2). Paths in the command are normalised by the caller; the environment is the allowlist,
/// without capacity variables; `machine` is the machine's name, or none for a suite that opts out of it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct KeyParts {
    pub kind: String,
    pub suite: Option<String>,
    pub rows: Vec<String>,
    pub command: Vec<String>,
    pub env: Vec<(String, String)>,
    pub outer_image: String,
    pub inner_images: Vec<String>,
    /// The hash of the whole synced wrapper set.
    pub wrapper_hash: String,
    pub mise_hash: String,
    /// The commit's git tree id.
    pub tree_id: String,
    pub overlay_hash: String,
    /// Hashes of `inputs.extra` and `inputs.outside`.
    pub inputs_extra: Vec<String>,
    pub inputs_outside: Vec<String>,
    /// The keys of the artefacts the job needs.
    pub artefact_keys: Vec<String>,
    pub machine: Option<String>,
}

struct Feed(Sha256);

impl Feed {
    /// One field: its length, then its bytes, so no two field lists feed the same bytes.
    fn bytes(&mut self, b: &[u8]) {
        self.0.update((b.len() as u64).to_le_bytes());
        self.0.update(b);
    }

    fn str(&mut self, s: &str) {
        self.bytes(s.as_bytes());
    }

    fn opt(&mut self, s: &Option<String>) {
        match s {
            Some(s) => {
                self.0.update([1]);
                self.str(s);
            }
            None => self.0.update([0]),
        }
    }

    fn list(&mut self, l: &[String]) {
        self.0.update((l.len() as u64).to_le_bytes());
        for s in l {
            self.str(s);
        }
    }
}

/// The key of PARTS: 64 hex digits.
pub fn cache_key(p: &KeyParts) -> String {
    let mut f = Feed(Sha256::new());
    f.0.update(SCHEMA.to_le_bytes());
    f.str(&p.kind);
    f.opt(&p.suite);
    f.list(&p.rows);
    f.list(&p.command);
    f.0.update((p.env.len() as u64).to_le_bytes());
    for (k, v) in &p.env {
        f.str(k);
        f.str(v);
    }
    f.str(&p.outer_image);
    f.list(&p.inner_images);
    f.str(&p.wrapper_hash);
    f.str(&p.mise_hash);
    f.str(&p.tree_id);
    f.str(&p.overlay_hash);
    f.list(&p.inputs_extra);
    f.list(&p.inputs_outside);
    f.list(&p.artefact_keys);
    f.opt(&p.machine);
    f.0.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// What a run's parser counted.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Counts {
    pub ran: u32,
    pub skipped: u32,
    pub failed: u32,
    pub crashed: u32,
    /// The parser counts rows at all (`exit` doesn't).
    pub counts_rows: bool,
}

/// A stored result: the key it was kept under, the job that ran, when, and what was counted. `red` is whether that run
/// ended in anything but a pass (a red, a crash, an infra end).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stored {
    pub key: String,
    pub job: JobId,
    pub at: u64,
    pub counts: Counts,
    pub red: bool,
}

/// A reused result: the job it came from and when, and the verdict judged again.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cached {
    pub job: JobId,
    pub at: u64,
    pub verdict: Verdict,
}

/// The verdict of COUNTS under EXPECT, the rules a parser's judge applies to a job that exited 0.
pub fn verdict_of(c: &Counts, expect: &Expect) -> Verdict {
    if c.failed > 0 {
        return Verdict::Red;
    }
    if c.crashed > 0 {
        return Verdict::Crash;
    }
    if let Some(min) = expect.min_ran {
        if !c.counts_rows {
            return Verdict::Suspect(format!(
                "expected at least {min} rows, and this parser counts none"
            ));
        }
        if c.ran < min {
            return Verdict::Suspect(format!("ran {} rows, expected at least {min}", c.ran));
        }
    }
    if let Some(max) = expect.max_skipped
        && c.skipped > max
    {
        return Verdict::Suspect(format!(
            "skipped {} rows, expected at most {max}",
            c.skipped
        ));
    }
    Verdict::Pass
}

/// What the job asks of the cache.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Want {
    /// A gate always runs.
    pub gate: bool,
    /// `--fresh`.
    pub fresh: bool,
    /// A timing run is never reused.
    pub timing: bool,
    /// The job's current `expect`.
    pub expect: Expect,
}

/// The newest stored pass for KEY at most [`MAX_AGE_S`] old at NOW, judged again under `want.expect`; none for a gate,
/// a fresh job or a timing run, for a red, and for a pass the current `expect` no longer accepts.
pub fn lookup(store: &[Stored], key: &str, now: u64, want: &Want) -> Option<Cached> {
    if want.gate || want.fresh || want.timing {
        return None;
    }
    store
        .iter()
        .filter(|s| s.key == key && !s.red && s.at <= now && now - s.at <= MAX_AGE_S)
        .max_by_key(|s| s.at)
        .and_then(|s| match verdict_of(&s.counts, &want.expect) {
            Verdict::Pass => Some(Cached {
                job: s.job.clone(),
                at: s.at,
                verdict: Verdict::Pass,
            }),
            _ => None,
        })
}

/// KEY has both a pass and a red in STORE: `jobq done` shows it `flaky`.
pub fn is_flaky(store: &[Stored], key: &str) -> bool {
    let has = |red| store.iter().any(|s| s.key == key && s.red == red);
    has(true) && has(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn stored(at: u64, red: bool, ran: u32) -> Stored {
        Stored {
            key: "k".into(),
            job: JobId(format!("j{at}")),
            at,
            counts: Counts {
                ran,
                counts_rows: true,
                ..Counts::default()
            },
            red,
        }
    }

    // [D] pure
    #[test]
    fn gate_never_cached() {
        let store = [stored(100, false, 10)];
        let want = Want::default();
        assert!(lookup(&store, "k", 200, &want).is_some());
        for w in [
            Want { gate: true, ..want },
            Want {
                fresh: true,
                ..want
            },
            Want {
                timing: true,
                ..want
            },
        ] {
            assert_eq!(lookup(&store, "k", 200, &w), None, "{w:?}");
        }
    }

    // [D] pure
    #[test]
    fn older_than_24h_misses() {
        let store = [stored(1_000, false, 10)];
        let want = Want::default();
        assert!(lookup(&store, "k", 1_000 + MAX_AGE_S, &want).is_some());
        assert_eq!(lookup(&store, "k", 1_000 + MAX_AGE_S + 1, &want), None);
        assert_eq!(
            lookup(&store, "k", 500, &want),
            None,
            "a result from the future is no result"
        );
        assert_eq!(lookup(&store, "other", 1_100, &want), None);
    }

    // [D] pure
    #[test]
    fn red_never_reused() {
        let store = [stored(100, true, 10)];
        assert_eq!(lookup(&store, "k", 200, &Want::default()), None);
        // the newest pass answers, a later red doesn't take it away: a key with both is flaky
        let both = [stored(100, false, 10), stored(150, true, 10)];
        let hit = lookup(&both, "k", 200, &Want::default()).expect("the pass");
        assert_eq!(hit.job, JobId("j100".into()));
        assert!(is_flaky(&both, "k"));
        assert!(!is_flaky(&both[..1], "k"));
        assert!(!is_flaky(&both, "other"));
    }

    // [D] pure
    #[test]
    fn verdict_recomputed_with_new_expect() {
        let store = [stored(100, false, 10)];
        let mut want = Want::default();
        assert_eq!(
            lookup(&store, "k", 200, &want).unwrap().verdict,
            Verdict::Pass
        );
        // a stricter threshold than the stored run met: never reuses the old verdict
        want.expect.min_ran = Some(11);
        assert_eq!(lookup(&store, "k", 200, &want), None);
        want.expect.min_ran = Some(10);
        assert!(lookup(&store, "k", 200, &want).is_some());
        let skipped = [Stored {
            counts: Counts {
                ran: 10,
                skipped: 3,
                counts_rows: true,
                ..Counts::default()
            },
            ..stored(100, false, 10)
        }];
        want.expect = Expect {
            min_ran: None,
            max_skipped: Some(2),
        };
        assert_eq!(lookup(&skipped, "k", 200, &want), None);
    }

    fn base() -> KeyParts {
        KeyParts {
            kind: "test".into(),
            suite: Some("unit".into()),
            rows: vec!["a".into(), "b".into()],
            command: vec!["make".into(), "check".into()],
            env: vec![("A".into(), "1".into())],
            outer_image: "o@sha256:1".into(),
            inner_images: vec!["i@sha256:2".into()],
            wrapper_hash: "w".into(),
            mise_hash: "m".into(),
            tree_id: "t".into(),
            overlay_hash: "ov".into(),
            inputs_extra: vec!["x".into()],
            inputs_outside: vec!["y".into()],
            artefact_keys: vec!["art".into()],
            machine: Some("desktop".into()),
        }
    }

    // [D] pure
    #[test]
    fn the_key_is_a_stable_sha256_that_starts_with_the_schema() {
        let k = cache_key(&base());
        assert_eq!(k.len(), 64);
        assert_eq!(k, cache_key(&base()));
        // a list's split can't be moved across fields
        let mut a = base();
        a.rows = vec!["ab".into()];
        a.command = vec!["make".into()];
        let mut b = base();
        b.rows = vec!["a".into(), "b".into()];
        b.command = vec!["make".into(), "check".into()];
        assert_ne!(cache_key(&a), cache_key(&b));
    }

    fn word() -> impl Strategy<Value = String> {
        "[a-z]{0,4}"
    }

    proptest! {
        // [D] property: each part, changed alone, changes the key
        #[test]
        fn any_key_part_changes_the_key(part in 0usize..16, edit in word()) {
            let mut p = base();
            let tag = format!("{edit}!");
            match part {
                0 => p.kind.push_str(&tag),
                1 => p.suite = Some(format!("{}{tag}", p.suite.clone().unwrap())),
                2 => p.rows.push(tag),
                3 => p.command.push(tag),
                4 => p.env.push((tag.clone(), tag)),
                5 => p.outer_image.push_str(&tag),
                6 => p.inner_images.push(tag),
                7 => p.wrapper_hash.push_str(&tag),
                8 => p.mise_hash.push_str(&tag),
                9 => p.tree_id.push_str(&tag),
                10 => p.overlay_hash.push_str(&tag),
                11 => p.inputs_extra.push(tag),
                12 => p.inputs_outside.push(tag),
                13 => p.artefact_keys.push(tag),
                14 => p.machine = None,
                _ => p.suite = None,
            }
            prop_assert_ne!(cache_key(&p), cache_key(&base()));
        }
    }
}
