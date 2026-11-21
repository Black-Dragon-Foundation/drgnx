//! The trace supervisor: a step's opens given once in every order of the listener's end and the step's close (pattern
//! A), and its rules, budget, skip list and labels (pattern D, through a fake probe: no file is touched).

use super::*;
use skuld::{Bound, Partial, every_order};
use std::collections::BTreeMap;

skuld::events!(TraceEv {
    Started,
    Opened,
    Over,
    Ended,
    StepClosed
});

fn started(trace: u64, command: &str) -> TraceEv {
    TraceEv::Started {
        trace,
        command: command.into(),
        tree: false,
        label: None,
    }
}

fn opened(trace: u64, path: &str, write: bool) -> TraceEv {
    TraceEv::Opened {
        trace,
        path: path.into(),
        write,
        parallel: 1,
    }
}

fn closed(step: i64, command: &str) -> TraceEv {
    TraceEv::StepClosed {
        step,
        command: command.into(),
        at: step as f64,
    }
}

fn paths(v: &[&str]) -> BTreeSet<PathBuf> {
    v.iter().map(PathBuf::from).collect()
}

#[derive(Default)]
struct Harness {
    core: Core,
    out: Vec<Emit>,
}

impl skuld::Core for Harness {
    type Event = TraceEv;
    fn step(&mut self, ev: TraceEv) -> Vec<TraceEv> {
        self.out.extend(self.core.apply(ev));
        Vec::new()
    }
}

/// Pattern A. Three shell steps in a row, each traced, the third going over the budget: a step's close may come
/// before its listener's last notifications (or its over-budget drop), or after its end; the next step's command
/// starts only after the previous step closed. In every order each step is given once, with exactly its own reads and
/// writes, and the third with nothing and its label. Edges: a trace starts before its step
/// closes (the wrapper parks on the answer before the command runs, and the step closes after the command ends);
/// each command starts after the previous step closed (one shell step at a time).
#[test]
fn step_closes_before_or_after_the_last_notifications() {
    let mut p = Partial::new();
    let t1 = p.source(
        "trace 1",
        vec![
            started(1, "cat a; sed -n 1,5p b > c"),
            opened(1, "/w/a", false),
            opened(1, "/w/b", false),
            opened(1, "/w/c", true),
            TraceEv::Ended { trace: 1 },
        ],
    );
    let t2 = p.source(
        "trace 2",
        vec![
            started(2, "wc -l d"),
            opened(2, "/w/d", false),
            TraceEv::Ended { trace: 2 },
        ],
    );
    let t3 = p.source(
        "trace 3",
        vec![
            started(3, "./build.sh"),
            opened(3, "/w/e", false),
            TraceEv::Over { trace: 3 },
            TraceEv::Ended { trace: 3 },
        ],
    );
    let steps = p.source(
        "steps",
        vec![
            closed(10, "cat a; sed -n 1,5p b > c"),
            closed(11, "wc -l d"),
            closed(12, "./build.sh"),
        ],
    );
    p.before((t1, 0), (steps, 0));
    p.before((steps, 0), (t2, 0));
    p.before((t2, 0), (steps, 1));
    p.before((steps, 1), (t3, 0));
    p.before((t3, 0), (steps, 2));
    let r = every_order(&p, Bound::default(), Harness::default, |h, _| {
        let mut got: Vec<(i64, Seen, Option<String>)> = h
            .out
            .iter()
            .map(|e| (e.step, e.seen.clone(), e.label.clone()))
            .collect();
        got.sort_by_key(|g| g.0);
        let want = vec![
            (
                10,
                Seen {
                    reads: paths(&["/w/a", "/w/b"]),
                    writes: paths(&["/w/c"]),
                },
                None,
            ),
            (
                11,
                Seen {
                    reads: paths(&["/w/d"]),
                    writes: BTreeSet::new(),
                },
                None,
            ),
            (12, Seen::default(), Some(LABEL_BUILD.to_string())),
        ];
        if got != want {
            return Err(format!("emitted {got:?}"));
        }
        if h.core.pending() != 0 {
            return Err(format!("{} traces left", h.core.pending()));
        }
        Ok(())
    });
    assert!(r.orders > 20, "{} orders", r.orders);
}

/// Real names from a table (absent: missing), and the paths git ignores.
#[derive(Default)]
struct Fake {
    real: BTreeMap<PathBuf, PathBuf>,
    ignored: BTreeSet<PathBuf>,
}

impl Fake {
    fn with(paths: &[&str]) -> Fake {
        let mut f = Fake::default();
        for p in paths {
            f.real.insert(p.into(), p.into());
        }
        f
    }
}

impl Probe for Fake {
    fn real(&mut self, p: &Path) -> Option<PathBuf> {
        self.real.get(p).cloned()
    }
    fn ignored(&mut self, _root: &Path, paths: &[PathBuf]) -> BTreeSet<PathBuf> {
        paths
            .iter()
            .filter(|p| self.ignored.contains(*p))
            .cloned()
            .collect()
    }
}

fn files(t: &[Touch]) -> Vec<(String, Mode)> {
    t.iter().map(|t| (t.file.clone(), t.mode)).collect()
}

fn rules() -> Rules {
    Rules::new(
        vec!["/ws/drgnx".into(), "/ws/org".into()],
        Some(Path::new("/hm/u")),
        &["/tools/node".into()],
    )
}

/// Pattern D. What git ignores (build output), toolchain, cache and system paths never show; the rest is kept, each
/// once, a path both read and written as written; every entry is `opened` with no line.
#[test]
fn drops_ignored_toolchain_and_system_paths() {
    let all = [
        "/ws/drgnx/src/a.rs",
        "/ws/drgnx/target/debug/x.rlib",
        "/usr/lib/libc.so.6",
        "/etc/ld.so.cache",
        "/hm/u/.cargo/registry/src/x.rs",
        "/hm/u/.rustup/toolchains/1.93/lib/y",
        "/hm/u/.local/share/mise/installs/z",
        "/tools/node/lib/n.js",
        "/proc/self/status",
        "/ws/org/notes.md",
        "/ws/drgnx/out.txt",
    ];
    let mut probe = Fake::with(&all);
    probe.ignored.insert("/ws/drgnx/target/debug/x.rlib".into());
    let seen = Seen {
        reads: all.iter().map(PathBuf::from).collect(),
        writes: paths(&["/ws/drgnx/out.txt"]),
    };
    let t = touches(&seen, &rules(), &mut probe);
    assert_eq!(
        files(&t),
        vec![
            ("/ws/drgnx/out.txt".to_string(), Mode::Write),
            ("/ws/drgnx/src/a.rs".to_string(), Mode::Read),
            ("/ws/org/notes.md".to_string(), Mode::Read),
        ]
    );
    assert!(
        t.iter()
            .all(|t| t.source == Source::Opened && t.line.is_none())
    );
}

/// Pattern D (review focus 1). A path is judged by its true name: a link inside a root that leads out of every root
/// is dropped, and so is a `..` that climbs out; a link that stays inside is kept by its target.
#[test]
fn a_link_out_of_the_roots_is_dropped() {
    let mut probe = Fake::default();
    probe.real.insert(
        "/ws/drgnx/elsewhere".into(),
        "/hm/u/notes/private.txt".into(),
    );
    probe
        .real
        .insert("/ws/drgnx/link-in".into(), "/ws/org/plan.md".into());
    probe
        .real
        .insert("/elsewhere/x".into(), "/elsewhere/x".into());
    let seen = Seen {
        reads: paths(&[
            "/ws/drgnx/elsewhere",
            "/ws/drgnx/link-in",
            "/ws/drgnx/../../elsewhere/x",
        ]),
        writes: BTreeSet::new(),
    };
    let t = touches(&seen, &rules(), &mut probe);
    assert_eq!(files(&t), vec![("/ws/org/plan.md".to_string(), Mode::Read)]);
}

/// Pattern D. A read whose file does not exist is a failed probe, and a write whose file is gone at the step's close
/// is dropped too; a write made by the step (it exists now) is kept.
#[test]
fn a_failed_probe_is_dropped() {
    let mut probe = Fake::with(&["/ws/drgnx/Cargo.toml", "/ws/drgnx/c"]);
    let seen = Seen {
        reads: paths(&[
            "/ws/drgnx/Cargo.toml",
            "/ws/drgnx/missing.el",
            "/ws/drgnx/missing.elc",
        ]),
        writes: paths(&["/ws/drgnx/c", "/ws/drgnx/tmp-gone"]),
    };
    let t = touches(&seen, &rules(), &mut probe);
    assert_eq!(
        files(&t),
        vec![
            ("/ws/drgnx/Cargo.toml".to_string(), Mode::Read),
            ("/ws/drgnx/c".to_string(), Mode::Write),
        ]
    );
}

/// Pattern D. Over the budget (max(5 %, 50 ms), at most 250 ms), the step keeps nothing it saw and is labelled; its
/// heads go on the worktree's skip list, so the same command is not traced again.
#[test]
fn over_budget_drops_to_layer_1_and_learns() {
    let ms = 1_000_000u64;
    // 2,000 opens at ~9 µs in a 100 ms step: 18 ms against the 50 ms floor
    assert!(!over_budget(100 * ms, 2000, 6 * ms));
    // 10,000 opens in 1 s: 60 + 30 ms against 50 ms
    assert!(over_budget(1000 * ms, 10_000, 30 * ms));
    // a 20 s step may gain 5 % = 1 s, but never more than 250 ms
    assert!(!over_budget(20_000 * ms, 30_000, 60 * ms));
    assert!(over_budget(20_000 * ms, 40_000, 20 * ms));
    let cmd = "cd sub && ./build.sh --all";
    let mut core = Core::new();
    core.apply(started(1, cmd));
    core.apply(opened(1, "/w/a", false));
    core.apply(TraceEv::Over { trace: 1 });
    core.apply(opened(1, "/w/b", false));
    core.apply(TraceEv::Ended { trace: 1 });
    let out = core.apply(closed(5, cmd));
    assert_eq!(
        out,
        vec![Emit {
            step: 5,
            at: 5.0,
            seen: Seen::default(),
            label: Some(LABEL_BUILD.into()),
        }]
    );
    let learned: BTreeSet<String> = heads(cmd).into_iter().collect();
    assert_eq!(learned, BTreeSet::from(["build.sh".to_string()]));
    assert_eq!(skip_head(cmd, &learned).as_deref(), Some("build.sh"));
    assert_eq!(
        skip_head("./build.sh", &learned).as_deref(),
        Some("build.sh")
    );
    assert_eq!(skip_head("cat a", &learned), None);
}

/// Pattern D. Heads on the skip list are not traced wherever they sit in a chain, by basename and after assignments
/// and prefixes: the design's list plus `emacs`, `nidhogg` and every `bin/drgnx` subcommand; `go` only to build or
/// test. A skipped step is labelled once its step closes, with no listener.
#[test]
fn skip_list_heads_are_not_traced() {
    let none = BTreeSet::new();
    for (cmd, head) in [
        ("cargo build -p x", Some("cargo")),
        ("cd runtime && RUSTFLAGS=-g cargo test", Some("cargo")),
        ("make -j4 && ./run", Some("make")),
        ("ninja -C build", Some("ninja")),
        ("cmake ..", Some("cmake")),
        ("npm test | tail", Some("npm")),
        ("pnpm i", Some("pnpm")),
        ("yarn build", Some("yarn")),
        ("go build ./...", Some("go")),
        ("go test ./x", Some("go")),
        ("go vet ./...", None),
        ("pytest -q", Some("pytest")),
        ("bin/drgnx test --leaks", Some("drgnx")),
        ("./bin/drgnx fmt", Some("drgnx")),
        ("time /opt/x/bin/drgnx doctor", Some("drgnx")),
        ("podman run x", Some("podman")),
        ("emacs --batch -l x.el", Some("emacs")),
        ("env A=1 nidhogg -Q", Some("nidhogg")),
        ("cat Cargo.toml; rg 'cargo build' src", None),
        ("echo 'make me'", None),
        ("sed -n 1,5p a > b", None),
    ] {
        assert_eq!(skip_head(cmd, &none).as_deref(), head, "{cmd}");
    }
    let mut core = Core::new();
    core.apply(TraceEv::Started {
        trace: 1,
        command: "cargo build".into(),
        tree: false,
        label: Some(LABEL_BUILD.into()),
    });
    let out = core.apply(closed(3, "cargo build"));
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].label.as_deref(), Some(LABEL_BUILD));
    assert_eq!(out[0].seen, Seen::default());
}

/// Pattern D. Whole-tree mode: an open while two shell steps run goes to both, and each is labelled "one of 2
/// parallel commands"; a step that ran alone is not; a tree trace ends with its step.
#[test]
fn parallel_steps_are_labelled() {
    let tree = |trace, command: &str| TraceEv::Started {
        trace,
        command: command.into(),
        tree: true,
        label: None,
    };
    let mut core = Core::new();
    core.apply(tree(1, "cat a"));
    core.apply(tree(2, "cat b"));
    assert_eq!(core.tree_trace("cat a"), Some(1));
    for t in [1, 2] {
        core.apply(TraceEv::Opened {
            trace: t,
            path: "/w/shared".into(),
            write: false,
            parallel: 2,
        });
    }
    let mut out = core.apply(closed(7, "cat a"));
    out.extend(core.apply(closed(8, "cat b")));
    assert_eq!(out.len(), 2);
    for e in &out {
        assert_eq!(e.label.as_deref(), Some("one of 2 parallel commands"));
        assert_eq!(e.seen.reads, paths(&["/w/shared"]));
    }
    core.apply(tree(3, "ls"));
    core.apply(opened(3, "/w/x", false));
    let out = core.apply(closed(9, "ls"));
    assert_eq!(out[0].label, None);
}

/// Pattern D. The wrapper's offer matches its step's command as given, or inside what the CLI wrapped around it.
#[test]
fn an_offer_matches_its_steps_command() {
    assert!(command_matches("cat a", "cat a"));
    assert!(command_matches(
        "eval 'cat a' < /dev/null && pwd -P >| /tmp/x",
        "cat a"
    ));
    assert!(command_matches(
        r"eval 'echo '\''hi'\''' && pwd",
        "echo 'hi'"
    ));
    assert!(!command_matches("cat b", "cat a"));
    assert!(!command_matches("anything", ""));
}
