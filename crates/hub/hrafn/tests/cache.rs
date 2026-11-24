//! The machine-wide vector cache (Hrafn redesign Tasks 11 and 13): one file per fingerprint, its one writer and its
//! readers, then its holders and its collection.
//!
//! test-pattern: pure (D): the cache's thread answers in order, and the time is a number the test gives (no clock).

use hrafn::cache::{MIN_CAP, QuantRow, VectorCache, default_cap};
use hrafn::{KeyKind, StoreError};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::Duration;

const REC: &str = r#"{"model_id":"test-model","dims":4}"#;
const DIMS: u32 = 4;
/// A holder's checkout counts as gone after this, with no folder at its root.
const IDLE: Duration = Duration::from_secs(14 * 24 * 3600);
/// The bytes of one stored row of DIMS: its key, one byte of sign bits and the int8 values.
const ROW: u64 = 32 + 1 + DIMS as u64;

fn fp(c: char) -> String {
    std::iter::repeat_n(c, 64).collect()
}

fn key(n: u8) -> [u8; 32] {
    let mut k = [0u8; 32];
    k[0] = n;
    k
}

fn v(x: [f32; 4]) -> Vec<f32> {
    x.to_vec()
}

fn writer(dir: &Path) -> VectorCache {
    VectorCache::open_writer(dir, &fp('a'), REC).unwrap()
}

/// What `put` stores for V.
fn stored(k: [u8; 32], x: [f32; 4]) -> QuantRow {
    let (bits, ints, scale) = urdr::graph::search::vec::quantize(&x);
    let mut vec = bits;
    vec.extend(ints.iter().map(|&i| i as u8));
    QuantRow {
        key: k,
        bits: 8,
        vec,
        scale,
    }
}

/// Pattern D. A vector goes in quantized and comes back as stored, each kind apart; a vector pack's rows go in as they
/// are; a reader sees the writer's rows and cannot write; the file is `<dir>/<hex16>.db`, mode 0600.
#[test]
fn put_get_round_trip() {
    saman::block_on_current(async {
        let dir = tempfile::tempdir().unwrap();
        let c = writer(dir.path());
        assert_eq!(c.path(), dir.path().join("aaaaaaaaaaaaaaaa.db"));
        assert_eq!(c.fp_hex(), fp('a'));
        c.put(
            KeyKind::Chunk,
            DIMS,
            &[
                (key(1), v([1.0, 0.0, 0.0, 0.0])),
                (key(2), v([0.0, -0.5, 0.5, 0.0])),
            ],
        )
        .await
        .unwrap();
        c.put(KeyKind::Path, DIMS, &[(key(1), v([0.0, 0.0, 1.0, 0.0]))])
            .await
            .unwrap();
        assert_eq!(
            c.has(KeyKind::Chunk, &[key(1), key(3), key(2)])
                .await
                .unwrap(),
            [true, false, true]
        );
        assert_eq!(c.has(KeyKind::Path, &[key(2)]).await.unwrap(), [false]);
        let got = c
            .get(KeyKind::Chunk, &[key(2), key(3), key(1)])
            .await
            .unwrap();
        assert_eq!(
            got,
            [
                stored(key(2), [0.0, -0.5, 0.5, 0.0]),
                stored(key(1), [1.0, 0.0, 0.0, 0.0])
            ]
        );
        assert_eq!(
            c.get(KeyKind::Path, &[key(1)]).await.unwrap(),
            [stored(key(1), [0.0, 0.0, 1.0, 0.0])]
        );
        let mode = std::fs::metadata(c.path()).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        // rows already quantized go in as they are
        let other = tempfile::tempdir().unwrap();
        let o = VectorCache::open_writer(other.path(), &fp('b'), REC).unwrap();
        o.put_quantized(KeyKind::Chunk, &got).await.unwrap();
        assert_eq!(o.get(KeyKind::Chunk, &[key(2), key(1)]).await.unwrap(), got);

        // a reader sees what the writer wrote, and writes nothing
        let r = VectorCache::open(dir.path(), &fp('a'), REC).unwrap();
        assert_eq!(r.get(KeyKind::Chunk, &[key(2), key(1)]).await.unwrap(), got);
        assert!(
            r.put(KeyKind::Chunk, DIMS, &[(key(9), v([1.0, 0.0, 0.0, 0.0]))])
                .await
                .is_err()
        );
        assert_eq!(c.has(KeyKind::Chunk, &[key(9)]).await.unwrap(), [false]);
    })
}

/// Pattern D. A row of another length than the dims given is an error naming both, and nothing of its batch is written.
#[test]
fn dims_checked() {
    saman::block_on_current(async {
        let dir = tempfile::tempdir().unwrap();
        let c = writer(dir.path());
        let err = c
            .put(
                KeyKind::Chunk,
                DIMS,
                &[
                    (key(1), v([1.0, 0.0, 0.0, 0.0])),
                    (key(2), vec![1.0, 0.0, 0.0, 0.0, 0.5]),
                ],
            )
            .await
            .unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("5 dims") && msg.contains('4'), "{msg}");
        assert_eq!(
            c.has(KeyKind::Chunk, &[key(1), key(2)]).await.unwrap(),
            [false, false],
            "nothing of the batch"
        );
    })
}

/// Pattern D. A file whose `meta.fingerprint` is another fingerprint's is refused, by a writer and by a reader, and
/// nothing is written to it.
#[test]
fn wrong_fingerprint_file_is_refused() {
    saman::block_on_current(async {
        let dir = tempfile::tempdir().unwrap();
        let c = writer(dir.path());
        c.put(KeyKind::Chunk, DIMS, &[(key(1), v([1.0, 0.0, 0.0, 0.0]))])
            .await
            .unwrap();
        let a = c.path().to_path_buf();
        c.shutdown();
        // b's file name, a's file
        let b = VectorCache::file_of(dir.path(), &fp('b'));
        std::fs::copy(&a, &b).unwrap();
        let before = std::fs::read(&b).unwrap();
        for refused in [
            VectorCache::open_writer(dir.path(), &fp('b'), REC),
            VectorCache::open(dir.path(), &fp('b'), REC),
        ] {
            match refused {
                Err(StoreError::Mismatch(why)) => assert!(why.contains(&fp('a')), "{why}"),
                Err(e) => panic!("refused for another reason: {e}"),
                Ok(_) => panic!("a file of another fingerprint was opened"),
            }
        }
        assert_eq!(std::fs::read(&b).unwrap(), before, "nothing written");
        // a's own fingerprint still opens it
        let again = writer(dir.path());
        assert_eq!(again.has(KeyKind::Chunk, &[key(1)]).await.unwrap(), [true]);
    })
}

/// Pattern D. Two fingerprints with the same first 16 hex characters name the same file: the second is refused by
/// the file's `meta`, and the first's vectors stay.
#[test]
fn hex16_collision_is_refused_by_meta() {
    saman::block_on_current(async {
        let dir = tempfile::tempdir().unwrap();
        let one = format!("0123456789abcdef{}", "1".repeat(48));
        let two = format!("0123456789abcdef{}", "2".repeat(48));
        assert_eq!(
            VectorCache::file_of(dir.path(), &one),
            VectorCache::file_of(dir.path(), &two)
        );
        let c = VectorCache::open_writer(dir.path(), &one, REC).unwrap();
        c.put(KeyKind::Chunk, DIMS, &[(key(1), v([1.0, 0.0, 0.0, 0.0]))])
            .await
            .unwrap();
        c.shutdown();
        assert!(matches!(
            VectorCache::open_writer(dir.path(), &two, REC),
            Err(StoreError::Mismatch(_))
        ));
        assert!(matches!(
            VectorCache::open(dir.path(), &two, REC),
            Err(StoreError::Mismatch(_))
        ));
        let c = VectorCache::open_writer(dir.path(), &one, REC).unwrap();
        assert_eq!(c.has(KeyKind::Chunk, &[key(1)]).await.unwrap(), [true]);
    })
}

/// Pattern D (Review Focus 4). While one writer holds the cache a second is refused, saying who holds it; a reader is
/// never blocked and sees the writer's commits; once the writer is gone, another may write.
#[test]
fn second_writer_is_refused_readers_continue() {
    saman::block_on_current(async {
        let dir = tempfile::tempdir().unwrap();
        let w = writer(dir.path());
        w.put(KeyKind::Chunk, DIMS, &[(key(1), v([1.0, 0.0, 0.0, 0.0]))])
            .await
            .unwrap();
        match VectorCache::open_writer(dir.path(), &fp('a'), REC) {
            Err(StoreError::Busy(why)) => {
                assert!(why.contains("the cache is written by hub"), "{why}");
                assert!(why.contains(&std::process::id().to_string()), "{why}");
            }
            Err(e) => panic!("refused for another reason: {e}"),
            Ok(_) => panic!("a second writer was let in"),
        }
        let r = VectorCache::open(dir.path(), &fp('a'), REC).unwrap();
        assert_eq!(r.has(KeyKind::Chunk, &[key(1)]).await.unwrap(), [true]);
        w.put(KeyKind::Chunk, DIMS, &[(key(2), v([0.0, 1.0, 0.0, 0.0]))])
            .await
            .unwrap();
        assert_eq!(
            r.has(KeyKind::Chunk, &[key(1), key(2)]).await.unwrap(),
            [true, true],
            "the reader sees the next commit"
        );
        w.shutdown();
        let next = writer(dir.path());
        next.put(KeyKind::Chunk, DIMS, &[(key(3), v([0.0, 0.0, 1.0, 0.0]))])
            .await
            .unwrap();
        assert_eq!(r.has(KeyKind::Chunk, &[key(3)]).await.unwrap(), [true]);
    })
}

/// Four chunk vectors, keys 1 to 4, written in that order (so 4 is the most recently used).
async fn four(c: &VectorCache) {
    for n in 1..=4u8 {
        c.put(
            KeyKind::Chunk,
            DIMS,
            &[(key(n), v([f32::from(n), 1.0, 0.0, 0.0]))],
        )
        .await
        .unwrap();
    }
}

async fn kept(c: &VectorCache) -> Vec<bool> {
    c.has(KeyKind::Chunk, &[key(1), key(2), key(3), key(4)])
        .await
        .unwrap()
}

/// Pattern D (Task 13). Every key a live holder holds survives a collection with no room at all for the rest.
#[test]
fn held_keys_survive_collect() {
    saman::block_on_current(async {
        let (dir, root) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let c = writer(dir.path());
        four(&c).await;
        c.hold(
            "s1",
            root.path(),
            KeyKind::Chunk,
            &[key(1), key(2)],
            &[],
            1000,
        )
        .await
        .unwrap();
        c.hold("s2", root.path(), KeyKind::Chunk, &[key(2)], &[], 1000)
            .await
            .unwrap();
        assert_eq!(
            c.referenced(KeyKind::Chunk, &[key(1), key(2), key(3), key(4)])
                .await
                .unwrap(),
            [true, true, false, false]
        );
        assert_eq!(c.live_bytes().await.unwrap(), 2 * ROW);
        assert_eq!(c.collect(0).await.unwrap(), 2);
        assert_eq!(kept(&c).await, [true, true, false, false]);
        // a holder lets one go: the other still holds key 2; key 1 is no one's
        c.hold(
            "s1",
            root.path(),
            KeyKind::Chunk,
            &[],
            &[key(1), key(2)],
            1001,
        )
        .await
        .unwrap();
        assert_eq!(c.collect(0).await.unwrap(), 1);
        assert_eq!(kept(&c).await, [false, true, false, false]);
    })
}

/// Pattern D (Task 13, MP-7). Of the keys nobody holds the most recently used stay, up to the cap in bytes; a key a
/// holder just let go counts as just used. The default cap is twice the held bytes, and at least 1 GiB.
#[test]
fn unheld_keys_go_lru_beyond_the_cap() {
    saman::block_on_current(async {
        let (dir, root) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let c = writer(dir.path());
        four(&c).await;
        c.hold("s1", root.path(), KeyKind::Chunk, &[key(1)], &[], 1000)
            .await
            .unwrap();
        c.hold("s1", root.path(), KeyKind::Chunk, &[], &[key(1)], 1001)
            .await
            .unwrap();
        assert_eq!(c.live_bytes().await.unwrap(), 0);
        assert_eq!(c.collect(2 * ROW).await.unwrap(), 2, "two rows fit");
        assert_eq!(
            kept(&c).await,
            [true, false, false, true],
            "the one let go last and the newest"
        );
        assert_eq!(
            c.collect(2 * ROW).await.unwrap(),
            0,
            "a second pass takes nothing"
        );
        assert_eq!(default_cap(0), MIN_CAP);
        assert_eq!(default_cap(MIN_CAP), 2 * MIN_CAP);
        assert_eq!(default_cap(10), MIN_CAP);
    })
}

/// Pattern D (Task 13, MP-21). A repo store that is closed (it has not refreshed for a long time) still protects its
/// keys while its checkout is there, and so does a store that never refreshed under this cache but is registered.
#[test]
fn closed_repo_still_protects_until_gone() {
    saman::block_on_current(async {
        let (dir, root) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let c = writer(dir.path());
        four(&c).await;
        c.hold("s1", root.path(), KeyKind::Chunk, &[key(1)], &[], 1000)
            .await
            .unwrap();
        c.register("s2").await.unwrap();
        c.register("s1").await.unwrap();
        let much_later = 1000 + 100 * IDLE.as_millis() as i64;
        assert_eq!(c.release_gone(much_later, IDLE).await.unwrap(), 0);
        c.collect(0).await.unwrap();
        assert_eq!(kept(&c).await, [true, false, false, false]);
        // the checkout goes: past the idle time its keys are no one's
        let gone = root.path().to_path_buf();
        drop(root);
        assert!(!gone.exists());
        assert_eq!(c.release_gone(much_later, IDLE).await.unwrap(), 1);
        assert_eq!(
            c.release_gone(much_later, IDLE).await.unwrap(),
            0,
            "s2, registered with no root yet, stays"
        );
        c.collect(0).await.unwrap();
        assert_eq!(kept(&c).await, [false, false, false, false]);
    })
}

/// Pattern D (Task 13, MP-21; the time is given). A checkout that is gone keeps protecting its keys until it has not
/// refreshed for the idle time, then stops; a refresh from a checkout there again makes it a live holder again.
#[test]
fn gone_checkout_stops_protecting_after_tree_idle() {
    saman::block_on_current(async {
        let (dir, root) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let c = writer(dir.path());
        four(&c).await;
        let at = 5_000;
        c.hold("s1", root.path(), KeyKind::Chunk, &[key(1)], &[], at)
            .await
            .unwrap();
        let path = root.path().to_path_buf();
        drop(root);
        let idle = IDLE.as_millis() as i64;
        assert_eq!(c.release_gone(at + idle - 1, IDLE).await.unwrap(), 0);
        assert_eq!(
            c.referenced(KeyKind::Chunk, &[key(1)]).await.unwrap(),
            [true]
        );
        assert_eq!(c.release_gone(at + idle, IDLE).await.unwrap(), 1);
        assert_eq!(
            c.referenced(KeyKind::Chunk, &[key(1)]).await.unwrap(),
            [false]
        );
        // the checkout comes back and refreshes: live again before anything was collected
        std::fs::create_dir_all(&path).unwrap();
        c.hold("s1", &path, KeyKind::Chunk, &[], &[], at + idle + 1)
            .await
            .unwrap();
        assert_eq!(
            c.referenced(KeyKind::Chunk, &[key(1)]).await.unwrap(),
            [true]
        );
        std::fs::remove_dir_all(&path).unwrap();
        assert_eq!(c.release_gone(at + 3 * idle, IDLE).await.unwrap(), 1);
        c.collect(0).await.unwrap();
        assert_eq!(kept(&c).await, [false, false, false, false]);
    })
}
