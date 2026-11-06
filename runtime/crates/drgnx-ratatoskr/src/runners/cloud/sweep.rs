//! The sweeper (design §6.7.6, layer 3): what this hub's cloud machines are, and the end of those that should be gone.
//!
//! At hub start and every [`EVERY_S`] (600 s), and at once when the meter says the cap plus a machine-hour is passed, a
//! [`Sweeper::pass`] lists the machines tagged with this hub's id in the provider's region and:
//!
//! - names the running ones the hub has no link to, for it to reattach (redial with a new certificate);
//! - ends any unreachable for [`UNREACHABLE_S`] (300 s) in a row, any past its lifetime, any stopped (by anyone), and
//!   with `CapState::PastCapPlusHour` every one;
//! - never touches a machine without this hub's tag, even one a provider's list returned: it is named in `not_ours`.
//!
//! When the credentials need a login (`CloudError::NeedsLogin`) it pauses: it ends nothing, and the card names the
//! command ([`needs_login_text`]). Machines keep their jobs while the hub reaches them and end through their own
//! layers (the watchdog, the provider's deadline). The next pass that the credentials work for resumes, and ends
//! whatever is past its bound by then.

pub use super::meter::needs_login_text;
use super::{CloudError, InstanceInfo, InstanceState, Provider, aws::HUB_TAG};
use forseti::cost::CapState;
use std::collections::BTreeMap;

/// How often it sweeps.
pub const EVERY_S: u64 = 600;
/// How long a machine may be out of reach in a row.
pub const UNREACHABLE_S: u64 = 300;

/// What ends a machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Bounds {
    /// The lifetime since its launch.
    pub lifetime_s: u64,
    /// Out of reach in a row.
    pub unreachable_s: u64,
}

/// Why the sweeper ended a machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ended {
    Unreachable,
    Lifetime,
    /// Stopped, not ended: a stopped machine still bills its disk.
    Stopped,
    /// The cap plus a machine-hour.
    Cap,
}

impl Ended {
    pub fn as_str(self) -> &'static str {
        match self {
            Ended::Unreachable => "unreachable for 5 minutes",
            Ended::Lifetime => "past its lifetime",
            Ended::Stopped => "stopped",
            Ended::Cap => "the cloud cap",
        }
    }
}

/// What a pass found and did.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Swept {
    /// Running machines of ours the hub has no link to: reattach.
    pub reattach: Vec<InstanceInfo>,
    /// Machines it ended, by id, in id order.
    pub ended: Vec<(String, Ended)>,
    /// Machines a list returned without this hub's tag: never touched.
    pub not_ours: Vec<String>,
}

/// A pass's outcome.
#[derive(Clone, Debug, PartialEq)]
pub enum Pass {
    Done(Swept),
    /// The credentials need a login: the command.
    Paused(String),
    /// The provider failed otherwise (tried again at the next pass).
    Failed(CloudError),
}

/// The sweeper of one provider and region.
#[derive(Clone, Debug)]
pub struct Sweeper {
    hub_id: String,
    bounds: Bounds,
    /// Since when each machine has been out of reach.
    unreachable_since: BTreeMap<String, u64>,
    paused: Option<String>,
}

fn secs(t: std::time::SystemTime) -> u64 {
    t.duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

impl Sweeper {
    pub fn new(hub_id: &str, bounds: Bounds) -> Sweeper {
        Sweeper {
            hub_id: hub_id.into(),
            bounds,
            unreachable_since: BTreeMap::new(),
            paused: None,
        }
    }

    /// The command the credentials wait for, while paused.
    pub fn paused(&self) -> Option<&str> {
        self.paused.as_deref()
    }

    /// One pass over PROVIDER's machines at NOW (the hub's clock), REACHED telling which the hub has a live link to,
    /// under the cap's state CAP.
    pub async fn pass(
        &mut self,
        provider: &dyn Provider,
        now: u64,
        reached: &dyn Fn(&str) -> bool,
        cap: CapState,
    ) -> Pass {
        let listed = match provider.list_ours().await {
            Ok(l) => l,
            Err(e) => return self.failed(e),
        };
        let mut w = Swept::default();
        let mut seen = vec![];
        for info in listed {
            if info.tags.get(HUB_TAG) != Some(&self.hub_id) {
                w.not_ours.push(info.id);
                continue;
            }
            seen.push(info.id.clone());
            let why = match info.state {
                InstanceState::Ending | InstanceState::Gone => continue,
                _ if cap == CapState::PastCapPlusHour => Some(Ended::Cap),
                InstanceState::Stopped | InstanceState::Stopping => Some(Ended::Stopped),
                _ if info
                    .launched
                    .is_some_and(|t| now.saturating_sub(secs(t)) >= self.bounds.lifetime_s) =>
                {
                    Some(Ended::Lifetime)
                }
                InstanceState::Running if reached(&info.id) => {
                    self.unreachable_since.remove(&info.id);
                    None
                }
                InstanceState::Running => {
                    let since = *self.unreachable_since.entry(info.id.clone()).or_insert(now);
                    if now - since.min(now) >= self.bounds.unreachable_s {
                        Some(Ended::Unreachable)
                    } else {
                        w.reattach.push(info.clone());
                        None
                    }
                }
                // still booting: its lifetime bounds it
                _ => None,
            };
            if let Some(why) = why {
                if let Err(e) = provider.end(&info.id).await {
                    return self.failed(e);
                }
                self.unreachable_since.remove(&info.id);
                w.ended.push((info.id, why));
            }
        }
        // forget the machines that are gone
        self.unreachable_since.retain(|id, _| seen.contains(id));
        self.paused = None;
        w.ended.sort_by(|a, b| a.0.cmp(&b.0));
        Pass::Done(w)
    }

    fn failed(&mut self, e: CloudError) -> Pass {
        match e {
            CloudError::NeedsLogin(cmd) => {
                self.paused = Some(cmd.clone());
                Pass::Paused(cmd)
            }
            e => Pass::Failed(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runners::cloud::aws::Aws;
    use crate::runners::cloud::testmock::{HUB, Mock};
    use crate::runners::cloud::{Check, Instance, Prices, StartReq};
    use mimir::BoxFuture;
    use serde_json::json;

    /// The mock's clock at its start (2026-11-06T00:00:00Z): the sweeper's NOW values are on it.
    const T0: u64 = 1_793_923_200;
    const B: Bounds = Bounds {
        lifetime_s: 8 * 3600,
        unreachable_s: 300,
    };

    async fn seed(m: &Mock, id: &str, hub: Option<&str>) {
        let tags = match hub {
            Some(h) => json!({"drgnx-hub": h}),
            None => json!({"Name": "someone else's"}),
        };
        m.knob("seed", json!({"provider": "aws", "id": id, "tags": tags}))
            .await;
    }

    /// The mock ended machine ID (with no containers behind it, it is gone at once).
    async fn gone(m: &Mock, id: &str) {
        let s = m.state_of(id).await;
        assert!(s == "shutting-down" || s == "terminated", "{id}: {s}");
    }

    fn done(p: Pass) -> Swept {
        match p {
            Pass::Done(w) => w,
            other => panic!("not a pass: {other:?}"),
        }
    }

    fn ended(w: &Swept) -> Vec<(&str, Ended)> {
        w.ended
            .iter()
            .map(|(id, why)| (id.as_str(), *why))
            .collect()
    }

    // [B] the mock's virtual clock and the sweeper's NOW values: no time passes for real
    #[tokio::test]
    async fn ends_an_unreachable_tagged_machine_after_5_minutes() {
        let m = Mock::start();
        let aws = m.aws();
        seed(&m, "i-lost", Some(HUB)).await;
        seed(&m, "i-linked", Some(HUB)).await;
        let mut s = Sweeper::new(HUB, B);
        let linked = |id: &str| id == "i-linked";
        let w = done(s.pass(&aws, T0 + 10, &linked, CapState::Under).await);
        let reattach: Vec<&str> = w.reattach.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(
            reattach,
            ["i-lost"],
            "a running machine it can't reach: reattach"
        );
        assert!(w.ended.is_empty(), "{w:?}");
        let w = done(s.pass(&aws, T0 + 309, &linked, CapState::Under).await);
        assert!(w.ended.is_empty(), "299 s unreachable: {w:?}");
        let w = done(s.pass(&aws, T0 + 310, &linked, CapState::Under).await);
        assert_eq!(ended(&w), [("i-lost", Ended::Unreachable)]);
        gone(&m, "i-lost").await;
        assert_eq!(m.state_of("i-linked").await, "running");
        // reached again, a machine's count starts afresh
        seed(&m, "i-flaky", Some(HUB)).await;
        let w = done(s.pass(&aws, T0 + 400, &|_| false, CapState::Under).await);
        assert!(!w.ended.iter().any(|(id, _)| id == "i-linked"), "{w:?}");
        done(s.pass(&aws, T0 + 650, &|_| true, CapState::Under).await);
        let w = done(s.pass(&aws, T0 + 800, &|_| false, CapState::Under).await);
        assert!(w.ended.is_empty(), "{w:?}");
        // past its lifetime: ended, reachable or not
        let w = done(
            s.pass(&aws, T0 + 8 * 3600, &|_| true, CapState::Under)
                .await,
        );
        assert_eq!(
            ended(&w),
            [("i-flaky", Ended::Lifetime), ("i-linked", Ended::Lifetime)]
        );
    }

    // [B]
    #[tokio::test]
    async fn stops_every_machine_past_the_cap() {
        let m = Mock::start();
        let aws = m.aws();
        seed(&m, "i-a", Some(HUB)).await;
        seed(&m, "i-b", Some(HUB)).await;
        let mut s = Sweeper::new(HUB, B);
        // at the cap they run on (they stop when their jobs end)
        let w = done(s.pass(&aws, T0 + 10, &|_| true, CapState::AtCap).await);
        assert!(w.ended.is_empty(), "{w:?}");
        // a machine-hour past it: every machine, reachable and busy, ends now
        let w = done(
            s.pass(&aws, T0 + 20, &|_| true, CapState::PastCapPlusHour)
                .await,
        );
        assert_eq!(ended(&w), [("i-a", Ended::Cap), ("i-b", Ended::Cap)]);
        for id in ["i-a", "i-b"] {
            gone(&m, id).await;
        }
    }

    /// AWS with a list that returns every machine in the account, as a broken filter would.
    struct Everything<'a> {
        aws: &'a Aws,
        ids: Vec<&'static str>,
    }

    impl Provider for Everything<'_> {
        fn preflight(&self) -> BoxFuture<'_, Vec<Check>> {
            self.aws.preflight()
        }
        fn start<'a>(&'a self, req: &'a StartReq) -> BoxFuture<'a, Result<Instance, CloudError>> {
            self.aws.start(req)
        }
        fn describe<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<InstanceInfo, CloudError>> {
            self.aws.describe(id)
        }
        fn list_ours(&self) -> BoxFuture<'_, Result<Vec<InstanceInfo>, CloudError>> {
            Box::pin(async move {
                let mut out = vec![];
                for id in &self.ids {
                    out.push(self.aws.describe(id).await?);
                }
                Ok(out)
            })
        }
        fn end<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<(), CloudError>> {
            self.aws.end(id)
        }
        fn console<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<String, CloudError>> {
            self.aws.console(id)
        }
        fn prices<'a>(&'a self, sizes: &'a [String]) -> BoxFuture<'a, Result<Prices, CloudError>> {
            self.aws.prices(sizes)
        }
    }

    // [B]
    #[tokio::test]
    async fn never_touches_an_untagged_instance() {
        let m = Mock::start();
        let aws = m.aws();
        seed(&m, "i-mine", Some(HUB)).await;
        seed(&m, "i-untagged", None).await;
        seed(&m, "i-other-hub", Some("hub-2")).await;
        let all = Everything {
            aws: &aws,
            ids: vec!["i-mine", "i-untagged", "i-other-hub"],
        };
        let mut s = Sweeper::new(HUB, B);
        for (now, cap) in [
            (T0, CapState::Under),
            (T0 + 400, CapState::Under),
            (T0 + 9 * 3600, CapState::PastCapPlusHour),
        ] {
            let w = done(s.pass(&all, now, &|_| false, cap).await);
            assert!(
                !w.ended.iter().any(|(id, _)| id != "i-mine"),
                "only ours is ever ended: {w:?}"
            );
            assert_eq!(w.not_ours, ["i-untagged", "i-other-hub"], "{w:?}");
            assert!(!w.reattach.iter().any(|i| i.id != "i-mine"), "{w:?}");
        }
        assert_eq!(m.state_of("i-untagged").await, "running");
        assert_eq!(m.state_of("i-other-hub").await, "running");
        gone(&m, "i-mine").await;
        // through the provider's own filter they are never even listed
        let w = done(
            Sweeper::new(HUB, B)
                .pass(&aws, T0 + 9 * 3600, &|_| false, CapState::Under)
                .await,
        );
        assert!(w.not_ours.is_empty(), "{w:?}");
    }

    mod creds {
        use super::*;

        // [B] the mock's expired token, then its token accepted again
        #[tokio::test]
        async fn expired_pauses_the_sweeper_and_it_resumes() {
            let m = Mock::start();
            let aws = m.aws();
            seed(&m, "i-old", Some(HUB)).await;
            let mut s = Sweeper::new(HUB, B);
            m.knob("expire", json!({})).await;
            // past its lifetime, but the credentials need a login: the sweeper pauses and ends nothing
            let late = T0 + 9 * 3600;
            let cmd = match s.pass(&aws, late, &|_| false, CapState::Under).await {
                Pass::Paused(cmd) => cmd,
                other => panic!("not paused: {other:?}"),
            };
            assert_eq!(s.paused(), Some(cmd.as_str()));
            assert_eq!(
                needs_login_text(&cmd),
                format!("Run `{cmd}`, then Runners: Retry Cloud")
            );
            assert_eq!(m.state_of("i-old").await, "running");
            assert!(matches!(
                s.pass(&aws, late + 600, &|_| false, CapState::Under).await,
                Pass::Paused(_)
            ));
            // the user logs in (the mock takes the token again): the next pass resumes, and ends what is past its bound
            m.knob("token", json!({})).await;
            let w = done(s.pass(&aws, late + 1200, &|_| false, CapState::Under).await);
            assert_eq!(ended(&w), [("i-old", Ended::Lifetime)]);
            assert_eq!(s.paused(), None);
            gone(&m, "i-old").await;
        }
    }
}
