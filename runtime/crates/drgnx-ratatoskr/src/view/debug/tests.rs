use super::model::*;
use crate::debug::session::{ScopeVars, Stop};
use serde_json::{Value, json};
use std::collections::HashMap;

fn v(name: &str, value: &str, reference: i64) -> Value {
    json!({"name": name, "value": value, "variablesReference": reference})
}

fn stop(epoch: u64, locals: Vec<Value>) -> Stop {
    Stop {
        epoch,
        thread: 1,
        reason: "breakpoint".into(),
        description: None,
        all_threads: true,
        threads: vec![
            json!({"id": 1, "name": "main"}),
            json!({"id": 2, "name": "worker"}),
        ],
        frames: vec![
            json!({"id": 100, "name": "handle", "line": 12, "column": 5,
                   "source": {"name": "app.py", "path": "/p/app.py"}}),
            json!({"id": 101, "name": "run", "line": 30, "column": 1,
                   "source": {"name": "app.py", "path": "/p/app.py"}}),
        ],
        total_frames: Some(2),
        frame: 100,
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
        exception: None,
    }
}

fn session(epoch: u64, locals: Vec<Value>) -> SessionView {
    let st = stop(epoch, locals);
    SessionView {
        id: "s1".into(),
        name: "Python: app".into(),
        state: "stopped".into(),
        tree: Tree::of_stop("s1", &st),
        stop: Some(st),
        thread_frames: Default::default(),
    }
}

fn build(sessions: &[SessionView], opened: &Opened, prev: &HashMap<String, String>) -> Vec<Line> {
    lines(&Input {
        sessions,
        selected: None,
        watches: &[],
        bps: &Bps::default(),
        opened,
        prev,
    })
    .0
}

fn line<'a>(ls: &'a [Line], id: &str) -> &'a Line {
    ls.iter().find(|l| l.id == id).unwrap_or_else(|| {
        panic!(
            "no line {id} in {:?}",
            ls.iter().map(|l| &l.id).collect::<Vec<_>>()
        )
    })
}

/// Node ids are paths that stay the same from one stop to the next; the scopes are the top nodes, a cheap one open
/// with its variables, an expensive one closed (and not fetched); a variable with children has a chevron.
#[test]
fn variables_are_paths_stable_across_stops() {
    let opened = Opened::default();
    let a = build(
        &[session(1, vec![v("x", "1", 0), v("items", "[3]", 7)])],
        &opened,
        &HashMap::new(),
    );
    let b = build(
        &[session(2, vec![v("x", "2", 0), v("items", "[3]", 9)])],
        &opened,
        &HashMap::new(),
    );
    let ids = |ls: &[Line]| ls.iter().map(|l| l.id.clone()).collect::<Vec<_>>();
    assert_eq!(ids(&a), ids(&b));
    assert_eq!(line(&a, "v:s1:Locals").open, Some(true));
    assert_eq!(line(&a, "v:s1:Globals").open, Some(false));
    assert_eq!(line(&a, "v:s1:Locals/x").open, None);
    assert_eq!(line(&a, "v:s1:Locals/items").open, Some(false));
    assert_eq!(line(&a, "v:s1:Locals/x").value.as_deref(), Some("1"));
    assert_eq!(
        line(&a, "v:s1:Locals/x").parent.as_deref(),
        Some("v:s1:Locals")
    );
    // the sections come first, in their order
    let sections: Vec<&str> = a
        .iter()
        .filter(|l| l.kind == "section")
        .map(|l| l.id.as_str())
        .collect();
    assert_eq!(
        sections,
        [
            "section:variables",
            "section:watch",
            "section:callstack",
            "section:breakpoints"
        ]
    );
    let s = seg("a/b%c");
    assert_eq!(s, "a%2Fb%25c");
}

/// An open path is fetched again at each stop, breadth first; an expensive scope only once opened; nothing for a
/// stale session.
#[test]
fn open_paths_are_wanted_breadth_first() {
    let mut opened = Opened::default();
    let mut s = session(1, vec![v("a", "{..}", 5), v("b", "{..}", 6)]);
    opened.set("v:s1:Locals/a", true);
    opened.set("v:s1:Locals/a/inner", true);
    let w = wants(&s, &opened);
    assert_eq!(w.len(), 1);
    assert_eq!(w[0].path, "v:s1:Locals/a");
    assert_eq!(w[0].args, json!({"variablesReference": 5}));
    s.tree.kids.insert(
        "v:s1:Locals/a".into(),
        vec![Var::of(&v("inner", "{..}", 8))],
    );
    opened.set("v:s1:Globals", true);
    let w: Vec<_> = wants(&s, &opened)
        .into_iter()
        .map(|w| (w.path, w.depth))
        .collect();
    assert_eq!(
        w,
        [
            ("v:s1:Globals".to_owned(), 1),
            ("v:s1:Locals/a/inner".to_owned(), 3)
        ]
    );
    s.tree.capped.insert("v:s1:Globals".into());
    s.tree
        .failed
        .insert("v:s1:Locals/a/inner".into(), "gone".into());
    assert!(
        wants(&s, &opened).is_empty(),
        "capped and failed paths wait for a new stop"
    );
    let mut stale = session(1, vec![v("a", "{..}", 5)]);
    stale.tree.stale = true;
    assert!(wants(&stale, &opened).is_empty());
}

/// A capped path shows closed with "expand again"; an old stop's nodes are dim and have no chevron to open.
#[test]
fn capped_and_stale_nodes() {
    let mut opened = Opened::default();
    opened.set("v:s1:Locals/a", true);
    let mut s = session(1, vec![v("a", "{..}", 5)]);
    s.tree.capped.insert("v:s1:Locals/a".into());
    let ls = build(&[s.clone()], &opened, &HashMap::new());
    let a = line(&ls, "v:s1:Locals/a");
    assert!(a.capped);
    assert_eq!(a.open, Some(false));
    s.tree.stale = true;
    let ls = build(&[s], &opened, &HashMap::new());
    let a = line(&ls, "v:s1:Locals/a");
    assert!(a.dim);
    assert_eq!(a.open, None);
    assert!(ls.iter().filter(|l| l.id.starts_with("v:")).all(|l| l.dim));
}

/// A node of 100,000 indexed children: its named children (filter `named`), then ten chunks of 10,000, each a
/// hundred chunks of 100; only an opened leaf chunk is fetched, with `start` and `count`.
#[test]
fn big_arrays_page_into_nested_chunks() {
    assert_eq!(chunks(0, 250), [(0, 100), (100, 100), (200, 50)]);
    assert_eq!(chunks(0, 100_000).len(), 10);
    assert_eq!(chunks(0, 100_000)[1], (10_000, 10_000));
    assert_eq!(chunks(10_000, 10_000)[0], (10_000, 100));
    let big = json!({"name": "arr", "value": "array(100000)", "variablesReference": 9,
                     "indexedVariables": 100_000, "namedVariables": 1});
    let mut s = session(1, vec![big]);
    let mut opened = Opened::default();
    opened.set("v:s1:Locals/arr", true);
    let w = wants(&s, &opened);
    assert_eq!(w.len(), 1, "no call for an unopened chunk: {w:?}");
    assert_eq!(
        w[0].args,
        json!({"variablesReference": 9, "filter": "named"})
    );
    s.tree.kids.insert(
        "v:s1:Locals/arr".into(),
        vec![Var::of(&v("length", "100000", 0))],
    );
    assert!(wants(&s, &opened).is_empty());
    let ls = build(&[s.clone()], &opened, &HashMap::new());
    let kids: Vec<&str> = ls
        .iter()
        .filter(|l| l.parent.as_deref() == Some("v:s1:Locals/arr"))
        .map(|l| l.id.as_str())
        .collect();
    assert_eq!(kids.len(), 11);
    assert_eq!(kids[0], "v:s1:Locals/arr/length");
    assert_eq!(kids[2], "v:s1:Locals/arr/[10000..19999]");
    assert_eq!(
        line(&ls, "v:s1:Locals/arr/[10000..19999]").label,
        "[10000 … 19999]"
    );
    opened.set("v:s1:Locals/arr/[10000..19999]", true);
    opened.set("v:s1:Locals/arr/[10000..19999]/[10100..10199]", true);
    let w = wants(&s, &opened);
    assert_eq!(w.len(), 1);
    assert_eq!(w[0].path, "v:s1:Locals/arr/[10000..19999]/[10100..10199]");
    assert_eq!(
        w[0].args,
        json!({"variablesReference": 9, "filter": "indexed", "start": 10_100, "count": 100})
    );
}

/// A lazy value shows `(…)` until fetched, then the one child's value in its place.
#[test]
fn lazy_values_show_once_fetched() {
    let lazy = json!({"name": "prop", "value": "", "variablesReference": 4, "presentationHint": {"lazy": true}});
    let mut s = session(1, vec![lazy]);
    let mut opened = Opened::default();
    let ls = build(&[s.clone()], &opened, &HashMap::new());
    assert!(line(&ls, "v:s1:Locals/prop").lazy);
    opened.set("v:s1:Locals/prop", true);
    assert_eq!(wants(&s, &opened)[0].args, json!({"variablesReference": 4}));
    s.tree
        .kids
        .insert("v:s1:Locals/prop".into(), vec![Var::of(&v("", "42", 0))]);
    let ls = build(&[s], &opened, &HashMap::new());
    let p = line(&ls, "v:s1:Locals/prop");
    assert!(!p.lazy);
    assert_eq!(p.value.as_deref(), Some("42"));
    assert_eq!(p.open, None);
}

/// A value that differs from the last stop's is marked, by `evaluateName` (else the path); a new one is not.
#[test]
fn changed_values_are_marked_against_the_last_stop() {
    let opened = Opened::default();
    let first = session(
        1,
        vec![
            json!({"name": "x", "value": "1", "variablesReference": 0, "evaluateName": "self.x"}),
            v("y", "2", 0),
        ],
    );
    let (_, prev) = lines(&Input {
        sessions: &[first],
        selected: None,
        watches: &[],
        bps: &Bps::default(),
        opened: &opened,
        prev: &HashMap::new(),
    });
    assert_eq!(prev.get("self.x").map(String::as_str), Some("1"));
    assert_eq!(prev.get("v:s1:Locals/y").map(String::as_str), Some("2"));
    let second = session(
        2,
        vec![
            json!({"name": "x", "value": "5", "variablesReference": 0, "evaluateName": "self.x"}),
            v("y", "2", 0),
            v("z", "0", 0),
        ],
    );
    let ls = build(&[second], &opened, &prev);
    assert!(line(&ls, "v:s1:Locals/x").changed);
    assert!(!line(&ls, "v:s1:Locals/y").changed);
    assert!(!line(&ls, "v:s1:Locals/z").changed);
}

/// Watch: each expression's answer in the selected frame, an error kept as its message; expandable as a variable.
#[test]
fn watches_show_answers_and_errors() {
    let mut s = session(1, vec![]);
    s.tree.watches = vec![
        (
            "len(xs)".into(),
            Ok(Var::of(&json!({"result": "3", "variablesReference": 0}))),
        ),
        ("nope".into(), Err("name 'nope' is not defined".into())),
        (
            "obj".into(),
            Ok(Var::of(&json!({"result": "Obj", "variablesReference": 12}))),
        ),
    ];
    let watches = ["len(xs)".to_owned(), "nope".to_owned(), "obj".to_owned()];
    let mut opened = Opened::default();
    opened.set("w:obj", true);
    let sessions = [s];
    let input = Input {
        sessions: &sessions,
        selected: None,
        watches: &watches,
        bps: &Bps::default(),
        opened: &opened,
        prev: &HashMap::new(),
    };
    let (ls, _) = lines(&input);
    assert_eq!(line(&ls, "w:len(xs)").value.as_deref(), Some("3"));
    let e = line(&ls, "w:nope");
    assert!(e.error);
    assert_eq!(e.value.as_deref(), Some("name 'nope' is not defined"));
    assert_eq!(line(&ls, "w:obj").open, Some(true));
    let w = wants(&sessions[0], &opened);
    assert_eq!(w[0].path, "w:obj");
    assert_eq!(w[0].args, json!({"variablesReference": 12}));
    // no session: the expressions, with nothing to show
    let (ls, _) = lines(&Input {
        sessions: &[],
        ..input
    });
    assert!(line(&ls, "w:nope").dim);
}

/// Call Stack: sessions only when two or more; the stopped thread open with its reason's chip and its frames
/// (the selected one current, `file line:col`), another thread closed ("PAUSED" when all stopped); a run of
/// subtle frames folds into "N frames hidden"; "Load more frames" past the frames fetched.
#[test]
fn call_stack_threads_and_frames() {
    let mut s = session(1, vec![]);
    let st = s.stop.as_mut().unwrap();
    st.frames
        .push(json!({"id": 102, "name": "lib1", "presentationHint": "subtle", "line": 1}));
    st.frames
        .push(json!({"id": 103, "name": "lib2", "presentationHint": "subtle", "line": 1}));
    st.frames
        .push(json!({"id": 104, "name": "main", "line": 3, "source": {"path": "/p/main.py"}}));
    st.total_frames = Some(60);
    let ls = build(&[s.clone()], &Opened::default(), &HashMap::new());
    assert!(!ls.iter().any(|l| l.kind == "session"));
    let t = line(&ls, "t:s1:1");
    assert_eq!(
        (t.open, t.chip.as_deref()),
        (Some(true), Some("PAUSED ON BREAKPOINT"))
    );
    assert_eq!(line(&ls, "t:s1:2").chip.as_deref(), Some("PAUSED"));
    assert_eq!(line(&ls, "t:s1:2").open, Some(false));
    let f = line(&ls, "f:s1:1:0");
    assert!(f.current);
    assert_eq!(f.label, "handle");
    assert_eq!(f.detail.as_deref(), Some("app.py 12:5"));
    assert!(f.fields.contains(&("frame", json!(100))));
    let h = line(&ls, "h:s1:1:2");
    assert_eq!((h.label.as_str(), h.open), ("2 frames hidden", Some(false)));
    assert!(ls.iter().all(|l| l.id != "f:s1:1:2"));
    assert_eq!(line(&ls, "f:s1:1:4").detail.as_deref(), Some("main.py 3"));
    assert_eq!(line(&ls, "m:s1:1").label, "Load more frames");
    // two sessions: a node each
    let mut other = session(1, vec![]);
    other.id = "s2".into();
    let ls = build(&[s, other], &Opened::default(), &HashMap::new());
    assert_eq!(line(&ls, "s:s2").open, Some(true));
    assert_eq!(line(&ls, "t:s2:1").parent.as_deref(), Some("s:s2"));
    // another thread opened: its frames are fetched
    let mut opened = Opened::default();
    opened.set("t:s1:2", true);
    let s = session(1, vec![]);
    let w = wants(&s, &opened);
    assert_eq!(w[0].command, "stackTrace");
    assert_eq!(
        w[0].args,
        json!({"threadId": 2, "startFrame": 0, "levels": 20})
    );
}

/// Breakpoints: the exception filters as tick boxes, then function breakpoints, then each file's breakpoints (the
/// tick is enabled; an unverified one is dim and carries its message).
#[test]
fn breakpoints_section() {
    let bps = Bps {
        filters: vec![Filter {
            ty: "python".into(),
            id: "raised".into(),
            label: "Raised Exceptions".into(),
            on: false,
        }],
        functions: vec![json!({"name": "main", "condition": "x > 1"})],
        files: vec![(
            "/p/app.py".into(),
            vec![
                json!({"id": 3, "line": 12, "enabled": true, "verified": true}),
                json!({"id": 4, "line": 20, "enabled": false, "verified": false,
                       "message": "no code here", "condition": "y"}),
            ],
        )],
    };
    let ls = lines(&Input {
        sessions: &[],
        selected: None,
        watches: &[],
        bps: &bps,
        opened: &Opened::default(),
        prev: &HashMap::new(),
    })
    .0;
    let f = line(&ls, "x:python:raised");
    assert_eq!(
        (f.ticked, f.label.as_str()),
        (Some(false), "Raised Exceptions")
    );
    let fnb = line(&ls, "fn:main");
    assert_eq!(fnb.detail.as_deref(), Some("x > 1"));
    let b = line(&ls, "b:3");
    assert_eq!((b.ticked, b.label.as_str()), (Some(true), "app.py:12"));
    let b4 = line(&ls, "b:4");
    assert_eq!(b4.ticked, Some(false));
    assert!(b4.dim);
    assert_eq!(b4.detail.as_deref(), Some("y"));
    assert!(b4.fields.contains(&("message", json!("no code here"))));
    assert!(b4.fields.contains(&("path", json!("/p/app.py"))));
    let order: Vec<&str> = ls
        .iter()
        .filter(|l| l.parent.as_deref() == Some("section:breakpoints"))
        .map(|l| l.id.as_str())
        .collect();
    assert_eq!(order, ["x:python:raised", "fn:main", "b:3", "b:4"]);
}

/// A closed section shows its header alone; the model has a node per line, `expanded` when open, with its parent and
/// fields, and the order of the lines.
#[test]
fn sections_close_and_the_model_follows_the_lines() {
    let mut opened = Opened::default();
    opened.set("section:callstack", false);
    let ls = build(
        &[session(1, vec![v("x", "1", 0)])],
        &opened,
        &HashMap::new(),
    );
    assert!(
        !ls.iter()
            .any(|l| l.parent.as_deref() == Some("section:callstack"))
    );
    let d = doc(&ls);
    assert_eq!(d.descriptor["scheme"], "tree");
    assert_eq!(d.lists["order"].len(), ls.len());
    let x = &d.nodes["v:s1:Locals/x"];
    assert_eq!(x["kind"], "var");
    assert_eq!(x["parent"], "v:s1:Locals");
    assert_eq!(x["flags"], 0);
    assert_eq!(d.nodes["v:s1:Locals"]["flags"], 1);
    let fields = x["fields"].as_array().unwrap();
    assert!(fields.contains(&json!(["label", "x"])));
    assert!(fields.contains(&json!(["value", "1"])));
}

/// The rows: a variable is `name: value` in the value's role (a number, a string), a changed value in the changed
/// face; an openable node's chevron is an image on a graphical display and `▸` / `▾` on a terminal, indented two
/// columns a level; a breakpoint has its tick box; every row names its node (`drgnx-work-id`).
#[test]
fn rows_draw_names_values_chevrons_and_ticks() {
    use super::rows::rows;
    use crate::view::explorer::RowLook;
    let mut s = session(
        2,
        vec![v("n", "5", 0), v("s", "'hi'", 0), v("obj", "Obj", 3)],
    );
    s.tree.kids.insert("v:s1:Locals/obj".into(), vec![]);
    let prev = HashMap::from([("v:s1:Locals/n".to_owned(), "4".to_owned())]);
    let bps = Bps {
        files: vec![(
            "/p/a.py".into(),
            vec![json!({"id": 1, "line": 3, "enabled": true, "verified": true})],
        )],
        ..Bps::default()
    };
    let sessions = [s];
    let ls = lines(&Input {
        sessions: &sessions,
        selected: None,
        watches: &[],
        bps: &bps,
        opened: &Opened::default(),
        prev: &prev,
    })
    .0;
    let tty = RowLook {
        gui: None,
        one_root: false,
    };
    let (rs, images) = rows(&ls, &tty);
    assert!(images.is_empty());
    let row = |id: &str| rs.iter().find(|r| r.key == id).unwrap().clone();
    let n = row("v:s1:Locals/n");
    assert_eq!(n.text, "      n: 5");
    assert!(n.runs.iter().any(|r| r.2 == "drgnx-debug-view-changed"));
    let st = row("v:s1:Locals/s");
    assert!(st.runs.iter().any(|r| r.2 == "drgnx-debug-view-string"));
    assert_eq!(row("v:s1:Locals/obj").text, "    ▸ obj: Obj");
    assert_eq!(row("v:s1:Locals").text, "  ▾ Locals");
    assert_eq!(row("b:1").text, "    [ ] ● a.py:3".replace("[ ]", "[x]"));
    assert!(
        n.props
            .iter()
            .any(|p| p.2 == "drgnx-work-id" && p.3 == json!("v:s1:Locals/n"))
    );
    let gui = RowLook {
        gui: Some((12, 16, 6)),
        one_root: false,
    };
    let (rs, images) = rows(&ls, &gui);
    assert_eq!(images.len(), 2, "the two chevrons, each once");
    let obj = rs.iter().find(|r| r.key == "v:s1:Locals/obj").unwrap();
    assert_eq!(obj.images.len(), 1);
    assert_eq!(obj.spaces.len(), 3, "two levels and the gap");
}

/// Filter on typing: only the rows whose name or value contains the text (any case), with the rows above them and
/// every section's header.
#[test]
fn the_filter_keeps_matches_and_their_parents() {
    let mut s = session(1, vec![v("total", "10", 0), v("items", "[2]", 7)]);
    s.tree.kids.insert(
        "v:s1:Locals/items".into(),
        vec![Var::of(&v("0", "Total cost", 0))],
    );
    let mut opened = Opened::default();
    opened.set("v:s1:Locals/items", true);
    let ls = filter(build(&[s], &opened, &HashMap::new()), "TOT");
    let ids: Vec<&str> = ls.iter().map(|l| l.id.as_str()).collect();
    assert_eq!(
        ids,
        [
            "section:variables",
            "v:s1:Locals",
            "v:s1:Locals/total",
            "v:s1:Locals/items",
            "v:s1:Locals/items/0",
            "section:watch",
            "section:callstack",
            "section:breakpoints"
        ]
    );
}

#[test]
fn open_pages_are_bounded_and_closed_pages_let_their_elements_go() {
    assert!(is_page("v:s1:Locals/arr/[0..9999]/[100..199]"));
    assert!(!is_page("v:s1:Locals/arr/[0..9999]"));
    assert!(!is_page("v:s1:Locals/arr"));
    let mut t = Tree::default();
    let mut o = Opened::default();
    let page = |i: usize| format!("v:s1:Locals/arr/[0..99999]/[{}..{}]", i * 100, i * 100 + 99);
    let el = |i: usize| vec![Var::of(&v(&format!("{i}"), "1", 0))];
    for i in 0..PAGE_CAP {
        assert!(o.set(&page(i), true).is_empty());
        t.kids.insert(page(i), el(i));
        t.kids.insert(format!("{}/{}", page(i), i * 100), el(i));
    }
    // one page more: the first closes, and its elements and all under them go
    let gone = o.set(&page(PAGE_CAP), true);
    assert_eq!(gone, [page(0)]);
    t.forget(&gone);
    assert!(!o.is_open(&page(0), false) && o.is_open(&page(1), false));
    assert!(!t.kids.contains_key(&page(0)) && !t.kids.contains_key(&format!("{}/0", page(0))));
    assert!(t.kids.contains_key(&page(1)));
    assert_eq!(o.pages.len(), PAGE_CAP);
    // a page closed lets its elements go; one opened again goes to the end of the line
    t.forget(&o.set(&page(1), false));
    assert!(!t.kids.contains_key(&page(1)));
    o.set(&page(2), true);
    assert_eq!(o.pages.back(), Some(&page(2)));
    // a node that is not a page is not counted
    assert!(o.set("v:s1:Locals/obj", true).is_empty());
    assert_eq!(o.pages.len(), PAGE_CAP - 1);
}

/// An opened or closed Variables node's subtree, walked alone ([`subtree`]) and spliced over its old one, is what the
/// whole walk draws: a chunk of a long array and a variable with children, both ways.
#[test]
fn a_subtree_spliced_is_what_the_whole_walk_draws() {
    let mut locals: Vec<Value> = (0..5)
        .map(|i| v(&format!("v{i}"), &format!("{i}"), 0))
        .collect();
    locals.push(v("obj", "Obj", 3));
    locals.push(
        json!({"name": "arr", "value": "list[1000]", "variablesReference": 8,
                       "indexedVariables": 1000, "namedVariables": 0}),
    );
    let mut s = session(2, locals);
    s.tree.kids.insert(
        "v:s1:Locals/obj".into(),
        vec![Var::of(&v("x", "1", 0)), Var::of(&v("y", "2", 0))],
    );
    let page = "v:s1:Locals/arr/[300..399]";
    s.tree.kids.insert(
        page.into(),
        (300..400)
            .map(|i| Var::of(&v(&format!("{i}"), &format!("{}", i * 3), 0)))
            .collect(),
    );
    let sessions = [s];
    let prev = HashMap::from([("v:s1:Locals/obj/x".to_owned(), "0".to_owned())]);
    let walk = |opened: &Opened| build(&sessions, opened, &prev);
    let walk_alone = |opened: &Opened, line: &Line| {
        subtree(
            &Input {
                sessions: &sessions,
                selected: None,
                watches: &[],
                bps: &Bps::default(),
                opened,
                prev: &prev,
            },
            line,
        )
    };
    let mut closed = Opened::default();
    closed.set("v:s1:Locals/arr", true);
    for node in [page, "v:s1:Locals/obj"] {
        let mut open = closed.clone();
        open.set(node, true);
        for (from, to) in [(&closed, &open), (&open, &closed)] {
            let mut ls = walk(from);
            let i = ls.iter().position(|l| l.id == node).unwrap();
            let end = subtree_end(&ls, i);
            let (sub, wants, _) = walk_alone(to, &ls[i]).expect("a Variables node");
            assert!(wants.is_empty(), "{wants:?}");
            ls.splice(i..end, sub);
            assert_eq!(ls, walk(to), "{node}");
        }
    }
    // a page not fetched yet: its subtree is its line and the request for it
    let mut open = closed.clone();
    open.set("v:s1:Locals/arr/[0..99]", true);
    let ls = walk(&closed);
    let i = ls
        .iter()
        .position(|l| l.id == "v:s1:Locals/arr/[0..99]")
        .unwrap();
    let (sub, wants, _) = walk_alone(&open, &ls[i]).unwrap();
    assert_eq!(sub.len(), 1);
    assert_eq!(wants.len(), 1);
    assert!(walk_alone(&open, &ls[0]).is_none(), "a section has no Src");
}

/// A variable whose adapter gives a `memoryReference` carries it as `memory_reference`, for View Binary Data; one
/// without has none.
#[test]
fn a_variables_memory_reference_is_a_field() {
    let mut buf = v("buf", "b'ab'", 0);
    buf["memoryReference"] = json!("0x1000");
    let ls = build(
        &[session(1, vec![buf, v("x", "1", 0)])],
        &Opened::default(),
        &HashMap::new(),
    );
    let field = |id: &str| {
        line(&ls, id)
            .fields
            .iter()
            .find(|(k, _)| *k == "memory_reference")
            .map(|(_, v)| v.clone())
    };
    assert_eq!(field("v:s1:Locals/buf"), Some(json!("0x1000")));
    assert_eq!(field("v:s1:Locals/x"), None);
}
