//! Vector packs in the hub (Hrafn redesign Tasks 20 and 21, `search::packs`): an index's vectors exported on one machine
//! and imported on another. Each "machine" is a temporary state directory with its own caches; the stores, caches and
//! packs are real, and no model runs (a vector is made from its key).
//!
//! test-pattern: pure (D): the stores and caches answer in order, nothing here has a clock.
#![cfg(feature = "test-hooks")]

use hrafn::{Class, CodeStore, ExportScope, KeyKind, Lang, Listed, View, missing, refresh};
use hrafn_embed::fingerprint::{Fingerprint, Identity};
use ratatoskr::search::caches::Caches;
use ratatoskr::search::packs::{self, HeldStore, PackError};
use ratatoskr::search::{TEST_TINY, builtin_identity};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

const NOW: i64 = 5_000;

const X: (&str, &str) = ("x.el", "(defun x-one () 1)\n(defun x-two () 2)\n");
const Y: (&str, &str) = ("y.el", "(defun y-only () 3)\n");

fn tiny() -> Identity {
    builtin_identity(&TEST_TINY)
}

fn el(path: &str) -> Listed {
    Listed {
        path: path.into(),
        blob: format!("blob-{path}"),
        class: Class::Code,
        lang: Lang::Elisp,
        generated: false,
        embed: true,
        size: 1,
    }
}

/// One machine: a state directory and its caches.
struct Machine {
    dir: tempfile::TempDir,
    caches: Arc<Caches>,
}

impl Machine {
    fn new() -> Machine {
        let dir = tempfile::tempdir().unwrap();
        let caches = Caches::shared(dir.path());
        Machine { dir, caches }
    }

    /// The repo store `<state>/code/ID.db`, tier 1 over FILES only.
    async fn repo(&self, id: &str, files: &[(&str, &str)]) -> CodeStore {
        std::fs::create_dir_all(self.dir.path().join("code")).unwrap();
        let s = CodeStore::open(&self.dir.path().join(format!("code/{id}.db"))).unwrap();
        let texts: HashMap<String, String> = files
            .iter()
            .map(|(p, t)| (p.to_string(), t.to_string()))
            .collect();
        let listed: Vec<Listed> = files.iter().map(|(p, _)| el(p)).collect();
        refresh(
            &s,
            &listed,
            &|p: &str| {
                texts
                    .get(p)
                    .map(|t| t.clone().into_bytes())
                    .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::NotFound))
            },
            &[],
        )
        .await
        .unwrap();
        s
    }

    /// A vector for every key STORE lacks in the cache of TINY (made from the key), as tier 2 would write them.
    async fn embed(&self, store: &CodeStore) {
        let c = self.caches.get(&tiny()).await.unwrap();
        hrafn::hold(store, &c, self.dir.path(), 1).await.unwrap();
        let dims = TEST_TINY.dims;
        let todo = missing(store, &c, 10_000).await.unwrap();
        for kind in [KeyKind::Chunk, KeyKind::Path] {
            let rows: Vec<([u8; 32], Vec<f32>)> = todo
                .iter()
                .filter(|(k, _, _)| *k == kind)
                .map(|(_, k, _)| {
                    let v: Vec<f32> = (0..dims).map(|i| f32::from(k[i]) + 1.0).collect();
                    let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
                    (*k, v.into_iter().map(|x| x / n).collect())
                })
                .collect();
            if !rows.is_empty() {
                c.put(kind, dims as u32, &rows).await.unwrap();
            }
        }
    }

    /// A pack of everything STORE holds in the cache of TINY.
    async fn pack(&self, store: &CodeStore, name: &str) -> (PathBuf, packs::Exported) {
        let out = self.dir.path().join(name);
        let e = packs::export(
            &self.caches,
            store,
            ExportScope::AllTrees,
            &out,
            1,
            (None, None),
        )
        .await
        .unwrap();
        (out, e)
    }

    /// How many of STORE's keys the cache of TINY has (chunks and paths).
    async fn have(&self, store: &CodeStore) -> usize {
        let c = self.caches.get(&tiny()).await.unwrap();
        let keys = hrafn::export_keys(store, ExportScope::AllTrees)
            .await
            .unwrap();
        let mut n = 0;
        for kind in [KeyKind::Chunk, KeyKind::Path] {
            let ks: Vec<[u8; 32]> = keys
                .iter()
                .filter(|(k, _)| *k == kind)
                .map(|(_, k)| *k)
                .collect();
            n += c
                .has(kind, &ks)
                .await
                .unwrap()
                .iter()
                .filter(|b| **b)
                .count();
        }
        n
    }
}

/// The keys of STORE, all trees.
async fn key_count(store: &CodeStore) -> usize {
    hrafn::export_keys(store, ExportScope::AllTrees)
        .await
        .unwrap()
        .len()
}

async fn import(
    m: &Machine,
    file: &Path,
    open: &[HeldStore<'_>],
    known: &[Fingerprint],
    keep_all: bool,
) -> Result<packs::Imported, PackError> {
    packs::import(&m.caches, file, open, known, keep_all, NOW).await
}

/// Pattern D. An export says which fingerprint it is of and how many keys it holds, hands back the file's sha, writes
/// where it was told, and carries the source-equivalence warning the CLI prints first.
#[tokio::test]
async fn export_names_the_warning_and_the_fingerprint() {
    let a = Machine::new();
    let s = a.repo("a", &[X, Y]).await;
    a.embed(&s).await;
    let (out, e) = a.pack(&s, "out.pack").await;
    assert_eq!(e.path, out);
    assert_eq!(e.fingerprint, tiny().fp.hex());
    assert_eq!(e.keys as usize, key_count(&s).await);
    assert!(e.keys > 3);
    let sha: String = {
        use sha2::{Digest, Sha256};
        Sha256::digest(std::fs::read(&out).unwrap())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    };
    assert_eq!(e.sha256, sha);
    assert!(
        packs::WARNING.contains("source-equivalent") && packs::WARNING.contains("recreate"),
        "{}",
        packs::WARNING
    );
    // a tree with no vectors anywhere has nothing to export
    let b = Machine::new();
    let t = b.repo("t", &[X]).await;
    let none = packs::export(
        &b.caches,
        &t,
        ExportScope::View(View::Base),
        &b.dir.path().join("none.pack"),
        1,
        (None, None),
    )
    .await;
    assert!(matches!(none, Err(PackError::Refused(_))), "{none:?}");
}

/// Pattern D (Review Focus 5). A pack imported on a machine with none of the code keeps nothing, and says so.
#[tokio::test]
async fn import_without_the_code_keeps_nothing() {
    let a = Machine::new();
    let s = a.repo("a", &[X, Y]).await;
    a.embed(&s).await;
    let (pack, e) = a.pack(&s, "p.pack").await;
    let b = Machine::new();
    let got = import(&b, &pack, &[], &[tiny().fp], false).await.unwrap();
    assert_eq!(got.keys_in_pack, e.keys);
    assert_eq!(got.kept, 0);
    assert_eq!(got.skipped_unreferenced, e.keys);
    assert_eq!(got.already_had, 0);
    assert_eq!(got.fingerprint, tiny().fp.hex());
    assert_eq!(
        got.summary(),
        format!("0 of {} keys kept: no repo here references them", e.keys)
    );
    // nothing of it is in the cache
    let c = b.caches.get(&tiny()).await.unwrap();
    assert!(c.get(KeyKind::Chunk, &[[0; 32]]).await.unwrap().is_empty());
    let s2 = b.repo("b", &[X]).await;
    assert_eq!(b.have(&s2).await, 0);
}

/// Pattern D. Of a pack of two files only the keys of the one this machine's repo has are kept, an open repo's among
/// them (its holder says what it holds); a second import adds nothing and says it had them.
#[tokio::test]
async fn import_keeps_only_referenced_keys() {
    let a = Machine::new();
    let s = a.repo("a", &[X, Y]).await;
    a.embed(&s).await;
    let (pack, e) = a.pack(&s, "p.pack").await;
    let b = Machine::new();
    let only_x = b.repo("b", &[X]).await;
    let wanted = key_count(&only_x).await as u64;
    assert!(wanted > 1 && wanted < e.keys);
    let open = [HeldStore {
        store: &only_x,
        root: b.dir.path(),
    }];
    let got = import(&b, &pack, &open, &[tiny().fp], false).await.unwrap();
    assert_eq!(got.kept, wanted);
    assert_eq!(got.skipped_unreferenced, e.keys - wanted);
    assert_eq!(got.already_had, 0);
    assert_eq!(b.have(&only_x).await as u64, wanted);
    // a second import of the pack adds nothing and says it had them
    let again = import(&b, &pack, &open, &[tiny().fp], false).await.unwrap();
    assert_eq!((again.kept, again.already_had), (0, wanted));
    // y's keys are not there: a repo holding y finds all of its keys missing
    let y_store = b.repo("y", &[Y]).await;
    let c = b.caches.get(&tiny()).await.unwrap();
    let still = missing(&y_store, &c, 10_000).await.unwrap();
    assert!(
        still.iter().any(|(k, _, _)| *k == KeyKind::Chunk),
        "y's chunk is not there"
    );
}

/// Pattern D. With `keep_all` the whole pack goes into the cache, referenced or not.
#[tokio::test]
async fn keep_all_keeps_everything() {
    let a = Machine::new();
    let s = a.repo("a", &[X, Y]).await;
    a.embed(&s).await;
    let (pack, e) = a.pack(&s, "p.pack").await;
    let b = Machine::new();
    let got = import(&b, &pack, &[], &[tiny().fp], true).await.unwrap();
    assert_eq!((got.kept, got.skipped_unreferenced), (e.keys, 0));
    // the repo that opens later finds every vector
    let later = b.repo("later", &[X, Y]).await;
    assert_eq!(b.have(&later).await as u64, e.keys);
}

/// Pattern D. A pack of a fingerprint no source or engine of this machine can produce for queries is refused (its
/// vectors would never be searched), and nothing is created; `keep_all` takes it anyway.
#[tokio::test]
async fn unknown_fingerprint_is_refused() {
    let a = Machine::new();
    let s = a.repo("a", &[X]).await;
    a.embed(&s).await;
    let (pack, _) = a.pack(&s, "p.pack").await;
    let b = Machine::new();
    let _repo = b.repo("b", &[X]).await;
    let other = {
        let mut r = tiny().record;
        r.model_id = "someone-elses-model".into();
        Identity::new(r, "other").fp
    };
    let refused = import(&b, &pack, &[], &[other], false).await.unwrap_err();
    assert!(
        matches!(&refused, PackError::Refused(m) if m.contains(&tiny().fp.hex16())),
        "{refused:?}"
    );
    assert!(
        !b.dir.path().join("vectors").exists(),
        "no cache file for a refused fingerprint"
    );
    let taken = import(&b, &pack, &[], &[other], true).await.unwrap();
    assert!(taken.keys_in_pack > 0);
    assert_eq!(taken.kept, taken.keys_in_pack);
    // and a pack that is not one is refused as such
    let junk = b.dir.path().join("junk");
    std::fs::write(&junk, b"nothing").unwrap();
    assert!(matches!(
        import(&b, &junk, &[], &[tiny().fp], false).await,
        Err(PackError::Store(_)) | Err(PackError::Refused(_))
    ));
}

/// Pattern D (MP-21). A repo this hub has not opened, a store file under `<state>/code/`, still proves possession: its
/// keys are kept.
#[tokio::test]
async fn closed_repo_on_disk_counts_as_possession() {
    let a = Machine::new();
    let s = a.repo("a", &[X, Y]).await;
    a.embed(&s).await;
    let (pack, e) = a.pack(&s, "p.pack").await;
    let b = Machine::new();
    let closed = b.repo("closed", &[Y]).await;
    let wanted = key_count(&closed).await as u64;
    tokio::task::spawn_blocking(move || closed.shutdown())
        .await
        .unwrap();
    let got = import(&b, &pack, &[], &[tiny().fp], false).await.unwrap();
    assert_eq!(got.kept, wanted, "{got:?}");
    assert_eq!(got.skipped_unreferenced, e.keys - wanted);
}

/// Pattern D. After an import the repo's tier 2 is offered nothing: the keys it would embed are all there, the eval's
/// "embedded 0".
#[tokio::test]
async fn import_then_query_embeds_nothing() {
    let a = Machine::new();
    let s = a.repo("a", &[X, Y]).await;
    a.embed(&s).await;
    let (pack, _) = a.pack(&s, "p.pack").await;
    let b = Machine::new();
    let fresh = b.repo("b", &[X, Y]).await;
    let c = b.caches.get(&tiny()).await.unwrap();
    assert!(!missing(&fresh, &c, 10_000).await.unwrap().is_empty());
    let open = [HeldStore {
        store: &fresh,
        root: b.dir.path(),
    }];
    import(&b, &pack, &open, &[tiny().fp], false).await.unwrap();
    assert!(missing(&fresh, &c, 10_000).await.unwrap().is_empty());
}
