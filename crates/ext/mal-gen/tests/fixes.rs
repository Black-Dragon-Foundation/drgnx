//! The generator's own tests: the Opus review's eight findings (docs/research/drgnx/b0/s-ext.md, "Generator
//! review"), each as a test that fails without its fix. The runtime halves (a script handing in 2^53 + 1, a panic in
//! the API) are in sattr's tests, which run the generated code.

use std::path::Path;

use mal_gen::{Options, Output, generate};

fn opts() -> Options {
    Options {
        generated: "crate::g".into(),
        bindings: "crate::b".into(),
        state: "crate::S<A>".into(),
        api_field: "field".into(),
        global: "script".into(),
        caller: "crate::C".into(),
    }
}

/// The generation of WIT (one package, world `w`).
fn gen_wit(wit: &str) -> villa::Result<Output> {
    let dir = tempfile::tempdir().expect("a temp dir");
    eitri::replace_file(&dir.path().join("a.wit"), wit.as_bytes()).expect("the fixture is written");
    generate(dir.path(), "w", &opts())
}

fn must(wit: &str) -> Output {
    match gen_wit(wit) {
        Ok(o) => o,
        Err(e) => panic!("generation failed: {e} {:?}", e.detail()),
    }
}

fn parses(out: &Output) {
    if let Err(e) = syn::parse_file(&out.rust) {
        panic!("the generated Rust does not parse: {e}\n{}", out.rust);
    }
}

const BASIC: &str = "package acme:thing@1.2.3;
interface i {
  enum kind { a, b }
  f: func(x: u64, y: s64, z: u8, name: string, k: kind) -> result<u64, kind>;
  g: func() -> bool;
}
interface e {
  use i.{kind};
  run: func(n: string) -> result<_, kind>;
}
world w { import i; export e; }
";

#[test]
fn the_real_api_generates_rust_that_parses() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../mal");
    let out = generate(&dir, "extension", &opts()).expect("the real WIT generates");
    parses(&out);
    assert!(out.bound.contains(&"commands.register".to_string()));
    assert!(out.exports.contains(&"entry.run".to_string()));
}

// 1. u64 and s64 refuse values above 2^53 and fractions
#[test]
fn integers_are_checked_whole_and_within_two_to_the_53() {
    let out = must(BASIC);
    parses(&out);
    // every integer parameter goes through the checked decoder, 64-bit ones cut at 2^53
    assert!(out.rust.contains("rt::dec_int("), "{}", out.rust);
    assert!(out.rust.contains("9007199254740992.0"), "{}", out.rust);
    assert!(out.rust.contains("-9007199254740992.0"), "{}", out.rust);
    // and a 64-bit result goes out through the checked encoder
    assert!(out.rust.contains("rt::enc_u64("), "{}", out.rust);
    assert!(
        !out.rust.contains("FromLua"),
        "no bare mlua integer conversion"
    );
}

// 2. the bound tables are read-only to scripts
#[test]
fn every_table_is_made_read_only() {
    let out = must(BASIC);
    // the interface table, the package table and the global
    assert!(
        out.rust.matches("set_readonly(true)").count() >= 3,
        "{}",
        out.rust
    );
    let interface_table = out
        .rust
        .find("__t.set_readonly(true)")
        .expect("the interface table");
    let first_set = out.rust.find("__t.set(\"f\"").expect("the function is set");
    assert!(first_set < interface_table, "set, then freeze");
}

// 3. every type is checked in every position, and the generator refuses with the WIT name
#[test]
fn unsupported_types_are_refused_with_the_wit_name() {
    let cases = [
        (
            "f: func(x: list<list<u8>>);",
            "acme:thing@1.0.0/i.f, parameter `x`: a list of lists is not supported",
        ),
        (
            "record r { a: list<u8> }\n  f: func(x: list<r>);",
            "acme:thing@1.0.0/i.f, parameter `x`: a list of records that hold lists is not supported",
        ),
        ("f: func(x: char);", "acme:thing@1.0.0/i.f, parameter `x`"),
        ("f: func() -> option<u8>;", "acme:thing@1.0.0/i.f, result"),
        (
            "f: func() -> tuple<u8, u8>;",
            "acme:thing@1.0.0/i.f, result",
        ),
        (
            "record r { a: list<option<u8>> }\n  f: func() -> r;",
            "acme:thing@1.0.0/i.f, result: record `r`, field `a`",
        ),
        (
            "f: func() -> result<u8, string>;",
            "acme:thing@1.0.0/i.f, result",
        ),
        ("f: func() -> result<u8>;", "acme:thing@1.0.0/i.f, result"),
        (
            "f: func() -> result<list<list<u8>>, k>;\n  enum k { a }",
            "acme:thing@1.0.0/i.f, result",
        ),
        (
            "f: func(x: result<u8, k>);\n  enum k { a }",
            "acme:thing@1.0.0/i.f, parameter `x`",
        ),
        (
            "flags fl { a }\n  f: func(x: fl);",
            "acme:thing@1.0.0/i.f, parameter `x`",
        ),
        (
            "variant v { a }\n  f: func() -> v;",
            "acme:thing@1.0.0/i.f, result",
        ),
    ];
    for (body, named) in cases {
        let wit = format!(
            "package acme:thing@1.0.0;\ninterface i {{\n  {body}\n}}\nworld w {{ import i; }}\n"
        );
        match gen_wit(&wit) {
            Ok(_) => panic!("{body} must be refused"),
            Err(e) => assert!(
                e.to_string().contains(named),
                "{body}: the error `{e}` does not name `{named}`"
            ),
        }
    }
}

#[test]
fn supported_shapes_in_every_position_generate() {
    // an enum as a parameter and as a bare result, a type alias, floats, a result with a string ok
    let out = must(
        "package acme:thing@1.0.0;
interface i {
  enum k { a, b }
  type text = string;
  f: func(x: k, t: text, p: f32, q: f64, r: bool, s: s8, u: u16, v: s32, w: s16) -> k;
  g: func() -> result<string, k>;
  h: func() -> result<_, k>;
}
world w { import i; }
",
    );
    parses(&out);
}

// 4. no `lock().unwrap()`: no poisoning, no re-entry deadlock
#[test]
fn the_api_lock_is_never_unwrapped_or_blocked_on() {
    let out = must(BASIC);
    assert!(!out.rust.contains("unwrap()"), "{}", out.rust);
    assert!(!out.rust.contains(".lock()"), "{}", out.rust);
    assert!(out.rust.contains("try_lock()"));
}

// 5. host names are passed in
#[test]
fn host_names_come_from_the_options() {
    let out = must(BASIC);
    for want in [
        "crate::g::",
        "crate::b::",
        "crate::S<A>",
        "__s.field",
        "\"script\"",
    ] {
        assert!(out.rust.contains(want), "`{want}` missing:\n{}", out.rust);
    }
    for hardcoded in [
        "crate::wasm",
        "crate::model",
        "crate::generated",
        "\"drgnx\"",
    ] {
        assert!(!out.rust.contains(hardcoded), "`{hardcoded}` is hard-coded");
    }
}

// 6. names are namespaced and escaped
#[test]
fn names_are_namespaced_and_escaped() {
    let out = must(
        "package acme:thing@1.0.0;
interface one {
  enum error-kind { a }
  enum kind { a }
  %type: func(match: u8, api: string, lua: string, store: string, t: string, d: string) -> result<_, error-kind>;
}
interface two {
  enum error-kind { b }
  enum kind { b }
  f: func() -> result<_, error-kind>;
}
world w { import one; import two; }
",
    );
    parses(&out);
    // two interfaces with an `error-kind` and a `kind` each get their own type, in their own module
    for want in ["one::ErrorKind", "two::ErrorKind", "one::Kind", "two::Kind"] {
        assert!(out.rust.contains(want), "`{want}` missing");
    }
    // keywords are raw
    assert!(out.rust.contains("r#type"), "{}", out.rust);
    assert!(out.rust.contains("r#match"), "{}", out.rust);
    // and a WIT parameter named like a generated local cannot shadow it: the generated locals start with `__`
    assert!(out.rust.contains("api: String"));
    assert!(out.rust.contains("let __api"));
}

#[test]
fn a_name_that_cannot_be_rust_is_refused() {
    let r = gen_wit(
        "package acme:thing@1.0.0;\ninterface i { self: func(); }\nworld w { import i; }\n",
    );
    let e = r.err().expect("`self` is refused");
    assert!(e.to_string().contains("acme:thing@1.0.0/i"), "{e}");
}

// 7. the WIT package version is kept in names
#[test]
fn the_package_version_is_in_the_names() {
    let out = must(BASIC);
    assert!(out.rust.contains("acme_thing_v1_2_3"), "{}", out.rust);
    assert!(
        out.rust.contains("\"thing_v1_2_3\""),
        "the Luau table key: {}",
        out.rust
    );
    assert!(
        out.rust
            .contains("pub const API_VERSION: &str = \"1.2.3\";"),
        "{}",
        out.rust
    );
    assert!(out.rust.contains("\"api_version\""), "{}", out.rust);
}

// 8. one Luau error contract
#[test]
fn a_script_result_is_checked_against_the_contract() {
    let out = must(BASIC);
    // the export caller refuses `true, kind`, a lone nil, and an unknown kind
    assert!(out.rust.contains("rt::contract("), "{}", out.rust);
    // and the failure is decoded as the error type, which refuses an unknown kind
    assert!(out.rust.contains("not one of"), "{}", out.rust);
    assert!(out.rust.contains("__v.len() != 1"), "{}", out.rust);
}

#[test]
fn no_function_is_skipped() {
    let out = must(BASIC);
    assert_eq!(out.bound, ["i.f", "i.g"]);
    assert_eq!(out.exports, ["e.run"]);
    for f in &out.bound {
        let (_, name) = f.split_once('.').expect("interface.function");
        assert!(
            out.rust.contains(&format!("__t.set(\"{name}\"")),
            "{f} has no Luau binding"
        );
    }
}

// the caller reaches every API method, from both hosts
#[test]
fn every_api_method_gets_the_caller() {
    let out = must(BASIC);
    // the trait: each method takes `&C` first
    assert_eq!(
        out.rust
            .matches("fn f(&mut self, __caller: &crate::C")
            .count(),
        1,
        "{}",
        out.rust
    );
    assert_eq!(
        out.rust
            .matches("fn g(&mut self, __caller: &crate::C")
            .count(),
        1,
        "{}",
        out.rust
    );
    // Luau: the host's cell is installed, and each call reads it and passes it
    assert!(
        out.rust
            .contains("caller: &std::sync::Arc<std::sync::RwLock<crate::C>>"),
        "{}",
        out.rust
    );
    assert!(out.rust.contains("::f(__m, &__c"), "{}", out.rust);
    // the component host: `WasmApi` holds the cell, and a Host method passes the caller too
    assert!(out.rust.contains("pub struct WasmApi<A>(pub std::sync::Arc<std::sync::Mutex<A>>, pub std::sync::Arc<std::sync::RwLock<crate::C>>, pub usize)"), "{}", out.rust);
    assert!(
        out.rust.contains("let __c = rt::caller(&self.1);"),
        "{}",
        out.rust
    );
}

// a poisoned lock fails the extension: nothing recovers it
#[test]
fn a_poisoned_lock_is_never_recovered() {
    let out = must(BASIC);
    assert!(!out.rust.contains("into_inner"), "{}", out.rust);
    assert!(out.rust.contains("Poisoned(_)"), "{}", out.rust);
}

// lists: scalars, strings and enums, as parameters, results and record fields; never in an exported function
#[test]
fn lists_are_supported_in_the_hosts_functions_and_checked_against_the_limit() {
    let out = must(
        "package acme:thing@1.0.0;
interface i {
  enum k { a, b }
  record bag { names: list<string>, sizes: list<u32>, n: u8 }
  f: func(a: list<string>, b: list<u64>, c: list<k>, d: bag) -> result<list<string>, k>;
  g: func() -> list<bool>;
}
world w { import i; }
",
    );
    parses(&out);
    for want in [
        "Vec<String>",
        "Vec<u64>",
        "rt::dec_list(",
        "rt::check_len(",
        "rt::len_ok(",
        "max_list: usize",
        ", pub usize);",
        "__lt.set(",
    ] {
        assert!(out.rust.contains(want), "`{want}` missing:\n{}", out.rust);
    }
    // a list in an exported function is refused, with the WIT name
    let e = gen_wit(
        "package acme:thing@1.0.0;
interface e { run: func(x: list<u8>); }
world w { export e; }
",
    )
    .err()
    .expect("refused");
    assert!(
        e.to_string()
            .contains("acme:thing@1.0.0/e.run: lists are not supported in exported functions"),
        "{e}"
    );
}

// a list of records: a codec one level deep, in every host
#[test]
fn a_list_of_records_is_supported_when_the_records_hold_no_list() {
    let out = must(
        "package acme:thing@1.0.0;
interface i {
  enum kind { a, b }
  record item { name: string, kind: kind, on: bool }
  record order { items: list<item>, note: string }
  f: func(o: order) -> result<list<item>, kind>;
}
world w { import i; }
",
    );
    parses(&out);
    for want in [
        "::i::Item>",
        "into_iter().map(Into::into).collect()",
        "rt::dec_list(",
        "__rt.set(",
    ] {
        assert!(out.rust.contains(want), "`{want}` missing:\n{}", out.rust);
    }
}
