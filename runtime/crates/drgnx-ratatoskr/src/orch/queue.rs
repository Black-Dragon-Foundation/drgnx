//! The merge queue (`docs/develop/orchestration.md`, "The merge queue"): a task that passed its gates is ready; the
//! next batch is the earliest ready, up to the pack's batch size, leaving out a task whose tip conflicts with an
//! earlier member's (`git merge-tree`: it waits for the next batch); members merge one at a time, in readiness order.
//! A member whose merge onto the line would cleanly join shared files both sides changed goes back to its agent to
//! merge the line in with notes (`orch::notes`).
//!
//! In memory: after a restart the tasks are ready again as their gates pass again.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;

use vordr::batch::{Ready, form};

/// One job's queue.
#[derive(Default, Debug)]
struct Line {
    ready: Vec<Ready>,
    batch: Vec<Ready>,
    seen: Seen,
}

/// What the Flow shows of a job's queue besides its tasks: what the queue last said to each member, what the
/// merge-notes check found on it, the combined tree the groups gate judged last (with the groups it listed there) and
/// the head and tree the push gate judged last.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Seen {
    pub said: std::collections::BTreeMap<String, String>,
    pub audited: std::collections::BTreeMap<String, String>,
    pub groups: Option<(String, Vec<vordr::pack::Check>)>,
    pub push: Option<(String, String)>,
}

/// The queues, by job.
#[derive(Default)]
pub struct Queue {
    jobs: Mutex<HashMap<String, Line>>,
}

/// What a ready task does now.
#[derive(Debug, PartialEq, Eq)]
pub enum Turn {
    /// It merges now.
    Merge,
    /// An earlier member merges first, or it waits for the next batch.
    Wait(String),
    /// Back to its agent, with these words.
    Back(String),
}

impl Queue {
    /// TASK of JOB is ready at TIP (now AT; a task ready at another tip before is ready anew), with LIVE the job's
    /// tasks that may merge (the rest leave the queue).  The batch it is in, formed now when none is open (CLASH
    /// says two tips conflict).
    pub(crate) fn place(
        &self,
        job: &str,
        r: Ready,
        live: &[String],
        size: usize,
        clash: impl Fn(&Ready, &Ready) -> bool,
    ) -> Vec<Ready> {
        let mut jobs = self.jobs.lock().unwrap();
        let line = jobs.entry(job.to_owned()).or_default();
        line.ready.retain(|x| live.contains(&x.task));
        match line.ready.iter_mut().find(|x| x.task == r.task) {
            Some(x) if x.tip == r.tip => {}
            Some(x) => *x = r,
            None => line.ready.push(r),
        }
        // a member that left, or is ready at another tip now, leaves its batch
        line.batch.retain(|x| {
            line.ready
                .iter()
                .any(|y| y.task == x.task && y.tip == x.tip)
        });
        if line.batch.is_empty() {
            line.batch = form(&line.ready, size, clash);
        }
        line.batch.clone()
    }

    /// TASK of JOB merged (or left): out of its queue.
    pub fn forget(&self, job: &str, task: &str) {
        if let Some(line) = self.jobs.lock().unwrap().get_mut(job) {
            line.ready.retain(|x| x.task != task);
            line.batch.retain(|x| x.task != task);
            line.seen.said.remove(task);
            line.seen.audited.remove(task);
        }
    }

    /// The merge-notes check found WORDS on TASK of JOB.
    pub fn audit(&self, job: &str, task: &str, words: &str) {
        let mut jobs = self.jobs.lock().unwrap();
        let line = jobs.entry(job.to_owned()).or_default();
        line.seen.audited.insert(task.to_owned(), words.to_owned());
    }

    /// The queue said WORDS to TASK of JOB (its turn: merge, wait or back).
    pub fn say(&self, job: &str, task: &str, words: &str) {
        let mut jobs = self.jobs.lock().unwrap();
        let line = jobs.entry(job.to_owned()).or_default();
        line.seen.said.insert(task.to_owned(), words.to_owned());
    }

    /// JOB's groups gate judged the combined tree TREE, which needs GROUPS.
    pub fn at_groups(&self, job: &str, tree: &str, groups: Vec<vordr::pack::Check>) {
        let mut jobs = self.jobs.lock().unwrap();
        jobs.entry(job.to_owned()).or_default().seen.groups = Some((tree.to_owned(), groups));
    }

    /// JOB's push gate judged the commit HEAD, of tree TREE.
    pub fn at_push(&self, job: &str, head: &str, tree: &str) {
        let mut jobs = self.jobs.lock().unwrap();
        jobs.entry(job.to_owned()).or_default().seen.push =
            Some((head.to_owned(), tree.to_owned()));
    }

    /// What the Flow shows of JOB's queue.
    pub fn seen(&self, job: &str) -> Seen {
        self.jobs
            .lock()
            .unwrap()
            .get(job)
            .map(|l| l.seen.clone())
            .unwrap_or_default()
    }

    /// JOB's queue as a test hub seeds it: READY all ready and in one batch.
    #[cfg(feature = "test-hooks")]
    pub(crate) fn seed(&self, job: &str, ready: Vec<Ready>) {
        let mut jobs = self.jobs.lock().unwrap();
        let line = jobs.entry(job.to_owned()).or_default();
        line.batch = ready.clone();
        line.ready = ready;
    }

    /// JOB's ready tasks, in readiness order.
    pub fn ready(&self, job: &str) -> Vec<Ready> {
        self.jobs
            .lock()
            .unwrap()
            .get(job)
            .map(|l| l.ready.clone())
            .unwrap_or_default()
    }

    /// JOB's current batch.
    pub fn batch(&self, job: &str) -> Vec<Ready> {
        self.jobs
            .lock()
            .unwrap()
            .get(job)
            .map(|l| l.batch.clone())
            .unwrap_or_default()
    }
}

/// Whether tips A and B conflict (`git merge-tree` exits 1).  Blocking.
fn conflict(dir: &Path, a: &str, b: &str) -> bool {
    std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["merge-tree", "--write-tree", "--name-only", a, b])
        .output()
        .is_ok_and(|o| o.status.code() == Some(1))
}

/// A task that passed its gates, asking for its turn.
pub struct Entry<'a> {
    pub job: &'a str,
    pub task: &'a str,
    /// The tip commit it passed at, and when.
    pub tip: &'a str,
    pub at: f64,
    /// The job's tasks that may merge (passed, in review).
    pub live: &'a [String],
    /// The pack's batch size.
    pub size: usize,
    /// The pack's shared paths, when it asks for merge notes.
    pub shared: Option<&'a [String]>,
}

/// E's turn in its job's queue, in DIR (the job's tree, HEAD its line).  With shared paths, a clean merge onto the
/// line joining shared files both sides changed sends the task back for notes.  Blocking (git).
pub fn turn(queue: &Queue, dir: &Path, e: Entry<'_>) -> Result<Turn, String> {
    let (job, task) = (e.job, e.task);
    let t = turn_of(queue, dir, e)?;
    match &t {
        Turn::Merge => queue.say(job, task, "trial merge clean"),
        Turn::Wait(why) => queue.say(job, task, why),
        // it left the queue: the words go with it
        Turn::Back(_) => {}
    }
    Ok(t)
}

fn turn_of(queue: &Queue, dir: &Path, e: Entry<'_>) -> Result<Turn, String> {
    let Entry {
        job,
        task,
        tip,
        at,
        live,
        size,
        shared,
    } = e;
    let r = Ready {
        task: task.to_owned(),
        tip: tip.to_owned(),
        at,
    };
    let batch = queue.place(job, r, live, size, |a, b| conflict(dir, &a.tip, &b.tip));
    let Some(first) = batch.first() else {
        return Ok(Turn::Wait("the queue is empty".into()));
    };
    if !batch.iter().any(|m| m.task == task) {
        let names: Vec<&str> = batch.iter().map(|m| m.task.as_str()).collect();
        return Ok(Turn::Wait(format!(
            "waits for the batch ahead ({})",
            names.join(", ")
        )));
    }
    if first.task != task {
        return Ok(Turn::Wait(format!("{} merges first", first.task)));
    }
    if let Some(globs) = shared {
        let n = crate::orch::notes::needs(dir, tip, "HEAD", globs)?;
        if n.hunks.is_empty() && !n.files.is_empty() {
            queue.forget(job, task);
            return Ok(Turn::Back(format!(
                "Your branch and job/{job} both changed the shared files {} since they parted. Merge job/{job} into \
                 your branch, check both sides' intent in each, and add to the merge commit's message one line per \
                 file: Merge-note: PATH ours=COMMIT theirs=COMMIT resolution=ours|theirs|both|new | why. Commit, \
                 then call complete_task.",
                n.files.join(", ")
            )));
        }
        queue.audit(job, task, &audit_words(n.hunks.len()));
    }
    Ok(Turn::Merge)
}

/// What the Flow says of a member the merge-notes check passed, with HUNKS the hunks both sides changed (each
/// resolved by intent in the merge's notes).
pub fn audit_words(hunks: usize) -> String {
    match hunks {
        0 => "shared paths audited".into(),
        1 => "1 hunk by intent · notes".into(),
        n => format!("{n} hunks by intent · notes"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(task: &str, at: f64) -> Ready {
        Ready {
            task: task.into(),
            tip: format!("tip-{task}"),
            at,
        }
    }

    #[test]
    fn a_batch_stays_until_its_members_merge_and_the_next_forms() {
        let q = Queue::default();
        let live: Vec<String> = ["a", "b", "c", "d"].map(String::from).to_vec();
        let names = |b: Vec<Ready>| b.into_iter().map(|r| r.task).collect::<Vec<_>>();
        assert_eq!(
            names(q.place("j", r("b", 2.0), &live, 2, |_, _| false)),
            vec!["b"]
        );
        // the batch formed with b alone stays: a, ready later in time, waits for the next
        assert_eq!(
            names(q.place("j", r("a", 1.0), &live, 2, |_, _| false)),
            vec!["b"]
        );
        q.forget("j", "b");
        assert_eq!(
            names(q.place("j", r("c", 3.0), &live, 2, |_, _| false)),
            vec!["a", "c"]
        );
        // a task that left the job (dropped) leaves its batch
        let live2: Vec<String> = ["c", "d"].map(String::from).to_vec();
        assert_eq!(
            names(q.place("j", r("d", 4.0), &live2, 2, |_, _| false)),
            vec!["c"]
        );
        // a new tip is ready anew
        let mut c2 = r("c", 9.0);
        c2.tip = "tip-c2".into();
        assert_eq!(
            names(q.place("j", c2, &live2, 2, |_, _| false)),
            vec!["d", "c"]
        );
        assert_eq!(names(q.batch("j")), vec!["d", "c"]);
        assert!(q.batch("other").is_empty());
    }

    /// [D] The queue keeps, for the Flow, what it last said to each member and the trees its groups and push gates
    /// judged last; a member that leaves takes its words along.
    #[test]
    fn the_queue_keeps_what_it_said_and_the_trees_it_judged() {
        let q = Queue::default();
        let unit = vordr::pack::Check {
            name: "unit".into(),
            dir: String::new(),
            run: vec!["t".into()],
        };
        q.say("j", "a", "trial merge clean");
        q.at_groups("j", "T1", vec![unit.clone()]);
        q.at_push("j", "h1", "T2");
        let s = q.seen("j");
        assert_eq!(
            s.said.get("a").map(String::as_str),
            Some("trial merge clean")
        );
        assert_eq!(s.groups, Some(("T1".into(), vec![unit])));
        assert_eq!(s.push, Some(("h1".into(), "T2".into())));
        q.forget("j", "a");
        assert!(q.seen("j").said.is_empty());
        assert_eq!(q.seen("other"), Seen::default());
    }

    /// [D] The merge-notes check's result is kept per member next to its words, and leaves with it.
    #[test]
    fn the_queue_keeps_what_the_notes_check_found() {
        let q = Queue::default();
        q.audit("j", "a", "1 hunk by intent · notes");
        q.audit("j", "b", "shared paths audited");
        let s = q.seen("j");
        assert_eq!(
            s.audited.get("a").map(String::as_str),
            Some("1 hunk by intent · notes")
        );
        assert_eq!(audit_words(0), "shared paths audited");
        assert_eq!(audit_words(1), "1 hunk by intent · notes");
        assert_eq!(audit_words(3), "3 hunks by intent · notes");
        q.forget("j", "a");
        assert_eq!(q.seen("j").audited.keys().collect::<Vec<_>>(), vec!["b"]);
    }
}
