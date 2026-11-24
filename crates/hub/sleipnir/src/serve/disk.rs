//! `serve`'s disk guard (`docs/develop/sleipnir.md`, "The disk guard"; editing-model design §4.8): the register's
//! items, the pass that evicts them ([`crate::sync::guard`]'s `plan` and `apply`), and the frames that carry them.
//!
//! - A pass runs before an admission while the disk is below the evict floor, every [`super::CLEANUP_EVERY`] from
//!   `tick` (after the register is reconciled and sized), and on the hub's `evict` order.
//! - A pass on a live link runs on a thread of its own (a removal may wait up to a minute on IO pressure), so pings go
//!   on; an offer that comes while it runs is refused, and admitted once it is done.
//! - The hub's `pins` are kept in `<root>/pins.json`: without the hub, `serve` goes on with the last ones it had.
//! - After a pass, and at hello and on the timer, a `disk` frame reports the items changed or gone since the last.

use super::attempts::COLLECTED;
use super::{Event, Next, Serve};
use crate::proto::Frame;
use crate::sync::guard::{self as sg, Df, Evict, Evicted, Pins, Why};
use crate::sync::register::{Register, blocks_bytes, epoch_s};
use crate::sync::slot::{self, SlotFamily};
use forseti::disk::{DiskItem, DiskReport, DiskRules, ItemKind, classes, owners_quota};
use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;
use stund::Instant;

/// The hub's last pins, kept under the runner folder.
pub const PINS: &str = "pins.json";
/// How long a timer pass may spend sizing the register's items.
const MEASURE_BUDGET: Duration = Duration::from_secs(5);

/// What `serve` keeps of the disk between passes.
pub(super) struct DiskState {
    /// The hub's last pins (`learned_at`: when they came).
    pub pins: Pins,
    /// The last pass (or `serve`'s start).
    pub last_pass: Instant,
    /// A pass runs on its thread.
    pub guarding: bool,
    /// The hub's orders that came while a pass ran.
    pub pending: Vec<(u64, Vec<Evict>)>,
    /// The items as the last report had them.
    pub reported: BTreeMap<String, DiskItem>,
    /// Items gone since the last report.
    pub gone: BTreeSet<String>,
}

impl DiskState {
    /// The state at `serve`'s start in ROOT: the pins the hub sent last, read back.
    pub fn load(root: &Path, now: Instant) -> DiskState {
        let pins: Pins = crate::fsio::read_to_string(root.join(PINS))
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        if let Some(at) = pins.learned_at {
            crate::eline!(
                "sleipnir serve: the disk guard keeps the hub's pins of {at} until it hears again"
            );
        }
        DiskState {
            pins,
            last_pass: now,
            guarding: false,
            pending: vec![],
            reported: BTreeMap::new(),
            gone: BTreeSet::new(),
        }
    }
}

/// IO pressure now, `full avg10` percent, from `/proc/pressure/io` (0 where it can't be read).
fn io_full10_now() -> f64 {
    crate::fsio::read_to_string("/proc/pressure/io")
        .ok()
        .and_then(|t| {
            t.lines()
                .find(|l| l.starts_with("full"))?
                .split_whitespace()
                .find_map(|w| w.strip_prefix("avg10="))?
                .parse()
                .ok()
        })
        .unwrap_or(0.0)
}

/// Whether item ID is in use: LIVE names it, or it is a job folder whose attempt the hub hasn't collected yet (read
/// from the folder now, so a pass that waited sees an attempt that started meanwhile).
fn in_use(root: &Path, live: &BTreeSet<String>, id: &str) -> bool {
    live.contains(id) || (id.starts_with("jobs/") && !root.join(id).join(COLLECTED).exists())
}

/// The bytes are GiB, rounded up.
fn gib(bytes: u64) -> u64 {
    bytes.div_ceil(1 << 30)
}

impl<W: Write> Serve<W> {
    /// The rules this runner's passes keep: §4.8's, with the owner's cap from its own `runner.conf` (the hub's own
    /// cap applies to its orders, [`owners_quota`]).
    pub(super) fn disk_rules(&self) -> DiskRules {
        DiskRules {
            quota_gb: owners_quota(self.platform.disk_quota_gb(), None),
            ..DiskRules::standard()
        }
    }

    /// What is in use now: the live attempts' job folders, their slots and build dirs, and what the hub's pins say is
    /// active.
    fn live_ids(&self) -> BTreeSet<String> {
        let mut out = self.disk.pins.active.clone();
        for l in self.live.values() {
            if let Ok(rel) = l.dir.strip_prefix(&self.cfg.root) {
                out.insert(rel.display().to_string());
            }
            if let Some(sid) = &l.meta.slot {
                out.insert(format!("slot:{sid}"));
                out.insert(format!("build:{sid}"));
            }
        }
        out
    }

    /// The pins the hub sent: kept, and written down for a `serve` that runs without the hub.
    pub(super) fn pins(&mut self, mut pins: Pins) -> Next {
        pins.learned_at = Some(epoch_s());
        let body = serde_json::to_vec(&pins).unwrap_or_default();
        super::note("pins", crate::fsio::write(self.cfg.root.join(PINS), body));
        self.disk.pins = pins;
        Next::Go
    }

    /// The hub's order ORDER: IDS removed for WHY, each re-checked first.
    pub(super) fn evict(&mut self, order: u64, ids: Vec<String>, why: String) -> Next {
        let plan = ids
            .into_iter()
            .map(|id| Evict {
                id,
                why: Why::Ordered(why.clone()),
            })
            .collect();
        self.guard_pass(Some((order, plan)))
    }

    /// Before an admission: below the evict floor a pass runs first. True while it runs on its thread (the offer
    /// waits for it).
    pub(super) fn guard_before_admission(&mut self) -> bool {
        if self.disk.guarding {
            return true;
        }
        let low = self
            .platform
            .df(&self.cfg.root)
            .is_ok_and(|d| d.below_evict(&self.disk_rules()));
        if low {
            self.guard_pass(None);
        }
        self.disk.guarding
    }

    /// The timer's pass: the register reconciled with the folder and sized (a bounded walk), a pass, a report.
    pub(super) fn guard_timer(&mut self) -> Next {
        self.disk.last_pass = Instant::now();
        if let Ok(mut reg) = Register::open(&self.cfg.root) {
            for rel in reg.reconcile() {
                crate::eline!(
                    "sleipnir serve: the disk register doesn't know {}: reported, kept",
                    rel.display()
                );
            }
            self.disk.gone.extend(reg.take_gone());
            reg.measure(MEASURE_BUDGET);
        }
        if self.guard_pass(None) == Next::Stop {
            return Next::Stop;
        }
        self.disk_report()
    }

    /// One pass: ORDER's evictions, or the plan for the register now. On a live link it runs on a thread of its own;
    /// in a test (no events) it runs here.
    pub(super) fn guard_pass(&mut self, order: Option<(u64, Vec<Evict>)>) -> Next {
        if self.disk.guarding {
            if let Some(o) = order {
                self.disk.pending.push(o);
            }
            return Next::Go;
        }
        let root = self.cfg.root.clone();
        let rules = self.disk_rules();
        let (number, plan) = match order {
            Some((n, p)) => (Some(n), p),
            None => {
                let Ok(reg) = Register::open(&root) else {
                    return Next::Go;
                };
                let Ok(df) = self.platform.df(&root) else {
                    return Next::Go;
                };
                let items = reg.items();
                let ours = items.iter().map(|i| i.bytes).sum();
                (
                    None,
                    sg::plan(df, ours, &items, &self.disk.pins, &rules, epoch_s()),
                )
            }
        };
        if plan.is_empty() && number.is_none() {
            return Next::Go;
        }
        let live = self.live_ids();
        if let Some(tx) = self.events.clone() {
            let started = saman::spawn_thread("sleipnir-disk-guard", move || {
                let done = run_pass(
                    &root,
                    &plan,
                    &live,
                    &mut || sg::df(&root),
                    &mut io_full10_now,
                    &rules,
                );
                // the loop may have ended meanwhile: nothing then waits for the answer
                if tx.send(Event::Guarded(number, done)).is_err() {
                    tracing::debug!("the disk guard's answer came after serve ended");
                }
            });
            match started {
                Ok(_) => self.disk.guarding = true,
                Err(e) => crate::eline!("sleipnir serve: the disk guard did not start: {e}"),
            }
            return Next::Go;
        }
        let platform = &self.platform;
        let limits = &self.limits;
        let done = run_pass(
            &root,
            &plan,
            &live,
            &mut || platform.df(&root),
            &mut || {
                platform
                    .machine(epoch_s(), limits)
                    .map_or(0.0, |m| m.psi.io_full10)
            },
            &rules,
        );
        self.guarded(number, done)
    }

    /// A pass ended with DONE (for the hub's order NUMBER): the hub hears what went and what stayed, and the disk now;
    /// an order that waited runs next.
    pub(super) fn guarded(&mut self, number: Option<u64>, done: Vec<Evicted>) -> Next {
        self.disk.guarding = false;
        self.disk.last_pass = Instant::now();
        for e in done.iter().filter(|e| e.refused.is_none()) {
            self.disk.gone.insert(e.id.clone());
            if let Some(sid) = e.id.strip_prefix("slot:") {
                self.disk.gone.insert(format!("build:{sid}"));
            }
        }
        if (number.is_some() || !done.is_empty())
            && self.send(&Frame::Evicted {
                order: number,
                done,
            }) == Next::Stop
        {
            return Next::Stop;
        }
        if self.disk_report() == Next::Stop {
            return Next::Stop;
        }
        if !self.disk.pending.is_empty() {
            let next = self.disk.pending.remove(0);
            return self.guard_pass(Some(next));
        }
        Next::Go
    }

    /// The `disk` frame: the disk now and the items changed or gone since the last one (none sent before a hello).
    pub(super) fn disk_report(&mut self) -> Next {
        if !self.hello {
            return Next::Go;
        }
        let Some(report) = self.disk_now() else {
            return Next::Go;
        };
        self.send(&Frame::Disk(report))
    }

    /// The report as it stands; the items it carries become the last reported. None, said on stderr, when the
    /// register can't be read: a torn register is never reported as empty.
    fn disk_now(&mut self) -> Option<DiskReport> {
        let root = self.cfg.root.clone();
        let reg = match Register::open(&root) {
            Ok(r) => r,
            Err(e) => {
                crate::eline!("sleipnir serve: the disk register: {e}: no disk report");
                return None;
            }
        };
        let df: Df = self.platform.df(&root).ok()?;
        let items = reg.items();
        let now: BTreeMap<String, DiskItem> =
            items.iter().map(|i| (i.id.clone(), i.clone())).collect();
        let changed: Vec<DiskItem> = items
            .iter()
            .filter(|i| self.disk.reported.get(&i.id) != Some(*i))
            .cloned()
            .collect();
        let mut gone: BTreeSet<String> = std::mem::take(&mut self.disk.gone);
        gone.extend(
            self.disk
                .reported
                .keys()
                .filter(|id| !now.contains_key(*id))
                .cloned(),
        );
        gone.retain(|id| !now.contains_key(id));
        let rules = self.disk_rules();
        let report = DiskReport {
            free: df.avail,
            total: df.total,
            ours: items.iter().map(|i| i.bytes).sum(),
            quota: rules.quota_gb.map(|q| q.saturating_mul(sg::GB)),
            btrfs_unallocated: self.platform.btrfs_unallocated(&root),
            classes: classes(&items, epoch_s(), &self.disk.pins, &rules),
            changed,
            gone: gone.into_iter().collect(),
        };
        self.disk.reported = now;
        Some(report)
    }

    /// The attempt in DIR (job SPEC's) joins the register as a job folder, at admission.
    pub(super) fn register_job(&self, dir: &Path, spec: &forseti::JobSpec) {
        let Ok(rel) = dir.strip_prefix(&self.cfg.root) else {
            return;
        };
        let key = SlotFamily::of(spec);
        let now = epoch_s();
        let item = DiskItem {
            id: rel.display().to_string(),
            kind: ItemKind::JobFolder,
            owner: key.project,
            machine: String::new(),
            bytes: 0,
            last_used: now,
            created: now,
            name: None,
            budget_bytes: None,
            trust: key.trust,
        };
        let added = Register::open(&self.cfg.root).and_then(|mut r| r.add(item, rel));
        super::note("the disk register", added);
    }

    /// Instance N of the slot family job SPEC runs on joins the register (or is used again), at its start.
    pub(super) fn register_slot(&self, spec: &forseti::JobSpec, n: u32) {
        let key = SlotFamily::of(spec);
        let p = slot::paths(&self.cfg.root, &key, n);
        let added = Register::open(&self.cfg.root)
            .and_then(|mut r| slot::register(&mut r, &p, &key, n, epoch_s()));
        super::note("the disk register", added);
    }

    /// How many instances a slot family may have here: what the free disk above the evict floor holds at the p95 sizes
    /// the register measured ([`slot::slot_limit`]), at most the runner's `max_slots`.
    pub(super) fn slot_limit(&self) -> u32 {
        let free = self.platform.df(&self.cfg.root).map_or(0, |d| d.avail);
        let floor = self.disk_rules().evict_below_gb.saturating_mul(sg::GB);
        let (slot_p95, build_p95) = Register::open(&self.cfg.root).map_or((0, 0), |r| {
            (r.p95(ItemKind::Slot), r.p95(ItemKind::BuildDir))
        });
        slot::slot_limit(
            free.saturating_sub(floor),
            slot_p95,
            build_p95,
            self.platform.max_slots(),
        )
    }

    /// What the attempt in DIR took on the disk at its end, GiB: its folder and its slot's build dir (`st_blocks`).
    /// The register keeps the folder's size.
    pub(super) fn measured_gib(&self, dir: &Path, slot: Option<&str>) -> u64 {
        let own = blocks_bytes(dir);
        let build = slot.map_or(0, |sid| {
            blocks_bytes(&self.cfg.root.join("slots-target").join(sid))
        });
        if let Ok(rel) = dir.strip_prefix(&self.cfg.root)
            && let Ok(mut reg) = Register::open(&self.cfg.root)
            && let Some((mut item, rel_kept)) = reg.get(&rel.display().to_string())
        {
            item.bytes = own;
            item.last_used = epoch_s();
            super::note("the disk register", reg.add(item, &rel_kept));
        }
        gib(own + build)
    }

    /// The running jobs' declared disk need they have not used yet, GiB (admission counts it as taken).
    pub(super) fn disk_unused_gib(&self) -> u64 {
        self.live
            .values()
            .filter(|l| {
                l.meta.started.is_some() && !l.dir.join(crate::linux::result::RESULT).exists()
            })
            .map(|l| u64::from(l.meta.spec.disk_gib).saturating_sub(gib(blocks_bytes(&l.dir))))
            .sum()
    }
}

/// PLAN carried out on ROOT's register, LIVE (and the job folders not collected yet) kept.
fn run_pass(
    root: &Path,
    plan: &[Evict],
    live: &BTreeSet<String>,
    df: &mut dyn FnMut() -> std::io::Result<Df>,
    io: &mut dyn FnMut() -> f64,
    rules: &DiskRules,
) -> Vec<Evicted> {
    let Ok(mut reg) = Register::open(root) else {
        return vec![];
    };
    let root: PathBuf = root.to_path_buf();
    sg::apply(
        &mut reg,
        plan,
        &|id| in_use(&root, live, id),
        &mut || df().map_err(|e| villa::Error::io(format!("statvfs: {e}"))),
        io,
        rules,
        &mut |e| match &e.refused {
            None => crate::eline!(
                "sleipnir serve: the disk guard removed {} ({} bytes, {})",
                e.id,
                e.bytes,
                e.why.text()
            ),
            Some(why) => crate::eline!(
                "sleipnir serve: the disk guard kept {} ({}): {why}",
                e.id,
                e.why.text()
            ),
        },
    )
}
