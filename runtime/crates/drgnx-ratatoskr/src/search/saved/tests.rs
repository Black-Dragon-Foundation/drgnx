use super::*;
use runstav::types::AbsPath;

fn text(t: &str) -> SearchSpec {
    SearchSpec {
        query: FindQuery::Text {
            text: t.into(),
            case: None,
            word: None,
            regexp: None,
        },
        replace: None,
        scope: None,
        include: None,
        exclude: None,
    }
}

fn typed(specs: &[SearchSpec]) -> Vec<&str> {
    specs.iter().map(|s| s.query.typed()).collect()
}

struct Fx {
    state: tempfile::TempDir,
    root: tempfile::TempDir,
    saved: Saved,
    t0: Instant,
}

fn fx() -> Fx {
    let state = tempfile::tempdir().unwrap();
    let saved = Saved::new(state.path().join("hub/search"));
    Fx {
        state,
        root: tempfile::tempdir().unwrap(),
        saved,
        t0: crate::clock::now(),
    }
}

impl Fx {
    fn root(&self) -> &Path {
        self.root.path()
    }
    fn at(&self, ms: u64) -> Instant {
        self.t0 + Duration::from_millis(ms)
    }
}

#[test]
fn a_search_is_recorded_only_once_it_stood_for_the_pause() {
    let f = fx();
    f.saved.offer(f.root(), "v", text("f"), f.at(0));
    f.saved.offer(f.root(), "v", text("fo"), f.at(100));
    f.saved.offer(f.root(), "v", text("foo"), f.at(200));
    assert_eq!(
        typed(&f.saved.recent(f.root(), f.at(300))),
        Vec::<&str>::new()
    );
    assert_eq!(typed(&f.saved.recent(f.root(), f.at(450))), vec!["foo"]);
}

#[test]
fn a_search_that_stood_is_recorded_when_the_next_one_comes() {
    let f = fx();
    f.saved.offer(f.root(), "v", text("one"), f.at(0));
    f.saved.offer(f.root(), "v", text("two"), f.at(1000));
    assert_eq!(typed(&f.saved.recent(f.root(), f.at(1100))), vec!["one"]);
}

#[test]
fn an_empty_search_is_never_recorded() {
    let f = fx();
    f.saved.offer(f.root(), "v", text(""), f.at(0));
    f.saved.offer(f.root(), "v", text("   "), f.at(1000));
    assert!(f.saved.recent(f.root(), f.at(5000)).is_empty());
}

#[test]
fn recent_is_newest_first_once_each_and_the_last_fifty() {
    let f = fx();
    for i in 0..60u64 {
        f.saved
            .offer(f.root(), "v", text(&format!("q{i}")), f.at(i * 1000));
    }
    f.saved.offer(f.root(), "v", text("q58"), f.at(60_000));
    let r = f.saved.recent(f.root(), f.at(61_000));
    assert_eq!(r.len(), RECENT_MAX);
    assert_eq!(typed(&r[..3]), vec!["q58", "q59", "q57"]);
    assert_eq!(r.last().unwrap().query.typed(), "q10");
}

/// [D] An offer never writes on the search's path (an fsync there held a search's first rows past the next key): it
/// says when a write is due, and `flush` (the hub runs it off that path) writes; a search recorded again while it is
/// already the newest changes nothing and asks for no write.
#[test]
fn an_offer_writes_only_through_flush_and_only_a_change() {
    let f = fx();
    let file = f.saved.file(f.root());
    assert!(!f.saved.offer(f.root(), "v", text("one"), f.at(0)));
    assert!(f.saved.offer(f.root(), "v", text("one"), f.at(1000)));
    assert!(!file.exists());
    f.saved.flush(f.root()).unwrap();
    let again = Saved::new(f.state.path().join("hub/search"));
    assert_eq!(
        typed(&again.recent(f.root(), crate::clock::now())),
        vec!["one"]
    );
    assert!(!f.saved.offer(f.root(), "v", text("one"), f.at(2000)));
    assert!(!f.saved.offer(f.root(), "v", text("two"), f.at(3000)));
    assert!(f.saved.offer(f.root(), "v", text("three"), f.at(4000)));
}

#[test]
fn recent_is_per_project_and_kept_across_hubs() {
    let f = fx();
    let other = tempfile::tempdir().unwrap();
    f.saved.offer(f.root(), "v", text("here"), f.at(0));
    f.saved.offer(other.path(), "v", text("there"), f.at(0));
    assert_eq!(typed(&f.saved.recent(f.root(), f.at(1000))), vec!["here"]);
    assert_eq!(
        typed(&f.saved.recent(other.path(), f.at(1000))),
        vec!["there"]
    );
    let again = Saved::new(f.state.path().join("hub/search"));
    assert_eq!(
        typed(&again.recent(f.root(), crate::clock::now())),
        vec!["here"]
    );
}

#[test]
fn recent_keeps_the_mode_scope_and_toggles_but_not_the_open_files() {
    let f = fx();
    let mut s = text("todo!(");
    s.query = FindQuery::Text {
        text: "todo!(".into(),
        case: Some(true),
        word: None,
        regexp: Some(false),
    };
    s.scope = Some(SearchScope {
        kind: ScopeKind::Open,
        base: None,
        changed_lines: Some(true),
        files: Some(vec![AbsPath::new("/x/a.rs").unwrap()]),
    });
    s.replace = Some("unimplemented!(".into());
    f.saved.offer(f.root(), "v", s.clone(), f.at(0));
    let r = f.saved.recent(f.root(), f.at(1000));
    let mut want = s;
    want.scope.as_mut().unwrap().files = None;
    assert_eq!(r, vec![want]);
}

#[test]
fn saved_put_list_and_delete() {
    let f = fx();
    f.saved.put(f.root(), "TODOs", text("TODO"), false).unwrap();
    f.saved.put(f.root(), "Fixme", text("FIXME"), true).unwrap();
    f.saved.put(f.root(), "TODOs", text("todo"), true).unwrap();
    let (list, problems) = f.saved.list(f.root());
    assert!(problems.is_empty());
    let names: Vec<_> = list
        .iter()
        .map(|s| (s.name.as_str(), s.search.query.typed(), s.pinned, s.project))
        .collect();
    assert_eq!(
        names,
        vec![
            ("TODOs", "todo", true, false),
            ("Fixme", "FIXME", true, false)
        ]
    );
    assert!(f.saved.delete(f.root(), "TODOs").unwrap());
    assert!(!f.saved.delete(f.root(), "TODOs").unwrap());
    let again = Saved::new(f.state.path().join("hub/search"));
    assert_eq!(again.list(f.root()).0.len(), 1);
}

fn project_file(f: &Fx, text: &str) {
    std::fs::create_dir_all(f.root().join(".drgnx")).unwrap();
    std::fs::write(f.root().join(PROJECT_FILE), text).unwrap();
}

#[test]
fn the_project_file_is_read_as_data() {
    let (got, problems) = read_project(
        br#";; the team's searches
(:name "Unwraps" :mode text :query "\\.unwrap\\(\\)" :regexp t :case t :include ("*.rs") :scope changed :changed-lines t)
(:name "Queue" :mode symbol :query "drgnx-gateway--queue")
(:name "Retries" :mode meaning :query "where do we retry a failed request" :scope branch :base "main")
"#,
    );
    assert_eq!(problems, Vec::<String>::new());
    let names: Vec<_> = got
        .iter()
        .map(|(n, s)| (n.as_str(), s.query.typed()))
        .collect();
    assert_eq!(
        names,
        vec![
            ("Unwraps", r"\.unwrap\(\)"),
            ("Queue", "drgnx-gateway--queue"),
            ("Retries", "where do we retry a failed request")
        ]
    );
    assert_eq!(
        got[0].1.query,
        FindQuery::Text {
            text: r"\.unwrap\(\)".into(),
            case: Some(true),
            word: None,
            regexp: Some(true)
        }
    );
    assert_eq!(got[0].1.include, Some(vec!["*.rs".to_string()]));
    let scope = got[0].1.scope.clone().unwrap();
    assert_eq!(
        (scope.kind, scope.changed_lines),
        (ScopeKind::Changed, Some(true))
    );
    assert_eq!(
        got[2].1.scope.clone().unwrap().base.as_deref(),
        Some("main")
    );
}

#[test]
fn a_form_that_is_not_a_plist_of_data_is_refused_and_nothing_runs() {
    let marker = tempfile::tempdir().unwrap();
    let ran = marker.path().join("ran");
    let src = format!(
        r#"(:name "ok" :query "x")
"just a string"
(:name "odd" :query)
(:name "code" :query (shell-command "touch {}"))
(:name "unknown" :query "x" :frobnicate t)
(:name "mode" :mode regex :query "x")
"#,
        ran.display()
    );
    let (got, problems) = read_project(src.as_bytes());
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].0, "ok");
    assert_eq!(problems.len(), 5, "{problems:?}");
    assert!(!ran.exists());
    // a reader macro refuses the whole file: `#.` would evaluate in Emacs
    let (got, problems) = read_project(b"(:name \"a\" :query #.(delete-file \"x\"))");
    assert!(got.is_empty());
    assert_eq!(problems.len(), 1);
}

#[test]
fn a_printed_form_reads_back_the_same() {
    let mut s = text("say \"hi\" \\ there");
    s.replace = Some("bye".into());
    s.exclude = Some(vec!["target".into(), "*.lock".into()]);
    s.scope = Some(SearchScope {
        kind: ScopeKind::Branch,
        base: Some("origin/main".into()),
        changed_lines: None,
        files: None,
    });
    let form = print_form("Greeting \"x\"", &s);
    let (got, problems) = read_project(form.as_bytes());
    assert!(problems.is_empty(), "{problems:?} in {form}");
    assert_eq!(got, vec![("Greeting \"x\"".to_string(), s)]);
}

#[test]
fn project_searches_are_listed_after_the_hubs_and_marked() {
    let f = fx();
    project_file(&f, "(:name \"Shared\" :query \"x\")\n(:name 7)\n");
    f.saved.put(f.root(), "Mine", text("y"), false).unwrap();
    let (list, problems) = f.saved.list(f.root());
    let names: Vec<_> = list.iter().map(|s| (s.name.as_str(), s.project)).collect();
    assert_eq!(names, vec![("Mine", false), ("Shared", true)]);
    assert_eq!(problems.len(), 1);
}

#[test]
fn share_writes_the_project_file_atomically_and_keeps_the_rest() {
    let f = fx();
    project_file(&f, ";; keep this comment\n(:name \"Other\" :query \"o\")\n");
    f.saved.put(f.root(), "Mine", text("first"), true).unwrap();
    let path = f.saved.share(f.root(), "Mine").unwrap();
    assert_eq!(path, f.root().join(PROJECT_FILE));
    f.saved.put(f.root(), "Mine", text("second"), true).unwrap();
    f.saved.share(f.root(), "Mine").unwrap();
    let body = std::fs::read_to_string(&path).unwrap();
    assert!(
        body.starts_with(";; keep this comment\n(:name \"Other\" :query \"o\")\n"),
        "{body}"
    );
    let (got, problems) = read_project(body.as_bytes());
    assert!(problems.is_empty());
    let names: Vec<_> = got
        .iter()
        .map(|(n, s)| (n.as_str(), s.query.typed()))
        .collect();
    assert_eq!(names, vec![("Other", "o"), ("Mine", "second")]);
    let left: Vec<_> = std::fs::read_dir(f.root().join(".drgnx"))
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    assert_eq!(left, vec![std::ffi::OsString::from("searches.eld")]);
    // the hub's own entry stays (its pin is the user's), marked shared; the project's copy is not listed twice
    let (list, _) = f.saved.list(f.root());
    let names: Vec<_> = list
        .iter()
        .map(|s| (s.name.as_str(), s.project, s.shared, s.pinned))
        .collect();
    assert_eq!(
        names,
        vec![("Mine", false, true, true), ("Other", true, false, false)]
    );
}

#[test]
fn share_creates_the_folder_and_refuses_a_file_it_cannot_read() {
    let f = fx();
    f.saved.put(f.root(), "Mine", text("x"), false).unwrap();
    assert_eq!(f.saved.share(f.root(), "Nope"), Err(ShareError::NoSuch));
    f.saved.share(f.root(), "Mine").unwrap();
    assert!(f.root().join(PROJECT_FILE).is_file());
    project_file(&f, "(:name \"broken\" :query \"x\"");
    assert!(matches!(
        f.saved.share(f.root(), "Mine"),
        Err(ShareError::Refused(_))
    ));
    assert_eq!(
        std::fs::read_to_string(f.root().join(PROJECT_FILE)).unwrap(),
        "(:name \"broken\" :query \"x\""
    );
}
