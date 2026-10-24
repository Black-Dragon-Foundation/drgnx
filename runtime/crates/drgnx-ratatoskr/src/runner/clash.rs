//! Clashes (Task 18; `docs/develop/coordination.md`, "Clashes"): the five rules (contradiction, proposed,
//! against-decision, stale, overlap) as `clash::scan(run, decisions, diffs) -> Vec<Clash>`, each carded once; the
//! Lisp `drgnx-job-clash.el` is the oracle.
//!
//! Pure: no git, no store. The caller (the plan runner) builds [`RunState`] from its tables and [`DiffIndex`] from
//! `HubGit::diff_hashes`, remembers each returned [`Clash::key`] in `RunState::carded`, and starts a reviewer for
//! every new clash through [`ReviewerHook`].

use runstav::methods::coord::Decision;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};

/// A clash whose diff is longer than this many lines gets a long review (`drgnx-job-clash-long-lines`).
pub const LONG_LINES: u32 = 200;

/// One file of a task's branch against the job's branch: the content hash and the changed line ranges
/// (inclusive start, exclusive end).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FileDiff {
    pub hash: String,
    pub ranges: Vec<(u32, u32)>,
}

/// Task id → path → what its branch changes there.  Tests build it directly; the runner fills it from
/// `HubGit::diff_hashes` (Task 17).
pub type DiffIndex = BTreeMap<String, BTreeMap<String, FileDiff>>;

/// A task of the run as the clash rules see it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunTask {
    pub id: String,
    pub n: i64,
    /// `claimed`, `running`, `needs-input`, `in-review`, ...
    pub status: String,
    pub agent: Option<String>,
    /// The task branch's head (keys the against-decision card: looked at once per head).
    pub head: Option<String>,
}

/// An agent session of the run, for the stale rule.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunSession {
    pub id: String,
    pub task: Option<String>,
    pub exited: bool,
    /// Coordination writes held in a row (`held:AGENT`).
    pub held: u32,
}

/// What a scan needs of a plan run.
#[derive(Clone, Debug, Default)]
pub struct RunState {
    /// `running` or `paused`: any other status scans nothing.
    pub status: String,
    pub tasks: Vec<RunTask>,
    pub sessions: Vec<RunSession>,
    /// Keys of clashes already carded (the job's `:clashes`).
    pub carded: BTreeSet<String>,
    /// Subjects (normalised) of settled clash cards: a clash about one again is long.
    pub settled_subjects: BTreeSet<String>,
    /// Tasks with an open clash card (their review waits).
    pub open_clash_tasks: BTreeSet<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Rule {
    Contradiction,
    Proposed,
    AgainstDecision,
    Stale,
    Overlap,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Size {
    Long,
    Short,
}

/// One side of a clash card.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Side {
    pub label: String,
    pub text: String,
    pub decision: Option<i64>,
    pub agent: Option<String>,
    pub task: Option<String>,
    pub reason: Option<String>,
}

/// A clash to card, once per `key`.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Clash {
    pub key: String,
    pub rule: Rule,
    pub subject: String,
    pub title: String,
    pub sides: Vec<Side>,
    /// The task the card is about.
    pub task: Option<String>,
    pub files: Vec<String>,
    pub lines: u32,
    pub size: Size,
    /// The task's review waits (against-decision only; overlap is advisory, stale is a `stalled` card).
    pub blocks_review: bool,
}

/// A subject as compared: lower case, spaces collapsed, trimmed.
pub fn subject(s: &str) -> String {
    s.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

fn paths(v: &str) -> Vec<&str> {
    v.split(|c: char| c == ',' || c.is_whitespace())
        .filter(|p| !p.is_empty())
        .collect()
}

fn glob(p: &[u8], s: &[u8]) -> bool {
    match p.first() {
        None => s.is_empty(),
        Some(b'*') => (0..=s.len()).any(|i| glob(&p[1..], &s[i..])),
        Some(b'?') => !s.is_empty() && glob(&p[1..], &s[1..]),
        Some(c) => s.first() == Some(c) && glob(&p[1..], &s[1..]),
    }
}

/// Does `pattern` cover `path`: a directory (with or without `/`), a file, or a glob (`*`, `?`; a glob with no `/`
/// also matches the file name alone).
pub fn covers(path: &str, pattern: &str) -> bool {
    if pattern.contains(['*', '?']) {
        glob(pattern.as_bytes(), path.as_bytes())
            || (!pattern.contains('/')
                && glob(
                    pattern.as_bytes(),
                    path.rsplit('/').next().unwrap_or(path).as_bytes(),
                ))
    } else {
        let dir = pattern.trim_end_matches('/');
        path == dir || path.strip_prefix(dir).is_some_and(|r| r.starts_with('/'))
    }
}

fn one_line(s: &str) -> String {
    s.split(['\n', '\r'])
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

fn side(label: &str, d: &Decision, text: Option<String>) -> Side {
    let text = text.unwrap_or_else(|| {
        format!(
            "#{} {}: {}",
            d.n,
            d.kind.as_deref().unwrap_or(""),
            d.subject.as_deref().unwrap_or("")
        )
    });
    Side {
        label: label.into(),
        text: one_line(&text),
        decision: Some(d.n),
        agent: d.author.clone(),
        task: d.task.clone(),
        reason: d.reason.clone(),
    }
}

fn live(decisions: &[Decision]) -> Vec<&Decision> {
    decisions
        .iter()
        .filter(|d| matches!(d.status.as_deref(), Some("current" | "proposed")))
        .collect()
}

fn kind_is(d: &Decision, k: &str) -> bool {
    d.kind.as_deref() == Some(k)
}

fn subj(d: &Decision) -> &str {
    d.subject.as_deref().unwrap_or("")
}

fn is_user(d: &Decision) -> bool {
    d.author.as_deref() == Some("user")
}

struct Ctx<'a> {
    run: &'a RunState,
    out: Vec<Clash>,
    keys: BTreeSet<String>,
}

impl Ctx<'_> {
    fn size(&self, rule: Rule, subj_: &str, lines: u32) -> Size {
        if rule == Rule::AgainstDecision
            || lines > LONG_LINES
            || self.run.settled_subjects.contains(&subject(subj_))
        {
            Size::Long
        } else {
            Size::Short
        }
    }

    /// Card once per key: not when the run has carded it, nor this scan.
    fn card(&mut self, mut c: Clash) -> bool {
        if self.run.carded.contains(&c.key) || !self.keys.insert(c.key.clone()) {
            return false;
        }
        c.size = self.size(c.rule, &c.subject, c.lines);
        c.subject = subject(&c.subject);
        self.out.push(c);
        true
    }
}

fn blank(key: String, rule: Rule, subj_: &str, title: String, sides: Vec<Side>) -> Clash {
    Clash {
        key,
        rule,
        subject: subj_.into(),
        title,
        sides,
        task: None,
        files: vec![],
        lines: 0,
        size: Size::Short,
        blocks_review: false,
    }
}

/// The decisions a user's decision overrides at once (no card): of a build / won't-build pair on one subject, the
/// agent's side, once however many of the user's decisions it contradicts.  The caller records a `replaces` of each.
pub fn user_wins(decisions: &[Decision]) -> Vec<i64> {
    contradictions(decisions, &mut Vec::new()).0
}

/// (replaced numbers, numbers in a carded contradiction); pushes the cards onto `cards`.
fn contradictions(
    decisions: &[Decision],
    cards: &mut Vec<(i64, i64, String, Vec<Side>)>,
) -> (Vec<i64>, Vec<i64>) {
    let ds = live(decisions);
    let mut wont: BTreeMap<String, Vec<&Decision>> = BTreeMap::new();
    for w in ds.iter().filter(|d| kind_is(d, "wont-build")) {
        wont.entry(subject(subj(w))).or_default().push(w);
    }
    let (mut replaced, mut carded) = (Vec::new(), Vec::new());
    for b in ds.iter().filter(|d| kind_is(d, "build")) {
        for w in wont.get(&subject(subj(b))).into_iter().flatten() {
            let (bu, wu) = (is_user(b), is_user(w));
            if bu && wu {
                continue; // the user's own two: theirs to sort out
            }
            if bu || wu {
                let other = if bu { w } else { b };
                if !replaced.contains(&other.n) {
                    replaced.push(other.n);
                }
            } else if replaced.contains(&b.n) || replaced.contains(&w.n) {
            } else {
                carded.push(b.n);
                carded.push(w.n);
                cards.push((
                    b.n,
                    w.n,
                    subj(b).to_string(),
                    vec![side("A", b, None), side("B", w, None)],
                ));
            }
        }
    }
    (replaced, carded)
}

/// All five rules over the run.  Returns the clashes not carded yet (keys not in `run.carded`).  A run that is not
/// `running` or `paused` has none.  The against-decision and overlap rules look at tasks `in-review`.
pub fn scan(run: &RunState, decisions: &[Decision], diffs: &DiffIndex) -> Vec<Clash> {
    if !matches!(run.status.as_str(), "running" | "paused") {
        return vec![];
    }
    let mut cx = Ctx {
        run,
        out: vec![],
        keys: BTreeSet::new(),
    };
    // contradiction, then proposed (decisions in a contradiction have that card only)
    let mut cards = Vec::new();
    let (_, in_contradiction) = contradictions(decisions, &mut cards);
    for (b, w, s, sides) in cards {
        let key = format!("contradiction:{}:{}", b.min(w), b.max(w));
        cx.card(blank(
            key,
            Rule::Contradiction,
            &s,
            format!("build or not: {s}"),
            sides,
        ));
    }
    for d in live(decisions) {
        if d.status.as_deref() == Some("proposed") && !in_contradiction.contains(&d.n) {
            let who = d.author.as_deref().unwrap_or("");
            let kind = d.kind.as_deref().unwrap_or("");
            let a = side(
                "A",
                d,
                Some(format!("record it: #{} {kind}: {}", d.n, subj(d))),
            );
            let b = Side {
                label: "B".into(),
                text: "leave it out".into(),
                decision: Some(d.n),
                agent: None,
                task: None,
                reason: None,
            };
            cx.card(blank(
                format!("proposed:{}", d.n),
                Rule::Proposed,
                subj(d),
                format!("{who} proposes: {kind} {}", subj(d)),
                vec![a, b],
            ));
        }
    }
    // stale: two held writes in a row
    for s in run.sessions.iter().filter(|s| !s.exited && s.held >= 2) {
        let mut c = blank(
            format!("stale:{}:{}", s.id, s.held),
            Rule::Stale,
            "",
            "its coordination writes are held: it keeps acting on an old decision log".into(),
            vec![],
        );
        c.task = s.task.clone();
        cx.card(c);
    }
    // against-decision and overlap, per task in review
    for t in run.tasks.iter().filter(|t| t.status == "in-review") {
        let empty = BTreeMap::new();
        let files: Vec<&String> = diffs.get(&t.id).unwrap_or(&empty).keys().collect();
        if files.is_empty() {
            continue;
        }
        for o in run.tasks.iter().filter(|o| {
            o.n != t.n
                && matches!(
                    o.status.as_str(),
                    "claimed" | "running" | "needs-input" | "in-review"
                )
        }) {
            let theirs = diffs.get(&o.id);
            let same: Vec<String> = files
                .iter()
                .filter(|f| theirs.is_some_and(|m| m.contains_key(**f)))
                .map(|f| (*f).clone())
                .collect();
            if !same.is_empty() {
                let mut c = blank(
                    format!("overlap:{}:{}", t.n.min(o.n), t.n.max(o.n)),
                    Rule::Overlap,
                    "",
                    format!(
                        "Task {} and Task {} both change {}",
                        t.n,
                        o.n,
                        same.join(", ")
                    ),
                    vec![],
                );
                c.task = Some(t.id.clone());
                c.files = same;
                cx.card(c);
            }
        }
        let hit = live(decisions)
            .into_iter()
            .filter(|d| kind_is(d, "wont-build") && d.status.as_deref() == Some("current"))
            .filter_map(|d| {
                let pats = paths(d.paths.as_deref()?);
                let touched: Vec<String> = files
                    .iter()
                    .filter(|f| pats.iter().any(|p| covers(f, p)))
                    .map(|f| (*f).clone())
                    .collect();
                (!touched.is_empty()).then_some((d, touched))
            })
            .next();
        if let Some((d, touched)) = hit {
            let head = t.head.as_deref().unwrap_or("");
            let lines: u32 = diffs[&t.id]
                .values()
                .flat_map(|f| &f.ranges)
                .map(|(a, b)| b.saturating_sub(*a))
                .sum();
            let a = side(
                "A",
                d,
                Some(format!(
                    "the decision stands: #{} won't build {}",
                    d.n,
                    subj(d)
                )),
            );
            let b = Side {
                label: "B".into(),
                text: format!("the change stands (Task {})", t.n),
                decision: None,
                agent: t.agent.clone(),
                task: Some(t.id.clone()),
                reason: None,
            };
            let mut c = blank(
                format!("against:{}:{head}", t.id),
                Rule::AgainstDecision,
                subj(d),
                format!(
                    "Task {} changes what #{} says will not be built: {}",
                    t.n,
                    d.n,
                    touched.join(", ")
                ),
                vec![a, b],
            );
            c.task = Some(t.id.clone());
            c.files = touched;
            c.lines = lines;
            c.blocks_review = true;
            cx.card(c);
        }
    }
    cx.out
}

/// What the runner needs before it starts the review of a task.
#[derive(Clone, Debug, PartialEq)]
pub struct ReviewGate {
    /// New clashes to card (and remember by key) now.
    pub clashes: Vec<Clash>,
    /// The review waits: a new against-decision clash, or a clash card about the task is open.
    pub wait: bool,
}

/// The hook the plan runner calls before starting a task's reviewer
/// (`drgnx-job-before-review-functions`).
pub fn before_review(
    run: &RunState,
    decisions: &[Decision],
    diffs: &DiffIndex,
    task: &str,
) -> ReviewGate {
    let clashes: Vec<Clash> = scan(run, decisions, diffs)
        .into_iter()
        .filter(|c| c.task.as_deref() == Some(task))
        .collect();
    let wait = run.open_clash_tasks.contains(task) || clashes.iter().any(|c| c.blocks_review);
    ReviewGate { clashes, wait }
}

/// Starts the reviewer (role `review`, `review-long` for a long clash when it has a route) of a carded clash;
/// the runner implements it, [`start_reviewers`] drives it.
pub trait ReviewerHook {
    fn start(&mut self, clash: &Clash, long: bool);
}

/// Start a reviewer for each clash (a stale card is a `stalled` card: no reviewer).
pub fn start_reviewers(hook: &mut dyn ReviewerHook, clashes: &[Clash]) {
    for c in clashes
        .iter()
        .filter(|c| !matches!(c.rule, Rule::Stale | Rule::Overlap))
    {
        hook.start(c, c.size == Size::Long);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dec(n: i64, kind: &str, subj_: &str, author: &str, status: &str) -> Decision {
        Decision {
            n,
            kind: Some(kind.into()),
            subject: Some(subj_.into()),
            task: None,
            paths: None,
            reason: None,
            author: Some(author.into()),
            status: Some(status.into()),
            job: None,
            replaces: None,
            at: None,
            ver: None,
        }
    }

    fn task(id: &str, n: i64, status: &str) -> RunTask {
        RunTask {
            id: id.into(),
            n,
            status: status.into(),
            agent: Some("a".into()),
            head: Some(format!("h{n}")),
        }
    }

    fn run() -> RunState {
        RunState {
            status: "running".into(),
            ..Default::default()
        }
    }

    fn diff(task: &str, files: &[(&str, u32)]) -> DiffIndex {
        let mut m = DiffIndex::new();
        add(&mut m, task, files);
        m
    }

    fn add(m: &mut DiffIndex, task: &str, files: &[(&str, u32)]) {
        let e = m.entry(task.into()).or_default();
        for (p, n) in files {
            e.insert(
                (*p).into(),
                FileDiff {
                    hash: format!("x{p}"),
                    ranges: vec![(0, *n)],
                },
            );
        }
    }

    #[test]
    fn contradiction_of_two_agents_is_one_card_and_the_user_wins_at_once() {
        let ds = [
            dec(1, "build", " Dark  Mode ", "a", "proposed"),
            dec(2, "wont-build", "dark mode", "b", "current"),
        ];
        let cs = scan(&run(), &ds, &DiffIndex::new());
        assert_eq!(cs.len(), 1);
        assert_eq!(
            (cs[0].rule, cs[0].key.as_str()),
            (Rule::Contradiction, "contradiction:1:2")
        );
        assert_eq!(cs[0].sides.len(), 2);
        assert_eq!(cs[0].title, "build or not:  Dark  Mode ");
        // the user's side stands: no card, the agent's decision is replaced, once for two user decisions
        let ds = [
            dec(1, "build", "x", "a", "current"),
            dec(2, "wont-build", "x", "user", "current"),
            dec(3, "wont-build", "X", "user", "current"),
        ];
        assert!(scan(&run(), &ds, &DiffIndex::new()).is_empty());
        assert_eq!(user_wins(&ds), vec![1]);
        // the user's own two are theirs to sort out
        let ds = [
            dec(1, "build", "x", "user", "current"),
            dec(2, "wont-build", "x", "user", "current"),
        ];
        assert!(scan(&run(), &ds, &DiffIndex::new()).is_empty() && user_wins(&ds).is_empty());
    }

    #[test]
    fn proposed_decision_is_a_card_unless_it_is_in_a_contradiction() {
        let ds = [dec(5, "build", "cache", "a", "proposed")];
        let cs = scan(&run(), &ds, &DiffIndex::new());
        assert_eq!(
            (cs.len(), cs[0].rule, cs[0].key.as_str()),
            (1, Rule::Proposed, "proposed:5")
        );
        assert_eq!(cs[0].title, "a proposes: build cache");
        assert_eq!(cs[0].sides[0].text, "record it: #5 build: cache");
        assert_eq!(cs[0].sides[1].text, "leave it out");
        let ds = [
            dec(5, "build", "cache", "a", "proposed"),
            dec(6, "wont-build", "cache", "b", "current"),
        ];
        let cs = scan(&run(), &ds, &DiffIndex::new());
        assert_eq!(
            cs.iter().map(|c| c.rule).collect::<Vec<_>>(),
            vec![Rule::Contradiction]
        );
    }

    #[test]
    fn against_decision_waits_and_is_long() {
        let mut d = dec(1, "wont-build", "vendored copy", "user", "current");
        d.paths = Some("vendor/, docs/*.tmp  src/gen.rs".into());
        let mut r = run();
        r.tasks = vec![task("t3", 3, "in-review")];
        let diffs = diff("t3", &[("vendor/lib/a.c", 10), ("src/ok.rs", 5)]);
        let cs = scan(&r, std::slice::from_ref(&d), &diffs);
        assert_eq!(cs.len(), 1);
        let c = &cs[0];
        assert_eq!(
            (c.rule, c.size, c.blocks_review),
            (Rule::AgainstDecision, Size::Long, true)
        );
        assert_eq!(
            (c.files.clone(), c.lines, c.key.as_str()),
            (vec!["vendor/lib/a.c".to_string()], 15, "against:t3:h3")
        );
        let g = before_review(&r, std::slice::from_ref(&d), &diffs, "t3");
        assert!(g.wait && g.clashes.len() == 1);
        // after carding the key, the card is not new but the review still waits while the card is open
        r.carded.insert(c.key.clone());
        r.open_clash_tasks.insert("t3".into());
        let g = before_review(&r, std::slice::from_ref(&d), &diffs, "t3");
        assert!(g.wait && g.clashes.is_empty());
        // a glob without a slash matches the file name; a directory covers nested files only
        assert!(
            covers("a/b/x.tmp", "*.tmp")
                && covers("vendor/x", "vendor")
                && !covers("vendors/x", "vendor")
        );
        // only a current won't-build counts
        d.status = Some("proposed".into());
        assert!(
            scan(&r, &[d], &diffs)
                .iter()
                .all(|c| c.rule != Rule::AgainstDecision)
        );
    }

    #[test]
    fn stale_agent_is_a_card() {
        let mut r = run();
        r.sessions = vec![
            RunSession {
                id: "s1".into(),
                task: Some("t1".into()),
                exited: false,
                held: 2,
            },
            RunSession {
                id: "s2".into(),
                task: None,
                exited: false,
                held: 1,
            },
            RunSession {
                id: "s3".into(),
                task: None,
                exited: true,
                held: 5,
            },
        ];
        let cs = scan(&r, &[], &DiffIndex::new());
        assert_eq!(cs.len(), 1);
        assert_eq!(
            (cs[0].rule, cs[0].task.as_deref()),
            (Rule::Stale, Some("t1"))
        );
    }

    #[test]
    fn overlap_is_advisory() {
        let mut r = run();
        r.tasks = vec![
            task("t1", 1, "in-review"),
            task("t2", 2, "running"),
            task("t4", 4, "done"),
        ];
        let mut diffs = diff("t1", &[("a.rs", 1), ("b.rs", 1)]);
        add(&mut diffs, "t2", &[("b.rs", 1), ("c.rs", 1)]);
        add(&mut diffs, "t4", &[("a.rs", 1)]);
        let cs = scan(&r, &[], &diffs);
        assert_eq!(cs.len(), 1);
        assert_eq!(
            (cs[0].rule, cs[0].blocks_review, cs[0].key.as_str()),
            (Rule::Overlap, false, "overlap:1:2")
        );
        assert_eq!(cs[0].title, "Task 1 and Task 2 both change b.rs");
        assert!(!before_review(&r, &[], &diffs, "t1").wait);
    }

    #[test]
    fn each_clash_carded_once() {
        let ds = [
            dec(1, "build", "x", "a", "proposed"),
            dec(2, "wont-build", "x", "b", "current"),
            dec(3, "build", "y", "a", "proposed"),
        ];
        let mut r = run();
        r.tasks = vec![task("t1", 1, "in-review"), task("t2", 2, "in-review")];
        let diffs = {
            let mut m = diff("t1", &[("f", 1)]);
            add(&mut m, "t2", &[("f", 1)]);
            m
        };
        let first = scan(&r, &ds, &diffs);
        assert_eq!(first.len(), 3); // contradiction, proposed:3, overlap (one pair, not two)
        r.carded.extend(first.iter().map(|c| c.key.clone()));
        assert!(scan(&r, &ds, &diffs).is_empty());
        // a run that is not running scans nothing
        r.carded.clear();
        r.status = "done".into();
        assert!(scan(&r, &ds, &diffs).is_empty());
    }

    #[test]
    fn long_vs_short() {
        let ds = [dec(5, "build", "cache", "a", "proposed")];
        let mut r = run();
        assert_eq!(scan(&r, &ds, &DiffIndex::new())[0].size, Size::Short);
        // a subject that clashed before is long
        r.settled_subjects.insert("cache".into());
        assert_eq!(scan(&r, &ds, &DiffIndex::new())[0].size, Size::Long);
        // a diff over the limit is long
        let mut c = blank("k".into(), Rule::Proposed, "z", String::new(), vec![]);
        c.lines = LONG_LINES + 1;
        let mut cx = Ctx {
            run: &RunState::default(),
            out: vec![],
            keys: BTreeSet::new(),
        };
        cx.card(c.clone());
        c.key = "k2".into();
        c.lines = LONG_LINES;
        cx.card(c);
        assert_eq!((cx.out[0].size, cx.out[1].size), (Size::Long, Size::Short));
    }

    #[test]
    fn reviewers_start_for_cards_not_for_stale_or_overlap() {
        struct H(Vec<(String, bool)>);
        impl ReviewerHook for H {
            fn start(&mut self, c: &Clash, long: bool) {
                self.0.push((c.key.clone(), long));
            }
        }
        let ds = [dec(5, "build", "cache", "a", "proposed")];
        let mut r = run();
        r.sessions = vec![RunSession {
            id: "s".into(),
            task: None,
            exited: false,
            held: 3,
        }];
        let mut h = H(vec![]);
        start_reviewers(&mut h, &scan(&r, &ds, &DiffIndex::new()));
        assert_eq!(h.0, vec![("proposed:5".to_string(), false)]);
    }
}
