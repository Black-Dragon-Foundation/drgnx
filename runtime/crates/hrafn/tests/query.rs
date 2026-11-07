//! The query over a fixture project: the routes (symbol, name, path, keyword, vector), the fusion, the demotion of
//! tests and generated files, the scope, and the hit's lines found again in a file that moved.
//!
//! test-pattern: pure (D): the store thread answers in order, nothing here has a clock or a timeout.

use hrafn::query::{Query, Scope, search};
use hrafn::{Class, CodeStore, Lang, Listed, collect, lag, put_vectors, refresh};
use std::collections::HashMap;
use std::io;

const MODEL: &str = "m";
const DIMS: usize = 4;

struct File {
    path: &'static str,
    text: &'static str,
    class: Class,
    lang: Lang,
    generated: bool,
}

const fn file(path: &'static str, text: &'static str, class: Class) -> File {
    File {
        path,
        text,
        class,
        lang: match class {
            Class::Docs => Lang::Markdown,
            _ => Lang::Elisp,
        },
        generated: false,
    }
}

/// One definer per file, so a chunk is one definition. `drgnx-timer-fire` is defined in the code and again in a test.
fn fixture() -> Vec<File> {
    vec![
        file(
            "core/drgnx-timer.el",
            ";;; drgnx-timer.el --- timers\n\n(defun drgnx-timer-fire (id)\n  \"Run the timer ID when the timer is due: the timer fires.\"\n  (funcall id))\n",
            Class::Code,
        ),
        file(
            "core/drgnx-macro.el",
            ";;; drgnx-macro.el --- macros\n\n(defmacro drgnx-with-timer (spec &rest body)\n  \"Run BODY with a timer made from SPEC.\"\n  `(progn ,spec ,@body))\n",
            Class::Code,
        ),
        file(
            "core/drgnx-var.el",
            ";;; drgnx-var.el --- tables\n\n(defvar drgnx-timer-table nil\n  \"The table of live timers.\")\n",
            Class::Code,
        ),
        file(
            "core/drgnx-hub.el",
            ";;; drgnx-hub.el --- the hub\n\n(defun drgnx-hub-call (method params)\n  \"Send METHOD with PARAMS to the hub and return its answer.\"\n  (ignore method params))\n",
            Class::Code,
        ),
        file(
            "core/drgnx-ai.el",
            ";;; drgnx-ai.el --- ai\n\n(defun drgnx-ai-embed (texts)\n  \"Embed TEXTS through the provider of the embed role.\"\n  (ignore texts))\n",
            Class::Code,
        ),
        file(
            "test/drgnx-timer-test.el",
            ";;; drgnx-timer-test.el --- tests\n\n(defun drgnx-timer-fire (id)\n  \"A stub for the test: the timer fires.\"\n  id)\n",
            Class::Test,
        ),
        file(
            "docs/timers.md",
            "# Timers\n\nA timer fires when it is due. The function drgnx-timer-fire runs it.\n",
            Class::Docs,
        ),
        File {
            generated: true,
            ..file(
                "core/drgnx-loaddefs.el",
                ";;; drgnx-loaddefs.el --- generated\n\n(defun drgnx-loaddefs-timer ()\n  \"The timer fires when the timer is due.\")\n",
                Class::Code,
            )
        },
    ]
}

/// Every definer of the fixture and the file that defines it (the test file's stub of `drgnx-timer-fire` comes second).
const DEFINERS: &[(&str, &str)] = &[
    ("drgnx-timer-fire", "core/drgnx-timer.el"),
    ("drgnx-with-timer", "core/drgnx-macro.el"),
    ("drgnx-timer-table", "core/drgnx-var.el"),
    ("drgnx-hub-call", "core/drgnx-hub.el"),
    ("drgnx-ai-embed", "core/drgnx-ai.el"),
];

async fn indexed() -> (
    tempfile::TempDir,
    CodeStore,
    HashMap<&'static str, &'static str>,
) {
    let dir = tempfile::tempdir().unwrap();
    let store = CodeStore::open(&dir.path().join("code.db")).unwrap();
    let files = fixture();
    let listed: Vec<Listed> = files
        .iter()
        .map(|f| Listed {
            path: f.path.into(),
            blob: format!("blob-{}", f.path),
            class: f.class,
            lang: f.lang,
            generated: f.generated,
            size: f.text.len() as u64,
        })
        .collect();
    let texts: HashMap<&str, &str> = files.iter().map(|f| (f.path, f.text)).collect();
    let by_path = texts.clone();
    refresh(
        &store,
        &listed,
        &move |p: &str| {
            by_path
                .get(p)
                .map(|t| t.as_bytes().to_vec())
                .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
        },
        &[(MODEL, DIMS)],
    )
    .await
    .unwrap();
    (dir, store, texts)
}

fn q(text: &str, scope: Scope) -> Query {
    Query {
        text: text.into(),
        scope,
        k: 10,
    }
}

/// The files as they are, so nothing is moved.
fn unchanged(texts: HashMap<&'static str, &'static str>) -> impl Fn(&str) -> Option<String> + Sync {
    move |p: &str| texts.get(p).map(|t| t.to_string())
}

/// Pattern D. A query that is one exact name puts its definition first, whatever else the words match; the test file's
/// stub of the same name comes after the code's.
#[tokio::test]
async fn exact_symbol_pins_definition() {
    let (_dir, store, texts) = indexed().await;
    let now = unchanged(texts);
    for (name, path) in DEFINERS {
        let a = search(&store, &q(name, Scope::All), None, &now)
            .await
            .unwrap();
        assert_eq!(a.hits[0].path, *path, "{name}: {:?}", a.hits);
        assert_eq!(a.hits[0].routes[0], "symbol", "{name}");
    }
    let a = search(&store, &q("drgnx-timer-fire", Scope::All), None, &now)
        .await
        .unwrap();
    let paths: Vec<&str> = a.hits.iter().map(|h| h.path.as_str()).collect();
    let code = paths
        .iter()
        .position(|p| *p == "core/drgnx-timer.el")
        .unwrap();
    let test = paths
        .iter()
        .position(|p| *p == "test/drgnx-timer-test.el")
        .unwrap();
    assert!(code < test, "non-test before test: {paths:?}");
}

/// Pattern D. Words that the code and the test both have: the code ranks above the test, and the test is still there.
#[tokio::test]
async fn test_file_demoted_not_dropped() {
    let (_dir, store, texts) = indexed().await;
    let a = search(
        &store,
        &q("timer fires when due", Scope::Code),
        None,
        &unchanged(texts),
    )
    .await
    .unwrap();
    let paths: Vec<&str> = a.hits.iter().map(|h| h.path.as_str()).collect();
    let code = paths.iter().position(|p| *p == "core/drgnx-timer.el");
    let test = paths.iter().position(|p| *p == "test/drgnx-timer-test.el");
    assert!(code.is_some() && test.is_some(), "{paths:?}");
    assert!(code < test, "{paths:?}");
    // the generated file is demoted, not dropped, too
    let gen_at = paths.iter().position(|p| *p == "core/drgnx-loaddefs.el");
    assert!(gen_at.is_some(), "{paths:?}");
    assert!(code < gen_at, "{paths:?}");
}

/// Pattern D. A scope narrows to its class.
#[tokio::test]
async fn scope_tests_only_tests() {
    let (_dir, store, texts) = indexed().await;
    let now = unchanged(texts);
    let tests = search(&store, &q("timer fires", Scope::Tests), None, &now)
        .await
        .unwrap();
    assert!(!tests.hits.is_empty());
    assert!(
        tests.hits.iter().all(|h| h.path.starts_with("test/")),
        "{:?}",
        tests.hits
    );
    let docs = search(&store, &q("timer fires", Scope::Docs), None, &now)
        .await
        .unwrap();
    assert_eq!(
        docs.hits
            .iter()
            .map(|h| h.path.as_str())
            .collect::<Vec<_>>(),
        ["docs/timers.md"]
    );
    let code = search(&store, &q("timer fires", Scope::Code), None, &now)
        .await
        .unwrap();
    assert!(
        code.hits.iter().all(|h| !h.path.starts_with("docs/")),
        "{:?}",
        code.hits
    );
}

/// Pattern D. A file name matches the path list, and the hit says the path route found it.
#[tokio::test]
async fn path_query_adds_path_list() {
    let (_dir, store, texts) = indexed().await;
    let now = unchanged(texts);
    let a = search(&store, &q("drgnx-hub.el", Scope::All), None, &now)
        .await
        .unwrap();
    assert_eq!(a.hits[0].path, "core/drgnx-hub.el", "{:?}", a.hits);
    assert!(a.hits[0].routes.contains(&"path"), "{:?}", a.hits[0].routes);
    // a bare file stem too
    let b = search(&store, &q("show me drgnx-hub", Scope::All), None, &now)
        .await
        .unwrap();
    assert!(
        b.hits
            .iter()
            .any(|h| h.path == "core/drgnx-hub.el" && h.routes.contains(&"path")),
        "{:?}",
        b.hits
    );
}

/// Pattern D. With no vector model the answer is keyword, symbol and path results at once, and says what it lacks.
#[tokio::test]
async fn no_model_answers_keyword_with_lag() {
    let (_dir, store, texts) = indexed().await;
    let a = search(
        &store,
        &q("embed role provider", Scope::Code),
        None,
        &unchanged(texts),
    )
    .await
    .unwrap();
    assert_eq!(a.hits[0].path, "core/drgnx-ai.el", "{:?}", a.hits);
    assert_eq!(a.model, None);
    assert_eq!(a.lag.model, None);
    let line = a.lag_line();
    assert!(line.starts_with("vectors: not used"), "{line}");
    assert!(
        line.contains("keyword and symbol results are current"),
        "{line}"
    );
}

/// Pattern D. The vector route: the nearest chunk comes in through it, and the lag line counts the files without
/// vectors of the model.
#[tokio::test]
async fn vector_route_and_lag_line() {
    let (_dir, store, texts) = indexed().await;
    let want = hrafn::missing(&store, MODEL, 100).await.unwrap();
    assert!(want.len() >= 6, "{}", want.len());
    // one chunk, the hub's, gets a vector; nothing else does
    let hub = want
        .iter()
        .find(|(_, t)| t.contains("drgnx-hub-call"))
        .unwrap()
        .0;
    put_vectors(&store, MODEL, &[(hub, vec![1.0, 0.0, 0.0, 0.0])])
        .await
        .unwrap();
    let a = search(
        &store,
        &q("completely unrelated words", Scope::All),
        Some((MODEL, &[1.0, 0.0, 0.0, 0.0])),
        &unchanged(texts),
    )
    .await
    .unwrap();
    assert_eq!(a.hits[0].path, "core/drgnx-hub.el", "{:?}", a.hits);
    assert_eq!(a.hits[0].routes, ["vector"]);
    assert_eq!(a.model.as_deref(), Some(MODEL));
    let behind = lag(&store, Some(MODEL)).await.unwrap().files_behind;
    assert!(behind >= 5, "{behind}");
    assert_eq!(a.lag.files_behind, behind);
    assert!(
        a.lag_line().contains(&format!("{behind} files behind")),
        "{}",
        a.lag_line()
    );
    let _ = collect(&store, MODEL).await;
}

/// Pattern D. The vector scan reads each vector once and looks its chunk up by key: its plan has no scan of `chunk` and
/// no list built from a subquery (that plan took 37 s on a 16,000-chunk project, 55 ms the other way).
#[tokio::test]
async fn the_vector_scan_plan_is_one_pass_over_the_vectors() {
    let (_dir, store, _texts) = indexed().await;
    let plan: Vec<String> = store
        .handle()
        .read(|c| {
            let mut st = c.prepare(&format!("explain query plan {}", hrafn::query::NEAREST_SQL))?;
            let rows = st
                .query_map([MODEL], |r| r.get::<_, String>(3))?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
        .unwrap();
    let text = plan.join("\n");
    assert!(!text.contains("LIST SUBQUERY"), "{text}");
    assert!(!text.contains("SCAN chunk"), "{text}");
    assert!(
        text.contains("SCAN v") || text.contains("SEARCH v"),
        "{text}"
    );
}

/// Pattern D. The scan touches the vectors and nothing else: a chunk is looked up only for a vector that enters the
/// best 200, not for each of the 50,000 (a subquery per vector was 160 ms of the 180 at 50,000 chunks).
#[tokio::test]
async fn the_vector_scan_reads_no_chunk_per_vector() {
    let (_dir, store, _texts) = indexed().await;
    let plan = plan_of(&store, hrafn::query::NEAREST_SQL, 1).await;
    assert!(!plan.contains("SUBQUERY"), "{plan}");
    assert!(!plan.contains("chunk"), "{plan}");
}

/// Pattern D. The lag every answer carries is counted on an index: a scan of the chunk table reads every chunk's text
/// (100 ms of each query at 50,000 chunks, twice more with a model).
#[tokio::test]
async fn the_lag_counts_are_passes_over_an_index() {
    let (_dir, store, _texts) = indexed().await;
    for sql in [
        hrafn::index::LAG_TOTAL_SQL,
        hrafn::index::LAG_BEHIND_SQL,
        hrafn::index::LAG_FILES_SQL,
    ] {
        let plan = plan_of(&store, sql, usize::from(sql.contains("?1"))).await;
        for line in plan.lines().filter(|l| l.starts_with("SCAN")) {
            assert!(line.contains("COVERING INDEX"), "{line}\n{plan}");
        }
    }
}

/// Pattern D. A path or symbol-name question reads the small tables (`file`, an index of symbol names), not the chunk
/// table with its text or a scan of every symbol: 7 ms per path token and 18 ms per name at 50,000 chunks.
#[tokio::test]
async fn path_and_name_routes_do_not_scan_chunks_or_symbols() {
    let (_dir, store, _texts) = indexed().await;
    for sql in [hrafn::query::PATH_ANY_SQL, hrafn::query::PATH_NAME_SQL] {
        let plan = plan_of(&store, sql, if sql.contains("?2") { 2 } else { 1 }).await;
        // the base's rows of `file`, by its primary key's first column (the view's tree)
        assert!(
            plan.contains("SEARCH f USING PRIMARY KEY (tree=?)"),
            "{plan}"
        );
        assert!(!plan.contains("SCAN c"), "{plan}");
    }
    let plan = plan_of(&store, hrafn::query::NAME_PREFIX_SQL, 1).await;
    assert!(plan.contains("symbol_name_nc"), "{plan}");
    assert!(!plan.contains("SCAN"), "{plan}");
}

/// The plan of SQL with BINDS parameters bound, one line per step.
async fn plan_of(store: &CodeStore, sql: &str, binds: usize) -> String {
    let sql = format!("explain query plan {sql}");
    store
        .handle()
        .read(move |c| {
            let mut st = c.prepare(&sql)?;
            let rows = st
                .query_map(rusqlite::params_from_iter(vec![MODEL; binds]), |r| {
                    r.get::<_, String>(3)
                })?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows.join("\n"))
        })
        .await
        .unwrap()
}

/// Pattern D. In a file that has not changed, no hit moves, whatever the chunk starts with (a blank line, an attribute):
/// the hit's lines are the chunk's own, and it is not marked as found again.
#[tokio::test]
async fn an_unchanged_file_moves_no_hit() {
    let text = "use std::fmt;\n\npub const FIRST_LIMIT: usize = 64;\n\n/// How long the second waits.\npub const SECOND_WAIT: u64 = 5;\n\n#[derive(Debug)]\nstruct ThirdArgs {\n    a: u32,\n}\n\nfn fourth_helper() -> u32 {\n    7\n}\n";
    let dir = tempfile::tempdir().unwrap();
    let store = CodeStore::open(&dir.path().join("code.db")).unwrap();
    let listed = vec![Listed {
        path: "src/lib.rs".into(),
        blob: "b".into(),
        class: Class::Code,
        lang: Lang::Rust,
        generated: false,
        size: text.len() as u64,
    }];
    refresh(
        &store,
        &listed,
        &|_: &str| Ok(text.as_bytes().to_vec()),
        &[],
    )
    .await
    .unwrap();
    let starts: Vec<(i64, String)> = store
        .handle()
        .read(|c| {
            let mut st = c.prepare(
                "select s.name, c.line_start from symbol s join chunk c on c.id = s.chunk",
            )?;
            let rows = st
                .query_map([], |r| Ok((r.get::<_, i64>(1)?, r.get::<_, String>(0)?)))?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
        .unwrap();
    assert!(starts.len() >= 4, "{starts:?}");
    for (line, name) in starts {
        let a = search(&store, &q(&name, Scope::All), None, &|_: &str| {
            Some(text.to_string())
        })
        .await
        .unwrap();
        let h = &a.hits[0];
        assert_eq!(
            (h.line_start as i64, h.reanchored),
            (line, false),
            "{name}: {h:?}"
        );
    }
}

/// Pattern D. The file grew three lines at its top since it was indexed: the hit's lines are found again and move.
#[tokio::test]
async fn reanchors_moved_hit() {
    let (_dir, store, texts) = indexed().await;
    let still = search(
        &store,
        &q("drgnx-hub-call", Scope::All),
        None,
        &unchanged(texts.clone()),
    )
    .await
    .unwrap();
    let before = still.hits[0].clone();
    assert!(!before.reanchored);
    let moved = |p: &str| {
        texts.get(p).map(|t| {
            if p == "core/drgnx-hub.el" {
                format!(";; one\n;; two\n;; three\n{t}")
            } else {
                t.to_string()
            }
        })
    };
    let after = search(&store, &q("drgnx-hub-call", Scope::All), None, &moved)
        .await
        .unwrap();
    let hit = &after.hits[0];
    assert_eq!(hit.path, "core/drgnx-hub.el");
    assert!(hit.reanchored);
    assert_eq!(
        (hit.line_start, hit.line_end),
        (before.line_start + 3, before.line_end + 3)
    );
    // a file that is gone keeps the lines it had
    let gone = search(
        &store,
        &q("drgnx-hub-call", Scope::All),
        None,
        &|_: &str| None,
    )
    .await
    .unwrap();
    assert_eq!(gone.hits[0].line_start, before.line_start);
    assert!(!gone.hits[0].reanchored);
}

/// Pattern D. The ranks of three queries with vectors off, frozen: a change to a route, a weight or the demotion
/// shows here.
#[tokio::test]
async fn golden_ranks_vectors_off() {
    let (_dir, store, texts) = indexed().await;
    let now = unchanged(texts);
    let mut got = Vec::new();
    for text in ["timer", "run BODY with a timer", "hub answer"] {
        let a = search(&store, &q(text, Scope::All), None, &now)
            .await
            .unwrap();
        got.push((
            text,
            a.hits
                .iter()
                .map(|h| h.path.as_str().to_string())
                .collect::<Vec<_>>(),
        ));
    }
    let golden: Vec<(&str, Vec<&str>)> = vec![
        (
            "timer",
            vec![
                "core/drgnx-timer.el",
                "core/drgnx-macro.el",
                "core/drgnx-var.el",
                "core/drgnx-loaddefs.el",
                "test/drgnx-timer-test.el",
                "docs/timers.md",
            ],
        ),
        (
            "run BODY with a timer",
            vec![
                "core/drgnx-macro.el",
                "core/drgnx-timer.el",
                "docs/timers.md",
                "core/drgnx-var.el",
                "core/drgnx-loaddefs.el",
                "test/drgnx-timer-test.el",
            ],
        ),
        ("hub answer", vec!["core/drgnx-hub.el"]),
    ];
    assert_eq!(
        format!("{got:#?}"),
        format!("{golden:#?}"),
        "the frozen ranks differ"
    );
}
