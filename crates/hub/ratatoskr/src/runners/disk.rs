//! The hub's disk register (editing-model design §4.8; docs/develop/hub.md, "Runners: the disk"): what drgnx keeps on
//! each machine's disk, as the runners report it (`Frame::Disk`), the pins the hub sends them (`Frame::Pins`), the
//! eviction orders it sends (`Frame::Evict`) and every eviction recorded with its reason (`Frame::Evicted`), in
//! `runtime.db`'s `disk_items` and `disk_evictions` (migration 12).
//!
//! The hub's own producers (B1's streams, urdr's backups and recordings) report the bytes they own through
//! [`DiskSource`] (2026-11-23-parallel-lines.md §2.1): their items are planned with the rest, the register asks `live`
//! before it removes one, and removes it only through the source's `remove`, never through a path of its own.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use forseti::disk::{
    ClassUse, DiskItem, DiskRules, Evict, Evicted, ItemKind, ItemState, Pins, Why, classes,
    owners_quota, state_of,
};
use sleipnir::sync::guard::{self, Df};

pub use forseti::disk::DiskReport;

/// The machine name the hub's own sources' items are on.
pub const HUB_MACHINE: &str = "hub";

/// The one way a hub-side producer reports the bytes it owns (2026-11-23-parallel-lines.md §2.1). Its items are
/// planned with the rest; the register asks `live` before ordering a removal and removes only through `remove`.
pub trait DiskSource: Send + Sync {
    /// `streams`, `records`, `recordings`.
    fn name(&self) -> &'static str;
    /// Its items now, sized lazily (an `st_blocks` walk).
    fn items(&self, now: u64) -> villa::Result<Vec<DiskItem>>;
    /// True: keep it (a pin of the source's own).
    fn live(&self, id: &str) -> bool;
    /// Removes item ID under the source's own root (`eitri`, no link followed): the bytes freed; `Kind::Refused` when
    /// it won't.
    fn remove(&self, id: &str) -> villa::Result<u64>;
}

/// A write to `runtime.db`, as the queue's store thread runs it.
pub type DiskOp = Box<dyn FnOnce(&urdr::Connection) -> Result<(), urdr::Error> + Send>;

/// What the register knows of one machine.
#[derive(Clone, Debug, Default)]
pub struct MachineDisk {
    /// Its last report (none: never reported).
    pub report: Option<DiskReport>,
    /// When it came, epoch seconds.
    pub at: u64,
    pub items: BTreeMap<String, DiskItem>,
    /// The user's pins there.
    pub user_pins: BTreeSet<String>,
    /// The pins last sent to it.
    pub pins: Pins,
}

/// One machine's disk as `runners/disk` and `runner disk` show it.
#[derive(Clone, Debug, PartialEq)]
pub struct DiskView {
    pub machine: String,
    pub free: u64,
    pub total: u64,
    pub ours: u64,
    pub quota: Option<u64>,
    pub btrfs_unallocated: Option<u64>,
    pub classes: Vec<ClassUse>,
    /// Each item with its state now.
    pub items: Vec<(DiskItem, ItemState)>,
}

/// The register of every machine's disk.
pub struct DiskRegister {
    machines: BTreeMap<String, MachineDisk>,
    sources: Vec<Arc<dyn DiskSource>>,
    next_order: u64,
    /// Orders sent and not answered yet: order → machine.
    open: BTreeMap<u64, String>,
    persist: Option<Box<dyn Fn(DiskOp) + Send + Sync>>,
}

impl Default for DiskRegister {
    fn default() -> DiskRegister {
        DiskRegister::new()
    }
}

/// One `disk_items` row as a report writes it.
struct ItemRow {
    id: String,
    kind: String,
    owner: String,
    bytes: i64,
    last_used: i64,
    state: String,
    pinned_by: Option<String>,
}

impl DiskRegister {
    pub fn new() -> DiskRegister {
        DiskRegister {
            machines: BTreeMap::new(),
            sources: Vec::new(),
            next_order: 1,
            open: BTreeMap::new(),
            persist: None,
        }
    }

    /// The register writing its rows through PERSIST (the queue's store thread).
    pub fn with_persist(
        mut self,
        persist: impl Fn(DiskOp) + Send + Sync + 'static,
    ) -> DiskRegister {
        self.persist = Some(Box::new(persist));
        self
    }

    fn write(&self, op: DiskOp) {
        if let Some(p) = &self.persist {
            p(op);
        }
    }

    /// A hub-side producer's items join the register (one line per source at the hub's start).
    pub fn add_source(&mut self, s: Arc<dyn DiskSource>) {
        self.sources.push(s);
    }

    /// MACHINE as the register knows it.
    pub fn machine(&self, machine: &str) -> Option<&MachineDisk> {
        self.machines.get(machine)
    }

    /// MACHINE's report F at NOW: its changed items replace theirs, its gone ones leave, and both reach `disk_items`
    /// ([`ItemRow`] each).
    pub fn report(&mut self, machine: &str, f: &DiskReport, now: u64) {
        let m = self.machines.entry(machine.to_string()).or_default();
        for i in &f.changed {
            let mut i = i.clone();
            i.machine = machine.to_string();
            m.items.insert(i.id.clone(), i);
        }
        for id in &f.gone {
            m.items.remove(id);
        }
        m.report = Some(f.clone());
        m.at = now;
        let rows: Vec<ItemRow> = f
            .changed
            .iter()
            .map(|i| {
                let state = state_of(
                    i,
                    now,
                    &m.pins.active,
                    &m.pins.pinned,
                    &DiskRules::standard(),
                );
                let pinned_by = m
                    .user_pins
                    .contains(&i.id)
                    .then(|| "user".to_string())
                    .or_else(|| m.pins.pinned.contains(&i.id).then(|| "queue".to_string()));
                ItemRow {
                    id: i.id.clone(),
                    kind: i.kind.name().to_string(),
                    owner: i.owner.clone(),
                    bytes: i.bytes as i64,
                    last_used: i.last_used as i64,
                    state: state_word(state).to_string(),
                    pinned_by,
                }
            })
            .collect();
        let (machine, gone) = (machine.to_string(), f.gone.clone());
        self.write(Box::new(move |c| {
            for r in rows {
                c.execute(
                    "insert or replace into disk_items(machine, id, kind, owner, bytes, last_used, state, pinned_by) \
                     values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                    (
                        &machine,
                        r.id,
                        r.kind,
                        r.owner,
                        r.bytes,
                        r.last_used,
                        r.state,
                        r.pinned_by,
                    ),
                )?;
            }
            for id in gone {
                c.execute(
                    "delete from disk_items where machine = ?1 and id = ?2",
                    (&machine, id),
                )?;
            }
            Ok(())
        }));
    }

    /// The pins for MACHINE: active what RUNNING jobs there use, pinned what NEEDED (queued jobs) name and the
    /// user's pins. They are kept as the machine's last pins (what an order is planned with).
    pub fn pins_for(
        &mut self,
        machine: &str,
        needed: &BTreeSet<String>,
        running: &BTreeSet<String>,
    ) -> Pins {
        let m = self.machines.entry(machine.to_string()).or_default();
        let pins = Pins {
            active: running.clone(),
            pinned: needed.union(&m.user_pins).cloned().collect(),
            learned_at: None,
        };
        m.pins = pins.clone();
        pins
    }

    /// The eviction order for MACHINE at NOW under R (the hub's rules; the quota is the smaller of the machine's own
    /// and R's): none while its last report needs none. The hub's own machine's plan takes the sources' items too.
    pub fn order(&mut self, machine: &str, r: &DiskRules, now: u64) -> Option<(u64, Vec<Evict>)> {
        let m = self.machines.get(machine)?;
        let rep = m.report.as_ref()?;
        let rules = DiskRules {
            quota_gb: owners_quota(rep.quota.map(|b| b / guard::GB), r.quota_gb),
            ..*r
        };
        let items: Vec<DiskItem> = m.items.values().cloned().collect();
        let df = Df {
            total: rep.total,
            avail: rep.free,
        };
        let plan = guard::plan(df, rep.ours, &items, &m.pins, &rules, now);
        if plan.is_empty() {
            return None;
        }
        let n = self.next_order;
        self.next_order += 1;
        self.open.insert(n, machine.to_string());
        Some((n, plan))
    }

    /// The user's `runner reclaim`: everything on MACHINE past its age and not pinned or in use, as an order (none:
    /// nothing to reclaim). DRY_RUN plans it only.
    pub fn reclaim(&mut self, machine: &str, dry_run: bool, now: u64) -> Option<(u64, Vec<Evict>)> {
        let m = self.machines.get(machine)?;
        let r = DiskRules::standard();
        let plan: Vec<Evict> = m
            .items
            .values()
            .filter(|i| {
                i.kind != ItemKind::Unknown
                    && state_of(i, now, &m.pins.active, &m.pins.pinned, &r) == ItemState::Evictable
            })
            .map(|i| Evict {
                id: i.id.clone(),
                why: Why::Ordered("reclaim".into()),
            })
            .collect();
        if plan.is_empty() {
            return None;
        }
        if dry_run {
            return Some((0, plan));
        }
        let n = self.next_order;
        self.next_order += 1;
        self.open.insert(n, machine.to_string());
        Some((n, plan))
    }

    /// MACHINE's answer DONE: every eviction, carried out or refused, recorded with its reason in `disk_evictions`;
    /// the items removed leave the register.
    pub fn evicted(&mut self, machine: &str, order: Option<u64>, done: &[Evicted]) {
        if let Some(n) = order {
            self.open.remove(&n);
        }
        let m = self.machines.entry(machine.to_string()).or_default();
        let mut rows = Vec::new();
        for e in done {
            let owner = m
                .items
                .get(&e.id)
                .map(|i| i.owner.clone())
                .unwrap_or_default();
            if e.refused.is_none() {
                m.items.remove(&e.id);
            }
            rows.push((
                e.id.clone(),
                e.kind.name().to_string(),
                owner,
                e.bytes as i64,
                e.why.text(),
                e.at as i64,
                e.refused.clone(),
            ));
        }
        let machine = machine.to_string();
        self.write(Box::new(move |c| {
            for (id, kind, owner, bytes, why, at, refused) in rows {
                c.execute(
                    "insert into disk_evictions(machine, id, kind, owner, bytes, why, at, refused) \
                     values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                    (&machine, &id, kind, owner, bytes, why, at, refused.clone()),
                )?;
                if refused.is_none() {
                    c.execute(
                        "delete from disk_items where machine = ?1 and id = ?2",
                        (&machine, &id),
                    )?;
                }
            }
            Ok(())
        }));
    }

    /// The user pins item ID on MACHINE (ON) or lets it go: `NotFound` for an item the register doesn't hold there,
    /// `Refused` for one of a source's (the source keeps its own) or an unknown folder.
    pub fn user_pin(&mut self, machine: &str, id: &str, on: bool) -> villa::Result<()> {
        let m = self
            .machines
            .get_mut(machine)
            .ok_or_else(|| villa::Error::not_found(format!("no disk report from {machine}")))?;
        let item = m
            .items
            .get(id)
            .ok_or_else(|| villa::Error::not_found(format!("{id} is not on {machine}'s disk")))?;
        if matches!(
            item.kind,
            ItemKind::Unknown
                | ItemKind::StreamWorktree
                | ItemKind::StreamLog
                | ItemKind::RecordsBackup
                | ItemKind::StoreBackup
                | ItemKind::Recording
        ) {
            return Err(villa::Error::refused(format!(
                "{id} is a {}: not the user's to pin",
                item.kind.name()
            )));
        }
        if on {
            m.user_pins.insert(id.to_string());
            m.pins.pinned.insert(id.to_string());
        } else {
            m.user_pins.remove(id);
            m.pins.pinned.remove(id);
        }
        Ok(())
    }

    /// The hub's own sources at NOW under R, with DF the hub's disk: their items planned (below the floor, over the
    /// quota, past their age), each asked `live` again before it goes and removed only through its source. Every
    /// outcome is recorded as an eviction on [`HUB_MACHINE`].
    pub fn run_sources(&mut self, df: Df, r: &DiskRules, now: u64) -> Vec<Evicted> {
        let mut owned: Vec<(DiskItem, usize)> = Vec::new();
        for (n, s) in self.sources.iter().enumerate() {
            match s.items(now) {
                Ok(items) => owned.extend(items.into_iter().map(|i| (i, n))),
                Err(e) => tracing::warn!("runners: the disk source {}: {e}", s.name()),
            }
        }
        let items: Vec<DiskItem> = owned.iter().map(|(i, _)| i.clone()).collect();
        let ours = items.iter().map(|i| i.bytes).sum();
        let plan = guard::plan(df, ours, &items, &Pins::default(), r, now);
        let mut done = Vec::new();
        for e in plan {
            let Some((item, n)) = owned.iter().find(|(i, _)| i.id == e.id) else {
                continue;
            };
            let s = &self.sources[*n];
            let (bytes, refused) = if s.live(&e.id) {
                (item.bytes, Some(format!("{} keeps it", s.name())))
            } else {
                match s.remove(&e.id) {
                    Ok(b) => (b, None),
                    Err(err) => (item.bytes, Some(err.to_string())),
                }
            };
            done.push(Evicted {
                id: e.id.clone(),
                kind: item.kind,
                bytes,
                why: e.why,
                at: now,
                refused,
            });
        }
        if !done.is_empty() {
            self.evicted(HUB_MACHINE, None, &done);
        }
        done
    }

    /// MACHINE's disk (every machine with none named) as `runners/disk` shows it, at NOW.
    pub fn view(&self, machine: Option<&str>, now: u64) -> Vec<DiskView> {
        let r = DiskRules::standard();
        self.machines
            .iter()
            .filter(|(name, _)| machine.is_none_or(|m| m == name.as_str()))
            .filter_map(|(name, m)| {
                let rep = m.report.as_ref()?;
                let items: Vec<DiskItem> = m.items.values().cloned().collect();
                Some(DiskView {
                    machine: name.clone(),
                    free: rep.free,
                    total: rep.total,
                    ours: rep.ours,
                    quota: rep.quota,
                    btrfs_unallocated: rep.btrfs_unallocated,
                    classes: classes(&items, now, &m.pins, &r),
                    items: items
                        .into_iter()
                        .map(|i| {
                            let s = state_of(&i, now, &m.pins.active, &m.pins.pinned, &r);
                            (i, s)
                        })
                        .collect(),
                })
            })
            .collect()
    }
}

/// A state as `disk_items.state` and the CLI write it.
pub fn state_word(s: ItemState) -> &'static str {
    match s {
        ItemState::Active => "active",
        ItemState::Idle => "idle",
        ItemState::Evictable => "evictable",
        ItemState::Pinned => "pinned",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use forseti::JobTrust;
    use std::sync::Mutex;

    const NOW: u64 = 10_000_000;
    const DAY: u64 = 24 * 3600;
    const GB: u64 = guard::GB;

    fn item(id: &str, kind: ItemKind, age: u64) -> DiskItem {
        DiskItem {
            id: id.into(),
            kind,
            owner: "p".into(),
            machine: String::new(),
            bytes: GB,
            last_used: NOW - age,
            created: NOW - age,
            name: None,
            budget_bytes: None,
            trust: JobTrust::Private,
        }
    }

    fn report(free_gb: u64, changed: Vec<DiskItem>, gone: Vec<String>) -> DiskReport {
        DiskReport {
            free: free_gb * GB,
            total: 1000 * GB,
            ours: changed.iter().map(|i| i.bytes).sum(),
            quota: None,
            btrfs_unallocated: None,
            classes: vec![],
            changed,
            gone,
        }
    }

    /// A register whose writes run on a fresh `runtime.db` in DIR.
    fn on_db(dir: &std::path::Path) -> (DiskRegister, Arc<Mutex<urdr::Connection>>) {
        let (store, _h) = crate::runtime_db::open(dir).unwrap();
        store.shutdown();
        let c = Arc::new(Mutex::new(
            urdr::Connection::open(dir.join("runtime.db")).unwrap(),
        ));
        let to = c.clone();
        let reg = DiskRegister::new().with_persist(move |op| op(&saman::lock(&to)).unwrap());
        (reg, c)
    }

    fn count(c: &Mutex<urdr::Connection>, sql: &str) -> i64 {
        saman::lock(c).query_row(sql, [], |r| r.get(0)).unwrap()
    }

    // [D] a fresh runtime.db
    #[test]
    fn a_report_updates_the_register_and_an_order_follows_below_the_floor() {
        let d = tempfile::tempdir().unwrap();
        let (mut reg, c) = on_db(d.path());
        let r = DiskRules::standard();
        let items = vec![
            item("build:old", ItemKind::BuildDir, 3 * DAY),
            item("build:young", ItemKind::BuildDir, 3600),
            item("jobs/a.1", ItemKind::JobFolder, 9 * DAY),
        ];
        reg.report("desk", &report(500, items, vec![]), NOW);
        assert_eq!(count(&c, "select count(*) from disk_items"), 3);
        assert!(
            reg.order("desk", &r, NOW).is_none(),
            "above the floor: no order"
        );
        // a report below the floor: an order, in §4.8's order, past their ages only
        reg.report("desk", &report(50, vec![], vec!["jobs/a.1".into()]), NOW);
        assert_eq!(count(&c, "select count(*) from disk_items"), 2);
        let (n, plan) = reg.order("desk", &r, NOW).unwrap();
        assert_eq!(n, 1);
        assert_eq!(
            plan,
            [Evict {
                id: "build:old".into(),
                why: Why::Floor
            }]
        );
        // the machine's own quota caps the hub's
        let mut q = report(500, vec![], vec![]);
        q.ours = 3 * GB;
        q.quota = Some(GB);
        reg.report("desk", &q, NOW);
        let (_, plan) = reg
            .order(
                "desk",
                &DiskRules {
                    quota_gb: Some(100),
                    ..r
                },
                NOW,
            )
            .unwrap();
        assert!(
            plan.iter().all(|e| e.why == Why::Quota) && plan.len() == 2,
            "{plan:?}"
        );
        assert!(reg.order("nobody", &r, NOW).is_none());
    }

    // [D] pure
    #[test]
    fn pins_come_from_queued_and_running_jobs_and_the_user() {
        let mut reg = DiskRegister::new();
        reg.report(
            "desk",
            &report(
                500,
                vec![
                    item("slot:s", ItemKind::Slot, 9 * DAY),
                    item("artifacts/a", ItemKind::Artifact, 9 * DAY),
                    item("build:b", ItemKind::BuildDir, 9 * DAY),
                    item("cache:c", ItemKind::Cache, 9 * DAY),
                ],
                vec![],
            ),
            NOW,
        );
        reg.user_pin("desk", "cache:c", true).unwrap();
        let needed: BTreeSet<String> = ["artifacts/a".to_string()].into();
        let running: BTreeSet<String> = ["slot:s".to_string(), "build:b".to_string()].into();
        let p = reg.pins_for("desk", &needed, &running);
        assert_eq!(p.active, running);
        assert_eq!(
            p.pinned,
            ["artifacts/a".to_string(), "cache:c".to_string()].into()
        );
        // with these pins nothing past its age is free to go but what no one holds
        let mut low = report(10, vec![], vec![]);
        low.ours = 4 * GB;
        reg.report("desk", &low, NOW);
        assert!(reg.order("desk", &DiskRules::standard(), NOW).is_none());
        reg.user_pin("desk", "cache:c", false).unwrap();
        let (_, plan) = reg.order("desk", &DiskRules::standard(), NOW).unwrap();
        assert_eq!(plan.len(), 1);
        assert_eq!(plan[0].id, "cache:c");
        assert!(reg.user_pin("desk", "nope", true).is_err());
        assert!(reg.user_pin("elsewhere", "cache:c", true).is_err());
    }

    // [D] a fresh runtime.db
    #[test]
    fn every_eviction_is_recorded_with_its_reason() {
        let d = tempfile::tempdir().unwrap();
        let (mut reg, c) = on_db(d.path());
        reg.report(
            "desk",
            &report(
                50,
                vec![
                    item("build:a", ItemKind::BuildDir, 9 * DAY),
                    item("slot:b", ItemKind::Slot, 9 * DAY),
                ],
                vec![],
            ),
            NOW,
        );
        let (n, _) = reg.order("desk", &DiskRules::standard(), NOW).unwrap();
        let done = [
            Evicted {
                id: "build:a".into(),
                kind: ItemKind::BuildDir,
                bytes: GB,
                why: Why::Floor,
                at: NOW,
                refused: None,
            },
            Evicted {
                id: "slot:b".into(),
                kind: ItemKind::Slot,
                bytes: GB,
                why: Why::Ordered("reclaim".into()),
                at: NOW,
                refused: Some("in use".into()),
            },
        ];
        reg.evicted("desk", Some(n), &done);
        let rows: Vec<(String, String, Option<String>)> = {
            let c = saman::lock(&c);
            let mut st = c
                .prepare("select id, why, refused from disk_evictions order by id")
                .unwrap();
            st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert_eq!(
            rows,
            [
                ("build:a".to_string(), "floor".to_string(), None),
                (
                    "slot:b".to_string(),
                    "ordered: reclaim".to_string(),
                    Some("in use".to_string())
                ),
            ]
        );
        assert_eq!(
            count(&c, "select count(*) from disk_items where id = 'build:a'"),
            0
        );
        assert_eq!(
            count(&c, "select count(*) from disk_items where id = 'slot:b'"),
            1
        );
        assert!(reg.machine("desk").unwrap().items.contains_key("slot:b"));
        assert!(!reg.machine("desk").unwrap().items.contains_key("build:a"));
    }

    /// A source with two old backups: it keeps one live; removals are counted.
    struct Backups {
        removed: Mutex<Vec<String>>,
    }

    impl DiskSource for Backups {
        fn name(&self) -> &'static str {
            "records"
        }
        fn items(&self, _now: u64) -> villa::Result<Vec<DiskItem>> {
            Ok(vec![
                item("records:kept", ItemKind::RecordsBackup, 9 * DAY),
                item("records:old", ItemKind::RecordsBackup, 9 * DAY),
                item("records:new", ItemKind::RecordsBackup, 3600),
            ])
        }
        fn live(&self, id: &str) -> bool {
            id == "records:kept"
        }
        fn remove(&self, id: &str) -> villa::Result<u64> {
            saman::lock(&self.removed).push(id.to_string());
            Ok(GB)
        }
    }

    // [D] pure (a fixture source)
    #[test]
    fn a_source_item_is_removed_only_through_its_source_after_live_says_no() {
        let src = Arc::new(Backups {
            removed: Mutex::new(vec![]),
        });
        let mut reg = DiskRegister::new();
        reg.add_source(src.clone());
        let low = Df {
            total: 1000 * GB,
            avail: 10 * GB,
        };
        let done = reg.run_sources(low, &DiskRules::standard(), NOW);
        assert_eq!(*saman::lock(&src.removed), ["records:old".to_string()]);
        let refused: Vec<&str> = done
            .iter()
            .filter(|e| e.refused.is_some())
            .map(|e| e.id.as_str())
            .collect();
        assert_eq!(refused, ["records:kept"]);
        assert_eq!(done.len(), 2, "the young backup is not planned");
        // above the floor nothing of a source goes
        let high = Df {
            total: 1000 * GB,
            avail: 500 * GB,
        };
        assert!(
            reg.run_sources(high, &DiskRules::standard(), NOW)
                .is_empty()
        );
    }

    // [D] pure: a report-only item (an unknown folder) is never ordered
    #[test]
    fn a_report_only_item_is_never_ordered() {
        let mut reg = DiskRegister::new();
        let mut low = report(
            10,
            vec![item("unknown:jobs/x", ItemKind::Unknown, 99 * DAY)],
            vec![],
        );
        low.ours = 1000 * GB;
        reg.report("desk", &low, NOW);
        let r = DiskRules {
            quota_gb: Some(0),
            ..DiskRules::standard()
        };
        assert!(reg.order("desk", &r, NOW).is_none());
        assert!(reg.reclaim("desk", false, NOW + 99 * DAY).is_none());
        assert!(reg.user_pin("desk", "unknown:jobs/x", true).is_err());
    }
}
