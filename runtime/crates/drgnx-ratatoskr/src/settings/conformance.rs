//! `settings::conformance`: the hub's reading against the editor's, through test/conformance/settings/lisp-dump.json,
//! which test/conformance/settings/dump.el writes from batch Nidhogg (its header says how; the ERT test
//! `drgnx-settings-runtime-dump/committed-dump-is-current` keeps it current on the editor's side).

use super::*;
use huginn::value::Datum;
use std::os::unix::fs::PermissionsExt;

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../test/conformance/settings")
}

fn lisp() -> Value {
    let text = std::fs::read_to_string(dir().join("lisp-dump.json"))
        .expect("lisp-dump.json: run test/conformance/settings/dump.el (its header)");
    serde_json::from_str(&text).expect("lisp-dump.json is JSON")
}

/// NODE in the canonical dump of test/fixtures/huginn/README.md (no floats in these files).
fn dump(node: &Node) -> Value {
    let all = |items: &[Node]| Value::Array(items.iter().map(dump).collect());
    match &node.datum {
        Datum::Int(i) => json!(["int", i.to_string()]),
        Datum::Float(f) => json!(["float", format!("{f:?}")]),
        Datum::Str(s) => json!(["str", s]),
        Datum::Sym(s) => json!(["sym", s]),
        Datum::List(items) => json!(["list", all(items)]),
        Datum::Cons(items, tail) => json!(["cons", all(items), dump(tail)]),
        Datum::Vec(items) => json!(["vec", all(items)]),
    }
}

/// Equal JSON, numbers by value (Lisp writes 3 where Rust writes 3.0).
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(x, y)| same(x, y))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

#[test]
fn defaults_json_equals_lisp() {
    let lisp = lisp();
    let want = lisp["defaults"].as_object().expect("defaults: an object");
    let file = parse_settings(DEFAULTS.as_bytes(), "drgnx-settings", Limits::default()).unwrap();
    assert_eq!(file.problems, []);
    assert_eq!(
        file.entries.len(),
        want.len(),
        "the same entries on both sides"
    );
    for e in &file.entries {
        let got = dump(&e.value);
        assert_eq!(
            want.get(&e.var),
            Some(&got),
            "{}: the editor read it otherwise",
            e.var
        );
    }
    // and what the hub decodes from it is the editor's too: the counts the editor's constants have
    let d = defaults();
    assert_eq!(lisp["counts"]["presets"], json!(d.presets.len()));
    assert_eq!(lisp["counts"]["profiles"], json!(d.profiles.len()));
    assert_eq!(lisp["counts"]["roles"], json!(d.roles.len()));
}

#[test]
fn providers_json_equals_lisp() {
    let conf = tempfile::tempdir().unwrap();
    let file = conf.path().join("settings.el");
    std::fs::copy(dir().join("providers-settings.el"), &file).unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
    let l = Settings::load(conf.path(), &Kv::default());
    assert_eq!(l.file, FileState::Ok);
    assert_eq!(l.problems, []);
    assert!(l.values.ai_providers.len() >= 4);
    let got = serde_json::to_value(&l.providers).unwrap();
    let want = &lisp()["providers"];
    assert!(
        same(want, &got),
        "the editor's table:\n{want:#}\nthe hub's:\n{got:#}"
    );
}

#[test]
fn runtime_names_equal_lisp_declarations() {
    let want: Vec<(String, String, String)> =
        serde_json::from_value(lisp()["runtime"].clone()).unwrap();
    let mut got: Vec<(String, String, String)> = RUNTIME
        .iter()
        .map(|s| {
            let on_error = match s.on_error {
                OnError::Strict => "strict",
                OnError::LastGood => "last-good",
            };
            (s.name.to_string(), s.ty.to_string(), on_error.to_string())
        })
        .collect();
    got.sort();
    assert_eq!(
        want, got,
        "every :runtime setting of the Lisp, with its type and :on-error"
    );
}
