//! Bisect over the edit history (spec §19.6): which change broke it.  The states are the project between a good state
//! and now (agent steps, saves, launch snapshots, commits), each a tree in the shadow repository of a staging folder
//! (`bisect_wire` makes them).  A [`Bisect`] re-checks the good state first, then runs the predicate over the states
//! in slots: each slot keeps **one** folder, restored by delta between states (`timeline::snapshot::restore_into`).
//! The search is [`Search`] (k-section, `git bisect run`'s meanings: a state that does not build or start is skipped);
//! the first bad state and the last good one are run a second time, and a disagreement is reported as flaky.  A first
//! bad state of several hunks can be narrowed to the hunks that matter ([`narrow`], delta debugging).

use super::BoxFut;
use serde::Serialize;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::sync::Notify;

/// The slot number of narrowing's own folder (`narrow`).
const NARROW: usize = usize::MAX;

/// The slots a bisect runs in by default.
pub const SLOTS: usize = 3;
/// The most states a bisect takes (the newest when there are more).
pub const STATES_MAX: usize = 512;

/// What a predicate said of a state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    Good,
    Bad,
    /// It could not be judged (it does not build or start, or it could not be set up): why.
    Skip(String),
}

impl Outcome {
    pub fn name(&self) -> &'static str {
        match self {
            Outcome::Good => "good",
            Outcome::Bad => "bad",
            Outcome::Skip(_) => "skip",
        }
    }

    /// A run's exit code read as `git bisect run` reads it: 0 good, 125 skip, 1–127 bad; a signal or a code past 127
    /// (a time box, a crash of the runner) is a skip.
    pub fn of_exit(code: Option<i32>) -> Outcome {
        match code {
            Some(0) => Outcome::Good,
            Some(125) => Outcome::Skip("the predicate said skip (125)".into()),
            Some(1..=127) => Outcome::Bad,
            Some(c) => Outcome::Skip(format!("ended with {c}")),
            None => Outcome::Skip("ended without an exit code".into()),
        }
    }
}

/// The search over states `0..n`: 0 is the good state (re-checked before the search), `n - 1` the bad one (now).
#[derive(Debug)]
pub struct Search {
    good: usize,
    bad: usize,
    first: Vec<Option<Outcome>>,
}

impl Search {
    pub fn new(n: usize) -> Search {
        let mut first = vec![None; n.max(2)];
        first[0] = Some(Outcome::Good);
        let last = first.len() - 1;
        first[last] = Some(Outcome::Bad);
        Search {
            good: 0,
            bad: last,
            first,
        }
    }

    /// The states to run next in SLOTS slots, RUNNING already running: the points that cut the range between the last
    /// good and the first bad into equal parts, each moved to the nearest state not yet run.
    pub fn next(&self, slots: usize, running: &[usize]) -> Vec<usize> {
        let open: Vec<usize> = (self.good + 1..self.bad)
            .filter(|i| self.first[*i].is_none() && !running.contains(i))
            .collect();
        let inside = running
            .iter()
            .filter(|r| (self.good + 1..self.bad).contains(*r))
            .count();
        let k = slots.saturating_sub(inside).min(open.len());
        let mut out: Vec<usize> = Vec::new();
        let span = (self.bad - self.good) as f64;
        for j in 1..=k {
            let target = self.good as f64 + span * j as f64 / (k + 1) as f64;
            if let Some(&pick) = open.iter().filter(|i| !out.contains(i)).min_by(|a, b| {
                let (da, db) = ((**a as f64 - target).abs(), (**b as f64 - target).abs());
                da.total_cmp(&db).then(a.cmp(b))
            }) {
                out.push(pick);
            }
        }
        out.sort_unstable();
        out
    }

    /// State I's outcome O (its first run).
    pub fn record(&mut self, i: usize, o: Outcome) {
        if self.first[i].is_none() {
            self.first[i] = Some(o.clone());
        }
        match o {
            Outcome::Good if i > self.good && i < self.bad => self.good = i,
            Outcome::Bad if i > self.good && i < self.bad => self.bad = i,
            _ => {}
        }
    }

    /// Whether nothing is left to run between the last good state and the first bad one, RUNNING running.
    pub fn done(&self, running: &[usize]) -> bool {
        self.next(1, running).is_empty()
            && !running
                .iter()
                .any(|r| (self.good + 1..self.bad).contains(r))
    }

    pub fn first_bad(&self) -> usize {
        self.bad
    }

    pub fn last_good(&self) -> usize {
        self.good
    }

    /// The skipped states between the last good one and the first bad one: the first bad is one of these or it.
    pub fn skipped(&self) -> Vec<usize> {
        (self.good + 1..self.bad)
            .filter(|i| matches!(self.first[*i], Some(Outcome::Skip(_))))
            .collect()
    }

    /// Each state's first outcome, for the card's dots.
    pub fn outcomes(&self) -> &[Option<Outcome>] {
        &self.first
    }
}

/// A state the bisect can run: what it is, who made it, and its tree in the staging folder's shadow repository.
#[derive(Clone, Debug, Serialize)]
pub struct Candidate {
    pub id: String,
    /// `agent_step`, `save`, `launch`, `commit`, `good` or `now`.
    pub kind: String,
    pub at: f64,
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<Value>,
    /// The agent session whose step it is (Revert Step, Ask the Agent).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub step: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub decision: Option<String>,
    /// The edit history's record (an agent step, a save): Show Step and Revert Step act on it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub record: Option<i64>,
    #[serde(skip)]
    pub tree: String,
}

/// What a bisect found.
#[derive(Clone, Debug, Serialize)]
pub struct Found {
    pub first_bad: Candidate,
    pub last_good: Candidate,
    /// States between them that could not be judged: the first bad is one of these or `first_bad`.
    pub skipped: Vec<String>,
    /// States whose two runs disagreed.
    pub flaky: Vec<String>,
    pub runs: usize,
    /// The change from the last good state to the first bad one (Show Step), at most [`DIFF_MAX`] bytes.
    pub diff: String,
}

/// The most bytes of a result's diff.
pub const DIFF_MAX: usize = 256 << 10;

/// How a bisect ended.
#[derive(Clone, Debug)]
pub enum Ending {
    Found(Box<Found>),
    /// The good state fails too (or cannot be judged): the user picks another.  Why.
    NeedsGood(String),
    Cancelled,
    Failed(String),
}

/// Runs the predicate in a folder.
pub trait Prober: Send + Sync {
    fn run(&self, dir: &Path) -> BoxFut<'static, Outcome>;
    /// Stop every run (a cancel).
    fn cancel(&self);
}

/// Where a bisect's events go (`debug-bisect`).
pub trait Sink: Send + Sync {
    fn event(&self, v: Value);
}

/// A hunk of a step: its file, the file's diff header and the hunk itself (`git diff -U0`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hunk {
    pub path: String,
    pub header: String,
    pub body: String,
}

/// The trees and the slots' folders: ROOT the checkpoints folder, SOURCE the staging folder whose shadow repository
/// holds the states' trees, WORK the bisect's own folder (`slot-N` in it).
pub struct Stage {
    pub root: PathBuf,
    pub source: PathBuf,
    pub work: PathBuf,
}

impl Stage {
    pub fn new(root: PathBuf, source: PathBuf, work: PathBuf) -> Stage {
        Stage { root, source, work }
    }

    fn repo(&self) -> PathBuf {
        crate::timeline::snapshot::repo_of(&self.root, &self.source)
    }

    /// Slot SLOT's folder holding TREE: made the first time, then changed by delta (only what differs is written).
    /// Blocking.
    pub fn restore(&self, slot: usize, tree: &str) -> Result<PathBuf, String> {
        let dir = match slot {
            NARROW => self.work.join("narrow"),
            s => self.work.join(format!("slot-{s}")),
        };
        std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        crate::timeline::snapshot::restore_into(&self.root, &self.source, &dir, tree, None, &[])?;
        Ok(dir)
    }

    /// The slots' folders removed (the trees stay, for narrowing).  Blocking.
    pub fn drop_slots(&self) {
        let Ok(rd) = std::fs::read_dir(&self.work) else {
            return;
        };
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with("slot-") || name == "narrow" {
                let _ = std::fs::remove_dir_all(e.path());
            }
        }
    }

    /// The diff from tree GOOD to tree BAD, cut at [`DIFF_MAX`] bytes.  Blocking.
    pub fn diff(&self, good: &str, bad: &str) -> Result<String, String> {
        let mut d = crate::timeline::snapshot::run_git(
            &self.repo(),
            None,
            None,
            &["diff", "--no-color", "--no-ext-diff", good, bad],
        )?;
        if d.len() > DIFF_MAX {
            let mut cut = DIFF_MAX;
            while !d.is_char_boundary(cut) {
                cut -= 1;
            }
            d.truncate(cut);
        }
        Ok(d)
    }

    /// The hunks from tree GOOD to tree BAD. Blocking.
    pub fn hunks(&self, good: &str, bad: &str) -> Result<Vec<Hunk>, String> {
        let diff = crate::timeline::snapshot::run_git(
            &self.repo(),
            None,
            None,
            &[
                "diff",
                "--no-color",
                "--no-renames",
                "--no-ext-diff",
                "-U0",
                good,
                bad,
            ],
        )?;
        Ok(parse_hunks(&diff))
    }

    /// Tree GOOD with the hunks HUNKS (a subset of [`Stage::hunks`]) applied: the new tree.  Blocking.
    pub fn with_hunks(&self, good: &str, hunks: &[&Hunk]) -> Result<String, String> {
        let repo = self.repo();
        let tmp = self.work.join("narrow-index");
        std::fs::create_dir_all(&tmp).map_err(|e| format!("{}: {e}", tmp.display()))?;
        let (index, patch) = (tmp.join("index"), tmp.join("patch"));
        let _ = std::fs::remove_file(&index);
        let mut text = String::new();
        let mut last: Option<&str> = None;
        for h in hunks {
            if last != Some(h.header.as_str()) {
                text.push_str(&h.header);
                last = Some(h.header.as_str());
            }
            text.push_str(&h.body);
        }
        std::fs::write(&patch, text).map_err(|e| e.to_string())?;
        let git =
            |args: &[&str]| crate::timeline::snapshot::run_git(&repo, None, Some(&index), args);
        git(&["read-tree", good])?;
        let p = patch.to_string_lossy().into_owned();
        git(&[
            "apply",
            "--cached",
            "--unidiff-zero",
            "--whitespace=nowarn",
            &p,
        ])?;
        let tree = git(&["write-tree"]);
        let _ = std::fs::remove_dir_all(&tmp);
        tree
    }
}

/// `git diff -U0`'s text as hunks, each with its file's header.
pub fn parse_hunks(diff: &str) -> Vec<Hunk> {
    let mut out = Vec::new();
    let (mut header, mut path, mut body) = (String::new(), String::new(), String::new());
    let mut in_header = false;
    let flush = |out: &mut Vec<Hunk>, header: &str, path: &str, body: &mut String| {
        if !body.is_empty() {
            out.push(Hunk {
                path: path.to_owned(),
                header: header.to_owned(),
                body: std::mem::take(body),
            });
        }
    };
    for line in diff.split_inclusive('\n') {
        let line = if line.ends_with('\n') {
            line.to_owned()
        } else {
            format!("{line}\n")
        };
        if line.starts_with("diff --git ") {
            flush(&mut out, &header, &path, &mut body);
            header = line.clone();
            path = line
                .trim_end()
                .rsplit_once(" b/")
                .map(|(_, p)| p.to_owned())
                .unwrap_or_default();
            in_header = true;
        } else if line.starts_with("@@") {
            flush(&mut out, &header, &path, &mut body);
            in_header = false;
            body.push_str(&line);
        } else if in_header {
            header.push_str(&line);
        } else {
            body.push_str(&line);
        }
    }
    flush(&mut out, &header, &path, &mut body);
    out
}

/// Delta debugging (ddmin) over N parts: the smallest set (1-minimal) for which TEST says bad, the whole set being
/// bad.  A skip counts as not bad.
pub fn ddmin(n: usize, mut test: impl FnMut(&[usize]) -> Outcome) -> Vec<usize> {
    let mut set: Vec<usize> = (0..n).collect();
    let mut parts = 2usize;
    while set.len() >= 2 {
        let chunk = set.len().div_ceil(parts);
        let subsets: Vec<Vec<usize>> = set.chunks(chunk).map(<[usize]>::to_vec).collect();
        let mut reduced = false;
        for s in &subsets {
            if test(s) == Outcome::Bad {
                set = s.clone();
                parts = 2;
                reduced = true;
                break;
            }
        }
        if !reduced && subsets.len() > 2 {
            for s in &subsets {
                let rest: Vec<usize> = set.iter().copied().filter(|x| !s.contains(x)).collect();
                if test(&rest) == Outcome::Bad {
                    set = rest;
                    parts = (parts - 1).max(2);
                    reduced = true;
                    break;
                }
            }
        }
        if !reduced {
            if parts >= set.len() {
                break;
            }
            parts = (parts * 2).min(set.len());
        }
    }
    set
}

/// The hunks of GOOD → bad (HUNKS) that make it fail, by [`ddmin`]: each set tried is tree GOOD with those hunks,
/// restored into a narrowing folder of its own and run by RUN.
pub async fn narrow(
    stage: &Stage,
    good: &str,
    hunks: &[Hunk],
    run: impl Fn(PathBuf) -> BoxFut<'static, Outcome>,
) -> Vec<usize> {
    // ddmin is written over a sync test; its sets are asked one at a time, each answered by a run
    let mut asked: Vec<(Vec<usize>, Outcome)> = Vec::new();
    loop {
        let mut need: Option<Vec<usize>> = None;
        let got = ddmin(hunks.len(), |set| {
            match asked.iter().find(|(s, _)| s == set) {
                Some((_, o)) => o.clone(),
                None => {
                    if need.is_none() {
                        need = Some(set.to_vec());
                    }
                    Outcome::Skip("not run yet".into())
                }
            }
        });
        let Some(set) = need else {
            return got;
        };
        let picked: Vec<&Hunk> = set.iter().map(|i| &hunks[*i]).collect();
        let tree = stage.with_hunks(good, &picked);
        let o = match tree.and_then(|t| stage.restore(NARROW, &t)) {
            Ok(dir) => run(dir).await,
            Err(e) => Outcome::Skip(e),
        };
        asked.push((set, o));
    }
}

/// Stops a running bisect.
#[derive(Clone)]
pub struct Canceller {
    flag: Arc<AtomicBool>,
    wake: Arc<Notify>,
}

impl Canceller {
    pub fn cancel(&self) {
        self.flag.store(true, Ordering::SeqCst);
        self.wake.notify_waiters();
    }
}

/// One bisect: its states, its stage, its predicate, its events.
pub struct Bisect {
    id: String,
    states: Vec<Candidate>,
    stage: Arc<Stage>,
    prober: Arc<dyn Prober>,
    sink: Arc<dyn Sink>,
    slots: usize,
    cancel: Canceller,
}

impl Bisect {
    pub fn new(
        id: String,
        states: Vec<Candidate>,
        stage: Stage,
        prober: Arc<dyn Prober>,
        sink: Arc<dyn Sink>,
        slots: usize,
    ) -> Bisect {
        Bisect {
            id,
            states,
            stage: Arc::new(stage),
            prober,
            sink,
            slots: slots.clamp(1, 8),
            cancel: Canceller {
                flag: Arc::new(AtomicBool::new(false)),
                wake: Arc::new(Notify::new()),
            },
        }
    }

    pub fn stage(&self) -> Arc<Stage> {
        self.stage.clone()
    }

    pub fn canceller(&self) -> Canceller {
        self.cancel.clone()
    }

    fn cancelled(&self) -> bool {
        self.cancel.flag.load(Ordering::SeqCst)
    }

    /// The runs it will take: the good state's, log2 of the states, the two confirming runs.
    pub fn estimate(&self) -> Value {
        let n = self.states.len().max(2) as f64;
        let search = (n - 1.0).log2().ceil() as u64;
        json!({"runs": 1 + search + 2, "slots": self.slots, "states": self.states.len()})
    }

    fn event(&self, state: &str, search: Option<&Search>, extra: Value) {
        let dots: Vec<Value> = match search {
            Some(s) => s
                .outcomes()
                .iter()
                .enumerate()
                .map(|(i, o)| json!({"i": i, "id": self.states[i].id, "outcome": o.as_ref().map_or("", Outcome::name)}))
                .collect(),
            None => Vec::new(),
        };
        let mut v =
            json!({"bisect": self.id, "state": state, "dots": dots, "estimate": self.estimate()});
        if let (Value::Object(m), Value::Object(x)) = (&mut v, extra) {
            m.extend(x);
        }
        self.sink.event(v);
    }

    /// State I run in slot SLOT: restored, then the predicate (a setup that fails is a skip).
    fn run_in(&self, slot: usize, i: usize) -> BoxFut<'static, (usize, usize, Outcome)> {
        let (stage, prober, tree) = (
            self.stage.clone(),
            self.prober.clone(),
            self.states[i].tree.clone(),
        );
        Box::pin(async move {
            let dir = crate::clock::blocking(move || stage.restore(slot, &tree)).await;
            let o = match dir {
                Ok(Ok(d)) => prober.run(&d).await,
                Ok(Err(e)) => Outcome::Skip(format!("could not set it up: {e}")),
                Err(e) => Outcome::Skip(format!("could not set it up: {e}")),
            };
            (slot, i, o)
        })
    }

    /// Run it to its end.
    pub async fn run(self) -> Ending {
        let n = self.states.len();
        if n < 2 {
            return self.end(Ending::Failed(
                "a bisect needs a good state and a later one".into(),
            ));
        }
        // the good state, re-checked first
        self.event("checking-good", None, json!({}));
        let mut runs = 1usize;
        let good = tokio::select! {
            r = self.run_in(0, 0) => r.2,
            () = self.cancel.wake.notified() => Outcome::Skip("cancelled".into()),
        };
        if self.cancelled() {
            return self.end(Ending::Cancelled);
        }
        if good != Outcome::Good {
            let why = match good {
                Outcome::Skip(w) => format!("the good state could not be judged: {w}"),
                _ => "the good state fails too".into(),
            };
            return self.end(Ending::NeedsGood(why));
        }
        let mut search = Search::new(n);
        let mut free: Vec<usize> = (0..self.slots).collect();
        let mut running: Vec<usize> = Vec::new();
        let mut set = tokio::task::JoinSet::new();
        self.event("running", Some(&search), json!({}));
        loop {
            if self.cancelled() {
                return self.end(Ending::Cancelled);
            }
            for i in search.next(free.len(), &running) {
                let slot = free.pop().unwrap_or(0);
                running.push(i);
                set.spawn(self.run_in(slot, i));
            }
            if search.done(&running) && running.is_empty() {
                break;
            }
            let joined = tokio::select! {
                j = set.join_next() => j,
                () = self.cancel.wake.notified() => None,
            };
            let Some(Ok((slot, i, o))) = joined else {
                if self.cancelled() {
                    return self.end(Ending::Cancelled);
                }
                return self.end(Ending::Failed("a run was lost".into()));
            };
            runs += 1;
            free.push(slot);
            running.retain(|r| *r != i);
            search.record(i, o);
            self.event("running", Some(&search), json!({}));
        }
        // the two that decide it, once more: a disagreement is flaky
        let (bad, last_good) = (search.first_bad(), search.last_good());
        let mut flaky = Vec::new();
        for (i, want) in [(bad, Outcome::Bad), (last_good, Outcome::Good)] {
            let again = tokio::select! {
                r = self.run_in(0, i) => r.2,
                () = self.cancel.wake.notified() => Outcome::Skip("cancelled".into()),
            };
            if self.cancelled() {
                return self.end(Ending::Cancelled);
            }
            runs += 1;
            if again != want && !matches!(again, Outcome::Skip(_)) {
                flaky.push(self.states[i].id.clone());
            }
        }
        let (st, g, b) = (
            self.stage.clone(),
            self.states[last_good].tree.clone(),
            self.states[bad].tree.clone(),
        );
        let diff = crate::clock::blocking(move || st.diff(&g, &b))
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or_default();
        let found = Found {
            first_bad: self.states[bad].clone(),
            last_good: self.states[last_good].clone(),
            skipped: search
                .skipped()
                .iter()
                .map(|i| self.states[*i].id.clone())
                .collect(),
            flaky,
            runs,
            diff,
        };
        self.event("found", Some(&search), json!({"result": found}));
        Ending::Found(Box::new(found))
    }

    fn end(&self, e: Ending) -> Ending {
        match &e {
            Ending::Cancelled => {
                self.prober.cancel();
                self.event("cancelled", None, json!({}));
            }
            Ending::NeedsGood(why) => self.event("needs-good", None, json!({"why": why})),
            Ending::Failed(why) => self.event("failed", None, json!({"why": why})),
            Ending::Found(_) => {}
        }
        e
    }
}
