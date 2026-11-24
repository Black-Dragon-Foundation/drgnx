//! The past sessions' scan, index and rows, on a temp home with hand-written session files (invented content).

use super::*;
use std::io::Write;

/// Built in two pieces: this source is public, and a key-shaped literal would trip the secret scan.
fn key() -> String {
    ["sk-ant-", "api03-Zk3Qw9Lm2Xv8Rt5Yp7Hn4Bd6Fg1Jc0Ua"].concat()
}

/// Claude Code's sessions folder under a home.
const CLAUDE_PROJECTS: &str = ".claude/projects";

fn claude_lines(id: &str, cwd: &str, said: &str) -> String {
    format!(
        "{}\n{}\n",
        json!({"type":"user","uuid":"u1","sessionId":id,"cwd":cwd,"gitBranch":"main","timestamp":"2026-11-01T10:00:00Z",
               "message":{"role":"user","content":said}}),
        json!({"type":"assistant","uuid":"u2","sessionId":id,"timestamp":"2026-11-01T10:00:05Z",
               "message":{"role":"assistant","content":[{"type":"text","text":"Counting the apples."}]}}),
    )
}

struct Home {
    _tmp: tempfile::TempDir,
    home: PathBuf,
    state: PathBuf,
    history: History,
}

impl Home {
    fn new() -> Home {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let state = tmp.path().join("state");
        std::fs::create_dir_all(&home).unwrap();
        let history = History::default();
        // the env overrides as the user may set them: Codex's home moved, Claude's and Gemini's where they default
        let codex = home.join("codex-home");
        history.configure(
            state.join(DB),
            Roots::of(&home, |v| {
                (v == "CODEX_HOME").then(|| codex.to_string_lossy().into_owned())
            }),
        );
        Home {
            _tmp: tmp,
            home,
            state,
            history,
        }
    }

    fn write(&self, rel: &str, text: &str) -> PathBuf {
        let p = self.home.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        crate::fsio::write(&p, text).unwrap();
        p
    }

    fn claude(&self, id: &str, said: &str) -> PathBuf {
        self.write(
            &format!("{CLAUDE_PROJECTS}/-w-orchard/{id}.jsonl"),
            &claude_lines(id, "/w/orchard", said),
        )
    }

    fn list(&self) -> Vec<PastSession> {
        lock(&self.history.list).clone()
    }
}

fn gemini_text() -> String {
    format!(
        "{}\n{}\n{}\n",
        json!({"sessionId":"9a1b2c3d","startTime":"2026-11-02T09:00:00Z","lastUpdated":"2026-11-02T09:00:00Z","directories":["/w/pear"]}),
        json!({"id":"m1","timestamp":"2026-11-02T09:00:01Z","type":"user","content":[{"text":"weigh the pears"}]}),
        json!({"id":"m2","timestamp":"2026-11-02T09:00:04Z","type":"gemini","content":"Weighing."}),
    )
}

fn codex_text() -> String {
    format!(
        "{}\n{}\n",
        json!({"timestamp":"2026-11-03T07:00:00Z","type":"session_meta","payload":{"id":"0199-c0de","timestamp":"2026-11-03T07:00:00Z","cwd":"/w/plum"}}),
        json!({"timestamp":"2026-11-03T07:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"sort the plums"}]}}),
    )
}

#[test]
fn a_scan_finds_the_three_clis_under_their_roots() {
    let h = Home::new();
    h.claude("5f0c", "count the apples");
    h.write(
        ".gemini/tmp/ab12/chats/session-2026-11-02T09-00-9a1b2c3d.jsonl",
        &gemini_text(),
    );
    h.write(
        "codex-home/sessions/2026/11/03/rollout-2026-11-03T07-00-00-0199-c0de.jsonl",
        &codex_text(),
    );
    // not sessions: another folder of the CLI, a file of the wrong name
    h.write(".claude/todos/x.jsonl", "{}\n");
    h.write("codex-home/sessions/2026/11/03/notes.jsonl", &codex_text());
    assert_eq!(h.history.scan().unwrap(), 3);
    let mut got: Vec<(PastProvider, String, String)> = h
        .list()
        .into_iter()
        .map(|s| (s.provider, s.id, s.title))
        .collect();
    got.sort_by(|a, b| a.1.cmp(&b.1));
    assert_eq!(
        got,
        [
            (
                PastProvider::Codex,
                "0199-c0de".into(),
                "sort the plums".into()
            ),
            (
                PastProvider::Claude,
                "5f0c".into(),
                "count the apples".into()
            ),
            (
                PastProvider::Gemini,
                "9a1b2c3d".into(),
                "weigh the pears".into()
            ),
        ]
    );
}

#[test]
fn the_index_is_the_users_alone() {
    let h = Home::new();
    h.claude("5f0c", "count the apples");
    h.history.scan().unwrap();
    let mode = std::fs::metadata(h.state.join(DB))
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600);
}

#[test]
fn a_scan_changes_no_byte_and_no_time_of_the_files() {
    let h = Home::new();
    let a = h.claude("5f0c", "count the apples");
    let b = h.write(".gemini/tmp/ab12/chats/session-x.jsonl", &gemini_text());
    let look = |p: &Path| {
        let m = std::fs::metadata(p).unwrap();
        (
            std::fs::read(p).unwrap(),
            mtime_of(&m),
            m.permissions().mode(),
        )
    };
    let before = (look(&a), look(&b));
    h.history.scan().unwrap();
    h.history.scan().unwrap();
    assert_eq!((look(&a), look(&b)), before);
}

#[test]
fn an_append_is_read_on_from_its_offset_and_found() {
    let h = Home::new();
    let p = h.claude("5f0c", "count the apples");
    h.history.scan().unwrap();
    assert!(h.history.search("pears").unwrap().is_empty());
    let more = json!({"type":"user","uuid":"u3","sessionId":"5f0c","timestamp":"2026-11-01T10:01:00Z",
                      "message":{"role":"user","content":"and the pears"}});
    let mut f = crate::fsio::append(&p, false).unwrap();
    writeln!(f, "{more}").unwrap();
    drop(f);
    h.history.scan().unwrap();
    let hits = h.history.search("pears").unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].session.id, "5f0c");
    assert_eq!(hits[0].session.turns, 2);
    // read on, not again: the reader kept its place at the file's end
    let i = lock(&h.history.inner);
    let (_, rd) = i.readers.iter().find(|(q, _)| *q == p).unwrap();
    assert_eq!(rd.offset(), std::fs::metadata(&p).unwrap().len());
}

#[test]
fn a_shrunk_file_is_read_again_and_a_deleted_one_goes() {
    let h = Home::new();
    let p = h.claude("5f0c", "count the apples");
    h.claude("77aa", "peel the oranges");
    h.history.scan().unwrap();
    assert_eq!(h.list().len(), 2);
    // rewritten shorter, with other words: the old ones are gone from the index
    let short = json!({"type":"user","uuid":"u1","sessionId":"5f0c","cwd":"/w/orchard","timestamp":"2026-11-01T10:00:00Z",
                       "message":{"role":"user","content":"rake"}});
    crate::fsio::write(&p, format!("{short}\n")).unwrap();
    h.history.scan().unwrap();
    assert!(
        h.history
            .search("apples")
            .unwrap()
            .iter()
            .all(|x| x.session.id != "5f0c")
    );
    assert_eq!(h.history.search("rake").unwrap().len(), 1);
    std::fs::remove_file(&p).unwrap();
    h.history.scan().unwrap();
    assert_eq!(h.list().len(), 1);
    assert!(h.history.search("rake").unwrap().is_empty());
}

#[test]
fn search_finds_every_word_and_the_index_holds_no_key() {
    let h = Home::new();
    h.claude("5f0c", &format!("count the apples with {}", key()));
    h.claude("77aa", "count the oranges");
    h.history.scan().unwrap();
    let ids = |q: &str| -> Vec<String> {
        h.history
            .search(q)
            .unwrap()
            .into_iter()
            .map(|x| x.session.id)
            .collect()
    };
    assert_eq!(ids("count apples"), ["5f0c"]);
    assert_eq!(ids("coun").len(), 2, "the last word is a prefix");
    h.history.search("\"unbalanced").unwrap();
    // the key never reached the index: not as text, not in the file
    assert!(ids("Zk3Qw9Lm2Xv8Rt5Yp7Hn4Bd6Fg1Jc0Ua").is_empty());
    let raw = std::fs::read(h.state.join(DB)).unwrap();
    assert!(!raw.windows(10).any(|w| w == b"Zk3Qw9Lm2X"));
}

#[test]
fn the_workspaces_sessions_come_first() {
    let s = |id: &str, cwd: &str| PastSession {
        provider: PastProvider::Claude,
        id: id.into(),
        title: id.into(),
        cwd: Some(cwd.into()),
        branch: None,
        started: None,
        updated: Some("2026-11-01T10:00:00Z".into()),
        turns: 1,
        live: None,
    };
    let list = [
        s("a", "/w/other"),
        s("b", "/w/orchard/sub"),
        s("c", "/w/orchardx"),
    ];
    let keys: Vec<String> = list_rows(&list, Some("/w/orchard"), None, None)
        .into_iter()
        .map(|r| r.key)
        .collect();
    assert_eq!(
        keys,
        [
            "h:here",
            "h:claude:b",
            "h:other",
            "h:claude:a",
            "h:claude:c"
        ]
    );
    assert_eq!(list_rows(&[], None, None, None)[0].key, "h:none");
}

#[test]
fn a_section_of_another_list_shows_a_few_and_says_how_many_more() {
    let s = |id: &str, cwd: &str| PastSession {
        provider: PastProvider::Claude,
        id: id.into(),
        title: id.into(),
        cwd: Some(cwd.into()),
        branch: None,
        started: None,
        updated: Some("2026-11-01T10:00:00Z".into()),
        turns: 1,
        live: None,
    };
    let list = [
        s("a", "/w/other"),
        s("b", "/w/orchard"),
        s("c", "/w/other"),
        s("d", "/w/other"),
    ];
    let keys = |limit| -> Vec<String> {
        list_rows(&list, Some("/w/orchard"), None, Some(limit))
            .into_iter()
            .map(|r| r.key)
            .collect()
    };
    assert_eq!(
        keys(2),
        [
            "h:past",
            "h:here",
            "h:claude:b",
            "h:other",
            "h:claude:a",
            "h:more"
        ]
    );
    // the workspace's one session fills a limit of one: the other projects' header goes with its rows
    assert_eq!(keys(1), ["h:past", "h:here", "h:claude:b", "h:more"]);
    assert_eq!(keys(4).last().map(String::as_str), Some("h:claude:d"));
    let more = list_rows(&list, Some("/w/orchard"), None, Some(2));
    assert!(
        more.last().unwrap().text.contains("2 more"),
        "{:?}",
        more.last()
    );
}

#[test]
fn a_transcript_draws_as_the_panel_draws_it() {
    let rd = minni::parse(
        Provider::Claude,
        claude_lines("5f0c", "/w", "count the apples").as_bytes(),
    );
    let entries: Vec<Entry> = rd.entries().iter().map(entry_of).collect();
    assert_eq!(entries[0].kind, EntryType::User);
    let rows = transcript_rows(&entries);
    let text: String = rows
        .iter()
        .map(|r| r.text.clone())
        .collect::<Vec<_>>()
        .join("\n");
    assert!(text.contains("count the apples"), "{text}");
    assert!(text.contains("Counting the apples."), "{text}");
}

#[test]
fn a_grant_is_one_regular_file_under_its_root() {
    let h = Home::new();
    let p = h.claude("5f0c", "count the apples");
    let root = h.home.join(".claude");
    assert_eq!(checked_file(&root, &p).unwrap(), p.canonicalize().unwrap());
    // a link to it, a folder, a file outside the root
    let link = p.with_file_name("link.jsonl");
    std::os::unix::fs::symlink(&p, &link).unwrap();
    assert!(checked_file(&root, &link).is_err());
    assert!(checked_file(&root, p.parent().unwrap()).is_err());
    let out = h.write("elsewhere/x.jsonl", "{}\n");
    assert!(checked_file(&root, &out).is_err());
    let dotted = root.join("projects/-w-orchard/../-w-orchard/5f0c.jsonl");
    assert!(
        checked_file(&root, &dotted).is_err(),
        "a path with .. is not its true name"
    );
}

/// A link above the root is the machine's (macOS's `/var` is `/private/var`): the file is granted whichever way the
/// root and the file name it; a link below the root is still refused.
#[test]
fn a_link_above_the_root_is_the_machines_and_one_below_it_is_refused() {
    let h = Home::new();
    let p = h.claude("5f0c", "count the apples");
    let linked = h.home.with_file_name("linked-home");
    std::os::unix::fs::symlink(&h.home, &linked).unwrap();
    let via_link = linked.join(p.strip_prefix(&h.home).unwrap());
    let real = p.canonicalize().unwrap();
    assert_eq!(
        checked_file(&linked.join(".claude"), &via_link),
        Ok(real.clone())
    );
    assert_eq!(
        checked_file(&h.home.join(".claude"), &via_link),
        Ok(real.clone())
    );
    assert_eq!(checked_file(&linked.join(".claude"), &p), Ok(real));
    // a folder below the root that is a link to another folder of the root
    let root = h.home.join(".claude");
    std::os::unix::fs::symlink(p.parent().unwrap(), root.join("projects/-w-elsewhere")).unwrap();
    assert!(checked_file(&root, &root.join("projects/-w-elsewhere/5f0c.jsonl")).is_err());
}

#[test]
fn the_history_methods_are_the_users_alone() {
    let ours: Vec<_> = runstav::registry::registry()
        .iter()
        .filter(|m| m.name.starts_with("agents/history/"))
        .collect();
    assert_eq!(ours.len(), 6);
    for m in ours {
        assert_eq!(m.classes, [runstav::registry::Class::User], "{}", m.name);
    }
    // no coordination tool an agent has reads them
    for t in norn::tools::tools() {
        let name = t.name();
        assert!(
            !name.contains("history") || name.starts_with("graph_history"),
            "{name}"
        );
    }
}

#[test]
fn fts_queries_are_phrases_with_a_prefix_last() {
    assert_eq!(
        fts_query("count  apples").as_deref(),
        Some("\"count\" \"apples\"*")
    );
    assert_eq!(fts_query("a\"b").as_deref(), Some("\"a\"\"b\"*"));
    assert_eq!(fts_query("   "), None);
}

#[test]
fn a_cli_taken_out_leaves_the_index_and_off_deletes_it() {
    let h = Home::new();
    h.claude("5f0c", "count the apples");
    h.write(".gemini/tmp/ab12/chats/session-x.jsonl", &gemini_text());
    h.history.scan().unwrap();
    assert_eq!(h.list().len(), 2);
    let roots = h.history.roots().unwrap().only(&["gemini".to_owned()]);
    assert_eq!(roots.claude, None);
    h.history.configure(h.state.join(DB), roots);
    h.history.scan().unwrap();
    assert_eq!(
        h.list().iter().map(|s| s.provider).collect::<Vec<_>>(),
        [PastProvider::Gemini]
    );
    assert!(h.history.search("apples").unwrap().is_empty());
    h.history.off(&h.state.join(DB));
    assert!(!h.state.join(DB).exists());
    assert!(h.list().is_empty());
    assert_eq!(h.history.scan().unwrap(), 0, "nothing is read while off");
    assert!(!h.state.join(DB).exists());
}

#[test]
fn an_unchanged_scan_opens_no_file_and_writes_nothing() {
    let h = Home::new();
    h.claude("c1", "count the apples");
    h.claude("c2", "count the pears");
    assert_eq!(h.history.scan_changed().unwrap(), (2, true));
    let reads = h.history.reads();
    assert_eq!(reads, 2);
    let db = h.state.join(DB);
    // the index's mtime moved into the past, so a write would show without waiting for a clock tick
    let past =
        std::fs::metadata(&db).unwrap().modified().unwrap() - std::time::Duration::from_secs(3600);
    std::fs::File::options()
        .write(true)
        .open(&db)
        .unwrap()
        .set_modified(past)
        .unwrap();
    let before = std::fs::metadata(&db).unwrap().modified().unwrap();
    let (n, changed) = h.history.scan_changed().unwrap();
    assert_eq!((n, changed), (2, false), "nothing changed");
    assert_eq!(h.history.reads(), reads, "no file was opened");
    assert_eq!(
        std::fs::metadata(&db).unwrap().modified().unwrap(),
        before,
        "the index was not written"
    );
    // a changed file is read again, and only that one
    let p = h.claude("c1", "count the apples and the plums");
    crate::fsio::append(&p, false)
        .unwrap()
        .write_all(b"\n")
        .unwrap();
    assert!(h.history.scan_changed().unwrap().1);
    assert_eq!(h.history.reads(), reads + 1);
    // a file gone is dropped and reported
    std::fs::remove_file(&p).unwrap();
    assert_eq!(h.history.scan_changed().unwrap(), (1, true));
}

#[test]
fn a_session_older_than_the_cap_is_neither_listed_nor_searchable() {
    let h = Home::new();
    let old = h.claude("old1", "count the quinces");
    let fresh = h.claude("new1", "count the quinces");
    let back = |p: &Path, days: u64| {
        // from the file's own mtime (just made), so no clock is read
        let t = std::fs::metadata(p).unwrap().modified().unwrap()
            - std::time::Duration::from_secs(days * 86_400);
        std::fs::File::options()
            .write(true)
            .open(p)
            .unwrap()
            .set_modified(t)
            .unwrap();
    };
    back(&old, 200);
    back(&fresh, 10);
    // no cap: both
    assert_eq!(h.history.scan().unwrap(), 2);
    // the cap of 180 days: the old one leaves the index, the 10-day one stays
    let roots = h.history.roots().unwrap().within(180);
    h.history.configure(h.state.join(DB), roots);
    assert_eq!(h.history.scan().unwrap(), 1);
    let ids: Vec<String> = h.list().into_iter().map(|s| s.id).collect();
    assert_eq!(ids, ["new1"]);
    let hits = h.history.search("quinces").unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].session.id, "new1");
    // 0 is no cap
    let roots = h.history.roots().unwrap().within(0);
    h.history.configure(h.state.join(DB), roots);
    assert_eq!(h.history.scan().unwrap(), 2);
}

#[test]
fn a_file_of_unknown_line_types_is_drift_and_ignored_types_are_not() {
    let h = Home::new();
    // 12 lines: 2 known, 10 of a type no reader has heard of
    let mut odd = claude_lines("odd1", "/w/orchard", "count the apples");
    for i in 0..10 {
        odd.push_str(&format!("{}\n", json!({"type":"brand-new-kind","n":i})));
    }
    h.write(&format!("{CLAUDE_PROJECTS}/-w-orchard/odd1.jsonl"), &odd);
    // 12 lines of types skipped on purpose
    let mut quiet = claude_lines("quiet1", "/w/orchard", "count the pears");
    for i in 0..10 {
        quiet.push_str(&format!(
            "{}\n",
            json!({"type":"file-history-snapshot","n":i})
        ));
    }
    h.write(
        &format!("{CLAUDE_PROJECTS}/-w-orchard/quiet1.jsonl"),
        &quiet,
    );
    // few lines: too small to say
    h.write(
        &format!("{CLAUDE_PROJECTS}/-w-orchard/tiny1.jsonl"),
        &format!("{}\n", json!({"type":"brand-new-kind"})),
    );
    h.history.scan().unwrap();
    let d = h.history.drift().unwrap();
    assert_eq!(
        d,
        vec![PastDrift {
            provider: PastProvider::Claude,
            files: 1,
            unknown_pct: 83
        }]
    );
}

/// A past Claude session resumed through the mock `claude-agent-acp` (`ratatoskr-mock acp --as claude`, a real
/// process) on each route: the hub sends `session/resume` with the CLI's own id (never a drgnx one) and the session's
/// cwd, and the mock, which resumes only a conversation that is where Claude Code reads it, starts the session.
async fn resume_through_the_mock(route: PastRoute) {
    use crate::agents::session::attach_tests::Fx;
    let fx = Fx::new();
    let id = "5f0c1e2a-0000-4000-8000-0000000000aa";
    let cwd = fx.work();
    // where claude-agent-acp's Claude Code reads it: the config dir's projects/<cwd as a folder name>/<id>.jsonl
    let folder: String = cwd
        .to_str()
        .unwrap()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    let file = fx
        .dir
        .path()
        .join("home")
        .join(".claude")
        .join("projects")
        .join(&folder)
        .join(format!("{id}.jsonl"));
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    crate::fsio::write(
        &file,
        claude_lines(id, cwd.to_str().unwrap(), "count the apples"),
    )
    .unwrap();
    fx.front.refresh_settings().await;
    assert_eq!(scan_now(&fx.front).await.unwrap(), 1);
    let caller = Caller {
        class: runstav::registry::Class::User,
        sid: None,
        job: None,
        conn_id: 1,
    };
    let done = resume(
        &fx.front,
        &caller,
        PastResume {
            provider: PastProvider::Claude,
            id: runstav::types::Bounded(id.into()),
            route,
            profile: Some(runstav::types::Bounded("mock-claude".into())),
        },
    )
    .await
    .expect("the resume starts a session");
    assert_ne!(done.session, id, "the drgnx id is not the CLI's");
    let logged = fx.logged("a.log", "session/resume");
    assert_eq!(logged.len(), 1, "{logged:?}");
    assert_eq!(logged[0]["sessionId"], json!(id), "the CLI's own id");
    assert_eq!(
        logged[0]["cwd"],
        json!(cwd.to_str().unwrap()),
        "the session's cwd"
    );
    assert!(
        fx.logged("a.log", "session/new").is_empty(),
        "never a fresh session"
    );
}

#[tokio::test]
async fn a_past_claude_session_resumes_through_the_mock_on_a_copy() {
    resume_through_the_mock(PastRoute::Copy).await;
}

#[tokio::test]
async fn a_past_claude_session_resumes_through_the_mock_on_the_original() {
    resume_through_the_mock(PastRoute::Original).await;
}

#[test]
fn a_cold_folder_is_read_again_when_it_changes_or_on_the_31st_walk() {
    let h = Home::new();
    let back = |p: &Path| {
        // from the file's own mtime (just made), so no clock is read
        let t = std::fs::metadata(p).unwrap().modified().unwrap()
            - std::time::Duration::from_secs(2 * 3600);
        std::fs::File::options()
            .write(true)
            .open(p)
            .unwrap()
            .set_modified(t)
            .unwrap();
    };
    let a = h.claude("cold1", "count the apples");
    let b = h.claude("cold2", "count the pears");
    back(&a);
    back(&b);
    // walk 1 reads the folder, which holds nothing changed within the hour: walk 2 takes it as it was
    assert_eq!(h.history.scan_changed().unwrap(), (2, true));
    assert_eq!(h.history.scan_changed().unwrap(), (2, false));
    let reads = h.history.reads();
    // an append to a cold file (its folder's change time does not move) is not seen by the next walks...
    let mut f = crate::fsio::append(&a, false).unwrap();
    f.write_all(b"{\"type\":\"user\",\"message\":{\"content\":\"more\"}}\n")
        .unwrap();
    drop(f);
    back(&a);
    for _ in 0..28 {
        assert!(!h.history.scan_changed().unwrap().1);
    }
    assert_eq!(h.history.reads(), reads);
    // ...until the next full walk (every 30th)
    assert!(h.history.scan_changed().unwrap().1);
    assert_eq!(h.history.reads(), reads + 1);
    // a file taken away changes its folder's change time: seen at once
    std::fs::remove_file(&b).unwrap();
    assert_eq!(h.history.scan_changed().unwrap(), (1, true));
}
