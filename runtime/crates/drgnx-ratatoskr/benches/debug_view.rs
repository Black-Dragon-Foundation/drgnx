//! The Run and Debug view's hub rows (docs/develop/debugging.md, "The Run and Debug view"): `debug-step-variables`,
//! the hub's half of a step (a stop's lines, model, model diff and rows built again with 300 variables shown and ten
//! of their values changed: the editor's half is the perf workload of the same name, together within 30 ms at the
//! 95th percentile), and `debug-hub-memory`, a 100,000-element list open to its two chunk levels with a page fetched
//! (its values, lines, model and rows: at most 64 MB of heap; the same with a stop's 200 pages fetched is reported).  Ignored in normal runs; the combined gate pass runs it
//! under the perf lock:
//! `cargo test --release -p drgnx-ratatoskr --bench debug_view -- --ignored --nocapture --test-threads 1`.  It
//! measures and prints; the pass judges.  The stops are made here from fixed arithmetic.

use std::alloc::{GlobalAlloc, Layout, System};
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use drgnx_ratatoskr::debug::session::{ScopeVars, Stop};
use drgnx_ratatoskr::view::debug::model::{
    Bps, Input, Opened, PAGE_CAP, SessionView, Tree, Var, chunks, doc, lines,
};
use drgnx_ratatoskr::view::debug::rows::rows;
use drgnx_ratatoskr::view::explorer::RowLook;
use serde_json::{Value, json};

fn p95(mut v: Vec<Duration>) -> Duration {
    v.sort();
    v[(v.len() * 95).div_ceil(100) - 1]
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

/// The bench's allocator: the system's, counting the bytes live, so a stage's memory is what it holds (resident
/// memory keeps what the allocator freed).
struct Counting;

static LIVE: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        LIVE.fetch_add(l.size(), Ordering::Relaxed);
        unsafe { System.alloc(l) }
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        LIVE.fetch_sub(l.size(), Ordering::Relaxed);
        unsafe { System.dealloc(p, l) }
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, new: usize) -> *mut u8 {
        LIVE.fetch_add(new, Ordering::Relaxed);
        LIVE.fetch_sub(l.size(), Ordering::Relaxed);
        unsafe { System.realloc(p, l, new) }
    }
}

#[global_allocator]
static ALLOC: Counting = Counting;

/// The heap's live bytes now.
fn live() -> usize {
    LIVE.load(Ordering::Relaxed)
}

/// A stop whose Locals hold VARS: the first ten values change with EPOCH.
fn a_stop(epoch: u64, locals: Vec<Value>) -> Stop {
    Stop {
        epoch,
        thread: 1,
        reason: "step".into(),
        description: None,
        all_threads: true,
        threads: (1..=8).map(|t| json!({"id": t, "name": format!("Thread-{t}")})).collect(),
        frames: (0..20)
            .map(|f| json!({"id": 1000 + f, "name": format!("fn_{f}"), "line": 10 + f, "column": 1, "source": {"path": "/p/app/m.py"}}))
            .collect(),
        total_frames: Some(20),
        exception: None,
        frame: 1000,
        scopes: vec![
            ScopeVars {
                scope: json!({"name": "Locals", "variablesReference": 1}),
                variables: Some(locals),
            },
            ScopeVars {
                scope: json!({"name": "Globals", "variablesReference": 2, "expensive": true}),
                variables: None,
            },
        ],
    }
}

fn session(stop: Stop) -> SessionView {
    SessionView {
        id: "s1".into(),
        name: "Python: app".into(),
        state: "stopped".into(),
        tree: Tree::of_stop("s1", &stop),
        stop: Some(stop),
        thread_frames: Default::default(),
    }
}

fn input<'a>(
    sessions: &'a [SessionView],
    bps: &'a Bps,
    opened: &'a Opened,
    prev: &'a HashMap<String, String>,
) -> Input<'a> {
    Input {
        sessions,
        selected: None,
        watches: &[],
        bps,
        opened,
        prev,
    }
}

#[test]
#[ignore]
fn debug_step_variables() {
    let locals = |epoch: u64| -> Vec<Value> {
        (0..300u64)
            .map(|i| {
                let value = if i < 10 { i * 7 + epoch } else { i * 7 };
                json!({"name": format!("v{i}"), "value": format!("{value}"), "type": "int",
                       "evaluateName": format!("v{i}"), "variablesReference": 0})
            })
            .collect()
    };
    let bps = Bps::default();
    let opened = Opened::default();
    let gui = RowLook {
        gui: Some((12, 16, 6)),
        one_root: false,
    };
    let first = [session(a_stop(0, locals(0)))];
    let (mut old_lines, mut prev) = lines(&input(&first, &bps, &opened, &HashMap::new()));
    let mut old_doc = doc(&old_lines);
    let mut runs = Vec::new();
    for epoch in 1..=120u64 {
        let t = Instant::now();
        let s = [session(a_stop(epoch, locals(epoch)))];
        let (ls, cur) = lines(&input(&s, &bps, &opened, &prev));
        let d = doc(&ls);
        let ops = d.diff(&old_doc);
        let (rs, _images) = rows(&ls, &gui);
        runs.push(t.elapsed());
        assert!(!ops.is_empty() && rs.len() > 300);
        assert!(ls.iter().filter(|l| l.changed).count() == 10);
        (old_lines, old_doc, prev) = (ls, d, cur);
    }
    assert!(!old_lines.is_empty());
    let runs: Vec<Duration> = runs.into_iter().skip(20).collect();
    println!(
        "debug-step-variables (hub): 300 variables, 10 changed, lines+model+diff+rows p95 {:.2} ms (with the editor's half: 30)",
        ms(p95(runs))
    );
}

/// A session's view of a stop holding a 100,000-element list: PAGES leaf pages fetched (100 elements each, the
/// first ones), the list open to its two chunk levels (10 chunks of 10,000, each open on its 100 chunks of 100).
/// The heap it holds after the values, the lines, the model and the rows are built, in MB (live bytes, counted by the
/// bench's allocator), and the line count.
fn held(pages: usize) -> (f64, [f64; 4], usize) {
    let before = live();
    let arr = json!({"name": "arr", "value": "list[100000]", "variablesReference": 7, "indexedVariables": 100_000,
                     "namedVariables": 0, "evaluateName": "arr"});
    let mut s = session(a_stop(1, vec![arr]));
    let mut opened = Opened::default();
    let top = "v:s1:Locals/arr";
    opened.set(top, true);
    let mut left = pages;
    for (a, ac) in chunks(0, 100_000) {
        let outer = format!("{top}/[{a}..{}]", a + ac - 1);
        opened.set(&outer, true);
        for (b, bc) in chunks(a, ac) {
            if left == 0 {
                continue;
            }
            left -= 1;
            let leaf = format!("{outer}/[{b}..{}]", b + bc - 1);
            // as `debug/expand` does: one page past the cap closes the oldest and lets its elements go
            let gone = opened.set(&leaf, true);
            s.tree.forget(&gone);
            let vars = (b..b + bc)
                .map(|i| Var::of(&json!({"name": format!("{i}"), "value": format!("{}", i * 3), "type": "int",
                                          "evaluateName": format!("arr[{i}]"), "variablesReference": 0})))
                .collect();
            s.tree.kids.insert(leaf, vars);
        }
    }
    let sessions = [s];
    let mb = |a: usize, b: usize| (b.saturating_sub(a)) as f64 / (1024.0 * 1024.0);
    let values = live();
    let bps = Bps::default();
    let (ls, cur) = lines(&input(&sessions, &bps, &opened, &HashMap::new()));
    let lined = live();
    let d = doc(&ls);
    let modeled = live();
    let gui = RowLook {
        gui: Some((12, 16, 6)),
        one_root: false,
    };
    let (rs, _images) = rows(&ls, &gui);
    let after = live();
    assert!(rs.len() == ls.len() && cur.len() >= pages.min(PAGE_CAP) * 100);
    let n = ls.len();
    drop((sessions, ls, d, rs, cur));
    (
        mb(before, after),
        [
            mb(before, values),
            mb(values, lined),
            mb(lined, modeled),
            mb(modeled, after),
        ],
        n,
    )
}

#[test]
#[ignore]
fn debug_hub_memory() {
    // the spec's fixture (§12): two chunk levels open, one page of elements fetched
    let (total, parts, n) = held(1);
    println!(
        "debug-hub-memory: 100000-element list at two chunk levels, {n} lines: +{total:.1} MB heap (budget 64); values {:.1}, lines {:.1}, model {:.1}, rows {:.1}",
        parts[0], parts[1], parts[2], parts[3]
    );
    // every page of the list opened in turn: the view keeps the last PAGE_CAP open and lets the rest go
    let (total, parts, n) = held(1000);
    println!(
        "debug-hub-memory-pages: the same with all 1000 pages opened in turn ({PAGE_CAP} kept), {n} lines: +{total:.1} MB heap (budget 64); values {:.1}, lines {:.1}, model {:.1}, rows {:.1}",
        parts[0], parts[1], parts[2], parts[3]
    );
    assert!(total <= 64.0, "+{total:.1} MB past the budget");
}
