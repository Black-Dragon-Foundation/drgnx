//! The minimap's hub layers (docs/develop/core.md, "Minimap"): what the hub knows of a file that the editor's line
//! model does not (labels, fold ranges for buffers with no parser, heat, a huge file's density buckets) goes to
//! Nidhogg's Sjá on the model's raw path, never through Lisp. A layer is one line, `view-model` like a model so the
//! framed reader hands it to Sjá whole:
//!
//! ```text
//! {"event": "view-model", "data": {"minimap": {"file": F, "layer": L, "version": N, "items": I}}}
//! L = "labels"   I = [[line, depth, kind, text]]    a definition's name, line from 1, depth 0 outermost
//!   | "folds"    I = [[first, last, kind]]          a fold range, lines from 1
//!   | "heat:" S  I = [[first, last, value, fact]]   source S (blame, coverage, …), value 0..=1000, the peek's text
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
//!
//! **Heat** (`minimap/watch`'s `heat`): the one heat layer the minimap shows, from [`super::heat`]'s sources, sent
//! with the labels and again when they are; a coverage report's folder is watched, so a test run's new report is read
//! again.  Asking for another layer (or none) removes the last one.  Each span carries its fact, which the peek and
//! `minimap-describe` read from Sjá.
//!
//! **Density** (`minimap/watch`'s `density`): a file past the editor's density limit gets no labels, folds or heat but
//! a scan of the file on disk ([`density`]) whose bucket table goes out in parts as the `density` layer;
//! `minimap/bucket` reads a bucket's first lines for its peek.

pub mod density;

use super::heat::{self, Span};
use super::lock;
use crate::dispatch::Caller;
use crate::front::{Front, event_line};
use runstav::methods::view::{MinimapBucket, MinimapBucketParams, MinimapWatch};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
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
    /// A heat source's spans: its name, then each run of lines with its value 0..=1000 and fact.
    Heat(String, Vec<Span>),
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
            Layer::Heat(_, v) => json!(
                v.iter()
                    .map(|s| (s.first, s.last, s.value, &s.fact))
                    .collect::<Vec<_>>()
            ),
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

/// What a connection's watch of a file asked for beyond its labels.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Ask {
    pub heat: Option<String>,
    pub coverage: Vec<String>,
    pub profile: Option<String>,
    /// The density scan's error and warning expressions, and the run that scans for this ask (none: no density).
    pub density: Option<(String, String, u64)>,
}

/// The coverage reports' folders watched, and the reports' name patterns.
#[derive(Default)]
struct CoverageWatch {
    watcher: Option<notify::RecommendedWatcher>,
    dirs: HashSet<PathBuf>,
    names: HashSet<String>,
}

/// The files each connection shows in a minimap, each with the generation of its latest ask and what it asked for.
#[derive(Default)]
pub struct Watches {
    files: Mutex<HashMap<(u64, String), (u64, Ask)>>,
    coverage: Mutex<CoverageWatch>,
}

impl Watches {
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.files).retain(|(c, _), _| *c != conn);
        self.coverage_unused();
    }

    /// The coverage folders unwatched once no watch shows the coverage layer.
    fn coverage_unused(&self) {
        let any = lock(&self.files)
            .values()
            .any(|(_, a)| a.heat.as_deref() == Some("coverage"));
        if !any {
            // the watcher is dropped outside the lock: its thread may be waiting for it
            let old = std::mem::take(&mut *lock(&self.coverage));
            drop(old);
        }
    }
}

/// The worktree FILE is in: the nearest folder above it with a `.git`.
fn worktree_root(file: &Path) -> Option<PathBuf> {
    file.ancestors()
        .skip(1)
        .find(|d| d.join(".git").exists())
        .map(Path::to_path_buf)
}

/// The bytes of PATH, a regular file of at most [`heat::REPORT_MAX`] bytes.
fn read_capped(path: &Path) -> Option<Vec<u8>> {
    let m = std::fs::metadata(path).ok()?;
    (m.is_file() && m.len() <= heat::REPORT_MAX)
        .then(|| std::fs::read(path).ok())
        .flatten()
}

/// The coverage reports PATTERNS name under ROOT (`*` and `?` in the last part), newest first.
fn coverage_reports(root: &Path, patterns: &[String]) -> Vec<PathBuf> {
    let mut found: Vec<(std::time::SystemTime, PathBuf)> = Vec::new();
    let mut seen = HashSet::new();
    let mut take = |path: PathBuf, m: std::fs::Metadata| {
        if m.is_file() && seen.insert(path.clone()) {
            found.push((m.modified().unwrap_or(std::time::UNIX_EPOCH), path));
        }
    };
    for p in patterns {
        let path = root.join(p);
        let (Some(dir), Some(name)) = (path.parent(), path.file_name().and_then(|n| n.to_str()))
        else {
            continue;
        };
        if !name.contains(['*', '?']) {
            if let Ok(m) = std::fs::metadata(&path) {
                take(path, m);
            }
            continue;
        }
        for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
            if e.file_name()
                .to_str()
                .is_some_and(|n| super::explorer::glob(name.as_bytes(), n.as_bytes()))
                && let Ok(m) = std::fs::metadata(e.path())
            {
                take(e.path(), m);
            }
        }
    }
    found.sort_by_key(|a| std::cmp::Reverse(a.0));
    found.into_iter().map(|(_, p)| p).collect()
}

/// Watch the folders of PATTERNS under ROOT: a report written there reads the coverage layers again.
fn watch_coverage(f: &Front, root: &Path, patterns: &[String]) {
    use notify::{RecursiveMode, Watcher};
    let mut cov = lock(&f.core.views.minimaps.coverage);
    for p in patterns {
        let path = root.join(p);
        let (Some(dir), Some(name)) = (path.parent(), path.file_name().and_then(|n| n.to_str()))
        else {
            continue;
        };
        cov.names.insert(name.to_owned());
        if cov.dirs.contains(dir) {
            continue;
        }
        if cov.watcher.is_none() {
            cov.watcher = coverage_watcher(f);
        }
        // a folder not made yet is tried again at the next push
        if let Some(w) = cov.watcher.as_mut()
            && w.watch(dir, RecursiveMode::NonRecursive).is_ok()
        {
            cov.dirs.insert(dir.to_path_buf());
        }
    }
}

fn coverage_watcher(f: &Front) -> Option<notify::RecommendedWatcher> {
    let front = f.core.views.front_weak()?;
    let rt = tokio::runtime::Handle::try_current().ok()?;
    notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        let Ok(ev) = res else { return };
        if matches!(ev.kind, notify::EventKind::Access(_)) {
            return;
        }
        let Some(f) = front.upgrade() else { return };
        let hit = {
            let cov = lock(&f.core.views.minimaps.coverage);
            ev.paths.iter().any(|p| {
                p.file_name().and_then(|n| n.to_str()).is_some_and(|n| {
                    cov.names
                        .iter()
                        .any(|g| super::explorer::glob(g.as_bytes(), n.as_bytes()))
                })
            })
        };
        if hit {
            let _in = rt.enter();
            again(&f, |_, a| a.heat.as_deref() == Some("coverage"));
        }
    })
    .ok()
}

/// FILE's heat layer as ASK wants it (LINES: the file's line count, for reads of the whole file); none without a
/// heat source, or when the source has nothing to say (no worktree, no report).
async fn heat_layer(f: &Front, file: &str, ask: &Ask, lines: u32) -> Option<Layer> {
    let source = ask.heat.clone()?;
    let root = worktree_root(Path::new(file));
    let rel = root.as_ref().and_then(|r| {
        Path::new(file)
            .strip_prefix(r)
            .ok()
            .and_then(Path::to_str)
            .map(str::to_owned)
    });
    let path = file.to_owned();
    let spans = match source.as_str() {
        "blame" => {
            let (root, rel) = (root?, rel?);
            let dir = f.dirs.get()?.hub.clone();
            let (hub, tree) = f.core.history.of_tree(&dir, &root).ok()?;
            let b = crate::clock::blocking(move || hub.git_blame(&tree, &rel))
                .await
                .ok()?
                .ok()?;
            heat::blame(&b, crate::clock::wall_secs() as i64)
        }
        "coverage" => {
            let root = root?;
            watch_coverage(f, &root, &ask.coverage);
            let patterns = ask.coverage.clone();
            crate::clock::blocking(move || {
                coverage_reports(&root, &patterns)
                    .iter()
                    .find_map(|r| {
                        let s = heat::coverage(&read_capped(r)?, &path);
                        (!s.is_empty()).then_some(s)
                    })
                    .unwrap_or_default()
            })
            .await
            .ok()?
        }
        "profile" => {
            let p = ask.profile.clone()?;
            crate::clock::blocking(move || {
                read_capped(Path::new(&p))
                    .map(|b| heat::profile(&b, &path))
                    .unwrap_or_default()
            })
            .await
            .ok()?
        }
        "agent-read" => {
            let names: Vec<String> = std::iter::once(path).chain(rel).collect();
            let reads = f
                .writer
                .db
                .read(move |c| {
                    let names: Vec<&str> = names.iter().map(String::as_str).collect();
                    norn::read::work::reads_of(c, &names)
                })
                .await
                .ok()?;
            let line = |n: Option<i64>| n.and_then(|n| u32::try_from(n).ok());
            let reads: Vec<_> = reads
                .into_iter()
                .map(|(a, b, who)| (line(a), line(b), who))
                .collect();
            heat::agent_read(&reads, lines)
        }
        _ => return None,
    };
    Some(Layer::Heat(source, spans))
}

/// Send CONN FILE's labels, its fold ranges when a pack's grammar parses it, and the heat layer it asked for, for its
/// ask GENERATION; nothing when a later ask came meanwhile or it is no longer watched.
async fn push(f: &Front, conn: u64, file: &str, generation: u64) {
    let key = (conn, file.to_owned());
    let ask = |f: &Front| {
        lock(&f.core.views.minimaps.files)
            .get(&key)
            .filter(|e| e.0 == generation)
            .map(|e| e.1.clone())
    };
    let Some(asked) = ask(f) else {
        return;
    };
    let text = super::outline::text_within(f, file, LABELS_MAX).await;
    let lines = text
        .as_ref()
        .map_or(0, |t| u32::try_from(t.lines().count()).unwrap_or(u32::MAX));
    let mut layers = match text {
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
    layers.extend(heat_layer(f, file, &asked, lines).await);
    if ask(f).is_none() {
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

/// `minimap/watch`: the caller shows P's file in a minimap (its labels and heat are sent before the answer), or no
/// longer.  A heat layer the last ask showed and this one does not is removed.
pub async fn watch(f: &Front, c: &Caller, p: MinimapWatch) -> Result<bool, Error> {
    let file = crate::work::presence::true_name(&p.file);
    let key = (c.conn_id, file.clone());
    let compiled = match &p.density {
        Some(d) => Some((
            compile(&d.error, "density.error")?,
            compile(&d.warning, "density.warning")?,
        )),
        None => None,
    };
    let run = DENSITY_RUN.fetch_add(1, Ordering::Relaxed);
    let ask = Ask {
        heat: p.heat,
        coverage: p.coverage,
        profile: p.profile,
        density: p.density.map(|d| (d.error, d.warning, run)),
    };
    let (generation, old, old_density) = {
        let mut files = lock(&f.core.views.minimaps.files);
        if p.on {
            let e = files.entry(key).or_default();
            e.0 += 1;
            let old = std::mem::replace(&mut e.1, ask.clone());
            (Some(e.0), old.heat, old.density.is_some())
        } else {
            let old = files.remove(&key).map(|(_, a)| a).unwrap_or_default();
            (None, old.heat, old.density.is_some())
        }
    };
    // a file no longer past the limit: its strip's layer goes
    if old_density && generation.is_some() && ask.density.is_none() {
        let version = VERSION.fetch_add(1, Ordering::Relaxed);
        f.send_to(
            c.conn_id,
            "view-model",
            data(&file, version, "density", Value::Null),
        );
    }
    if let Some(old) = old.filter(|o| generation.is_none() || ask.heat.as_ref() != Some(o)) {
        let version = VERSION.fetch_add(1, Ordering::Relaxed);
        f.send_to(
            c.conn_id,
            "view-model",
            data(&file, version, &format!("heat:{old}"), Value::Null),
        );
    }
    f.core.views.minimaps.coverage_unused();
    match (generation, compiled) {
        (Some(_), Some((error, warning))) => start_density(f, c.conn_id, file, run, error, warning),
        (Some(g), None) => push(f, c.conn_id, &file, g).await,
        _ => {}
    }
    Ok(true)
}

/// Each density ask's run: a scan goes on while its watch still holds the same run.
static DENSITY_RUN: AtomicU64 = AtomicU64::new(1);

/// The largest compiled density expression, in bytes.
const DENSITY_REGEX_MAX: usize = 1 << 20;

fn compile(re: &str, path: &str) -> Result<regex::bytes::Regex, Error> {
    regex::bytes::RegexBuilder::new(re)
        .size_limit(DENSITY_REGEX_MAX)
        .build()
        .map_err(|e| Error {
            code: ErrorCode::InvalidParams,
            message: format!("not an expression the density scan reads: {e}"),
            path: Some(path.to_owned()),
        })
}

/// Whether CONN's watch of FILE still asks for density run RUN.
fn density_alive(f: &Front, conn: u64, file: &str, run: u64) -> bool {
    lock(&f.core.views.minimaps.files)
        .get(&(conn, file.to_owned()))
        .is_some_and(|(_, a)| a.density.as_ref().is_some_and(|d| d.2 == run))
}

/// FILE's density table (BUCKETS of TOTAL) to CONN as the `density` layer.
fn send_density(f: &Front, conn: u64, file: &str, buckets: &[density::Bucket], total: u32) {
    let version = VERSION.fetch_add(1, Ordering::Relaxed);
    let layer = Layer::Density {
        buckets: buckets.to_vec(),
        total,
    };
    f.send_to(
        conn,
        "view-model",
        data(file, version, "density", layer.items()),
    );
}

/// Scan FILE for CONN's density strip while run RUN is its watch's (design §7.6): the parts as they come, the whole
/// table at the end; again from the start when the file changes under the scan, or after it ([`density::POLL`]).
fn start_density(
    f: &Front,
    conn: u64,
    file: String,
    run: u64,
    error: regex::bytes::Regex,
    warning: regex::bytes::Regex,
) {
    let Some(front) = f.core.views.front_weak() else {
        return;
    };
    crate::clock::spawn("minimap:density", async move {
        let path = PathBuf::from(&file);
        loop {
            let Some(stamp) = density::stamp(&path) else {
                return;
            };
            let (front2, file2, path2) = (front.clone(), file.clone(), path.clone());
            let (error2, warning2) = (error.clone(), warning.clone());
            let scanned = crate::clock::blocking(move || {
                density::scan(
                    &path2,
                    stamp,
                    &error2,
                    &warning2,
                    crate::clock::real_now,
                    |part| {
                        let Some(f) = front2.upgrade() else {
                            return false;
                        };
                        if !density_alive(&f, conn, &file2, run) {
                            return false;
                        }
                        if let Some((buckets, total)) = part {
                            send_density(&f, conn, &file2, buckets, total);
                        }
                        true
                    },
                )
            })
            .await;
            match scanned {
                Ok(Ok(density::Scanned::Done(buckets, done))) => {
                    {
                        let Some(f) = front.upgrade() else {
                            return;
                        };
                        if !density_alive(&f, conn, &file, run) {
                            return;
                        }
                        send_density(&f, conn, &file, &buckets, buckets.len() as u32);
                    }
                    // the file is looked at now and then: a change scans it again
                    loop {
                        crate::clock::sleep(density::POLL).await;
                        let Some(f) = front.upgrade() else {
                            return;
                        };
                        if !density_alive(&f, conn, &file, run) {
                            return;
                        }
                        if density::stamp(&path) != Some(done) {
                            break;
                        }
                    }
                }
                Ok(Ok(density::Scanned::Changed)) => {}
                _ => return,
            }
        }
    });
}

/// `minimap/bucket`: the first lines of bucket P.bucket of P.file, for the density strip's peek.
pub async fn bucket(
    _f: &Front,
    _c: &Caller,
    p: MinimapBucketParams,
) -> Result<MinimapBucket, Error> {
    let path = PathBuf::from(crate::work::presence::true_name(&p.file));
    let (bucket, lines) = (p.bucket, p.lines);
    match crate::clock::blocking(move || density::peek(&path, bucket, lines)).await {
        Ok(Ok((text, start, buckets))) => Ok(MinimapBucket {
            text,
            start,
            buckets,
        }),
        Ok(Err(e)) => Err(Error {
            code: ErrorCode::InvalidParams,
            message: format!("the file cannot be read: {e}"),
            path: Some("file".into()),
        }),
        Err(_) => Err(Error {
            code: ErrorCode::Internal,
            message: "the bucket's read failed".into(),
            path: None,
        }),
    }
}

/// Every watch DUE picks (by file and ask) gets its layers again once things settle ([`super::outline::QUIET`]).
fn again(f: &Front, due: impl Fn(&str, &Ask) -> bool) {
    let due: Vec<(u64, String, u64)> = {
        let mut files = lock(&f.core.views.minimaps.files);
        files
            .iter_mut()
            .filter(|((_, name), (_, a))| due(name, a))
            .map(|((conn, name), (g, _))| {
                *g += 1;
                (*conn, name.clone(), *g)
            })
            .collect()
    };
    let Some(front) = f.core.views.front_weak() else {
        return;
    };
    for (conn, file, generation) in due {
        let front = front.clone();
        crate::clock::spawn("minimap:quiet", async move {
            crate::clock::sleep(super::outline::QUIET).await;
            if let Some(f) = front.upgrade() {
                push(&f, conn, &file, generation).await;
            }
        });
    }
}

/// The edit history took an edit to FILE (its true name): every connection watching it gets its labels (and heat)
/// again once the edits pause.
pub fn touched(f: &Front, file: &str) {
    again(f, |name, _| name == file);
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
                Layer::Heat(
                    "blame".into(),
                    vec![
                        Span {
                            first: 1,
                            last: 10,
                            value: 1000,
                            fact: "not committed".into(),
                        },
                        Span {
                            first: 11,
                            last: 30,
                            value: 250,
                            fact: "2 days ago · 9f3c21e first · ann".into(),
                        },
                    ],
                ),
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
            crate::fsio::write(path, serde_json::to_string_pretty(&now).unwrap() + "\n").unwrap();
        }
        let held: Option<Value> = crate::fsio::read_to_string(path)
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
