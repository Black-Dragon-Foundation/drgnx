//! The presence model: the same "now" in every order of its sources (pattern A), and its rules (pattern D).

use super::*;
use crate::work::shell_read::Resolved;
use skuld::{Bound, Partial, every_order};
use std::path::PathBuf;

skuld::events!(PresenceEv {
    Step,
    SessionEnd,
    Live,
    CloseLive,
    Withdraw
});

fn live(
    session: &str,
    call: &str,
    file: &str,
    mode: Mode,
    line: u32,
    status: CallStatus,
    at: f64,
) -> PresenceEv {
    PresenceEv::Live {
        session: session.into(),
        tool_call: call.into(),
        update: LiveUpdate {
            path: file.into(),
            mode,
            line: Some(line),
            line_end: Some(line + 2),
            col: Some(4),
            status,
            source: Source::Edit,
            at,
        },
    }
}

fn closed(
    session: &str,
    call: &str,
    file: &str,
    mode: Mode,
    line: u32,
    step: i64,
    at: f64,
) -> PresenceEv {
    PresenceEv::CloseLive {
        session: session.into(),
        tool_call: call.into(),
        closed: Some(Entry {
            session: session.into(),
            file: file.into(),
            mode,
            line: Some(line),
            line_end: None,
            col: None,
            source: Source::Edit,
            step,
            at,
            live: false,
            tool_call: None,
        }),
    }
}

fn dropped(session: &str, call: &str) -> PresenceEv {
    PresenceEv::CloseLive {
        session: session.into(),
        tool_call: call.into(),
        closed: None,
    }
}

/// (session, mode, line, step, live) of each entry now in FILE at T.
fn seen_live(p: &Presence, file: &str) -> Vec<(String, Mode, Option<u32>, i64, bool)> {
    p.now(file, T)
        .iter()
        .map(|e| (e.session.clone(), e.mode, e.line, e.step, e.live))
        .collect()
}

fn touch(file: &str, mode: Mode, line: Option<u32>, source: Source) -> Touch {
    Touch {
        file: file.into(),
        mode,
        line,
        source,
    }
}

fn step(session: &str, step: i64, at: f64, files: Vec<Touch>) -> PresenceEv {
    PresenceEv::Step {
        session: session.into(),
        step,
        at,
        files,
    }
}

fn withdrawn(session: &str, call: &str) -> PresenceEv {
    PresenceEv::Withdraw {
        session: session.into(),
        tool_call: call.into(),
    }
}

fn end(session: &str) -> PresenceEv {
    PresenceEv::SessionEnd {
        session: session.into(),
    }
}

/// The files of the every-order run, and when it reads them.
const FILES: [&str; 4] = ["/w/x.rs", "/w/y.rs", "/w/z.rs", "/w/out.txt"];
const T: f64 = 250.0;

/// (session, mode, line, step) of each entry now in FILE at T.
fn seen(p: &Presence, file: &str) -> Vec<(String, Mode, Option<u32>, i64)> {
    p.now(file, T)
        .iter()
        .map(|e| (e.session.clone(), e.mode, e.line, e.step))
        .collect()
}

/// The model, and the first step whose outs missed a file whose "now" changed.
#[derive(Default)]
struct Harness {
    p: Presence,
    missed: Option<String>,
}

impl skuld::Core for Harness {
    type Event = PresenceEv;
    fn step(&mut self, ev: PresenceEv) -> Vec<PresenceEv> {
        let before: Vec<_> = FILES.iter().map(|f| seen_live(&self.p, f)).collect();
        let shown = format!("{ev:?}");
        let outs = self.p.apply(ev);
        for (f, was) in FILES.iter().zip(before) {
            let told = outs.contains(&PresenceOut::Changed {
                file: (*f).to_string(),
            });
            if seen_live(&self.p, f) != was && !told && self.missed.is_none() {
                self.missed = Some(format!("{f} changed at {shown}, not told"));
            }
        }
        Vec::new()
    }
}

/// Pattern A. Two sessions read, edit and run commands in files while a third only listed one long ago; one of them
/// ends. In every order the files' "now" at one time is the same, and each step names every file whose "now" it
/// changed. Edges: a session's end comes after its last step (the hub ends a session after its reader stops).
#[test]
fn every_order_same_now_set() {
    let mut p = Partial::new();
    p.source(
        "a",
        vec![
            step(
                "a",
                1,
                0.0,
                vec![touch("/w/x.rs", Mode::Read, Some(10), Source::Acp)],
            ),
            step(
                "a",
                2,
                100.0,
                vec![touch("/w/y.rs", Mode::Edit, Some(5), Source::Edit)],
            ),
            step(
                "a",
                3,
                200.0,
                vec![touch("/w/x.rs", Mode::Read, Some(40), Source::Acp)],
            ),
        ],
    );
    let b = p.source(
        "b",
        vec![
            step(
                "b",
                1,
                150.0,
                vec![touch("/w/x.rs", Mode::Read, Some(7), Source::Acp)],
            ),
            step(
                "b",
                2,
                160.0,
                vec![
                    touch("/w/z.rs", Mode::Read, None, Source::Command),
                    touch("/w/out.txt", Mode::Write, None, Source::Command),
                ],
            ),
        ],
    );
    p.source(
        "c",
        vec![step(
            "c",
            1,
            10.0,
            vec![touch("/w/y.rs", Mode::Listed, None, Source::Command)],
        )],
    );
    let gone = p.source("end", vec![end("b")]);
    p.before((b, 1), (gone, 0));
    // a call that ran in a file and was dropped, and a request whose entry was withdrawn, leave nothing there
    p.source(
        "d",
        vec![
            live(
                "d",
                "t",
                "/w/out.txt",
                Mode::Pending,
                1,
                CallStatus::Pending,
                240.0,
            ),
            dropped("d", "t"),
            live(
                "d",
                "p",
                "/w/out.txt",
                Mode::Pending,
                2,
                CallStatus::Pending,
                241.0,
            ),
            withdrawn("d", "p"),
        ],
    );
    let r = every_order(&p, Bound::default(), Harness::default, |h, _| {
        if let Some(m) = &h.missed {
            return Err(m.clone());
        }
        let got: Vec<_> = FILES.iter().map(|f| seen(&h.p, f)).collect();
        let want = vec![
            vec![("a".to_string(), Mode::Read, Some(40), 3)],
            vec![("c".to_string(), Mode::Listed, None, 1)],
            vec![],
            vec![],
        ];
        if got != want {
            return Err(format!("now {got:?}"));
        }
        Ok(())
    });
    assert!(r.orders > 20, "{} orders", r.orders);
}

/// Pattern D. An entry is "now" for 120 s; after that only while it is its session's latest; never once the session
/// ended. A step that moves a session's latest away from a file says that file changed too.
#[test]
fn stale_after_120s_unless_latest() {
    let mut p = Presence::new();
    p.apply(step(
        "a",
        1,
        0.0,
        vec![touch("/w/x.rs", Mode::Read, Some(3), Source::Acp)],
    ));
    assert_eq!(
        p.now("/w/x.rs", 500.0).len(),
        1,
        "the latest is now however old"
    );
    let outs = p.apply(step(
        "a",
        2,
        10.0,
        vec![touch("/w/y.rs", Mode::Read, None, Source::Acp)],
    ));
    assert!(outs.contains(&PresenceOut::Changed {
        file: "/w/x.rs".into()
    }));
    assert!(outs.contains(&PresenceOut::Changed {
        file: "/w/y.rs".into()
    }));
    assert_eq!(p.now("/w/x.rs", 119.0).len(), 1);
    assert_eq!(p.now("/w/x.rs", 121.0).len(), 0);
    assert_eq!(p.now("/w/y.rs", 1000.0).len(), 1);
    assert_eq!(p.files_under("/w", 1000.0), ["/w/y.rs"]);
    assert_eq!(p.files_under("/w/x", 50.0), Vec::<String>::new());
    let outs = p.apply(end("a"));
    assert!(outs.contains(&PresenceOut::Changed {
        file: "/w/y.rs".into()
    }));
    assert_eq!(p.now("/w/y.rs", 20.0).len(), 0);
}

/// Pattern D. The files a shell step's command names keep that step: reads (and scripts) read, writes written,
/// listings listed, with no line, "from the command".
#[test]
fn shell_reads_keep_their_step() {
    let r = Resolved {
        reads: vec![PathBuf::from("/w/a.rs")],
        writes: vec![PathBuf::from("/w/out.txt")],
        listed: vec![PathBuf::from("/w/src")],
        patterns: vec!["*.md".into()],
    };
    let files = touches_of_command(&r);
    assert_eq!(
        files,
        [
            touch("/w/a.rs", Mode::Read, None, Source::Command),
            touch("/w/out.txt", Mode::Write, None, Source::Command),
            touch("/w/src", Mode::Listed, None, Source::Command),
        ]
    );
    let mut p = Presence::new();
    p.apply(step("a", 42, 5.0, files));
    let e = p.now("/w/a.rs", 6.0);
    assert_eq!(
        e.iter()
            .map(|e| (e.step, e.mode, e.source, e.line))
            .collect::<Vec<_>>(),
        [(42, Mode::Read, Source::Command, None)]
    );
    assert_eq!(p.now("/w/out.txt", 6.0)[0].mode, Mode::Write);
}

/// Pattern D. The model rebuilt from the timeline's steps and their files equals the one the live events built.
#[test]
fn rebuild_equals_live() {
    let evs = [
        (
            "a",
            1,
            0.0,
            vec![touch("/w/x.rs", Mode::Read, Some(1), Source::Acp)],
        ),
        (
            "b",
            2,
            5.0,
            vec![touch("/w/x.rs", Mode::Edit, Some(9), Source::Edit)],
        ),
        (
            "a",
            3,
            7.0,
            vec![touch("/w/y.rs", Mode::Read, None, Source::Acp)],
        ),
        ("b", 4, 8.0, vec![]),
    ];
    let mut live = Presence::new();
    let mut steps = Vec::new();
    let mut details = BTreeMap::new();
    for (s, id, at, files) in evs {
        live.apply(step(s, id, at, files.clone()));
        steps.push((s.to_string(), id, at));
        details.insert(id, files);
    }
    let rebuilt = Presence::rebuild(&steps, &details);
    assert_eq!(rebuilt, live);
    assert_eq!(rebuilt.now("/w/x.rs", 9.0).len(), 2);
}

/// Pattern D. The model knows a file that exists by its true name ([`place`]); asked by a name through a link (macOS's
/// `/tmp` is `/private/tmp`), it is found, and the answer names it as it was asked. A subscription by that name gets
/// its changes too.
#[test]
fn a_file_is_found_by_a_name_through_a_link() {
    let dir = tempfile::tempdir().unwrap();
    let real = std::fs::canonicalize(dir.path()).unwrap().join("real");
    std::fs::create_dir(&real).unwrap();
    std::fs::write(real.join("a.txt"), "one\n").unwrap();
    let link = real.with_file_name("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let file = place(&link, "a.txt");
    assert_eq!(file, real.join("a.txt").to_string_lossy());
    let live = Arc::new(Live::default());
    live.apply(step(
        "s",
        1,
        T,
        vec![touch(&file, Mode::Read, None, Source::Command)],
    ));
    let asked = link.join("a.txt").to_string_lossy().into_owned();
    let got = live.file_asked(&asked, T);
    assert_eq!(got.file, asked);
    assert_eq!(got.entries.len(), 1, "{got:?}");
    let sub = Sub {
        roots: vec![],
        files: [true_name(&asked)].into(),
    };
    assert!(sub.wants(&file));
    let root = Sub {
        roots: vec![true_name(&link.to_string_lossy())],
        files: BTreeSet::new(),
    };
    assert!(root.wants(&file));
}

/// One entry as a check names it: (session, mode, line, step, live).
type Seen<'a> = (&'a str, Mode, Option<u32>, i64, bool);

/// What a run of the live feed must end with: the files' entries, and every change told.
fn live_check(h: &Harness, want: &[(&str, Vec<Seen<'_>>)]) -> Result<(), String> {
    if let Some(m) = &h.missed {
        return Err(m.clone());
    }
    for (file, w) in want {
        let w: Vec<_> = w
            .iter()
            .map(|(s, m, l, st, lv)| (s.to_string(), *m, *l, *st, *lv))
            .collect();
        let got = seen_live(&h.p, file);
        if got != w {
            return Err(format!("{file}: {got:?}"));
        }
    }
    Ok(())
}

/// Pattern A. A's edit streams (in progress, then completed) while its step writer closes it; a second call of A runs
/// in another file; B reads the same file and its read closes. The step writer's close may come before the reader's
/// last update of the call (the race of two tasks): in every order each session has one entry per file, the closed
/// step's, none of them live, and every change was told. Edges: a call's close comes after its first update.
#[test]
fn every_order_live_then_close_leaves_one_entry() {
    let mut p = Partial::new();
    let reader = p.source(
        "reader-a",
        vec![
            live(
                "a",
                "t1",
                "/w/x.rs",
                Mode::Edit,
                5,
                CallStatus::InProgress,
                200.0,
            ),
            live(
                "a",
                "t1",
                "/w/x.rs",
                Mode::Edit,
                7,
                CallStatus::Completed,
                201.0,
            ),
            live(
                "a",
                "t2",
                "/w/y.rs",
                Mode::Read,
                3,
                CallStatus::Pending,
                202.0,
            ),
        ],
    );
    let writer = p.source(
        "writer-a",
        vec![
            closed("a", "t1", "/w/x.rs", Mode::Edit, 7, 3, 200.0),
            closed("a", "t2", "/w/y.rs", Mode::Read, 3, 4, 202.0),
        ],
    );
    let b = p.source(
        "b",
        vec![
            live(
                "b",
                "r1",
                "/w/x.rs",
                Mode::Read,
                10,
                CallStatus::InProgress,
                190.0,
            ),
            closed("b", "r1", "/w/x.rs", Mode::Read, 10, 1, 190.0),
        ],
    );
    p.before((reader, 0), (writer, 0));
    p.before((reader, 2), (writer, 1));
    let _ = b;
    // a third session reads elsewhere, has a request's entry withdrawn there, and ends
    p.source(
        "c",
        vec![
            step(
                "c",
                9,
                230.0,
                vec![touch("/w/z.rs", Mode::Read, None, Source::Acp)],
            ),
            live(
                "c",
                "p",
                "/w/z.rs",
                Mode::Pending,
                2,
                CallStatus::Pending,
                231.0,
            ),
            withdrawn("c", "p"),
            end("c"),
        ],
    );
    let r = every_order(&p, Bound::default(), Harness::default, |h, _| {
        live_check(
            h,
            &[
                (
                    "/w/x.rs",
                    vec![
                        ("a", Mode::Edit, Some(7), 3, false),
                        ("b", Mode::Read, Some(10), 1, false),
                    ],
                ),
                ("/w/y.rs", vec![("a", Mode::Read, Some(3), 4, false)]),
            ],
        )
    });
    assert!(r.orders > 20, "{} orders", r.orders);
}

/// Pattern A. A's edit waits on a permission (pending) and is denied: the failed update and the step writer's drop
/// come in either order with B's read and A's earlier read of the file. In every order the pending entry is gone and
/// A's entry is its earlier read again. Edges: the denial and the drop follow the request.
#[test]
fn every_order_a_denied_pending_is_dropped() {
    let mut p = Partial::new();
    let steps = p.source(
        "a-steps",
        vec![step(
            "a",
            1,
            200.0,
            vec![touch("/w/x.rs", Mode::Read, Some(2), Source::Acp)],
        )],
    );
    let ask = p.source(
        "ask",
        vec![live(
            "a",
            "p1",
            "/w/x.rs",
            Mode::Pending,
            5,
            CallStatus::Pending,
            201.0,
        )],
    );
    let deny = p.source(
        "deny",
        vec![live(
            "a",
            "p1",
            "/w/x.rs",
            Mode::Pending,
            5,
            CallStatus::Failed,
            202.0,
        )],
    );
    let writer = p.source("writer", vec![dropped("a", "p1")]);
    p.source(
        "b",
        vec![step(
            "b",
            2,
            210.0,
            vec![touch("/w/x.rs", Mode::Read, Some(9), Source::Acp)],
        )],
    );
    p.before((ask, 0), (deny, 0));
    p.before((ask, 0), (writer, 0));
    let _ = steps;
    // a third session that was pending elsewhere, and allowed, ends
    p.source(
        "c",
        vec![
            live(
                "c",
                "q1",
                "/w/z.rs",
                Mode::Pending,
                3,
                CallStatus::Pending,
                205.0,
            ),
            // allowed: the request's own entry gives way to the call the agent reports
            withdrawn("c", "q1"),
            end("c"),
        ],
    );
    let r = every_order(&p, Bound::default(), Harness::default, |h, _| {
        live_check(
            h,
            &[(
                "/w/x.rs",
                vec![
                    ("a", Mode::Read, Some(2), 1, false),
                    ("b", Mode::Read, Some(9), 2, false),
                ],
            )],
        )
    });
    assert!(r.orders > 20, "{} orders", r.orders);
}

/// Pattern A. A edits and B reads one file at once, each call moving: in every order both are there, live, each at
/// its own latest line.
#[test]
fn every_order_two_sessions_one_file_keep_both() {
    let mut p = Partial::new();
    p.source(
        "a",
        vec![
            live(
                "a",
                "t1",
                "/w/x.rs",
                Mode::Edit,
                5,
                CallStatus::InProgress,
                200.0,
            ),
            live(
                "a",
                "t1",
                "/w/x.rs",
                Mode::Edit,
                8,
                CallStatus::InProgress,
                210.0,
            ),
        ],
    );
    p.source(
        "b",
        vec![
            live(
                "b",
                "u1",
                "/w/x.rs",
                Mode::Read,
                20,
                CallStatus::Pending,
                205.0,
            ),
            live(
                "b",
                "u1",
                "/w/x.rs",
                Mode::Read,
                30,
                CallStatus::InProgress,
                215.0,
            ),
            live(
                "b",
                "u2",
                "/w/z.rs",
                Mode::Read,
                1,
                CallStatus::InProgress,
                216.0,
            ),
        ],
    );
    // a third session read the file, ran a call there that was dropped, and ended: it is in no file
    p.source(
        "c",
        vec![
            step(
                "c",
                1,
                220.0,
                vec![touch("/w/x.rs", Mode::Read, Some(2), Source::Acp)],
            ),
            live(
                "c",
                "k",
                "/w/x.rs",
                Mode::Edit,
                4,
                CallStatus::Pending,
                221.0,
            ),
            dropped("c", "k"),
            withdrawn("c", "k"),
            end("c"),
        ],
    );
    let r = every_order(&p, Bound::default(), Harness::default, |h, _| {
        live_check(
            h,
            &[
                (
                    "/w/x.rs",
                    vec![
                        ("a", Mode::Edit, Some(8), 0, true),
                        ("b", Mode::Read, Some(30), 0, true),
                    ],
                ),
                ("/w/z.rs", vec![("b", Mode::Read, Some(1), 0, true)]),
            ],
        )
    });
    assert!(r.orders >= 10, "{} orders", r.orders);
}

/// Pattern D. After a restart the model is rebuilt from the closed steps alone: the calls that were running are not
/// in it, and it equals the model those steps alone build.
#[test]
fn rebuild_after_restart_has_no_live_entries() {
    let mut p = Presence::new();
    let s1 = step(
        "a",
        1,
        10.0,
        vec![touch("/w/x.rs", Mode::Read, Some(1), Source::Acp)],
    );
    p.apply(s1.clone());
    p.apply(live(
        "a",
        "t9",
        "/w/x.rs",
        Mode::Edit,
        4,
        CallStatus::InProgress,
        11.0,
    ));
    p.apply(live(
        "b",
        "u1",
        "/w/y.rs",
        Mode::Read,
        2,
        CallStatus::Pending,
        12.0,
    ));
    assert!(p.now("/w/x.rs", 13.0)[0].live, "the live entry stands in");
    let mut details = BTreeMap::new();
    details.insert(1, vec![touch("/w/x.rs", Mode::Read, Some(1), Source::Acp)]);
    let rebuilt = Presence::rebuild(&[("a".to_string(), 1, 10.0)], &details);
    let mut only_steps = Presence::new();
    only_steps.apply(s1);
    assert_eq!(rebuilt, only_steps);
    assert!(rebuilt.now("/w/x.rs", 13.0).iter().all(|e| !e.live));
    assert!(rebuilt.now("/w/y.rs", 13.0).is_empty());
    assert_eq!(rebuilt.files_under("/w", 13.0), ["/w/x.rs"]);
}

fn git(dir: &Path, args: &[&str]) {
    let out = std::process::Command::new("git")
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {out:?}");
}

/// Pattern D. A file in an agent's linked worktree is named on the user's tree: its path relative to the worktree's
/// top, and the project id of the main checkout (the code index's), the same as the user's own copy of the file.
#[test]
fn rel_and_repo_are_the_users_tree_for_a_worktree_path() {
    let dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    let main = root.join("main");
    std::fs::create_dir_all(main.join("src")).unwrap();
    std::fs::write(main.join("src/a.rs"), "fn a() {}\n").unwrap();
    git(&main, &["init", "-q", "-b", "main"]);
    git(&main, &["add", "-A"]);
    git(&main, &["commit", "-q", "-m", "one"]);
    let wt = root.join("wt");
    git(
        &main,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "agent",
            &wt.to_string_lossy(),
        ],
    );
    let live = Live::default();
    let users = live
        .rel_and_repo(&main.join("src/a.rs").to_string_lossy())
        .unwrap();
    let agents = live
        .rel_and_repo(&wt.join("src/a.rs").to_string_lossy())
        .unwrap();
    assert_eq!(users.0, "src/a.rs");
    assert_eq!(agents, users, "the worktree's file is the user's file");
    let (_, id) = crate::search::project::project_id(&wt).unwrap();
    assert_eq!(agents.1, id, "the code index's project id");
    assert!(
        live.rel_and_repo(&root.join("loose.txt").to_string_lossy())
            .is_none()
    );
}
