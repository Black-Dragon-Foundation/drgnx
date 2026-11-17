//! The minimap's hub layers (docs/develop/core.md, "Minimap"): what the hub knows of a file that the editor's line
//! model does not (labels, fold ranges for buffers with no parser, heat, a huge file's density buckets) goes to
//! Nidhogg's Sjá on the model's raw path, never through Lisp. A layer is one line, `view-model` like a model so the
//! framed reader hands it to Sjá whole:
//!
//! ```text
//! {"event": "view-model", "data": {"minimap": {"file": F, "layer": L, "version": N, "items": I}}}
//! L = "labels"   I = [[line, depth, kind, text]]    a definition's name, line from 1, depth 0 outermost
//!   | "folds"    I = [[first, last, kind]]          a fold range, lines from 1
//!   | "heat:" S  I = [[first, last, value]]         source S (blame, coverage, …), value 0..=1000
//!   | "density"  I = {"buckets": [[bytes, errors, warnings]], "total": n}   the first buckets of n
//! I = null removes the layer.
//! ```
//!
//! Sjá keeps the newest version of each (file, layer); an older one is dropped there.
//!
//! **Labels** (`minimap/watch`): while a connection shows a file in a minimap, the hub sends it the file's definitions
//! as the Outline reads them (the editor's text where the edit history tracks it, else the disk), up to
//! [`LABELS_MAX`] bytes, at once and again [`super::outline::QUIET`] after the edits to it pause.  MARK sections are
//! not the hub's: the editor's line model finds them (any size, no hub).

use super::lock;
use crate::dispatch::Caller;
use crate::front::{Front, event_line};
use runstav::methods::view::MinimapWatch;
use runstav::wire::Error;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

/// The largest text whose definitions label the minimap, in bytes (design Q6: past the Outline's 1 MiB).
pub const LABELS_MAX: usize = 8 << 20;

/// One layer of a file's minimap, as the hub has it.
#[derive(Clone, Debug, PartialEq)]
pub enum Layer {
    /// Names drawn over the minimap: (line, depth, kind, text).
    Labels(Vec<(u32, u32, String, String)>),
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

/// The labels of TEXT of PATH: each definition's line, depth, kind and name; none past [`LABELS_MAX`].
pub fn labels_of(path: &str, text: &str) -> Layer {
    if text.len() > LABELS_MAX {
        return Layer::Labels(Vec::new());
    }
    Layer::Labels(
        hrafn::symbols::outline_text(path, text)
            .map(|(_, entries)| {
                entries
                    .into_iter()
                    .map(|e| (e.line_start, e.depth, e.kind, e.name))
                    .collect()
            })
            .unwrap_or_default(),
    )
}

/// The fold ranges of TEXT of PATH by its pack's grammar (lines from 1); none for a file no tree-sitter pack parses
/// (the editor folds those itself), past [`LABELS_MAX`], or when it does not parse.
pub fn folds_of(path: &str, text: &str) -> Option<Layer> {
    if text.len() > LABELS_MAX {
        return None;
    }
    let (lang, _) = hrafn::files::classify(path, text.as_bytes());
    let folds = hrafn::chunk::folds::of_file(path, lang, text)?;
    Some(Layer::Folds(
        folds
            .into_iter()
            .map(|f| {
                let kind = hrafn::chunk::folds::KINDS[usize::from(f.kind)];
                (f.first + 1, f.last + 1, kind.to_owned())
            })
            .collect(),
    ))
}

/// Every layer's version: one counter for the hub, so a later push is always newer.
static VERSION: AtomicU64 = AtomicU64::new(1);

/// The files each connection shows in a minimap, each with the generation of its latest ask.
#[derive(Default)]
pub struct Watches {
    files: Mutex<HashMap<(u64, String), u64>>,
}

impl Watches {
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.files).retain(|(c, _), _| *c != conn);
    }
}

/// Send CONN FILE's labels, and its fold ranges when a pack's grammar parses it, for its ask GENERATION; nothing when a
/// later ask came meanwhile or it is no longer watched.
async fn push(f: &Front, conn: u64, file: &str, generation: u64) {
    let current = |f: &Front| {
        lock(&f.core.views.minimaps.files).get(&(conn, file.to_owned())) == Some(&generation)
    };
    if !current(f) {
        return;
    }
    let layers = match super::outline::text_within(f, file, LABELS_MAX).await {
        Ok(text) => {
            let path = file.to_owned();
            crate::clock::blocking(move || {
                let mut v = vec![labels_of(&path, &text)];
                v.extend(folds_of(&path, &text));
                v
            })
            .await
            .unwrap_or_else(|_| vec![Layer::Labels(Vec::new())])
        }
        Err(_) => vec![Layer::Labels(Vec::new())],
    };
    if !current(f) {
        return;
    }
    for layer in layers {
        let version = VERSION.fetch_add(1, Ordering::Relaxed);
        f.send_to(
            conn,
            "view-model",
            data(file, version, &layer.name(), layer.items()),
        );
    }
}

/// `minimap/watch`: the caller shows P's file in a minimap (its labels are sent before the answer), or no longer.
pub async fn watch(f: &Front, c: &Caller, p: MinimapWatch) -> Result<bool, Error> {
    let file = crate::work::presence::true_name(&p.file);
    let key = (c.conn_id, file.clone());
    if !p.on {
        lock(&f.core.views.minimaps.files).remove(&key);
        return Ok(true);
    }
    let generation = {
        let mut files = lock(&f.core.views.minimaps.files);
        let g = files.entry(key).or_default();
        *g += 1;
        *g
    };
    push(f, c.conn_id, &file, generation).await;
    Ok(true)
}

/// The edit history took an edit to FILE (its true name): every connection watching it gets its labels again once
/// the edits pause.
pub fn touched(f: &Front, file: &str) {
    let due: Vec<(u64, u64)> = {
        let mut files = lock(&f.core.views.minimaps.files);
        files
            .iter_mut()
            .filter(|((_, name), _)| name == file)
            .map(|((conn, _), g)| {
                *g += 1;
                (*conn, *g)
            })
            .collect()
    };
    let Some(front) = f.core.views.front_weak() else {
        return;
    };
    for (conn, generation) in due {
        let (front, file) = (front.clone(), file.to_owned());
        crate::clock::spawn("minimap:quiet", async move {
            crate::clock::sleep(super::outline::QUIET).await;
            if let Some(f) = front.upgrade() {
                push(&f, conn, &file, generation).await;
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn layers() -> Vec<(u64, Layer)> {
        vec![
            (
                1,
                Layer::Labels(vec![
                    (3, 0, "function".into(), "main".into()),
                    (40, 1, "method".into(), "parse".into()),
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
                Layer::Labels(vec![(4, 0, "function".into(), "main".into())]),
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

    #[test]
    fn labels_are_the_definitions_with_their_depth_and_none_past_the_limit() {
        let text = "fn main() {}\n\nstruct S;\nimpl S {\n    fn go(&self) {}\n}\n";
        let Layer::Labels(l) = labels_of("/r/a.rs", text) else {
            panic!("labels");
        };
        let names: Vec<(u32, u32, &str)> =
            l.iter().map(|(a, d, _, n)| (*a, *d, n.as_str())).collect();
        assert!(names.contains(&(1, 0, "main")), "{names:?}");
        assert!(
            names.iter().any(|&(a, d, n)| a == 5 && d >= 1 && n == "go"),
            "{names:?}"
        );
        let big = "fn f() {}\n".repeat(LABELS_MAX / 10 + 1);
        assert_eq!(labels_of("/r/a.rs", &big), Layer::Labels(Vec::new()));
        // between the Outline's limit and the minimap's: labelled
        let mid = "fn f() {}\n".repeat((1 << 20) / 10 + 100);
        let Layer::Labels(m) = labels_of("/r/a.rs", &mid) else {
            panic!("labels");
        };
        assert!(!m.is_empty());
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

    /// A fetched pack's file folds through its worker, by the same rule as a built-in pack's: the fold query's ranges,
    /// widened to lines, one a start line, on a tie the more specific kind ([Fact] is a test).
    #[cfg(feature = "test-hooks")]
    #[test]
    fn a_fetched_packs_file_folds_through_its_worker_as_a_built_in_one() {
        let _pack = crate::parse_worker::fixture::install_csharp("csharpx", "xcs");
        let text = "class G\n{\n    [Fact]\n    void M()\n    {\n        Foo(1);\n    }\n}\n";
        let fetched = folds_of("/r/a.xcs", text).expect("the worker folds it");
        assert_eq!(
            fetched,
            Layer::Folds(vec![
                (1, 8, "class".into()),
                (2, 8, "block".into()),
                (3, 7, "test".into()),
                (5, 7, "block".into()),
            ])
        );
        assert_eq!(folds_of("/r/a.cs", text), Some(fetched));
        // a file no pack parses folds by the editor's own rules: no layer
        assert_eq!(folds_of("/r/a.txt", "a\n  b\n"), None);
    }
}
