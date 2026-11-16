//! The minimap's hub layers (docs/develop/core.md, "Minimap"): what the hub knows of a file that the editor's line
//! model does not (labels, fold ranges for buffers with no parser, heat, a huge file's density buckets) goes to
//! Nidhogg's Sjá on the model's raw path, never through Lisp. A layer is one line, `view-model` like a model so the
//! framed reader hands it to Sjá whole:
//!
//! ```text
//! {"event": "view-model", "data": {"minimap": {"file": F, "layer": L, "version": N, "items": I}}}
//! L = "labels"   I = [[line, kind, text]]           a definition's name or a MARK comment, line from 1
//!   | "folds"    I = [[first, last, kind]]          a fold range, lines from 1
//!   | "heat:" S  I = [[first, last, value]]         source S (blame, coverage, …), value 0..=1000
//!   | "density"  I = {"buckets": [[bytes, errors, warnings]], "total": n}   the first buckets of n
//! I = null removes the layer.
//! ```
//!
//! Sjá keeps the newest version of each (file, layer); an older one is dropped there.

use crate::front::event_line;
use serde_json::{Value, json};
use std::sync::Arc;

/// One layer of a file's minimap, as the hub has it.
#[derive(Clone, Debug, PartialEq)]
pub enum Layer {
    /// Names drawn over the minimap: (line, kind, text).
    Labels(Vec<(u32, String, String)>),
    /// Fold ranges for a buffer no parser folds: (first line, last line, kind).
    Folds(Vec<(u32, u32, String)>),
    /// A heat source's spans: its name, then (first line, last line, value 0..=1000).
    Heat(String, Vec<(u32, u32, u16)>),
    /// A huge file's density: the buckets built so far, (bytes, errors, warnings) each, of `total`.
    Density {
        buckets: Vec<(u64, u32, u32)>,
        total: u32,
    },
}

impl Layer {
    /// The layer's name on the wire.
    pub fn name(&self) -> String {
        match self {
            Layer::Labels(_) => "labels".into(),
            Layer::Folds(_) => "folds".into(),
            Layer::Heat(source, _) => format!("heat:{source}"),
            Layer::Density { .. } => "density".into(),
        }
    }

    fn items(&self) -> Value {
        match self {
            Layer::Labels(v) => json!(v),
            Layer::Folds(v) => json!(v),
            Layer::Heat(_, v) => json!(v),
            Layer::Density { buckets, total } => json!({"buckets": buckets, "total": total}),
        }
    }
}

/// FILE's LAYER at VERSION as the line Sjá takes; none (logged) over the hub's line limit.
pub fn line(file: &str, version: u64, layer: &Layer) -> Option<Arc<str>> {
    event_line(
        "view-model",
        data(file, version, &layer.name(), layer.items()),
    )
}

/// The line that removes FILE's layer NAME (a heat source turned off, a file no longer huge).
pub fn removal(file: &str, version: u64, name: &str) -> Option<Arc<str>> {
    event_line("view-model", data(file, version, name, Value::Null))
}

fn data(file: &str, version: u64, name: &str, items: Value) -> Value {
    json!({"minimap": {"file": file, "layer": name, "version": version, "items": items}})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn layers() -> Vec<(u64, Layer)> {
        vec![
            (
                1,
                Layer::Labels(vec![
                    (3, "function".into(), "main".into()),
                    (40, "mark".into(), "Parsing".into()),
                ]),
            ),
            (
                1,
                Layer::Folds(vec![(3, 20, "block".into()), (5, 9, "comment".into())]),
            ),
            (
                1,
                Layer::Heat("blame".into(), vec![(1, 10, 1000), (11, 30, 250)]),
            ),
            (
                1,
                Layer::Density {
                    buckets: vec![(4096, 2, 1), (4100, 0, 0)],
                    total: 8,
                },
            ),
            // a newer labels layer replaces the first; an older folds layer is dropped by Sjá
            (
                2,
                Layer::Labels(vec![(4, "function".into(), "main".into())]),
            ),
            (0, Layer::Folds(vec![(1, 2, "block".into())])),
        ]
    }

    #[test]
    fn a_layer_is_a_model_line_sja_takes_whole() {
        let l = line("/r/a.rs", 7, &Layer::Folds(vec![(3, 20, "block".into())])).unwrap();
        assert!(
            l.starts_with("{\"event\":\"view-model\""),
            "the framed reader's raw prefix: {l}"
        );
        assert!(l.ends_with('\n'));
        let v: Value = serde_json::from_str(&l).unwrap();
        assert_eq!(
            v["data"]["minimap"],
            json!({"file": "/r/a.rs", "layer": "folds", "version": 7, "items": [[3, 20, "block"]]})
        );
        let r: Value = serde_json::from_str(&removal("/r/a.rs", 8, "heat:blame").unwrap()).unwrap();
        assert_eq!(r["data"]["minimap"]["items"], Value::Null);
        assert_eq!(r["data"]["minimap"]["layer"], "heat:blame");
    }

    /// The lines as the hub writes them are what Nidhogg's Sjá loads: the same file sits in Nidhogg's test tree
    /// (`sja/tests/fixtures/minimap-push.json`), where a test pushes it. `UPDATE_SJA_FIXTURES=1` rewrites it here; copy
    /// it to Nidhogg's tree.
    #[test]
    fn the_layer_lines_are_the_fixture_sja_loads() {
        let lines: Vec<String> = layers()
            .iter()
            .map(|(v, l)| line("/r/a.rs", *v, l).unwrap().trim_end().to_owned())
            .chain(std::iter::once(
                removal("/r/a.rs", 3, "heat:blame")
                    .unwrap()
                    .trim_end()
                    .to_owned(),
            ))
            .collect();
        let now = json!({"file": "/r/a.rs", "lines": lines});
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/minimap-push.json"
        );
        if std::env::var_os("UPDATE_SJA_FIXTURES").is_some() {
            std::fs::write(path, serde_json::to_string_pretty(&now).unwrap() + "\n").unwrap();
        }
        let held: Option<Value> = std::fs::read_to_string(path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok());
        assert!(
            held.as_ref() == Some(&now),
            "the fixture differs (UPDATE_SJA_FIXTURES=1 rewrites it, then copy it to Nidhogg); the hub writes:\n{}",
            serde_json::to_string_pretty(&now).unwrap()
        );
    }
}
