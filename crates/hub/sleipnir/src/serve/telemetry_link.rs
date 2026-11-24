//! `serve`'s side of the resource telemetry (Task 38; `docs/develop/sleipnir.md`, "Resource telemetry"): the sampler's
//! thread ([`super::telemetry::spawn`]) started at the first hello, what it samples told to it every second, the
//! hub's `telemetry-watch`, `telemetry-unwatch` and `telemetry-range` handed to it, and the markers `serve` leaves on
//! its timeline.

use super::telemetry::{self, Cmd, Engine, Rates, Target};
use super::{Event, Next, Serve, now_s};
use crate::proto::Frame;
use std::collections::BTreeMap;
use std::io::Write;
use std::time::Duration;

/// How often what the sampler reads is told to it.
const PUSH_EVERY: Duration = Duration::from_secs(1);

impl<W: Write> Serve<W> {
    /// Starts the sampler's thread, once, on a platform that has the files to read; the frames it makes come back to
    /// the loop as events.
    pub(super) fn telemetry_start(&mut self) {
        if self.telemetry.is_some() {
            return;
        }
        let Some(events) = self.events.clone() else {
            return;
        };
        let Some((roots, gpu)) = self.platform.telemetry_source() else {
            return;
        };
        let rates = self.telemetry_rates();
        let engine = Engine::new(roots, rates, &self.cfg.root.join("telemetry"), gpu);
        let emit = move |f: Frame| drop(events.send(Event::Telemetry(f)));
        match telemetry::spawn(engine, emit) {
            Ok(tx) => {
                self.telemetry = Some(tx);
                self.telemetry_rates = rates;
            }
            Err(e) => crate::eline!("sleipnir serve: telemetry: {e}"),
        }
    }

    /// The rates in the runner's `runner.conf` now (its `[telemetry]` table; the defaults without one).
    fn telemetry_rates(&self) -> Rates {
        crate::fsio::read_to_string(self.cfg.root.join("runner.conf"))
            .map(|t| Rates::parse(&t))
            .unwrap_or_default()
    }

    /// The thread is told CMD (nothing when there is none: a platform without the files).
    pub(super) fn telemetry_cmd(&self, cmd: Cmd) {
        if let Some(tx) = &self.telemetry {
            drop(tx.send(cmd));
        }
    }

    /// The hub's watch, unwatch or range frame.
    pub(super) fn telemetry_frame(&mut self, f: Frame) -> Next {
        match f {
            Frame::TelemetryWatch {
                id,
                level,
                ids,
                every_ms,
            } => self.telemetry_cmd(Cmd::Watch {
                id,
                level,
                ids,
                every_ms,
            }),
            Frame::TelemetryUnwatch { id } => self.telemetry_cmd(Cmd::Unwatch(id)),
            Frame::TelemetryRange { id, range } => {
                if self.telemetry.is_some() {
                    self.telemetry_cmd(Cmd::Range { id, range });
                } else {
                    // nothing to read here: an empty history, not silence
                    return self.send(&Frame::TelemetryRanged {
                        id,
                        ranged: Default::default(),
                    });
                }
            }
            _ => {}
        }
        Next::Go
    }

    /// A moment on the timeline: JOB (or a slot) KIND, with DETAIL.
    pub(super) fn mark(&self, id: &str, kind: &str, detail: &str) {
        self.telemetry_cmd(Cmd::Mark(crate::proto::telemetry::Marker {
            at_ms: telemetry::now_ms(),
            id: id.to_string(),
            kind: kind.to_string(),
            detail: detail.to_string(),
        }));
    }

    /// Every second: the rates in `runner.conf`, and what to sample: each running job's cgroup and reservation, each
    /// slot the jobs are on, and admission's headroom line.
    pub(super) fn telemetry_push(&mut self) {
        if self.telemetry.is_none()
            || self
                .telemetry_pushed
                .is_some_and(|t| t.elapsed() < PUSH_EVERY)
        {
            return;
        }
        self.telemetry_pushed = Some(stund::Instant::now());
        let rates = self.telemetry_rates();
        if rates != self.telemetry_rates {
            self.telemetry_rates = rates;
            self.telemetry_cmd(Cmd::Rates(rates));
        }
        let jobs = self.running_jobs();
        let mut targets = Vec::new();
        let mut slots: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for l in self.live.values().filter(|l| l.meta.started.is_some()) {
            let id = &l.meta.r.job;
            if let Some(cgroup) = self.platform.job_cgroup(id) {
                targets.push(Target::job(id, cgroup));
            }
            if let Some(s) = &l.meta.slot {
                slots.entry(s.clone()).or_default().push(id.clone());
            }
        }
        for (slot, members) in slots {
            targets.push(Target::slot(&slot, None, members));
        }
        for r in &jobs {
            targets.push(Target::reservation(&r.id.0, r.reserve_mib, r.current_mib));
        }
        let headroom = self
            .platform
            .machine(now_s(), &self.limits)
            .ok()
            .map(|mut m| {
                m.running = jobs;
                telemetry::headroom_mib(&m, &self.limits)
            });
        self.telemetry_cmd(Cmd::Targets(targets, headroom));
    }
}
