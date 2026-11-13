//! The origin trail: the tracer run for real (python3 ≥ 3.12, under the tracer, to the program's end standing in for
//! the stop) over golden fixtures, the levels it follows, a change through a call, and Python < 3.12's candidates.

use super::BoxFut;
use super::origin::{self, Link, Replay, Traced, trail};
use std::path::{Path, PathBuf};
use std::process::Command;

const STOCK: &str = include_str!("../../tests/fixtures/origin/stock.py");

/// The replay of a script: python3 runs it in a folder of its own with the tracer on.
struct Direct {
    dir: PathBuf,
    script: &'static str,
    /// Answer "too old" (a Python 3.11).
    old: bool,
}

impl Replay for Direct {
    fn trace(
        &self,
        _run: &str,
        _stop: u64,
        watch: Vec<String>,
    ) -> BoxFut<'static, Result<Traced, String>> {
        let (dir, script, old) = (self.dir.clone(), self.script, self.old);
        Box::pin(async move {
            if old {
                return Ok(Traced::Old("3.11".into()));
            }
            Ok(Traced::Records(run_traced(&dir, script, &watch)))
        })
    }

    fn probe(
        &self,
        _run: &str,
        _stop: u64,
        _probes: Vec<super::record::RunProbe>,
    ) -> BoxFut<'static, Result<Vec<super::record::RunHit>, String>> {
        Box::pin(async { Err("Python is traced, never probed".into()) })
    }
}

fn run_traced(dir: &Path, script: &str, watch: &[String]) -> Vec<origin::Rec> {
    let tracer = origin::write_tracer(&dir.join(origin::DIR)).unwrap();
    let _ = std::fs::remove_file(tracer.join(origin::OUT));
    std::fs::write(dir.join("stock.py"), script).unwrap();
    let mut c = Command::new("python3");
    c.arg("stock.py").current_dir(dir).env_remove("PYTHONPATH");
    for (k, v) in origin::env(&tracer, dir, watch, None) {
        c.env(k, v);
    }
    let out = c.output().expect("python3 runs");
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    match origin::traced(&std::fs::read_to_string(tracer.join(origin::OUT)).unwrap_or_default())
        .unwrap()
    {
        Traced::Records(r) => r,
        Traced::Old(v) => panic!("the test image's Python is {v}: the tracer needs 3.12"),
    }
}

fn short(l: &Link) -> String {
    let ops: Vec<String> = l.operands.iter().map(|(e, v)| format!("{e}={v}")).collect();
    format!(
        "{} {}: {} = {} @{} {} [{}]{}",
        l.level,
        l.question,
        l.target,
        l.value.as_deref().unwrap_or("?"),
        l.path.rsplit('/').next().unwrap_or_default(),
        l.line,
        ops.join(" "),
        l.inside
            .as_deref()
            .map(|i| format!(" inside {i}"))
            .unwrap_or_default()
    )
}

#[tokio::test]
async fn the_trail_of_a_value_follows_its_operands_three_levels() {
    let tmp = tempfile::tempdir().unwrap();
    let r = Direct {
        dir: tmp.path().to_owned(),
        script: STOCK,
        old: false,
    };
    let mut levels = Vec::new();
    let t = trail(&r, "r1", 3, "shortfall", 3, Vec::new, |l| {
        levels.push(l.len())
    })
    .await
    .unwrap();
    let got: Vec<String> = t.links.iter().map(short).collect();
    assert_eq!(
        got,
        vec![
            "1 shortfall: shortfall = 16 @stock.py 15 [item.min=10 item.qty=2 item.reserve=8]",
            "2 item.min: self.min = 10 @stock.py 4 [minimum=10]",
            "2 item.qty: self.qty = 2 @stock.py 3 [qty=2]",
            // the last store before the stop: load's, not __init__'s 0
            "2 item.reserve: item.reserve = 8 @stock.py 10 []",
        ],
        "{got:#?}"
    );
    // a level per replay; the parameters have no store, so the third level finds nothing
    assert_eq!(levels, vec![1, 3, 0]);
    assert!(t.note.is_none());
    assert!(t.links.iter().all(|l| l.traced));
}

#[tokio::test]
async fn a_change_through_a_call_is_a_link_inside_the_method() {
    let tmp = tempfile::tempdir().unwrap();
    let r = Direct {
        dir: tmp.path().to_owned(),
        script: STOCK,
        old: false,
    };
    let t = trail(&r, "r1", 3, "log", 1, Vec::new, |_| {})
        .await
        .unwrap();
    let got: Vec<String> = t.links.iter().map(short).collect();
    assert_eq!(
        got,
        vec!["1 log: log = [16] @stock.py 22 [s=16] inside list.append"],
        "{got:#?}"
    );
}

#[tokio::test]
async fn python_before_3_12_gets_labelled_candidates() {
    let tmp = tempfile::tempdir().unwrap();
    let r = Direct {
        dir: tmp.path().to_owned(),
        script: STOCK,
        old: true,
    };
    let files = || vec![("/p/stock.py".to_owned(), STOCK.to_owned())];
    let t = trail(&r, "r1", 3, "item.reserve", 3, files, |_| {})
        .await
        .unwrap();
    let got: Vec<(String, u32, bool)> = t
        .links
        .iter()
        .map(|l| (l.target.clone(), l.line, l.traced))
        .collect();
    assert_eq!(
        got,
        vec![
            ("self.reserve".into(), 5, false),
            ("item.reserve".into(), 10, false)
        ]
    );
    assert!(
        t.note
            .as_deref()
            .unwrap()
            .contains("candidates, not traced")
    );
    // a plain name, augmented assignments included
    let c = origin::candidates(&[("/p/a.py".into(), "x = 1\ny = x\nx += 2\n".into())], "x");
    assert_eq!(c.iter().map(|l| l.line).collect::<Vec<_>>(), vec![1, 3]);
}

#[test]
fn records_are_read_leniently_and_the_last_store_wins() {
    let recs = origin::parse(
        "{\"seq\":1,\"kind\":\"store\",\"target\":\"self.n\",\"key\":\".n\",\"value\":\"0\",\"file\":\"/p/a.py\",\"line\":3}\n\
         not json\n\
         {\"seq\":2,\"kind\":\"store\",\"target\":\"o.n\",\"key\":\".n\",\"value\":\"5\",\"file\":\"/p/a.py\",\"line\":9,\
          \"operands\":{\"k\":\"5\",\"f\":\"<function f at 0x1>\"}}\n",
    );
    assert_eq!(recs.len(), 2);
    let l = origin::link(&recs, "x.n", 1).unwrap();
    assert_eq!((l.target.as_str(), l.line), ("o.n", 9));
    // an operand without a value worth showing (a function) is neither shown nor followed
    assert_eq!(l.operands, vec![("k".to_owned(), "5".to_owned())]);
    assert_eq!(origin::follow(&l), vec!["k".to_owned()]);
    assert!(origin::link(&recs, "m", 1).is_none());
    // the first line names the Python that ran
    assert_eq!(
        origin::traced("{\"python\":\"3.11.9\"}\n").unwrap(),
        Traced::Old("3.11.9".into())
    );
    assert!(
        matches!(origin::traced("{\"python\":\"3.13.1\"}\n").unwrap(), Traced::Records(r) if r.is_empty())
    );
    assert!(origin::traced("").is_err());
}

#[test]
fn a_replays_files_are_named_as_the_projects() {
    let dir = tempfile::tempdir().unwrap();
    let tree = dir.path().join("trace-1");
    std::fs::create_dir_all(tree.join("pkg")).unwrap();
    let real = std::fs::canonicalize(&tree).unwrap();
    let mut recs = origin::parse(&format!(
        "{{\"seq\":1,\"kind\":\"store\",\"target\":\"a\",\"file\":\"{}/pkg/m.py\",\"line\":1}}\n\
         {{\"seq\":2,\"kind\":\"store\",\"target\":\"b\",\"file\":\"{}/x.py\",\"line\":2}}\n\
         {{\"seq\":3,\"kind\":\"store\",\"target\":\"c\",\"file\":\"/usr/lib/python3/os.py\",\"line\":3}}\n",
        tree.display(),
        real.display()
    ));
    origin::rebase(&mut recs, &tree, Path::new("/work/proj"));
    let files: Vec<&str> = recs.iter().map(|r| r.file.as_str()).collect();
    // the tree as the replay named it and as the interpreter resolved it; a file outside it stays
    assert_eq!(
        files,
        vec![
            "/work/proj/pkg/m.py",
            "/work/proj/x.py",
            "/usr/lib/python3/os.py"
        ]
    );
}

#[test]
fn the_card_shows_each_link_by_level() {
    use serde_json::json;
    let s = json!({"expr": "shortfall", "n": 4, "stop": 3, "state": "done", "links": [
        {"level": 1, "target": "shortfall", "value": "16", "path": "/p/stock.py", "line": 15, "traced": true,
         "operands": [["item.min", "10"], ["item.qty", "2"], ["item.reserve", "8"]]},
        {"level": 2, "target": "item.reserve", "value": "8", "path": "/p/stock.py", "line": 10, "traced": true, "operands": []},
        {"level": 1, "target": "log", "value": "[16]", "inside": "list.append", "path": "/p/stock.py", "line": 22,
         "traced": true, "operands": []}]});
    let rows = origin::rows(&s);
    let text: Vec<&str> = rows.iter().map(|r| r.text.as_str()).collect();
    assert_eq!(
        text,
        vec![
            "Where did shortfall come from? · run 4, stop 3 · done",
            "← shortfall = 16  (item.min 10, item.qty 2, item.reserve 8)  stock.py 15",
            "  ← item.reserve = 8  stock.py 10",
            "← log changed inside list.append → [16]  stock.py 22",
        ]
    );
    assert!(
        rows[2]
            .props
            .iter()
            .any(|p| p.2 == "drgnx-debug-origin-link" && p.3 == json!(1))
    );
    let c = origin::rows(
        &json!({"expr": "x", "state": "done", "note": "Python 3.11: candidates, not traced",
                                 "links": [{"level": 1, "target": "x", "path": "/p/a.py", "line": 1, "traced": false}]}),
    );
    assert_eq!(c[1].text, "Python 3.11: candidates, not traced");
    assert!(c[2].text.ends_with("a.py 1  candidate"));
}

#[test]
fn a_js_files_stores_name_their_target_reads_and_pure_value() {
    let text = include_str!("../../tests/fixtures/origin/stock.js");
    let files = vec![("/p/stock.js".to_owned(), text.to_owned())];
    let lang = origin::lang_of("/p/stock.js").unwrap();
    let got: Vec<(u32, String, Vec<String>, Option<String>)> =
        origin::stores(lang, &files, "shortfall")
            .into_iter()
            .chain(origin::stores(lang, &files, "item.reserve"))
            .map(|s| (s.line, s.target, s.operands, s.pure))
            .collect();
    assert_eq!(
        got,
        vec![
            (
                16,
                "shortfall".into(),
                vec!["item.min".into(), "item.qty".into(), "item.reserve".into()],
                Some("item.min - item.qty + item.reserve".into())
            ),
            (5, "this.reserve".into(), vec![], Some("0".into())),
            (11, "item.reserve".into(), vec![], Some("8".into())),
        ]
    );
    // a call is never logged again: no value, only what it reads
    let item = origin::stores(lang, &files, "item");
    assert_eq!(item.len(), 1, "{item:?}");
    assert_eq!((item[0].line, item[0].pure.clone()), (10, None));
}

#[test]
fn a_go_files_stores_are_assignments_and_short_declarations() {
    let text = "package main\n\nfunc f(a int, b []int) int {\n\tx := a + len(b)\n\tx += b[0]\n\tx = a\n\treturn x\n}\n";
    let files = vec![("/p/m.go".to_owned(), text.to_owned())];
    let lang = origin::lang_of("/p/m.go").unwrap();
    let got: Vec<(u32, Vec<String>, Option<String>)> = origin::stores(lang, &files, "x")
        .into_iter()
        .map(|s| (s.line, s.operands, s.pure))
        .collect();
    assert_eq!(
        got,
        vec![
            (4, vec!["a".into(), "b".into()], None),
            (5, vec!["b".into()], None),
            (6, vec!["a".into()], Some("a".into())),
        ]
    );
}
