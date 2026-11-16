//! The kit's conformance test, the hub's half: each comp of `test/fixtures/kit/cases.json` expanded at each env by
//! `drgnx_rows::kit` equals `expected.json`'s entry. The Lisp half (`drgnx-ui-kit/conformance`) reads the same files,
//! so the hub and the Lisp chrome draw a component alike. `DRGNX_KIT_BLESS=1` writes `expected.json` instead.

use drgnx_rows::RowBuilder;
use drgnx_rows::kit::{self, Comp, KitEnv};
use serde_json::{Value, json};
use std::path::PathBuf;

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../test/fixtures/kit")
        .join(name)
}

/// Every case's expansion, as `expected.json` holds it: `[{name, text, runs, props, spaces}…]`.
fn expansions() -> Value {
    let cases: Value =
        serde_json::from_str(&std::fs::read_to_string(fixture("cases.json")).unwrap()).unwrap();
    let mut out = Vec::new();
    for e in cases["envs"].as_array().unwrap() {
        let ascii: Vec<(String, String)> = kit::GLYPHS
            .iter()
            .map(|(n, _, a)| ((*n).to_owned(), (*a).to_owned()))
            .collect();
        let density =
            serde_json::from_value(e.get("density").cloned().unwrap_or(json!("comfortable")))
                .unwrap();
        let env = KitEnv {
            density,
            scale: e["scale"].as_f64().unwrap() as f32,
            tty: e["tty"].as_bool().unwrap(),
            glyphs: if e["ascii"].as_bool().unwrap() {
                &ascii
            } else {
                &[]
            },
        };
        for c in cases["comps"].as_array().unwrap() {
            let name = format!(
                "{}/{}",
                e["name"].as_str().unwrap(),
                c["name"].as_str().unwrap()
            );
            let comp: Comp = serde_json::from_value(c["comp"].clone()).unwrap();
            let mut b = RowBuilder::new(name.clone());
            kit::expand(&mut b, &env, &comp);
            let row = b.finish();
            out.push(json!({"name": name, "text": row.text, "runs": row.runs, "props": row.props, "spaces": row.spaces, "height": row.height}));
        }
    }
    Value::Array(out)
}

#[test]
fn kit_conformance() {
    let got = expansions();
    let path = fixture("expected.json");
    if std::env::var_os("DRGNX_KIT_BLESS").is_some() {
        let mut text = String::from("[\n");
        let items = got.as_array().unwrap();
        for (i, item) in items.iter().enumerate() {
            text.push_str(&serde_json::to_string(item).unwrap());
            text.push_str(if i + 1 < items.len() { ",\n" } else { "\n" });
        }
        text.push_str("]\n");
        std::fs::write(&path, text).unwrap();
        return;
    }
    let want: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).expect("expected.json (bless it)"))
            .unwrap();
    let (got, want) = (got.as_array().unwrap(), want.as_array().unwrap());
    for (g, w) in got.iter().zip(want) {
        assert_eq!(g, w, "{}", g["name"]);
    }
    assert_eq!(got.len(), want.len(), "the number of cases");
}
