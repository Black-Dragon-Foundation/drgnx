//! The hub's vector caches (Hrafn redesign Tasks 12 and 13, `search::caches`): one file per fingerprint under
//! `<state>/vectors/`, one writer per file in the process, every repo store of the state a holder from the first open,
//! and the hourly sweep that collects what nobody holds.
//!
//! test-pattern: pure (D): the state is a temporary folder, the sweep's clock is passed in, nothing waits.
#![cfg(feature = "test-hooks")]

use hrafn::{CodeStore, KeyKind};
use ratatoskr::search::caches::{CACHE_SWEEP, Caches};
use ratatoskr::search::{TEST_TINY, builtin_identity};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

/// The holders' ids in the cache file F.
fn holders(f: &Path) -> Vec<String> {
    let c = rusqlite::Connection::open_with_flags(f, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .unwrap();
    let mut st = c.prepare("select id from holder order by id").unwrap();
    st.query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<Vec<String>, _>>()
        .unwrap()
}

/// Pattern D. A state's caches are one object in the process, a fingerprint's cache is one file under
/// `<state>/vectors/` named by its hex16, opened once (its one writer), and another fingerprint is another file.
#[test]
fn one_file_and_one_writer_per_fingerprint() {
    saman::block_on_current(async move {
        let state = tempfile::tempdir().unwrap();
        let caches = Caches::shared(state.path());
        assert!(Arc::ptr_eq(&caches, &Caches::shared(state.path())));
        assert_eq!(caches.dir(), state.path().join("vectors"));
        let id = builtin_identity(hrafn_embed::default_model());
        let c = caches.get(&id).await.unwrap();
        assert_eq!(
            c.path(),
            state
                .path()
                .join("vectors")
                .join(format!("{}.db", id.fp.hex16()))
        );
        assert_eq!(c.fp_hex(), id.fp.hex());
        assert!(Arc::ptr_eq(&c, &caches.get(&id).await.unwrap()));
        let tiny = builtin_identity(&TEST_TINY);
        let t = caches.get(&tiny).await.unwrap();
        assert_ne!(t.path(), c.path());
        let mut opened: Vec<String> = caches
            .opened()
            .await
            .iter()
            .map(|c| c.fp_hex().to_string())
            .collect();
        opened.sort();
        let mut want = vec![id.fp.hex(), tiny.fp.hex()];
        want.sort();
        assert_eq!(opened, want);
        // another state, other caches
        let other = tempfile::tempdir().unwrap();
        assert!(!Arc::ptr_eq(&caches, &Caches::shared(other.path())));
    })
}

/// Pattern D (MP-21). A cache's first open makes every repo store of the state a holder, open or not, so a key only a
/// closed project uses is not collected before that project's next refresh says what it holds.
#[test]
fn first_open_registers_every_repo_store() {
    saman::block_on_current(async move {
        let state = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(state.path().join("code")).unwrap();
        for name in ["alpha", "beta"] {
            drop(CodeStore::open(&state.path().join("code").join(format!("{name}.db"))).unwrap());
        }
        let caches = Caches::shared(state.path());
        let c = caches
            .get(&builtin_identity(hrafn_embed::default_model()))
            .await
            .unwrap();
        assert_eq!(holders(c.path()), ["alpha", "beta"]);
    })
}

/// Pattern D (MP-7). The sweep runs at most once per [`CACHE_SWEEP`]: the first is due at once, the next only an hour
/// later. With a cap of 0 bytes it collects every vector no holder holds, in every open cache.
#[test]
fn the_sweep_is_hourly_and_collects_unheld_vectors() {
    saman::block_on_current(async move {
        tokio::time::pause();
        let state = tempfile::tempdir().unwrap();
        let caches = Caches::shared(state.path());
        caches.set_cap(Some(0));
        let c = caches.get(&builtin_identity(&TEST_TINY)).await.unwrap();
        let dims = TEST_TINY.dims as u32;
        let rows: Vec<([u8; 32], Vec<f32>)> = (0..3u8)
            .map(|i| ([i; 32], vec![1.0; TEST_TINY.dims]))
            .collect();
        c.put(KeyKind::Chunk, dims, &rows).await.unwrap();
        let t0 = tokio::time::Instant::from_std(stund::real::instant());
        assert_eq!(caches.sweep_if_due(t0, 1_000).await.unwrap(), Some(3));
        assert!(c.get(KeyKind::Chunk, &[[0; 32]]).await.unwrap().is_empty());
        c.put(KeyKind::Chunk, dims, &rows).await.unwrap();
        let early = t0 + CACHE_SWEEP - Duration::from_secs(1);
        assert_eq!(caches.sweep_if_due(early, 2_000).await.unwrap(), None);
        assert_eq!(c.get(KeyKind::Chunk, &[[0; 32]]).await.unwrap().len(), 1);
        assert_eq!(
            caches.sweep_if_due(t0 + CACHE_SWEEP, 3_000).await.unwrap(),
            Some(3)
        );
    })
}
