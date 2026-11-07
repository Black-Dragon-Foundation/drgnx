//! What cloud machines cost, as drgnx's own meter counts it (design §6.7.5; `docs/guide/runners.md`, "What cloud can
//! cost").
//!
//! Per machine: running seconds × the hourly price at its start, its disk's GB-hours, its public IPv4 address-hours
//! and the bytes it sent back at the provider's egress price; and the images' storage. Each machine-hour is one
//! `cloud_spend` record, which the hub writes ([`write`]). The meter is the gate:
//!
//! - [`Meter::gate`]: no start whose projection (`forseti::cost::projection`) passes the cap, at the cap no new cloud
//!   work, and with the credentials needing a login nothing new at all;
//! - [`Meter::check`], at every check: at the cap no new work; one machine-hour past it, looking one check ahead,
//!   every machine stops now (the sweeper ends them, `CapState::PastCapPlusHour`) and its jobs requeue
//!   (`Queue::cloud_gone`).
//!
//! The provider's bill can differ (late charges, taxes, transfer the meter didn't see): what it shows is drgnx's
//! estimate. A new month starts a new meter from that month's records.

use super::Market;
pub use forseti::cost::{CapState, RunningCost, cap_state, guard, projection};
use serde::Serialize;
use std::collections::BTreeMap;

/// How often the hub checks the cap, at most: the guard looks this far ahead.
pub const CHECK_S: u64 = 10;
/// The record that carries the images' storage.
pub const IMAGES: &str = "images";
/// Hours in a billing month, as the providers price storage.
const MONTH_H: f64 = 730.0;

/// The prices besides the machine's own (USD).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rates {
    /// A disk's GB-month.
    pub disk_gb_month: f64,
    /// A public IPv4 address-hour.
    pub ipv4_h: f64,
    /// A GB sent out.
    pub egress_gb: f64,
    /// An image's (its snapshots') GB-month.
    pub image_gb_month: f64,
}

impl Default for Rates {
    /// AWS's list prices (us-east-1, read 2026-11-05): gp3, public IPv4, data out, EBS snapshots.
    fn default() -> Rates {
        Rates {
            disk_gb_month: 0.08,
            ipv4_h: 0.005,
            egress_gb: 0.09,
            image_gb_month: 0.05,
        }
    }
}

/// A machine as it starts.
#[derive(Clone, Debug, PartialEq)]
pub struct Started {
    /// Its instance id.
    pub machine: String,
    /// Its runner's name in the queue.
    pub runner: String,
    pub provider: String,
    pub region: String,
    pub size: String,
    pub market: Market,
    /// Its hourly price at the start.
    pub price_h: f64,
    pub disk_gb: f64,
    pub at: u64,
}

/// One `cloud_spend` record: what MACHINE cost from FROM to TO.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct CloudSpend {
    pub machine: String,
    pub provider: String,
    pub region: String,
    #[serde(rename = "type")]
    pub size: String,
    pub market: &'static str,
    pub from: u64,
    pub to: u64,
    pub amount: f64,
}

/// What the cap means now.
#[derive(Clone, Debug, PartialEq)]
pub enum CapAct {
    Go,
    /// At the cap: no new cloud work; each machine stops when its jobs end.
    NoNewWork,
    /// A machine-hour past it: every machine (instance id, runner) stops now.
    StopAll(Vec<(String, String)>),
}

#[derive(Clone, Debug)]
struct Running {
    s: Started,
    /// Recorded up to here.
    to: u64,
    /// Bytes sent since then.
    bytes: u64,
}

/// The meter of one month.
#[derive(Clone, Debug)]
pub struct Meter {
    rates: Rates,
    /// What this month's records hold.
    recorded: f64,
    running: BTreeMap<String, Running>,
    /// The images' storage in GB, and recorded up to when.
    images: Option<(f64, u64)>,
}

fn market_name(m: Market) -> &'static str {
    match m {
        Market::Spot => "spot",
        Market::OnDemand => "on-demand",
    }
}

/// `$41`, `$3.10`: dollars once the sum is ten or more, cents below.
fn usd(x: f64) -> String {
    if x >= 10.0 {
        format!("${x:.0}")
    } else {
        format!("${x:.2}")
    }
}

/// The card for credentials that need a login.
pub fn needs_login_text(cmd: &str) -> String {
    format!("Run `{cmd}`, then Runners: Retry Cloud")
}

impl Meter {
    /// A month's meter with RATES, its records so far adding up to MONTH_SPENT.
    pub fn new(rates: Rates, month_spent: f64) -> Meter {
        Meter {
            rates,
            recorded: month_spent,
            running: BTreeMap::new(),
            images: None,
        }
    }

    pub fn start(&mut self, s: Started) {
        let to = s.at;
        self.running
            .insert(s.machine.clone(), Running { s, to, bytes: 0 });
    }

    /// MACHINE sent BYTES back.
    pub fn sent(&mut self, machine: &str, bytes: u64) {
        if let Some(r) = self.running.get_mut(machine) {
            r.bytes += bytes;
        }
    }

    /// The images now hold GB, from NOW (what they held before is recorded up to now first).
    pub fn images(&mut self, gb: f64, now: u64) {
        if let Some(rec) = self.images_record(now) {
            self.recorded += rec.amount;
        }
        self.images = Some((gb, now));
    }

    /// The machines it meters.
    pub fn machines(&self) -> Vec<&str> {
        self.running.keys().map(String::as_str).collect()
    }

    /// A machine's own hourly rate: its price, its disk, its address.
    fn rate_h(&self, r: &Running) -> f64 {
        r.s.price_h + r.s.disk_gb * self.rates.disk_gb_month / MONTH_H + self.rates.ipv4_h
    }

    /// Every machine's hourly rate together.
    pub fn rate_all(&self) -> f64 {
        self.running.values().map(|r| self.rate_h(r)).sum()
    }

    fn cost(&self, r: &Running, to: u64) -> f64 {
        self.rate_h(r) * to.saturating_sub(r.to) as f64 / 3600.0
            + r.bytes as f64 / 1e9 * self.rates.egress_gb
    }

    fn record(&self, r: &Running, to: u64) -> CloudSpend {
        CloudSpend {
            machine: r.s.machine.clone(),
            provider: r.s.provider.clone(),
            region: r.s.region.clone(),
            size: r.s.size.clone(),
            market: market_name(r.s.market),
            from: r.to,
            to,
            amount: self.cost(r, to),
        }
    }

    fn images_record(&self, to: u64) -> Option<CloudSpend> {
        let (gb, from) = self.images?;
        (to > from).then(|| CloudSpend {
            machine: IMAGES.into(),
            provider: String::new(),
            region: String::new(),
            size: String::new(),
            market: "",
            from,
            to,
            amount: gb * self.rates.image_gb_month / MONTH_H * (to - from) as f64 / 3600.0,
        })
    }

    /// This month's spend at NOW: the records, and what runs since.
    pub fn spent(&self, now: u64) -> f64 {
        self.recorded
            + self
                .running
                .values()
                .map(|r| self.cost(r, now))
                .sum::<f64>()
            + self.images_record(now).map_or(0.0, |r| r.amount)
    }

    /// The records due at NOW: one per whole machine-hour (and the images' hour), each once.
    pub fn tick(&mut self, now: u64) -> Vec<CloudSpend> {
        let mut out = vec![];
        let ids: Vec<String> = self.running.keys().cloned().collect();
        for id in ids {
            while let Some(r) = self.running.get(&id).filter(|r| r.to + 3600 <= now) {
                let rec = self.record(r, r.to + 3600);
                let r = self.running.get_mut(&id).expect("just read");
                r.to += 3600;
                r.bytes = 0;
                self.recorded += rec.amount;
                out.push(rec);
            }
        }
        while let Some((gb, from)) = self.images.filter(|(_, from)| from + 3600 <= now) {
            if let Some(rec) = self.images_record(from + 3600) {
                self.recorded += rec.amount;
                out.push(rec);
            }
            self.images = Some((gb, from + 3600));
        }
        out
    }

    /// MACHINE ended at NOW: its last part-hour's record.
    pub fn end(&mut self, machine: &str, now: u64) -> Option<CloudSpend> {
        let r = self.running.remove(machine)?;
        let rec = self.record(&r, now.max(r.to));
        self.recorded += rec.amount;
        Some(rec)
    }

    /// Whether a start may go ahead: a SIZE at PRICE_H, busy for BUSY_S and then idle for IDLE_S, with RUNNING's
    /// machines going on until their idle stops; never with NEEDS_LOGIN (the command the card names).
    #[allow(clippy::too_many_arguments)]
    pub fn gate(
        &self,
        now: u64,
        cap: f64,
        size: &str,
        price_h: f64,
        busy_s: u64,
        idle_s: u64,
        running: &[RunningCost],
        needs_login: Option<&str>,
    ) -> Result<(), String> {
        if let Some(cmd) = needs_login {
            return Err(needs_login_text(cmd));
        }
        let spent = self.spent(now);
        if spent >= cap {
            return Err(format!(
                "cloud cap: {} of {} used; no new cloud work",
                usd(spent),
                usd(cap)
            ));
        }
        if projection(spent, price_h, busy_s, idle_s, running) > cap {
            let min = (busy_s + idle_s).div_ceil(60);
            return Err(format!(
                "cloud cap: {} of {} used; a {size} for ~{min} min would pass it",
                usd(spent),
                usd(cap)
            ));
        }
        Ok(())
    }

    /// What the cap means at NOW, MACHINE_HOUR being one machine-hour's price and CHECK_S the time to the next check.
    pub fn check(&self, now: u64, cap: f64, machine_hour: f64, check_s: u64) -> CapAct {
        match guard(self.spent(now), self.rate_all(), check_s, cap, machine_hour) {
            CapState::Under => CapAct::Go,
            CapState::AtCap => CapAct::NoNewWork,
            CapState::PastCapPlusHour => CapAct::StopAll(
                self.running
                    .values()
                    .map(|r| (r.s.machine.clone(), r.s.runner.clone()))
                    .collect(),
            ),
        }
    }
}

/// Writes REC as `cloud_spend:<machine>.<from>`, as `("hub", Class::System)`.
pub async fn write(db: &norn::store::CoordDb, rec: &CloudSpend) -> Result<(), String> {
    let name = format!("{}.{}", rec.machine, rec.from);
    let data = serde_json::to_value(rec).map_err(|e| e.to_string())?;
    let meta = urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "runners/cloud");
    db.write(meta, move |tx| {
        norn::write::runners::put(tx, "cloud_spend", &name, data).map(|_| ())
    })
    .await
    .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const NO_EXTRAS: Rates = Rates {
        disk_gb_month: 0.0,
        ipv4_h: 0.0,
        egress_gb: 0.0,
        image_gb_month: 0.0,
    };

    fn started(machine: &str, price_h: f64, at: u64) -> Started {
        Started {
            machine: machine.into(),
            runner: format!("cloud-{machine}"),
            provider: "aws".into(),
            region: "eu-west-1".into(),
            size: "c7a.4xlarge".into(),
            market: Market::Spot,
            price_h,
            disk_gb: 0.0,
            at,
        }
    }

    // [D] pure
    #[test]
    fn the_reason_text_is_the_designs() {
        let m = Meter::new(NO_EXTRAS, 41.0);
        // $15/h for 25 min busy and 15 min idle is $10 more: past $50
        assert_eq!(
            m.gate(0, 50.0, "c7a.4xlarge", 15.0, 1500, 900, &[], None),
            Err("cloud cap: $41 of $50 used; a c7a.4xlarge for ~40 min would pass it".into())
        );
        assert_eq!(
            m.gate(0, 50.0, "c7a.4xlarge", 1.2, 1500, 900, &[], None),
            Ok(())
        );
        // what already runs until its idle stop counts too
        let running = [RunningCost {
            price_h: 9.0,
            remaining_s: 3600,
        }];
        assert!(
            m.gate(0, 50.0, "c7a.4xlarge", 1.2, 1500, 900, &running, None)
                .is_err()
        );
        // at the cap: no new cloud work
        let at = Meter::new(NO_EXTRAS, 50.0);
        assert_eq!(
            at.gate(0, 50.0, "m7g.large", 0.01, 60, 900, &[], None),
            Err("cloud cap: $50 of $50 used; no new cloud work".into())
        );
        // small sums in cents
        let low = Meter::new(NO_EXTRAS, 3.1);
        assert_eq!(
            low.gate(0, 3.5, "m7g.large", 1.0, 1500, 900, &[], None),
            Err("cloud cap: $3.10 of $3.50 used; a m7g.large for ~40 min would pass it".into())
        );
        // expired credentials: nothing new starts, and the card names the command
        assert_eq!(
            m.gate(
                0,
                50.0,
                "m7g.large",
                0.01,
                60,
                900,
                &[],
                Some("aws sso login")
            ),
            Err("Run `aws sso login`, then Runners: Retry Cloud".into())
        );
    }

    // [D] pure: the meter's clock is a value
    #[test]
    fn cap_plus_one_hour_stops_now() {
        assert_eq!(cap_state(49.99, 50.0, 0.82), CapState::Under);
        assert_eq!(cap_state(50.0, 50.0, 0.82), CapState::AtCap);
        assert_eq!(cap_state(50.81, 50.0, 0.82), CapState::AtCap);
        assert_eq!(cap_state(50.82, 50.0, 0.82), CapState::PastCapPlusHour);

        // two machines at $0.82/h, started with $49 of $50 spent
        let mut m = Meter::new(NO_EXTRAS, 49.0);
        m.start(started("i-a", 0.82, 0));
        m.start(started("i-b", 0.82, 0));
        assert_eq!(m.check(0, 50.0, 0.82, CHECK_S), CapAct::Go);
        // at 37 min, $50.01: the cap; no new work, the machines finish what they run
        assert_eq!(m.check(37 * 60, 50.0, 0.82, CHECK_S), CapAct::NoNewWork);
        // one machine-hour past the cap, one check ahead: both stop now, and their runners' jobs requeue
        assert_eq!(m.check(3980, 50.0, 0.82, CHECK_S), CapAct::NoNewWork);
        assert_eq!(
            m.check(3990, 50.0, 0.82, CHECK_S),
            CapAct::StopAll(vec![
                ("i-a".into(), "cloud-i-a".into()),
                ("i-b".into(), "cloud-i-b".into())
            ])
        );

        // one record per machine-hour, once
        let recs = m.tick(3600);
        assert_eq!(recs.len(), 2, "{recs:?}");
        assert!((recs[0].amount - 0.82).abs() < 1e-9, "{recs:?}");
        assert_eq!(
            (recs[0].machine.as_str(), recs[0].from, recs[0].to),
            ("i-a", 0, 3600)
        );
        assert!(m.tick(3600).is_empty(), "an hour is recorded once");
        let last = m.end("i-a", 3990).expect("the last part-hour");
        assert_eq!((last.from, last.to), (3600, 3990));
        assert!((m.spent(3990) - (49.0 + 1.64 * 3990.0 / 3600.0)).abs() < 1e-9);
        assert_eq!(m.machines(), ["i-b"]);
    }

    // [D] pure
    #[test]
    fn the_meter_counts_disk_ipv4_egress_and_images() {
        let rates = Rates {
            disk_gb_month: 0.08,
            ipv4_h: 0.005,
            egress_gb: 0.09,
            image_gb_month: 0.05,
        };
        let mut m = Meter::new(rates, 0.0);
        let mut s = started("i-a", 0.1, 0);
        s.disk_gb = 30.0;
        m.start(s);
        m.sent("i-a", 2_000_000_000);
        m.images(16.0, 0);
        let recs = m.tick(3600);
        let machine = recs.iter().find(|r| r.machine == "i-a").unwrap();
        let want = 0.1 + 30.0 * 0.08 / 730.0 + 0.005 + 2.0 * 0.09;
        assert!((machine.amount - want).abs() < 1e-9, "{machine:?}");
        let images = recs.iter().find(|r| r.machine == IMAGES).unwrap();
        assert!(
            (images.amount - 16.0 * 0.05 / 730.0).abs() < 1e-9,
            "{images:?}"
        );
        assert!((m.spent(3600) - want - images.amount).abs() < 1e-9);
        // the record as the graph keeps it
        let v = serde_json::to_value(machine).unwrap();
        for k in [
            "machine", "provider", "region", "type", "market", "from", "to", "amount",
        ] {
            assert!(v.get(k).is_some(), "{k}: {v}");
        }
        assert_eq!(v["market"], "spot");
    }

    // [D] a graph of its own in a temporary folder: the hub's records go in through `write` and come back as the
    // hub's readers see them
    #[tokio::test]
    async fn write_records_the_spend_in_the_graph_and_it_reads_back() {
        let dir = tempfile::tempdir().unwrap();
        let db = norn::store::CoordDb::spawn(dir.path().join("work.db"));
        let mut m = Meter::new(NO_EXTRAS, 0.0);
        m.start(started("i-a", 0.36, 0));
        let hour = m.tick(3600);
        let last = m.end("i-a", 5400).expect("the last part-hour");
        for rec in hour.iter().chain([&last]) {
            write(&db, rec).await.unwrap();
        }
        // a write tried again (a retry after a lost answer) replaces its record: no second one
        write(&db, &hour[0]).await.unwrap();
        let rows = db
            .read(|c| norn::read::runners::list(c, "cloud_spend"))
            .await
            .unwrap();
        let names: Vec<&str> = rows.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(names, ["i-a.0", "i-a.3600"], "{rows:?}");
        let (_, first) = &rows[0];
        assert_eq!(first["machine"], "i-a");
        assert_eq!(first["provider"], "aws");
        assert_eq!(first["region"], "eu-west-1");
        assert_eq!(first["type"], "c7a.4xlarge");
        assert_eq!(first["market"], "spot");
        assert_eq!(
            (first["from"].as_u64(), first["to"].as_u64()),
            (Some(0), Some(3600))
        );
        assert!(
            (first["amount"].as_f64().unwrap() - 0.36).abs() < 1e-9,
            "{first}"
        );
        let (_, second) = &rows[1];
        assert_eq!(
            (second["from"].as_u64(), second["to"].as_u64()),
            (Some(3600), Some(5400))
        );
        assert!(
            (second["amount"].as_f64().unwrap() - 0.18).abs() < 1e-9,
            "{second}"
        );
        // the month's spend read back from the graph is what the meter counted
        let total: f64 = rows
            .iter()
            .map(|(_, d)| d["amount"].as_f64().unwrap())
            .sum();
        assert!(
            (total - m.spent(5400)).abs() < 1e-9,
            "{total} vs {}",
            m.spent(5400)
        );
    }
}
