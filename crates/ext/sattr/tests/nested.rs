//! What the real API does not use yet, generated from a test world (tests/wit-nested) and run: a record in a record, a list
//! of records that hold lists, and lists in exported functions, in both hosts' codecs and against the host's limit.

use std::sync::{Arc, Mutex, RwLock};

mod b {
    wasmtime::component::bindgen!({
        path: "tests/wit-nested",
        world: "w",
        imports: { default: trappable },
    });
}

#[allow(dead_code)]
mod g {
    include!(concat!(env!("OUT_DIR"), "/nested_gen.rs"));
}

#[derive(Clone, Debug)]
pub struct C;

pub struct S<A> {
    pub api: g::WasmApi<A>,
}

use g::acme_nest_v1_0_0::i::{Kind, Point, Row, Span, Table};

#[derive(Default)]
struct Fake {
    seen: Vec<Table>,
}

impl g::acme_nest_v1_0_0::i::Api for Fake {
    fn put(&mut self, _c: &C, t: Table) -> Result<Vec<Row>, Kind> {
        let rows = t.rows.clone();
        self.seen.push(t);
        if rows.is_empty() {
            Err(Kind::B)
        } else {
            Ok(rows)
        }
    }
}

fn row(name: &str, tags: &[&str]) -> Row {
    Row {
        name: name.into(),
        tags: tags.iter().map(|t| t.to_string()).collect(),
        at: Span {
            start: Point { x: 1, y: 2 },
            finish: Point { x: 3, y: 4 },
            kind: Kind::B,
        },
    }
}

fn lua(max: usize) -> (mlua::Lua, Arc<Mutex<Fake>>) {
    let lua = mlua::Lua::new();
    let api = Arc::new(Mutex::new(Fake::default()));
    let caller = Arc::new(RwLock::new(C));
    g::install_luau(&lua, &api, &caller, max).expect("installs");
    (lua, api)
}

#[test]
fn a_nested_table_crosses_into_luau_and_back() {
    let (lua, api) = lua(4);
    lua.load(
        r#"
        local rows = nest.i.put({ title = "t", rows = {
          { name = "r1", tags = { "a", "b" },
            at = { start = { x = 1, y = 2 }, finish = { x = 3, y = -4 }, kind = "b" } },
        } })
        assert(#rows == 1)
        assert(rows[1].name == "r1" and rows[1].tags[2] == "b")
        assert(rows[1].at.finish.y == -4 and rows[1].at.kind == "b" and rows[1].at.start.x == 1)
        "#,
    )
    .exec()
    .expect("the round trip");
    let seen = &saman::lock(&api).seen;
    assert_eq!(seen[0].rows[0].at.finish, Point { x: 3, y: -4 });
    assert_eq!(seen[0].rows[0].tags, ["a", "b"]);
}

#[test]
fn a_list_inside_a_list_of_records_is_checked_against_the_limit_in_luau() {
    let (lua, _api) = lua(2);
    let e = lua
        .load(
            r#"nest.i.put({ title = "t", rows = { { name = "r", tags = { "a", "b", "c" },
               at = { start = { x = 0, y = 0 }, finish = { x = 0, y = 0 }, kind = "a" } } } })"#,
        )
        .exec()
        .expect_err("a row's tags are over the limit");
    assert!(e.to_string().contains("longer than 2"), "{e}");
    // a missing nested field and a wrong kind are named
    let e = lua
        .load(r#"nest.i.put({ title = "t", rows = { { name = "r", tags = {}, at = { start = 1 } } } })"#)
        .exec()
        .expect_err("a point that is a number");
    assert!(e.to_string().contains("expected a table"), "{e}");
    let e = lua
        .load(
            r#"nest.i.put({ title = "t", rows = { { name = "r", tags = {},
               at = { start = { x = 0, y = 0 }, finish = { x = 0, y = 0 }, kind = "c" } } } })"#,
        )
        .exec()
        .expect_err("an unknown kind");
    assert!(e.to_string().contains("not one of"), "{e}");
}

#[test]
fn an_exported_function_with_lists_sends_and_reads_them_in_luau() {
    let (lua, _api) = lua(3);
    lua.load(
        r#"
        ext = {}
        function ext.rows(t, names)
          assert(#names == 2 and names[2] == "n2")
          assert(t.rows[1].tags[1] == "x" and t.rows[1].at.finish.x == 3)
          return t.rows
        end
        function ext.tags() return { "p", "q" } end
        "#,
    )
    .exec()
    .expect("the script");
    let ext: mlua::Table = lua.globals().get("ext").expect("the table");
    let t = Table {
        rows: vec![row("r", &["x"])],
        title: "t".into(),
    };
    let got = g::acme_nest_v1_0_0::exports::e::luau_rows(
        &lua,
        &ext,
        3,
        t.clone(),
        vec!["n1".into(), "n2".into()],
    )
    .expect("calls")
    .expect("not an error");
    assert_eq!(got, t.rows);
    assert_eq!(
        g::acme_nest_v1_0_0::exports::e::luau_tags(&lua, &ext, 3).expect("calls"),
        ["p", "q"]
    );
    // the list the host sends is checked against the limit, and so is the one the script returns
    let e = g::acme_nest_v1_0_0::exports::e::luau_rows(
        &lua,
        &ext,
        1,
        t.clone(),
        vec!["n1".into(), "n2".into()],
    )
    .expect_err("two names over a limit of one");
    assert!(e.to_string().contains("longer than 1"), "{e}");
    let e = g::acme_nest_v1_0_0::exports::e::luau_tags(&lua, &ext, 1).expect_err("returns two");
    assert!(e.to_string().contains("longer than 1"), "{e}");
}

#[test]
fn the_component_host_checks_nested_lists_a_guest_sends() {
    use b::acme::nest::i::{
        Host, Kind as WKind, Point as WPoint, Row as WRow, Span as WSpan, Table as WTable,
    };
    let api = Arc::new(Mutex::new(Fake::default()));
    let mut w = g::WasmApi(api.clone(), Arc::new(RwLock::new(C)), 2);
    let wrow = |tags: usize| WRow {
        name: "r".into(),
        tags: (0..tags).map(|i| i.to_string()).collect(),
        at: WSpan {
            start: WPoint { x: 1, y: 2 },
            finish: WPoint { x: 3, y: 4 },
            kind: WKind::A,
        },
    };
    let ok = Host::put(
        &mut w,
        WTable {
            rows: vec![wrow(2)],
            title: "t".into(),
        },
    )
    .expect("within the limit")
    .expect("not an error");
    assert_eq!(ok.len(), 1);
    assert_eq!(ok[0].at.finish.y, 4, "the nested record converts back");
    // the row's tags are one level down: they are checked too
    let e = Host::put(
        &mut w,
        WTable {
            rows: vec![wrow(3)],
            title: "t".into(),
        },
    )
    .expect_err("a row's tags are over the limit");
    assert!(e.to_string().contains("longer than 2"), "{e}");
    // and so are the rows
    let e = Host::put(
        &mut w,
        WTable {
            rows: vec![wrow(0), wrow(0), wrow(0)],
            title: "t".into(),
        },
    )
    .expect_err("the rows are over the limit");
    assert!(e.to_string().contains("longer than 2"), "{e}");
    assert_eq!(
        saman::lock(&api).seen.len(),
        1,
        "a refused call reaches nothing"
    );
}
