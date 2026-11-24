//! The disk rules (editing-model design §4.8): what drgnx keeps on a machine's disk, when each kind of item may go,
//! and whether a job's disk need fits.
//!
//! - Every machine evicts below [`DiskRules::evict_below_gb`] free and stops running jobs below
//!   [`DiskRules::stop_below_gb`]; admission keeps the stop floor free after the job's need ([`disk_fits`]).
//! - Build output may go after [`DiskRules::build_idle_s`] unused, a recording after
//!   [`DiskRules::recording_idle_s`], everything else after [`DiskRules::other_idle_s`] ([`rule_of`]).
//! - An active item is never evictable; a pinned one only to the owner's quota, never by age ([`state_of`]).
//!
//! The item kinds of every line are reserved here (runners, the streams, the records), so the enum is never edited
//! again. Pure: the runner's guard (`sleipnir::sync::guard`) and the hub's register (`ratatoskr::runners::disk`) read
//! these rules and carry out what they decide.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::model::JobTrust;

/// The compiler cache's budget, GB (the shared `sccache` of a machine).
pub const COMPILER_CACHE_GB: u64 = 15;

const HOUR_S: u64 = 3600;
const DAY_S: u64 = 24 * HOUR_S;

/// A machine's disk rules ([`DiskRules::standard`]: §4.8's values).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct DiskRules {
    /// Below this much free, GB, the guard evicts until it is free again.
    pub evict_below_gb: u64,
    /// Below this much free, GB, running jobs stop (`infra: disk`), the one that grew most first; admission keeps it
    /// free after a job's need.
    pub stop_below_gb: u64,
    /// Build output (build dirs, a job's outputs) may go after this long unused.
    pub build_idle_s: u64,
    /// Everything else may go after this long unused.
    pub other_idle_s: u64,
    /// Images: the newest this many per name are kept.
    pub keep_images_per_name: u32,
    /// The owner's cap on what drgnx keeps on this machine, GB; none: no quota.
    pub quota_gb: Option<u64>,
    /// A removal waits while IO `full avg10` is above this, percent ...
    pub pace_io_full_pct: f64,
    /// ... at most this long per removal.
    pub pace_max_s: u64,
    /// A recording may go after this long unused (the user, 2026-11-23: 30 days).
    pub recording_idle_s: u64,
}

impl DiskRules {
    /// §4.8's rules: evict below 80 GB, stop below 20 GB; build output after 24 h, a recording after 30 days, the
    /// rest after 3 days; the newest two images per name; no quota; removals paced at IO full 20 %, 60 s at most.
    pub fn standard() -> DiskRules {
        DiskRules {
            evict_below_gb: 80,
            stop_below_gb: 20,
            build_idle_s: DAY_S,
            other_idle_s: 3 * DAY_S,
            keep_images_per_name: 2,
            quota_gb: None,
            pace_io_full_pct: 20.0,
            pace_max_s: 60,
            recording_idle_s: 30 * DAY_S,
        }
    }
}

impl Default for DiskRules {
    fn default() -> DiskRules {
        DiskRules::standard()
    }
}

/// What an item on a machine's disk is. Every kind any line needs is reserved here (B1's streams, urdr's backups and
/// recordings among them), so the enum is never edited again.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ItemKind {
    // runners
    JobFolder,
    Output,
    Artifact,
    BuildDir,
    Slot,
    Cache,
    Image,
    // the streams (B1)
    StreamWorktree,
    StreamLog,
    // the records (urdr)
    RecordsBackup,
    StoreBackup,
    Recording,
    /// A folder where items live that nothing registered: reported and kept.
    Unknown,
}

impl ItemKind {
    /// Every kind, in the order a report lists them.
    pub const ALL: [ItemKind; 13] = [
        ItemKind::JobFolder,
        ItemKind::Output,
        ItemKind::Artifact,
        ItemKind::BuildDir,
        ItemKind::Slot,
        ItemKind::Cache,
        ItemKind::Image,
        ItemKind::StreamWorktree,
        ItemKind::StreamLog,
        ItemKind::RecordsBackup,
        ItemKind::StoreBackup,
        ItemKind::Recording,
        ItemKind::Unknown,
    ];

    /// The kind's word, as the wire and the CLI write it.
    pub fn name(self) -> &'static str {
        match self {
            ItemKind::JobFolder => "job-folder",
            ItemKind::Output => "output",
            ItemKind::Artifact => "artifact",
            ItemKind::BuildDir => "build-dir",
            ItemKind::Slot => "slot",
            ItemKind::Cache => "cache",
            ItemKind::Image => "image",
            ItemKind::StreamWorktree => "stream-worktree",
            ItemKind::StreamLog => "stream-log",
            ItemKind::RecordsBackup => "records-backup",
            ItemKind::StoreBackup => "store-backup",
            ItemKind::Recording => "recording",
            ItemKind::Unknown => "unknown",
        }
    }
}

/// Which age rule a kind follows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KindRule {
    /// [`DiskRules::build_idle_s`].
    BuildAge,
    /// [`DiskRules::other_idle_s`].
    OtherAge,
    /// [`DiskRules::recording_idle_s`].
    RecordingAge,
    /// Never by age.
    Pinned,
}

/// The age rule of kind K: build dirs and outputs the build age; a stream log never ages; a recording the recording
/// age; every other kind (backups included: their source keeps the newest two nightlies live) the other age.
pub const fn rule_of(k: ItemKind) -> KindRule {
    match k {
        ItemKind::BuildDir | ItemKind::Output => KindRule::BuildAge,
        ItemKind::StreamLog => KindRule::Pinned,
        ItemKind::Recording => KindRule::RecordingAge,
        ItemKind::JobFolder
        | ItemKind::Artifact
        | ItemKind::Slot
        | ItemKind::Cache
        | ItemKind::Image
        | ItemKind::StreamWorktree
        | ItemKind::RecordsBackup
        | ItemKind::StoreBackup
        | ItemKind::Unknown => KindRule::OtherAge,
    }
}

/// An item's state now.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ItemState {
    /// In use (a running job, a held lock): never evicted.
    Active,
    /// Used within its kind's age.
    Idle,
    /// Unused past its kind's age.
    Evictable,
    /// Kept by a pin (a queued job's, the user's, or its kind's): only the owner's quota takes it.
    Pinned,
}

/// One item drgnx put on a machine's disk. Times are epoch seconds; `id` is unique on its machine.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DiskItem {
    pub id: String,
    pub kind: ItemKind,
    /// Its owner: the project, or the source that made it.
    pub owner: String,
    pub machine: String,
    pub bytes: u64,
    pub last_used: u64,
    pub created: u64,
    /// An image's repository, a cache's name.
    #[serde(default)]
    pub name: Option<String>,
    /// A cache's budget, bytes.
    #[serde(default)]
    pub budget_bytes: Option<u64>,
    pub trust: JobTrust,
}

/// I's state at NOW: active beats pinned beats age; the age is [`rule_of`]'s.
pub fn state_of(
    i: &DiskItem,
    now: u64,
    active: &BTreeSet<String>,
    pinned: &BTreeSet<String>,
    r: &DiskRules,
) -> ItemState {
    if active.contains(&i.id) {
        return ItemState::Active;
    }
    let limit = match rule_of(i.kind) {
        KindRule::Pinned => return ItemState::Pinned,
        _ if pinned.contains(&i.id) => return ItemState::Pinned,
        KindRule::BuildAge => r.build_idle_s,
        KindRule::OtherAge => r.other_idle_s,
        KindRule::RecordingAge => r.recording_idle_s,
    };
    if now.saturating_sub(i.last_used) >= limit {
        ItemState::Evictable
    } else {
        ItemState::Idle
    }
}

/// Whether a job needing NEED_GIB fits a disk with FREE_GIB free: the running jobs' need they have not yet used
/// (RUNNING_UNUSED_GIB) counts as taken, and the warm build dir the job would reuse (WARM_REUSE_GIB) as already held:
/// `free − running_unused − (need − warm_reuse)⁺ ≥ stop_below_gb`.
pub fn disk_fits(
    need_gib: u64,
    free_gib: u64,
    running_unused_gib: u64,
    warm_reuse_gib: u64,
    r: &DiskRules,
) -> bool {
    let need = need_gib.saturating_sub(warm_reuse_gib);
    i128::from(free_gib) - i128::from(running_unused_gib) - i128::from(need)
        >= i128::from(r.stop_below_gb)
}

/// What the hub tells a runner to keep: the items in use (`active`: running and queued jobs' slots and artifacts) and
/// the pinned ones (the user's pins, and what queued jobs will need). `learned_at`: when the runner had them from the
/// hub (none: never; the guard then keeps its own live state only).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pins {
    #[serde(default)]
    pub active: BTreeSet<String>,
    #[serde(default)]
    pub pinned: BTreeSet<String>,
    #[serde(default)]
    pub learned_at: Option<u64>,
}

/// Why an item is evicted.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Why {
    /// Free space is below the evict floor.
    Floor,
    /// What drgnx keeps is over the owner's quota.
    Quota,
    /// A cache is over its budget.
    CacheBudget,
    /// The hub ordered it, for this reason.
    Ordered(String),
}

impl Why {
    /// The reason in words, as a record keeps it.
    pub fn text(&self) -> String {
        match self {
            Why::Floor => "floor".into(),
            Why::Quota => "quota".into(),
            Why::CacheBudget => "cache budget".into(),
            Why::Ordered(why) => format!("ordered: {why}"),
        }
    }
}

/// One planned eviction.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Evict {
    pub id: String,
    pub why: Why,
}

/// One eviction carried out, or refused (`refused`: why it was kept, e.g. `in use`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Evicted {
    pub id: String,
    pub kind: ItemKind,
    pub bytes: u64,
    pub why: Why,
    pub at: u64,
    #[serde(default)]
    pub refused: Option<String>,
}

/// One kind's use of a machine's disk: its items, their bytes, and the bytes that are evictable now.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClassUse {
    pub kind: ItemKind,
    pub items: u32,
    pub bytes: u64,
    pub evictable_bytes: u64,
}

/// ITEMS per kind at NOW under PINS, in [`ItemKind::ALL`]'s order; a kind with no item is left out.
pub fn classes(items: &[DiskItem], now: u64, pins: &Pins, r: &DiskRules) -> Vec<ClassUse> {
    ItemKind::ALL
        .iter()
        .filter_map(|&kind| {
            let of: Vec<&DiskItem> = items.iter().filter(|i| i.kind == kind).collect();
            if of.is_empty() {
                return None;
            }
            let evictable_bytes = of
                .iter()
                .filter(|i| {
                    kind != ItemKind::Unknown
                        && state_of(i, now, &pins.active, &pins.pinned, r) == ItemState::Evictable
                })
                .map(|i| i.bytes)
                .sum();
            Some(ClassUse {
                kind,
                items: of.len() as u32,
                bytes: of.iter().map(|i| i.bytes).sum(),
                evictable_bytes,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(crate) fn item(id: &str, kind: ItemKind, last_used: u64) -> DiskItem {
        DiskItem {
            id: id.into(),
            kind,
            owner: "alpha".into(),
            machine: "m".into(),
            bytes: 1 << 30,
            last_used,
            created: last_used,
            name: None,
            budget_bytes: None,
            trust: JobTrust::Private,
        }
    }

    const NOW: u64 = 10_000_000;

    fn state(i: &DiskItem, active: &[&str], pinned: &[&str]) -> ItemState {
        let set = |s: &[&str]| s.iter().map(|x| x.to_string()).collect::<BTreeSet<_>>();
        state_of(i, NOW, &set(active), &set(pinned), &DiskRules::standard())
    }

    /// [D] pure (§4.8): build output may go after 24 h unused, everything else after 3 days.
    #[test]
    fn build_output_is_evictable_after_24h_and_the_rest_after_3_days() {
        for k in [ItemKind::BuildDir, ItemKind::Output] {
            assert_eq!(
                state(&item("b", k, NOW - DAY_S + 1), &[], &[]),
                ItemState::Idle
            );
            assert_eq!(
                state(&item("b", k, NOW - DAY_S), &[], &[]),
                ItemState::Evictable
            );
        }
        for k in [
            ItemKind::JobFolder,
            ItemKind::Artifact,
            ItemKind::Slot,
            ItemKind::Cache,
            ItemKind::Image,
        ] {
            assert_eq!(
                state(&item("o", k, NOW - DAY_S), &[], &[]),
                ItemState::Idle,
                "{k:?}"
            );
            assert_eq!(
                state(&item("o", k, NOW - 3 * DAY_S + 1), &[], &[]),
                ItemState::Idle
            );
            assert_eq!(
                state(&item("o", k, NOW - 3 * DAY_S), &[], &[]),
                ItemState::Evictable
            );
        }
        assert_eq!(COMPILER_CACHE_GB, 15);
        let r = DiskRules::standard();
        assert_eq!(
            (r.evict_below_gb, r.stop_below_gb, r.keep_images_per_name),
            (80, 20, 2)
        );
        assert_eq!(r.quota_gb, None);
    }

    /// [D] pure (parallel lines §2.1): every reserved kind has its rule: a stream log never ages, a recording at 30
    /// days, a backup at 3 days.
    #[test]
    fn each_reserved_kind_has_its_rule() {
        assert_eq!(rule_of(ItemKind::StreamLog), KindRule::Pinned);
        assert_eq!(rule_of(ItemKind::Recording), KindRule::RecordingAge);
        assert_eq!(rule_of(ItemKind::RecordsBackup), KindRule::OtherAge);
        assert_eq!(rule_of(ItemKind::StoreBackup), KindRule::OtherAge);
        assert_eq!(rule_of(ItemKind::StreamWorktree), KindRule::OtherAge);
        assert_eq!(
            state(&item("l", ItemKind::StreamLog, 0), &[], &[]),
            ItemState::Pinned
        );
        let month = 30 * DAY_S;
        let rec = |at| state(&item("r", ItemKind::Recording, at), &[], &[]);
        assert_eq!(rec(NOW - month + 1), ItemState::Idle);
        assert_eq!(rec(NOW - month), ItemState::Evictable);
        for k in [ItemKind::RecordsBackup, ItemKind::StoreBackup] {
            assert_eq!(
                state(&item("k", k, NOW - 3 * DAY_S), &[], &[]),
                ItemState::Evictable
            );
        }
        // every kind has a word of its own, and the wire writes it
        let words: BTreeSet<&str> = ItemKind::ALL.iter().map(|k| k.name()).collect();
        assert_eq!(words.len(), ItemKind::ALL.len());
        for k in ItemKind::ALL {
            assert_eq!(
                serde_json::to_string(&k).unwrap(),
                format!("\"{}\"", k.name())
            );
        }
    }

    /// [D] pure: active beats pinned beats age.
    #[test]
    fn an_active_or_pinned_item_is_never_evictable() {
        let old = item("s", ItemKind::Slot, 0);
        assert_eq!(state(&old, &[], &[]), ItemState::Evictable);
        assert_eq!(state(&old, &["s"], &[]), ItemState::Active);
        assert_eq!(state(&old, &[], &["s"]), ItemState::Pinned);
        assert_eq!(state(&old, &["s"], &["s"]), ItemState::Active);
        assert_eq!(
            state(&item("l", ItemKind::StreamLog, 0), &["l"], &[]),
            ItemState::Active
        );
    }

    /// [D] §4.8: admission keeps the stop floor free after the job's need.
    #[test]
    fn admission_keeps_the_stop_floor_after_the_need() {
        let r = DiskRules::standard();
        assert!(!disk_fits(11, 30, 0, 0, &r));
        assert!(disk_fits(10, 30, 0, 0, &r));
        assert!(!disk_fits(0, 19, 0, 0, &r));
    }

    /// [D] old Task 48's two rows in one: the running jobs' unused need counts as taken, and a warm build dir the job
    /// would reuse counts as already held.
    #[test]
    fn running_jobs_unused_need_counts_and_a_warm_dir_counts_as_held() {
        let r = DiskRules::standard();
        assert!(disk_fits(10, 40, 10, 0, &r));
        assert!(!disk_fits(10, 40, 11, 0, &r));
        assert!(disk_fits(15, 30, 0, 5, &r));
        assert!(!disk_fits(15, 30, 0, 4, &r));
        // a warm dir bigger than the need holds nothing more, and frees nothing
        assert!(disk_fits(5, 20, 0, 50, &r));
        assert!(!disk_fits(5, 19, 0, 50, &r));
        // more unused need than free: never fits
        assert!(!disk_fits(
            0,
            5,
            10,
            0,
            &DiskRules {
                stop_below_gb: 0,
                ..r
            }
        ));
    }

    /// [D] the report's classes: per kind, the bytes and the evictable bytes; an unknown folder is never evictable.
    #[test]
    fn classes_sum_per_kind() {
        let items = vec![
            item("a", ItemKind::BuildDir, 0),
            item("b", ItemKind::BuildDir, NOW),
            item("c", ItemKind::Unknown, 0),
        ];
        let pins = Pins::default();
        let c = classes(&items, NOW, &pins, &DiskRules::standard());
        assert_eq!(c.len(), 2);
        assert_eq!(
            (c[0].kind, c[0].items, c[0].bytes, c[0].evictable_bytes),
            (ItemKind::BuildDir, 2, 2 << 30, 1 << 30)
        );
        assert_eq!((c[1].kind, c[1].evictable_bytes), (ItemKind::Unknown, 0));
    }
}
