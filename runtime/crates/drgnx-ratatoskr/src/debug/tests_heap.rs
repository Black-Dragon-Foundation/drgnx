//! The heap graph's walk against fake adapters shaped like the five measured ones (`tests_live_adapters::heap_identity_*`):
//! a ring a → b → c → a and `shared` = b.
use super::BoxFut;
use super::heap::{self, Graph, Ident, Limits, Probe};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Mutex;

/// A stopped frame: each reference's children, each expression's value; what was asked is counted.
#[derive(Default)]
struct Fake {
    children: BTreeMap<i64, Vec<Value>>,
    values: BTreeMap<String, String>,
    asked: Mutex<Vec<String>>,
}

impl Probe for Fake {
    fn variables(&self, reference: i64) -> BoxFut<'_, Result<Vec<Value>, String>> {
        self.asked
            .lock()
            .unwrap()
            .push(format!("variables {reference}"));
        let r = self
            .children
            .get(&reference)
            .cloned()
            .ok_or("no such reference".to_owned());
        Box::pin(async move { r })
    }
    fn evaluate(&self, expression: String) -> BoxFut<'_, Result<String, String>> {
        let r = self
            .values
            .get(&expression)
            .cloned()
            .ok_or(format!("cannot evaluate {expression}"));
        self.asked
            .lock()
            .unwrap()
            .push(format!("evaluate {expression}"));
        Box::pin(async move { r })
    }
}

fn var(name: &str, value: &str, ty: &str, eval: &str, reference: i64) -> Value {
    json!({"name": name, "value": value, "type": ty, "evaluateName": eval, "variablesReference": reference})
}

/// debugpy: objects have children `v`, `next` (and its groups); `id(E)` names them.
fn python() -> (Fake, Vec<Value>) {
    let mut f = Fake::default();
    // node k (1 = a, 2 = b, 3 = c) has reference 10 * k; its children are named from the first path that reaches it
    // (an adapter names them from the path the client expanded, and the walk expands each object once)
    let objs = [(1, "1", 2), (2, "2", 3), (3, "3", 1)];
    let mut roots = vec![];
    for (name, k) in [("a", 1), ("b", 2), ("c", 3), ("shared", 2)] {
        roots.push(var(name, "<Node>", "Node", name, k * 10));
    }
    // every expression the walk may use: four levels below each root
    for (name, k) in [("a", 1), ("b", 2), ("c", 3), ("shared", 2)] {
        let mut e = name.to_owned();
        let mut k = k;
        for _ in 0..4 {
            let (_, v, next) = objs[k as usize - 1];
            f.values.insert(format!("id({e})"), format!("{}", 1000 + k));
            let r = k * 10;
            f.children.entry(r).or_insert(vec![
                json!({"name": "special variables", "value": "", "variablesReference": 999,
                           "presentationHint": {"kind": "class"}}),
                var("v", v, "int", &format!("{e}.v"), 0),
                var("next", "<Node>", "Node", &format!("{e}.next"), next * 10),
            ]);
            e = format!("{e}.next");
            k = next;
        }
    }
    (f, roots)
}

fn node<'a>(g: &'a Graph, id: &str) -> &'a heap::Node {
    g.nodes
        .iter()
        .find(|n| n.id == id)
        .unwrap_or_else(|| panic!("no node {id} in {g:#?}"))
}

fn to(n: &heap::Node, field: &str) -> Option<String> {
    n.fields
        .iter()
        .find(|f| f.name == field)
        .and_then(|f| f.to.clone())
}

#[tokio::test]
async fn a_ring_and_a_shared_reference_are_three_objects() {
    let (f, roots) = python();
    let g = heap::walk(&f, Ident::Python, roots, Limits::default()).await;
    assert_eq!(g.nodes.len(), 3, "a, b, c once each: {g:#?}");
    let (a, b, c) = ("1001", "1002", "1003");
    assert_eq!(to(node(&g, a), "next").as_deref(), Some(b));
    assert_eq!(to(node(&g, b), "next").as_deref(), Some(c));
    assert_eq!(
        to(node(&g, c), "next").as_deref(),
        Some(a),
        "the ring closes"
    );
    let root = |n: &str| {
        g.roots
            .iter()
            .find(|(r, _)| r == n)
            .and_then(|(_, id)| id.clone())
    };
    assert_eq!(root("shared"), root("b"), "shared is b");
    assert_eq!(
        node(&g, a)
            .fields
            .iter()
            .find(|f| f.name == "v")
            .map(|f| f.value.as_str()),
        Some("1")
    );
    assert!(
        node(&g, a)
            .fields
            .iter()
            .all(|f| f.name != "special variables"),
        "debugpy's groups are not fields"
    );
    assert_eq!(g.cut, 0);
    // each object is expanded once
    let asked = f.asked.lock().unwrap();
    let expanded = asked.iter().filter(|a| a.starts_with("variables")).count();
    assert_eq!(expanded, 3, "{asked:?}");
}

#[tokio::test]
async fn the_limit_cuts_and_counts_what_it_left() {
    let (f, roots) = python();
    let g = heap::walk(
        &f,
        Ident::Python,
        roots,
        Limits {
            nodes: 2,
            ..Limits::default()
        },
    )
    .await;
    assert_eq!(g.nodes.len(), 2, "{g:#?}");
    assert!(
        g.cut >= 1,
        "the reference past the limit is counted: {g:#?}"
    );
}

/// delve: a pointer `*main.Node` has one child `(*a)`, the struct, whose children are the fields.
#[tokio::test]
async fn a_go_pointers_object_is_its_one_dereferenced_child() {
    let mut f = Fake::default();
    let objs = [("1", 2), ("2", 3), ("3", 1)];
    let addr = |k: i64| format!("{} = 0x{:x}", 4096 + k * 16, 4096 + k * 16);
    let mut roots = vec![];
    for (name, k) in [("a", 1i64), ("b", 2), ("c", 3), ("shared", 2)] {
        roots.push(var(name, "*main.Node {V: …}", "*main.Node", name, k * 10));
    }
    for (name, k) in [("a", 1i64), ("b", 2), ("c", 3), ("shared", 2)] {
        let (mut e, mut k) = (name.to_owned(), k);
        for _ in 0..4 {
            let (v, next) = objs[k as usize - 1];
            f.values.insert(format!("uintptr({e})"), addr(k));
            // delve names the dereferenced struct "" and gives the path only as its evaluateName (measured)
            let d = format!("(*{e})");
            f.children.entry(k * 10).or_insert(vec![var(
                "",
                "main.Node {V: …}",
                "main.Node",
                &d,
                k * 10 + 1,
            )]);
            f.children.entry(k * 10 + 1).or_insert(vec![
                var("V", v, "int", &format!("{d}.V"), 0),
                var(
                    "Next",
                    "*main.Node {V: …}",
                    "*main.Node",
                    &format!("{d}.Next"),
                    next * 10,
                ),
            ]);
            e = format!("{d}.Next");
            k = next;
        }
    }
    let g = heap::walk(&f, Ident::Go, roots, Limits::default()).await;
    assert_eq!(g.nodes.len(), 3, "{g:#?}");
    let a = node(&g, "0x1010");
    assert_eq!(a.ty, "main.Node");
    assert_eq!(to(a, "Next").as_deref(), Some("0x1020"));
    assert_eq!(to(node(&g, "0x1030"), "Next").as_deref(), Some("0x1010"));
}

/// lldb-dap: a pointer's children are the fields; `(void *)(E)` is the address.
#[tokio::test]
async fn a_native_pointer_is_named_by_its_address() {
    let mut f = Fake::default();
    let objs = [("1", 2), ("2", 3), ("3", 1)];
    let addr = |k: i64| format!("0x{:016x}", 0x1000 + k * 0x20);
    let mut roots = vec![];
    for (name, k) in [("a", 1i64), ("b", 2), ("c", 3), ("shared", 2)] {
        roots.push(var(name, &addr(k), "Node *", name, k * 10));
    }
    for (name, k) in [("a", 1i64), ("b", 2), ("c", 3), ("shared", 2)] {
        let (mut e, mut k) = (name.to_owned(), k);
        for _ in 0..4 {
            let (v, next) = objs[k as usize - 1];
            f.values.insert(format!("(void *)({e})"), addr(k));
            f.children.entry(k * 10).or_insert(vec![
                var("v", v, "int", &format!("{e}->v"), 0),
                var(
                    "next",
                    &addr(next),
                    "Node *",
                    &format!("{e}->next"),
                    next * 10,
                ),
            ]);
            e = format!("{e}->next");
            k = next;
        }
    }
    let g = heap::walk(&f, Ident::Native, roots, Limits::default()).await;
    assert_eq!(g.nodes.len(), 3, "{g:#?}");
    assert_eq!(to(node(&g, &addr(3)), "next"), Some(addr(1)));
    assert_eq!(node(&g, &addr(1)).ty, "Node *");
}

/// No identity (an adapter not in the table): a tree, cut by the depth, and js-debug's internal slots skipped.
#[tokio::test]
async fn without_identity_the_walk_is_a_tree_cut_at_its_depth() {
    let mut f = Fake::default();
    let roots = vec![var("a", "Node", "Node", "a", 10)];
    for d in 0..6 {
        let e = format!("a{}", ".next".repeat(d));
        f.children.insert(
            10 + d as i64,
            vec![
                var("v", "1", "number", &format!("{e}.v"), 0),
                var("next", "Node", "Node", &format!("{e}.next"), 11 + d as i64),
                var(
                    "[[Prototype]]",
                    "Object",
                    "Object",
                    &format!("{e}[\"[[Prototype]]\"]"),
                    500,
                ),
            ],
        );
    }
    let g = heap::walk(
        &f,
        Ident::Paths,
        roots,
        Limits {
            depth: 3,
            ..Limits::default()
        },
    )
    .await;
    assert_eq!(g.nodes.len(), 3, "depth 3: a, a.next, a.next.next: {g:#?}");
    assert_eq!(g.nodes[0].id, "a");
    assert!(
        g.nodes
            .iter()
            .all(|n| n.fields.iter().all(|f| !f.name.starts_with("[[")))
    );
    assert_eq!(g.cut, 1, "a.next.next's next is left: {g:#?}");
}

/// js-debug: every object and function gets the hidden map's tag; a primitive gets null and stays a field.
#[tokio::test]
async fn javascript_objects_are_named_by_the_hidden_maps_tag() {
    let mut f = Fake::default();
    let tag = |e: &str| heap::JS_TAG.replace("{}", e);
    let roots = vec![
        var("a", "Node {v: 1, next: Node}", "Node", "a", 10),
        var("shared", "Node {v: 2, next: Node}", "Node", "shared", 20),
    ];
    f.values.insert(tag("a"), "1".into());
    f.values.insert(tag("shared"), "2".into());
    f.values.insert(tag("a.next"), "2".into());
    f.values.insert(tag("a.next.next"), "1".into());
    f.children.insert(
        10,
        vec![
            var("v", "1", "number", "a.v", 0),
            var("next", "Node", "Node", "a.next", 20),
        ],
    );
    f.children.insert(
        20,
        vec![
            var("v", "2", "number", "a.next.v", 0),
            var("next", "Node", "Node", "a.next.next", 10),
            var(
                "[[Prototype]]",
                "Object",
                "Object",
                "a.next[\"[[Prototype]]\"]",
                30,
            ),
        ],
    );
    let g = heap::walk(&f, Ident::of("pwa-node"), roots, Limits::default()).await;
    assert_eq!(g.nodes.len(), 2, "{g:#?}");
    assert_eq!(to(node(&g, "js:1"), "next").as_deref(), Some("js:2"));
    assert_eq!(
        to(node(&g, "js:2"), "next").as_deref(),
        Some("js:1"),
        "the ring closes"
    );
    assert_eq!(g.roots[1].1.as_deref(), Some("js:2"), "shared is a.next");
}

/// An adapter that takes a second for each object's children.
struct Slow(Fake);

impl Probe for Slow {
    fn variables(&self, reference: i64) -> BoxFut<'_, Result<Vec<Value>, String>> {
        Box::pin(async move {
            crate::clock::sleep(std::time::Duration::from_secs(1)).await;
            self.0.variables(reference).await
        })
    }
    fn evaluate(&self, expression: String) -> BoxFut<'_, Result<String, String>> {
        self.0.evaluate(expression)
    }
}

#[tokio::test(start_paused = true)]
async fn a_slow_adapter_gets_a_partial_graph_at_the_time_limit() {
    let (f, roots) = python();
    let limits = Limits {
        within: std::time::Duration::from_millis(1500),
        ..Limits::default()
    };
    let g = heap::walk(&Slow(f), Ident::Python, roots, limits).await;
    // a at 1 s, b at 2 s: then the time is up, and what was left is counted
    assert_eq!(g.nodes.len(), 2, "{g:#?}");
    assert!(g.cut >= 2, "{g:#?}");
}

#[test]
fn the_next_stops_graph_says_what_was_added_changed_and_gone() {
    let node = |id: &str, v: &str, to: Option<&str>| heap::Node {
        id: id.into(),
        ty: "Node".into(),
        path: id.into(),
        fields: vec![
            heap::Field {
                name: "v".into(),
                value: v.into(),
                to: None,
            },
            heap::Field {
                name: "next".into(),
                value: "Node".into(),
                to: to.map(str::to_owned),
            },
        ],
    };
    let before = vec![
        node("A", "1", Some("B")),
        node("B", "2", None),
        node("C", "3", None),
    ];
    let after = vec![
        node("A", "1", Some("D")),
        node("B", "20", None),
        node("D", "4", None),
    ];
    let d = heap::diff(&before, &after);
    assert_eq!(d.added, vec!["D".to_owned()]);
    assert_eq!(
        d.changed,
        vec!["A".to_owned(), "B".to_owned()],
        "A's reference, B's value"
    );
    assert_eq!(d.gone, vec!["C".to_owned()]);
}
