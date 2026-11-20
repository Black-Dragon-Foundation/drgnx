//! Accessibility over every kit component (flow Task 30, `a11y-flow/every-glyph-has-a-label`): each surface draws its
//! glyphs through the kit, so its components' expansions in `test/fixtures/kit/expected.json` (every case at every
//! env) are what a screen reader meets. A clickable span with no word in it (`drgnx-action` over glyphs only), and a
//! row of glyphs with no word, carry a `help-echo` label. A row of only brackets, bars and spaces (an empty field's
//! box) is drawn chrome, not a glyph.

use serde_json::Value;

fn expected() -> Vec<Value> {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../test/fixtures/kit/expected.json"
    );
    serde_json::from_str(&std::fs::read_to_string(path).expect("expected.json")).expect("JSON")
}

fn wordless(text: &str) -> bool {
    !text.chars().any(char::is_alphanumeric)
        && text.chars().any(|c| !c.is_whitespace() && !"[]|".contains(c))
}

/// The unlabelled glyph-only parts of ROW: `(what, text)`.
fn unlabelled(row: &Value) -> Vec<(String, String)> {
    let text: Vec<char> = row["text"].as_str().unwrap_or("").chars().collect();
    let props = row["props"].as_array().cloned().unwrap_or_default();
    let span = |p: &Value| (p[0].as_u64().unwrap() as usize, p[1].as_u64().unwrap() as usize);
    let helps: Vec<(usize, usize)> = props
        .iter()
        .filter(|p| p[2] == "help-echo")
        .map(span)
        .collect();
    let covered = |a: usize, z: usize| helps.iter().any(|(s, e)| *s < z && a < *e);
    let mut out = Vec::new();
    for p in props.iter().filter(|p| p[2] == "drgnx-action") {
        let (a, z) = span(p);
        let seg: String = text[a.min(text.len())..z.min(text.len())].iter().collect();
        if wordless(&seg) && !covered(a, z) {
            out.push(("action".to_owned(), seg));
        }
    }
    let whole: String = text.iter().collect();
    if wordless(&whole) && helps.is_empty() {
        out.push(("row".to_owned(), whole));
    }
    out
}

#[test]
fn every_glyph_has_a_label() {
    let mut bad = Vec::new();
    for e in expected() {
        let name = e["name"].as_str().unwrap_or("").to_owned();
        let mut rows = vec![e.clone()];
        rows.extend(e["more"].as_array().cloned().unwrap_or_default());
        for r in &rows {
            for (what, text) in unlabelled(r) {
                bad.push(format!("{name}: {what} {text:?}"));
            }
        }
    }
    assert!(bad.is_empty(), "glyphs with no label:\n{}", bad.join("\n"));
}
