//! The hub's side of a runner's resource telemetry (Task 38; `docs/develop/hub.md`, "Resource telemetry"): who watches
//! which runner's stream, and who waits for which runner's history. A runner sends `telemetry` and `telemetry-ranged`
//! frames ([`sleipnir::proto::Frame`]); the relay hands each to the viewer it belongs to as the wire's events and
//! answers. It holds no samples: the runner keeps its history.

use std::collections::BTreeMap;

use runstav::methods::runners::{
    TelemetryBatch, TelemetryHistory, TelemetryMarker, TelemetryPoint, TelemetrySample,
    TelemetrySeries, TelemetryValue,
};
use serde_json::Value;
use sleipnir::proto::Frame;
use sleipnir::proto::telemetry::{Marker, Ranged, Sample};
use tokio::sync::oneshot;

/// Where a watch's batches go: the `runners-telemetry` event's data; false when the viewer is gone.
pub type Sink = Box<dyn FnMut(Value) -> bool + Send>;

struct Watch {
    runner: String,
    sink: Sink,
}

/// The streams and the ranges asked, over every runner.
#[derive(Default)]
pub struct Relay {
    next: u64,
    watches: BTreeMap<u64, Watch>,
    waiting: BTreeMap<u64, (String, oneshot::Sender<TelemetryHistory>)>,
}

impl Relay {
    /// A new watch of RUNNER's stream into SINK; its id.
    pub fn watch(&mut self, runner: &str, sink: Sink) -> u64 {
        self.next += 1;
        self.watches.insert(
            self.next,
            Watch {
                runner: runner.to_string(),
                sink,
            },
        );
        self.next
    }

    /// The viewer under ID is done; the runner it watched, to tell it.
    pub fn unwatch(&mut self, id: u64) -> Option<String> {
        self.watches.remove(&id).map(|w| w.runner)
    }

    /// A range asked of RUNNER: the id to send and the receiver of its answer.
    pub fn range(&mut self, runner: &str) -> (u64, oneshot::Receiver<TelemetryHistory>) {
        self.next += 1;
        let (tx, rx) = oneshot::channel();
        self.waiting.insert(self.next, (runner.to_string(), tx));
        (self.next, rx)
    }

    /// A range that will not be answered (its frame could not be sent).
    pub fn forget(&mut self, id: u64) {
        self.waiting.remove(&id);
    }

    /// FRAME from RUNNER: handed to its viewer or waiter. The watches whose viewer is gone, removed: the caller tells
    /// their runners to stop.
    pub fn heard(&mut self, runner: &str, frame: Frame) -> Vec<(u64, String)> {
        match frame {
            Frame::Telemetry {
                id,
                every_ms,
                samples,
                markers,
            } => {
                let Some(w) = self.watches.get_mut(&id).filter(|w| w.runner == runner) else {
                    return vec![];
                };
                let Some(data) = batch_of(runner, id, every_ms, samples, markers) else {
                    return vec![];
                };
                if (w.sink)(data) {
                    return vec![];
                }
                self.watches.remove(&id);
                vec![(id, runner.to_string())]
            }
            Frame::TelemetryRanged { id, ranged } => {
                if self.waiting.get(&id).is_some_and(|(r, _)| r == runner)
                    && let Some((_, tx)) = self.waiting.remove(&id)
                {
                    // a waiter that gave up is no one to tell
                    drop(tx.send(history_of(ranged)));
                }
                vec![]
            }
            _ => vec![],
        }
    }

    /// RUNNER's link is gone: its watches end (the viewers hear no more) and its waiters get nothing; the ids ended.
    pub fn lost(&mut self, runner: &str) -> Vec<u64> {
        let ended: Vec<u64> = self
            .watches
            .iter()
            .filter(|(_, w)| w.runner == runner)
            .map(|(id, _)| *id)
            .collect();
        for id in &ended {
            self.watches.remove(id);
        }
        self.waiting.retain(|_, (r, _)| r != runner);
        ended
    }
}

/// The wire's event data for a batch of WATCH's stream from RUNNER.
pub fn batch_of(
    runner: &str,
    watch: u64,
    every_ms: u64,
    samples: Vec<Sample>,
    markers: Vec<Marker>,
) -> Option<Value> {
    let batch = TelemetryBatch {
        watch,
        runner: runstav::types::Id::new(runner).ok()?,
        every_ms,
        samples: samples
            .into_iter()
            .map(|s| TelemetrySample {
                at_ms: s.at_ms,
                level: s.level.word().to_string(),
                id: s.id,
                values: s
                    .values
                    .into_iter()
                    .map(|(metric, value)| TelemetryValue { metric, value })
                    .collect(),
            })
            .collect(),
        markers: markers.into_iter().map(marker_of).collect(),
    };
    serde_json::to_value(batch).ok()
}

fn marker_of(m: Marker) -> TelemetryMarker {
    TelemetryMarker {
        at_ms: m.at_ms,
        id: m.id,
        kind: m.kind,
        detail: m.detail,
    }
}

/// The wire's history for what a runner stored.
pub fn history_of(r: Ranged) -> TelemetryHistory {
    TelemetryHistory {
        series: r
            .series
            .into_iter()
            .map(|s| TelemetrySeries {
                level: s.level.word().to_string(),
                id: s.id,
                metric: s.metric,
                points: s
                    .points
                    .into_iter()
                    .map(|p| TelemetryPoint {
                        t: p.t,
                        min: p.min,
                        max: p.max,
                        mean: p.mean,
                        last: p.last,
                    })
                    .collect(),
            })
            .collect(),
        markers: r.markers.into_iter().map(marker_of).collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sleipnir::proto::telemetry::{Level, Point, Series};
    use std::sync::{Arc, Mutex};

    type Heard = Arc<Mutex<Vec<Value>>>;

    fn sink(alive: bool) -> (Sink, Heard) {
        let heard: Heard = Arc::default();
        let h = heard.clone();
        (
            Box::new(move |v| {
                saman::lock(&h).push(v);
                alive
            }),
            heard,
        )
    }

    fn frame(id: u64, at: u64) -> Frame {
        Frame::Telemetry {
            id,
            every_ms: 50,
            samples: vec![Sample {
                at_ms: at,
                level: Level::Job,
                id: "a3f".into(),
                values: [("cpu".to_string(), 1.5)].into(),
            }],
            markers: vec![Marker {
                at_ms: at,
                id: "a3f".into(),
                kind: "admitted".into(),
                detail: String::new(),
            }],
        }
    }

    /// [D] pure: a runner's batch reaches the watch it is for, as the wire's event, and no other.
    #[test]
    fn a_telemetry_frame_reaches_its_watcher_only() {
        let mut r = Relay::default();
        let (s1, h1) = sink(true);
        let (s2, h2) = sink(true);
        let w1 = r.watch("r1", s1);
        let w2 = r.watch("r1", s2);
        assert!(r.heard("r1", frame(w1, 7)).is_empty());
        assert_eq!(saman::lock(&h2).len(), 0, "the other watch heard nothing");
        let got = saman::lock(&h1);
        assert_eq!(got.len(), 1);
        let batch: TelemetryBatch = serde_json::from_value(got[0].clone()).unwrap();
        assert_eq!(
            (batch.watch, batch.runner.as_str(), batch.every_ms),
            (w1, "r1", 50)
        );
        assert_eq!(
            batch.samples[0].values,
            [TelemetryValue {
                metric: "cpu".into(),
                value: 1.5
            }]
        );
        assert_eq!(batch.samples[0].level, "job");
        assert_eq!(batch.markers[0].kind, "admitted");
        assert_ne!(w1, w2);
    }

    /// [D] pure: a frame from another runner under the id of a watch is not that watch's.
    #[test]
    fn a_watch_hears_only_its_own_runner() {
        let mut r = Relay::default();
        let (s, h) = sink(true);
        let w = r.watch("r1", s);
        r.heard("r2", frame(w, 1));
        assert!(saman::lock(&h).is_empty());
    }

    /// [D] pure: a viewer that is gone is unwatched, and its runner is named to be told.
    #[test]
    fn a_viewer_that_is_gone_is_unwatched() {
        let mut r = Relay::default();
        let (s, h) = sink(false);
        let w = r.watch("r1", s);
        assert_eq!(r.heard("r1", frame(w, 1)), [(w, "r1".to_string())]);
        assert!(r.heard("r1", frame(w, 2)).is_empty());
        assert_eq!(saman::lock(&h).len(), 1, "nothing after it went");
        assert_eq!(r.unwatch(w), None);
    }

    /// [D] pure: the history a runner answers wakes the one who asked, with the points as the wire has them.
    #[test]
    fn a_range_answer_wakes_its_waiter() {
        let mut r = Relay::default();
        let (id, mut rx) = r.range("r1");
        assert!(rx.try_recv().is_err());
        r.heard(
            "r1",
            Frame::TelemetryRanged {
                id,
                ranged: Ranged {
                    series: vec![Series {
                        level: Level::Runner,
                        id: "runner".into(),
                        metric: "cpu".into(),
                        points: vec![Point {
                            t: 1,
                            min: 0.5,
                            max: 3.0,
                            mean: 1.0,
                            last: 2.0,
                        }],
                    }],
                    markers: vec![],
                },
            },
        );
        let h = rx.try_recv().unwrap();
        assert_eq!(h.series[0].level, "runner");
        assert_eq!(
            h.series[0].points,
            [TelemetryPoint {
                t: 1,
                min: 0.5,
                max: 3.0,
                mean: 1.0,
                last: 2.0
            }]
        );
    }

    /// [D] pure: a lost link ends its runner's watches and drops its waiters, and no other runner's.
    #[test]
    fn a_lost_runner_ends_its_watches_and_waiters() {
        let mut r = Relay::default();
        let (s1, _) = sink(true);
        let (s2, h2) = sink(true);
        let w1 = r.watch("r1", s1);
        let w2 = r.watch("r2", s2);
        let (_, mut rx1) = r.range("r1");
        let (id2, mut rx2) = r.range("r2");
        let ended = r.lost("r1");
        assert_eq!(ended, [w1]);
        assert!(matches!(
            rx1.try_recv(),
            Err(oneshot::error::TryRecvError::Closed)
        ));
        assert!(matches!(
            rx2.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        r.heard("r2", frame(w2, 1));
        assert_eq!(saman::lock(&h2).len(), 1, "r2's stream goes on");
        r.heard(
            "r2",
            Frame::TelemetryRanged {
                id: id2,
                ranged: Ranged::default(),
            },
        );
        assert!(rx2.try_recv().is_ok());
    }

    /// [D] pure: the samples and markers of a batch keep their values and order through the wire types.
    #[test]
    fn a_batch_keeps_values_and_order() {
        let v = batch_of(
            "r1",
            9,
            20,
            vec![
                Sample {
                    at_ms: 2,
                    level: Level::Slot,
                    id: "s1-0".into(),
                    values: [("mem_mib".to_string(), 64.0), ("cpu".to_string(), 0.25)].into(),
                },
                Sample {
                    at_ms: 3,
                    level: Level::Slot,
                    id: "s1-0".into(),
                    values: Default::default(),
                },
            ],
            vec![Marker {
                at_ms: 2,
                id: "s1-0".into(),
                kind: "evicted".into(),
                detail: "floor".into(),
            }],
        )
        .unwrap();
        let b: TelemetryBatch = serde_json::from_value(v).unwrap();
        assert_eq!(
            b.samples.iter().map(|s| s.at_ms).collect::<Vec<_>>(),
            [2, 3]
        );
        assert_eq!(
            b.samples[0]
                .values
                .iter()
                .map(|v| (v.metric.as_str(), v.value))
                .collect::<Vec<_>>(),
            [("cpu", 0.25), ("mem_mib", 64.0)],
            "a sample's values keep the metric order of the map"
        );
        assert_eq!(
            b.markers,
            [TelemetryMarker {
                at_ms: 2,
                id: "s1-0".into(),
                kind: "evicted".into(),
                detail: "floor".into()
            }]
        );
    }
}
