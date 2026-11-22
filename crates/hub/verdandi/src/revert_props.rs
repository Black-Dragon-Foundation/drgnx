//! The span revert against git's 3-way merge, in 2,000 seeded cases (10,000 with `DRGNX_PROP_CASES=10000`, the
//! combined pass's run; the seeds are the same, so a failing seed is the same in both) (the spike's property, through the history's
//! own records and a reload of each document from its rows).  A 40-line file in 8 blocks of 5; the agent edits lines
//! of 1 to 3 blocks (a new line, a deleted line, 3 characters replaced) in one record; then the user edits lines of
//! other blocks, and in about a fifth of the cases types inside or deletes from the agent's new text.  Keep mine must
//! then equal `git merge-file` (ours: now, base: after the agent, theirs: before it) wherever no user edit overlaps,
//! with no 3-way fallback taken; every real overlap must be found and no other.
//! Pattern D (pure: seeded, a temporary folder and `git merge-file`, no clock).

use crate::store::{BranchKind, Cause, History, Kind, Record};
use crate::{Change, Mode, PeerId};

/// How many seeds run: 2,000 (about half a minute), or `DRGNX_PROP_CASES`.
fn cases() -> u64 {
    std::env::var("DRGNX_PROP_CASES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(2_000)
}

const BLOCKS: usize = 8;

/// xorshift64*: the cases are seeded, the same on every run.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Rng {
        Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
    fn chance(&mut self, pct: u64) -> bool {
        self.next() % 100 < pct
    }
}

fn base_text(rng: &mut Rng) -> String {
    let words = [
        "alpha", "beta", "gamma", "delta", "eps", "zeta", "eta", "theta",
    ];
    let mut s = String::new();
    for b in 0..BLOCKS {
        for j in 0..5 {
            s.push_str(&format!("B{b}L{j}"));
            for _ in 0..2 + rng.below(4) {
                s.push(' ');
                s.push_str(words[rng.below(words.len())]);
            }
            s.push('\n');
        }
    }
    s
}

/// The character offset of line MARKER's start in T.
fn line(t: &str, marker: &str) -> Option<usize> {
    let mut off = 0;
    for l in t.split_inclusive('\n') {
        if l.starts_with(marker) && l[marker.len()..].starts_with(' ') {
            return Some(off);
        }
        off += l.chars().count();
    }
    None
}

/// Edits of lines 1 to 3 of BLOCKS in the text T, as changes in order (each against the text the last left).
fn edits(t: &str, rng: &mut Rng, blocks: &[usize], tag: &str, force_insert: bool) -> Vec<Change> {
    let mut text = t.to_string();
    let mut out = Vec::new();
    let mut first = true;
    for &b in blocks {
        for j in 1..=3 {
            let r = rng.below(100);
            let kind = if force_insert && first {
                0
            } else {
                match r {
                    0..20 => 0,
                    20..35 => 1,
                    35..55 => 2,
                    _ => 3,
                }
            };
            first = false;
            let Some(off) = line(&text, &format!("B{b}L{j}")) else {
                continue;
            };
            let ch = match kind {
                0 => Change {
                    start: off,
                    old_len: 0,
                    inserted: format!("{tag}-new{b}{j} inserted line text\n"),
                },
                1 => {
                    let len = text.chars().skip(off).take_while(|c| *c != '\n').count() + 1;
                    Change {
                        start: off,
                        old_len: len,
                        inserted: String::new(),
                    }
                }
                2 => Change {
                    start: off + 5,
                    old_len: 3,
                    inserted: format!("<{tag}{j}>"),
                },
                _ => continue,
            };
            let mut cs: Vec<char> = text.chars().collect();
            cs.splice(ch.start..ch.start + ch.old_len, ch.inserted.chars());
            text = cs.into_iter().collect();
            out.push(ch);
        }
    }
    out
}

fn pick(rng: &mut Rng, from: &[usize], k: usize) -> Vec<usize> {
    let mut v = from.to_vec();
    for i in (1..v.len()).rev() {
        v.swap(i, rng.below(i + 1));
    }
    v.truncate(k);
    v.sort();
    v
}

fn apply(
    h: &mut History,
    doc: crate::DocId,
    br: crate::BranchId,
    p: PeerId,
    chs: &[Change],
) -> Vec<crate::Span> {
    let mut spans = Vec::new();
    let mut d = h.activate(doc, br, || unreachable!()).unwrap();
    for c in chs {
        spans.extend(d.apply(p, c).unwrap());
    }
    spans
}

#[test]
fn keep_mine_equals_threeway_outside_hunks() {
    let dir = tempfile::tempdir().unwrap();
    let mut h = History::open_fast(dir.path()).unwrap();
    let (mut equal, mut conflicted, mut overlap_cases) = (0, 0, 0);
    let mut misses = Vec::new();
    let cases = cases();
    for seed in 0..cases {
        let mut rng = Rng::new(seed);
        let want_overlap = rng.chance(40);
        let base = base_text(&mut rng);
        let doc = h.doc_for(&format!("case{seed}.txt")).unwrap();
        let br = h
            .branch(
                &format!("wt/{seed}"),
                BranchKind::Worktree,
                Some(&format!("c{seed}")),
            )
            .unwrap();
        h.activate(doc, br, || Ok(base.clone())).unwrap();
        let agent = h.peer(&serde_json::json!({"run": seed}), Some(br)).unwrap();
        let user = h
            .peer(&serde_json::json!({"user": seed}), Some(br))
            .unwrap();
        let all: Vec<usize> = (0..BLOCKS).collect();
        let ka = 1 + rng.below(3);
        let ablocks = pick(&mut rng, &all, ka);
        let pool: Vec<usize> = all
            .iter()
            .copied()
            .filter(|b| !ablocks.contains(b))
            .collect();
        let ku = rng.below(3);
        let ublocks = pick(&mut rng, &pool, ku);
        let ach = edits(&base, &mut rng, &ablocks, "AG", want_overlap);
        let spans = apply(&mut h, doc, br, agent, &ach);
        let step = h
            .record(Record {
                kind: Kind::AgentStep,
                author: agent,
                cause: Cause::default(),
                spans: spans.into_iter().map(|s| (doc, s)).collect(),
                parents: vec![],
                git: None,
                summary: String::new(),
                at: 0.0,
            })
            .unwrap();
        let after_agent = h.text(doc, br).unwrap();
        let uch = edits(&after_agent, &mut rng, &ublocks, "US", false);
        apply(&mut h, doc, br, user, &uch);
        // inside the agent's new line: type two characters, or delete one
        let mut truth = false;
        if want_overlap {
            let t = h.text(doc, br).unwrap();
            if let Some(i) = t.find("AG-new") {
                let at = t[..i].chars().count() + 3;
                let ch = if rng.chance(50) {
                    Change {
                        start: at,
                        old_len: 0,
                        inserted: "ZZ".into(),
                    }
                } else {
                    Change {
                        start: at,
                        old_len: 1,
                        inserted: String::new(),
                    }
                };
                apply(&mut h, doc, br, user, &[ch]);
                truth = true;
            }
        }
        // the hub restarts between the edits and the revert: the document comes back from its rows
        h.park(doc, br).unwrap();
        let ours = h.text(doc, br).unwrap();
        let p = h.preview_revert(br, &[step]).unwrap();
        let found = !p.overlaps.is_empty();
        assert_eq!(
            found, truth,
            "seed {seed}: overlap found {found}, made {truth}\n{ours}"
        );
        if truth {
            overlap_cases += 1;
        } else {
            let (clean, git) = crate::threeway::merge(&after_agent, &ours, &base).unwrap();
            if !clean {
                conflicted += 1;
            } else if p.threeway_differs
                // an agent record that changed nothing previews no file: the text stays
                || p.files.first().map_or(ours.as_str(), |f| f.after.as_str()) != git
            {
                misses.push(seed);
            } else {
                h.apply_revert(p.id, &[], Mode::KeepMine, user, 1.0)
                    .unwrap();
                assert_eq!(h.text(doc, br).unwrap(), git, "seed {seed}: applied");
                equal += 1;
            }
        }
        h.park(doc, br).unwrap();
    }
    assert!(
        misses.is_empty(),
        "keep mine differs from git in seeds {misses:?}"
    );
    assert_eq!(
        conflicted, 0,
        "git's 3-way conflicted where no edit overlapped"
    );
    assert!(
        overlap_cases > cases / 10 && equal > cases / 2,
        "{overlap_cases} overlaps, {equal} equal"
    );
}
