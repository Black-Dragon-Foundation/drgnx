//! The presence model: the same "now" in every order of its sources (pattern A), and its rules (pattern D).

use super::*;
use crate::work::shell_read::Resolved;
use skuld::{Bound, Partial, every_order};
use std::path::PathBuf;

skuld::events!(PresenceEv { Step, SessionEnd });

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
        let before: Vec<_> = FILES.iter().map(|f| seen(&self.p, f)).collect();
        let shown = format!("{ev:?}");
        let outs = self.p.apply(ev);
        for (f, was) in FILES.iter().zip(before) {
            let told = outs.contains(&PresenceOut::Changed {
                file: (*f).to_string(),
            });
            if seen(&self.p, f) != was && !told && self.missed.is_none() {
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

/// Pattern D. A file that does not exist (an agent read it before it was made, or after it was removed) under a folder
/// reached through a link is named by that folder's true name, as the folder is: a workspace root asked through the
/// link (macOS's `/tmp/…`) still wants it, and asking for the file through the link finds it.
#[test]
fn a_missing_file_is_named_by_its_folders_true_name() {
    let dir = tempfile::tempdir().unwrap();
    let real = std::fs::canonicalize(dir.path()).unwrap().join("real");
    std::fs::create_dir(&real).unwrap();
    let link = real.with_file_name("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let file = place(&link, "src/../src/b.rs");
    assert_eq!(file, real.join("src/b.rs").to_string_lossy());
    let root = Sub {
        roots: vec![true_name(&link.to_string_lossy())],
        files: BTreeSet::new(),
    };
    assert!(root.wants(&file), "{file} under {:?}", root.roots);
    let asked = link.join("src/b.rs").to_string_lossy().into_owned();
    assert_eq!(true_name(&asked), file);
}
