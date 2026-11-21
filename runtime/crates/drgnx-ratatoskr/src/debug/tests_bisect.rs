//! Bisect over the edit history (spec §19.6): the search (k-section over slots, skips, a re-checked good state, flaky
//! states), hunk narrowing (delta debugging), the states made trees in a shadow repository and restored into one
//! folder per slot, cancel.  The predicate is scripted (`Script`); the trees and restores are real git.
use super::BoxFut;
use super::bisect::{self, Bisect, Candidate, Ending, Outcome, Prober, Search, Stage};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

fn oc(c: char) -> Outcome {
    match c {
        'g' => Outcome::Good,
        'b' => Outcome::Bad,
        _ => Outcome::Skip("does not build".into()),
    }
}

/// The search alone over STATES ('g', 'b', 's' per state; state 0 is the re-checked good one), one slot.
fn search(states: &str) -> (Search, Vec<usize>) {
    let st: Vec<char> = states.chars().collect();
    let mut s = Search::new(st.len());
    let mut asked = Vec::new();
    loop {
        let next = s.next(1, &[]);
        if next.is_empty() {
            break;
        }
        for i in next {
            asked.push(i);
            s.record(i, oc(st[i]));
        }
    }
    (s, asked)
}

#[test]
fn the_search_halves_and_names_the_first_bad_state() {
    let (s, asked) = search("gggggbbbb");
    assert_eq!(s.first_bad(), 5);
    assert!(s.skipped().is_empty());
    // log2(8) runs, not 8
    assert!(asked.len() <= 3, "{asked:?}");
}

#[test]
fn a_state_that_does_not_build_is_skipped_and_its_neighbour_asked() {
    // the middle state (4) does not build: a neighbour is asked instead
    let (s, asked) = search("ggggsgbbb");
    assert_eq!(asked[0], 4);
    assert!(asked.contains(&3) || asked.contains(&5), "{asked:?}");
    assert_eq!(s.first_bad(), 6);
    assert!(s.skipped().is_empty());
    // only skipped states between the last good and the first bad: the answer is a range
    let (s, _) = search("ggggsbbbb");
    assert_eq!(s.first_bad(), 5);
    assert_eq!(s.skipped(), vec![4]);
}

#[test]
fn slots_ask_several_states_at_once() {
    let s = Search::new(9);
    let three = s.next(3, &[]);
    assert_eq!(three.len(), 3);
    assert!(three.iter().all(|i| (1..8).contains(i)));
    // a state already running is not asked twice
    let more = s.next(3, &three);
    assert!(more.iter().all(|i| !three.contains(i)));
}

#[test]
fn hunk_narrowing_finds_the_hunks_that_matter() {
    // fails only when hunks 1 and 4 are both in
    let runs = AtomicUsize::new(0);
    let test = |set: &[usize]| {
        runs.fetch_add(1, Ordering::Relaxed);
        if set.contains(&1) && set.contains(&4) {
            Outcome::Bad
        } else {
            Outcome::Good
        }
    };
    assert_eq!(bisect::ddmin(6, test), vec![1, 4]);
    assert!(runs.load(Ordering::Relaxed) < 30);
    // one hunk: nothing to narrow
    assert_eq!(bisect::ddmin(1, |_: &[usize]| Outcome::Bad), vec![0]);
}

/// The scripted predicate: each state's outcomes in order (the last repeats), read from the slot's `state` file; it
/// counts its runs and folders.
struct Script {
    outcomes: HashMap<String, Vec<char>>,
    runs: Mutex<Vec<(PathBuf, String)>>,
    cancelled: AtomicBool,
    hold: Option<Arc<tokio::sync::Notify>>,
}

impl Script {
    fn new(table: &[(&str, &str)]) -> Arc<Script> {
        Arc::new(Script {
            outcomes: table
                .iter()
                .map(|(k, v)| ((*k).to_owned(), v.chars().collect()))
                .collect(),
            runs: Mutex::new(Vec::new()),
            cancelled: AtomicBool::new(false),
            hold: None,
        })
    }
}

impl Prober for Script {
    fn run(&self, dir: &Path) -> BoxFut<'static, Outcome> {
        let state = std::fs::read_to_string(dir.join("state")).unwrap_or_default();
        let state = state.trim().to_owned();
        let n = {
            let mut r = self.runs.lock().unwrap();
            r.push((dir.to_path_buf(), state.clone()));
            r.iter().filter(|(_, s)| *s == state).count()
        };
        let seq = self
            .outcomes
            .get(&state)
            .cloned()
            .unwrap_or_else(|| vec!['s']);
        let c = seq[(n - 1).min(seq.len() - 1)];
        let hold = self.hold.clone();
        Box::pin(async move {
            if let Some(h) = hold {
                h.notified().await;
            }
            oc(c)
        })
    }
    fn cancel(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }
}

/// Nine states as trees in a shadow repository: a `state` file naming each, `app.py` changing at every state, a file
/// that comes at state 4.
fn history(d: &Path) -> (PathBuf, PathBuf, Vec<Candidate>) {
    let (root, src) = (d.join("cp"), d.join("src"));
    std::fs::create_dir_all(&src).unwrap();
    let mut out = Vec::new();
    for i in 0..9 {
        std::fs::write(src.join("state"), format!("s{i}\n")).unwrap();
        std::fs::write(src.join("app.py"), format!("LIMIT = {i}\n")).unwrap();
        if i == 4 {
            std::fs::write(src.join("extra.py"), "x = 1\n").unwrap();
        }
        let tree =
            crate::timeline::snapshot::take_kept(&root, &src, "t", &format!("refs/drgnx/test/{i}"))
                .unwrap();
        out.push(Candidate {
            id: format!("s{i}"),
            kind: if i % 2 == 0 {
                "save".into()
            } else {
                "agent_step".into()
            },
            at: f64::from(i),
            label: format!("state {i}"),
            author: Some(json!({"user": 1})),
            session: None,
            step: (i % 2 == 1).then(|| format!("step-{i}")),
            decision: (i == 5).then(|| "dec-5".to_owned()),
            record: Some(i as i64 + 1),
            tree,
        });
    }
    (root, src, out)
}

#[derive(Default)]
struct Events(Mutex<Vec<Value>>);
impl bisect::Sink for Events {
    fn event(&self, v: Value) {
        self.0.lock().unwrap().push(v);
    }
}

async fn run(
    table: &[(&str, &str)],
    slots: usize,
) -> (Ending, Arc<Script>, Arc<Events>, PathBuf, tempfile::TempDir) {
    let d = tempfile::tempdir().unwrap();
    let (root, src, states) = history(d.path());
    let work = d.path().join("bisect");
    let script = Script::new(table);
    let events = Arc::new(Events::default());
    let b = Bisect::new(
        "b1".into(),
        states,
        Stage::new(root, src, work.clone()),
        script.clone(),
        events.clone(),
        slots,
    );
    let ending = b.run().await;
    (ending, script, events, work, d)
}

const NINE: [(&str, &str); 9] = [
    ("s0", "g"),
    ("s1", "g"),
    ("s2", "s"),
    ("s3", "g"),
    ("s4", "g"),
    ("s5", "b"),
    ("s6", "b"),
    ("s7", "b"),
    ("s8", "b"),
];

#[tokio::test]
async fn nine_states_one_bad_step_one_that_does_not_build() {
    let (ending, script, events, work, _d) = run(&NINE, 3).await;
    let Ending::Found(r) = ending else {
        panic!("{ending:?}")
    };
    assert_eq!(r.first_bad.id, "s5");
    assert_eq!(r.first_bad.decision.as_deref(), Some("dec-5"));
    assert!(r.flaky.is_empty());
    // the good state was re-checked first
    let runs = script.runs.lock().unwrap().clone();
    assert_eq!(runs[0].1, "s0");
    // one folder per slot, reused: restored by delta, never one per state
    let mut dirs: Vec<PathBuf> = runs.iter().map(|(d, _)| d.clone()).collect();
    dirs.sort();
    dirs.dedup();
    assert!(dirs.len() <= 3, "{dirs:?}");
    assert!(dirs.iter().all(|d| d.starts_with(&work)));
    // a slot holds the files of the last state it ran, nothing stale
    for (dir, state) in runs.iter().rev().take(1) {
        let app = std::fs::read_to_string(dir.join("app.py")).unwrap();
        assert_eq!(app, format!("LIMIT = {}\n", &state[1..]));
    }
    // the card's events: the estimate first, a dot per finished run, the result last
    let ev = events.0.lock().unwrap().clone();
    assert_eq!(ev[0]["state"], "checking-good");
    assert!(ev[0]["estimate"]["runs"].as_u64().unwrap() >= 3);
    assert!(ev.iter().any(|e| {
        e["dots"]
            .as_array()
            .is_some_and(|d| d.iter().any(|x| x["outcome"] == "skip"))
    }));
    assert_eq!(ev.last().unwrap()["state"], "found");
    assert_eq!(ev.last().unwrap()["result"]["first_bad"]["id"], "s5");
}

#[tokio::test]
async fn a_good_state_that_fails_asks_for_another() {
    let mut t = NINE;
    t[0] = ("s0", "b");
    let (ending, script, events, _w, _d) = run(&t, 3).await;
    assert!(matches!(ending, Ending::NeedsGood(_)), "{ending:?}");
    // nothing else ran
    assert_eq!(script.runs.lock().unwrap().len(), 1);
    assert_eq!(
        events.0.lock().unwrap().last().unwrap()["state"],
        "needs-good"
    );
}

#[tokio::test]
async fn a_predicate_that_disagrees_with_itself_is_reported_flaky() {
    let mut t = NINE;
    t[5] = ("s5", "bg"); // bad, then good on the confirming run
    let (ending, _s, _e, _w, _d) = run(&t, 1).await;
    let Ending::Found(r) = ending else {
        panic!("{ending:?}")
    };
    assert_eq!(r.flaky, vec!["s5".to_owned()]);
}

#[tokio::test]
async fn cancel_stops_the_runs() {
    let d = tempfile::tempdir().unwrap();
    let (root, src, states) = history(d.path());
    let hold = Arc::new(tokio::sync::Notify::new());
    let script = Arc::new(Script {
        hold: Some(hold.clone()),
        ..Arc::try_unwrap(Script::new(&NINE)).ok().unwrap()
    });
    let b = Bisect::new(
        "b2".into(),
        states,
        Stage::new(root, src, d.path().join("bisect")),
        script.clone(),
        Arc::new(Events::default()),
        3,
    );
    let cancel = b.canceller();
    let run = crate::clock::spawn("test:bisect", b.run());
    // the good state's run is held: cancel while it waits
    while script.runs.lock().unwrap().is_empty() {
        tokio::task::yield_now().await;
    }
    cancel.cancel();
    hold.notify_waiters();
    let ending = run.await.unwrap();
    assert!(matches!(ending, Ending::Cancelled), "{ending:?}");
    assert!(script.cancelled.load(Ordering::Relaxed));
}

#[tokio::test]
async fn narrowing_a_step_of_several_hunks_on_real_trees() {
    let d = tempfile::tempdir().unwrap();
    let (root, src) = (d.path().join("cp"), d.path().join("src"));
    std::fs::create_dir_all(&src).unwrap();
    std::fs::write(
        src.join("a.py"),
        "a = 1\nb = 2\nc = 3\nd = 4\ne = 5\nf = 6\ng = 7\nh = 8\n",
    )
    .unwrap();
    std::fs::write(src.join("b.py"), "z = 0\n").unwrap();
    let good = crate::timeline::snapshot::take_kept(&root, &src, "t", "refs/drgnx/test/g").unwrap();
    // three hunks: two in a.py, one in b.py; only `LIMIT` in b.py breaks it
    std::fs::write(
        src.join("a.py"),
        "a = 10\nb = 2\nc = 3\nd = 4\ne = 5\nf = 6\ng = 70\nh = 8\n",
    )
    .unwrap();
    std::fs::write(src.join("b.py"), "z = 0\nLIMIT = 0\n").unwrap();
    let bad = crate::timeline::snapshot::take_kept(&root, &src, "t", "refs/drgnx/test/b").unwrap();
    let stage = Stage::new(root, src, d.path().join("bisect"));
    let hunks = stage.hunks(&good, &bad).unwrap();
    assert_eq!(hunks.len(), 3);
    let picked = bisect::narrow(&stage, &good, &hunks, |dir: PathBuf| {
        let b = std::fs::read_to_string(dir.join("b.py")).unwrap_or_default();
        Box::pin(async move {
            if b.contains("LIMIT") {
                Outcome::Bad
            } else {
                Outcome::Good
            }
        }) as BoxFut<'static, Outcome>
    })
    .await;
    assert_eq!(picked.len(), 1);
    assert_eq!(hunks[picked[0]].path, "b.py");
}
